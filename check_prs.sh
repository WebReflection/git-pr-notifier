#!/usr/bin/env bash
# git-pr-notifier - worker.
# Invoked by cron every 2 minutes (installed by start.sh) and once by start.sh.
# For new open PRs in $REPO authored by any login in $AUTHORS: wait for the "$BOT_CHECK_NAME"
# check to succeed, counter-verify the diff with the local Kilo CLI, run
# heuristic scans for issues the bot did not flag, notify on macOS, and persist
# findings. State lives in ./state/.
set -euo pipefail

export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- Configuration: every value is mandatory and comes from config.env ---
# No defaults here on purpose: real repo/author/model details must not be
# published in this repository. See config.env.example.
REPO=""
AUTHORS=""
BOT_CHECK_NAME=""
RETRY_LIMIT=""
SOUND=""
AI_PROVIDER=""
AI_MODEL_ID=""
AI_VARIANT=""
AI_TIMEOUT=""
AI_CONFIG="$SCRIPT_DIR/kilo-ai.json"

# shellcheck disable=SC1091
if [ -f "$SCRIPT_DIR/config.env" ]; then
  source "$SCRIPT_DIR/config.env"
fi

# Headless (cron) gh auth: the macOS keyring is unreadable outside GUI
# sessions. gh_token.env holds `export GH_TOKEN=...` (chmod 600, gitignored).
# shellcheck disable=SC1091
if [ -f "$SCRIPT_DIR/gh_token.env" ]; then
  source "$SCRIPT_DIR/gh_token.env"
fi

# Normalize AUTHORS (comma-separated GitHub logins) into a JSON array for the
# jq filters below. GitHub logins cannot contain whitespace or commas, so
# stripping all whitespace first is safe and tolerates "a, b" or stray commas.
authors_json="$(printf '%s' "$AUTHORS" | tr -d '[:space:]' | jq -cR 'split(",") | map(select(length > 0))')"

STATE_DIR="$SCRIPT_DIR/state"
STATE_FILE="$STATE_DIR/parsed_prs.json"
RETRY_FILE="$STATE_DIR/retries.json"  # internal: retry counters for undecided PRs
LOCK_DIR="$STATE_DIR/locks/.check.lock"
PID_FILE="$LOCK_DIR/pid"

mkdir -p "$STATE_DIR/locks"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Every knob must come from config.env: fail loudly instead of running
# unattended with empty values.
missing=""
for var in REPO AUTHORS BOT_CHECK_NAME RETRY_LIMIT SOUND AI_PROVIDER AI_MODEL_ID AI_VARIANT AI_TIMEOUT; do
  [ -n "${!var:-}" ] || missing="$missing $var"
done
if [ -n "$missing" ]; then
  log "ERROR: missing required config in config.env (see config.env.example):$missing"
  exit 1
fi
AI_MODEL="$AI_PROVIDER/$AI_MODEL_ID"

# notify <message> [url]: desktop notification. With terminal-notifier
# installed and a url given, clicking the notification opens the url in the
# browser; otherwise falls back to a plain osascript notification.
notify() {
  local msg="$1" url="${2:-}"
  if [ -n "$url" ] && command -v terminal-notifier >/dev/null 2>&1; then
    if terminal-notifier -title "Kilo PR Watcher" -message "$msg" -sound "$SOUND" -group "$url" -open "$url" >/dev/null 2>&1; then
      return
    fi
    log "WARN: terminal-notifier notification failed: $msg (falling back to osascript)"
  fi
  if ! osascript -e "display notification \"$msg\" with title \"Kilo PR Watcher\" sound name \"${SOUND}\"" >/dev/null 2>&1; then
    log "WARN: osascript notification failed: $msg"
  fi
}

count_lines() { printf '%s' "$1" | grep -c . || true; }

# with_timeout <seconds> <cmd...>: run cmd in its own process group; on expiry
# kill the whole group and exit 124 (GNU timeout convention)
with_timeout() {
  local secs="$1"; shift
  perl -e '
    use POSIX qw(WNOHANG);
    my $secs = shift @ARGV;
    defined(my $pid = fork()) or exit 127;
    if ($pid == 0) {
      setpgrp(0, 0);
      exec @ARGV or exit 127;
    }
    $SIG{ALRM} = sub {
      return if waitpid($pid, &WNOHANG) != 0;
      kill "KILL", -$pid;
      waitpid($pid, 0);
      exit 124;
    };
    alarm $secs;
    waitpid($pid, 0);
    my $st = $?;
    exit(($st & 127) ? 128 + ($st & 127) : ($st >> 8));
  ' "$secs" "$@"
}

# --- Lock (mkdir-based; no flock on macOS) ---
LOCK_ACQUIRED=0
if mkdir "$LOCK_DIR" 2>/dev/null; then
  LOCK_ACQUIRED=1
else
  old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    log "check already in flight (pid $old_pid); exiting"
    exit 0
  fi
  log "stale lock detected; removing and retrying"
  rm -rf "$LOCK_DIR"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_ACQUIRED=1
  else
    log "ERROR: failed to acquire lock; exiting"
    exit 1
  fi
fi
printf '%s\n' "$$" > "$PID_FILE"

cleanup() {
  if [ "$LOCK_ACQUIRED" = "1" ]; then
    rm -rf "$LOCK_DIR"
  fi
}
trap cleanup EXIT

# --- Preflight ---
# --- Preflight: gh must reach the API with the effective credential ---
# gh auth status exits 1 under cron because the macOS keyring is unreadable
# there, even when GH_TOKEN (gh_token.env) is valid; validate with a real call.
if ! gh api rate_limit -q .resources.core.remaining >/dev/null 2>&1; then
  log "ERROR: gh API check failed (invalid GH_TOKEN from gh_token.env, or no network); full error follows:"
  gh api rate_limit 2>&1 | while IFS= read -r line; do log "  | $line"; done
  exit 1
fi

# --- Fetch all open PRs (one paginated call chain per run) ---
log "fetching open PRs from $REPO"
prs="$(gh api --paginate "repos/$REPO/pulls?state=open&per_page=100" | jq -s 'add // [] | map({number, author: {login: (.user.login // "")}, isDraft: (.draft // false)})')"
log "fetched $(jq 'length' <<<"$prs") open PRs"

# --- Load state (missing/empty/corrupt -> {}) ---
state="{}"
if [ -s "$STATE_FILE" ] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
  state="$(cat "$STATE_FILE")"
fi
retries="{}"
if [ -s "$RETRY_FILE" ] && jq -e . "$RETRY_FILE" >/dev/null 2>&1; then
  retries="$(cat "$RETRY_FILE")"
fi

# Work copy so jq can read state without huge argv (--slurpfile).
tmp_state="$STATE_DIR/.state.work.json"
printf '%s' "$state" > "$tmp_state"

record() {
  # record <number> <author> <decision> <findings_file_json_literal> <retries>
  local number="$1" author="$2" decision="$3" findings_file="$4" r="$5"
  state="$(jq --arg n "$number" --arg a "$author" --arg d "$decision" \
             --arg ts "$(now_iso)" --argjson ff "$findings_file" --argjson r "$r" \
             '.[$n] = {author: $a, decision: $d,
                      recorded_at: $ts, findings_file: $ff, retries: $r}' <<<"$state")"
  log "recorded PR #$number: decision=$decision"
}

bump_retry() {
  # bump_retry <number> <kind> -> increments counter; new count in BUMP_RESULT
  local number="$1" kind="$2" r
  r="$(jq -n --argjson retries "$retries" --arg n "$number" '($retries[$n].retries // 0)')"
  r=$((r + 1))
  retries="$(jq -n --argjson retries "$retries" --arg n "$number" --argjson r "$r" --arg k "$kind" \
             '($retries | .[$n] = {retries: $r, kind: $k})')"
  BUMP_RESULT="$r"
}

clear_retry() {
  retries="$(jq -n --argjson retries "$retries" --arg n "$1" '($retries | del(.[$n]))')"
}

# --- Batch-record all unknown non-watched PRs as "ignored" (no extra API calls) ---
before_len="$(jq 'length' <<<"$state")"
state="$(jq --slurpfile S "$tmp_state" --arg ts "$(now_iso)" --argjson authors "$authors_json" '
  reduce (.[] | . as $it | (($it.author.login // "") as $login
           | select(($authors | index($login)) | not))
          | select(($S[0] | has($it.number | tostring)) | not)) as $pr ($S[0];
    . + {($pr.number | tostring): {author: ($pr.author.login // ""),
         decision: "ignored", recorded_at: $ts, findings_file: null, retries: 0}})
' <<<"$prs")"
after_len="$(jq 'length' <<<"$state")"
log "recorded $((after_len - before_len)) non-watched PRs as ignored"

# --- Watched-author PRs not yet decided ---
authors_unknown="$(jq -c --slurpfile S "$tmp_state" --argjson authors "$authors_json" '
  [.[] | . as $pr | (($pr.author.login // "") as $login
    | select(($authors | index($login)) != null))
   | select(($S[0] | has($pr.number | tostring)) | not)]
' <<<"$prs")"
log "watching authors: $AUTHORS"
log "new PRs by watched authors to check: $(jq 'length' <<<"$authors_unknown")"

while IFS= read -r pr; do
  [ -n "$pr" ] || continue
  number="$(jq -r '.number' <<<"$pr")"
  pr_author="$(jq -r '.author.login // ""' <<<"$pr")"

  # Drafts: bot check does not run on drafts; leave unknown (no retry budget).
  if [ "$(jq -r '.isDraft // false' <<<"$pr")" = "true" ]; then
    log "PR #$number is a draft; leaving untracked until out of draft"
    continue
  fi

  if ! detail="$(gh pr view "$number" -R "$REPO" --json statusCheckRollup,reviews,mergeable,mergeStateStatus,files,state,reviewDecision 2>/dev/null)"; then
    log "WARN: could not fetch details for PR #$number; retrying next cycle"
    continue
  fi

  # --- Already approved or merged/closed: nothing to notify; record as ignored ---
  pr_state="$(jq -r '.state // ""' <<<"$detail")"
  review_decision="$(jq -r '.reviewDecision // ""' <<<"$detail")"
  if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ] || [ "$review_decision" = "APPROVED" ]; then
    record "$number" "$pr_author" "ignored" "null" 0
    clear_retry "$number"
    log "PR #$number: state=$pr_state reviewDecision=$review_decision; recorded as ignored"
    continue
  fi

  check_json="$(jq -c --arg name "$BOT_CHECK_NAME" \
    '(.statusCheckRollup // []) | map(select(.name? == $name)) | .[0] // empty' <<<"$detail")"

  # --- Bot check missing / not completed: wait, with a safety cap ---
  if [ -z "$check_json" ] || [ "$(jq -r '.status // ""' <<<"$check_json")" != "COMPLETED" ]; then
    bump_retry "$number" "no-bot-check"
    if [ "$BUMP_RESULT" -ge "$RETRY_LIMIT" ]; then
      log "PR #$number: no completed bot check after $BUMP_RESULT cycles -> no-bot-check"
      notify "PR #$number needs attention: no completed bot check after $BUMP_RESULT cycles" "https://github.com/$REPO/pull/$number"
      record "$number" "$pr_author" "no-bot-check" "null" "$BUMP_RESULT"
      clear_retry "$number"
    else
      log "PR #$number: bot check not completed yet; waiting (cycle $BUMP_RESULT/$RETRY_LIMIT)"
    fi
    continue
  fi

  conclusion="$(jq -r '.conclusion // ""' <<<"$check_json")"

  # --- Bot check completed but not SUCCESS: retry up to RETRY_LIMIT, then report ---
  if [ "$conclusion" != "SUCCESS" ]; then
    bump_retry "$number" "bot-failed"
    if [ "$BUMP_RESULT" -ge "$RETRY_LIMIT" ]; then
      {
        echo "# PR #$number - bot check failed"
        echo
        echo "\`$BOT_CHECK_NAME\` did not succeed after $BUMP_RESULT retry cycles."
        echo
        echo "- Final status: $(jq -r '.status // ""' <<<"$check_json") / $conclusion"
        echo "- Bot review report: $(jq -r '.detailsUrl // ""' <<<"$check_json")"
        echo "- Generated: $(now_iso)"
      } > "$SCRIPT_DIR/PR${number}.md"
      log "PR #$number: bot check $conclusion after $BUMP_RESULT cycles -> bot-failed (see PR${number}.md)"
      notify "PR #$number needs attention: bot check $conclusion" "https://github.com/$REPO/pull/$number"
      record "$number" "$pr_author" "bot-failed" "\"PR${number}.md\"" "$BUMP_RESULT"
      clear_retry "$number"
    else
      log "PR #$number: bot check $conclusion; retrying (cycle $BUMP_RESULT/$RETRY_LIMIT)"
    fi
    continue
  fi

  # --- Bot check OK: heuristic scan for issues the bot did not flag ---
  findings_file="null"
  notify_msg="PR #$number is ready for review"
  out_file="$SCRIPT_DIR/PR${number}.md"

  failing_checks="$(jq -r '
    [ (.statusCheckRollup // [])[]
      | select(((.status == "COMPLETED") and
                (.conclusion == "FAILURE" or .conclusion == "TIMED_OUT" or
                 .conclusion == "ACTION_REQUIRED" or .conclusion == "CANCELLED" or
                 .conclusion == "STARTUP_FAILURE"))
               or (.state == "FAILURE"))
      | if has("name") then "- \(.name) (\(.conclusion // .state))"
        else "- \(.context) (\(.state))" end
    ] | join("\n")' <<<"$detail")"

  mergeable="$(jq -r '.mergeable // ""' <<<"$detail")"
  merge_state="$(jq -r '.mergeStateStatus // ""' <<<"$detail")"
  conflict_reason=""
  if [ "$mergeable" = "CONFLICTING" ] && [ "$merge_state" = "DIRTY" ]; then
    conflict_reason="mergeable = CONFLICTING; mergeStateStatus = DIRTY"
  elif [ "$mergeable" = "CONFLICTING" ]; then
    conflict_reason="mergeable = CONFLICTING"
  elif [ "$merge_state" = "DIRTY" ]; then
    conflict_reason="mergeStateStatus = DIRTY"
  fi

  changes_requested="$(jq -r '
    [ (.reviews // [])[] | select(.author != null) ]
    | sort_by(.submittedAt)
    | group_by(.author.login)
    | map(.[-1])
    | map(select(.state == "CHANGES_REQUESTED") | "- @" + .author.login)
    | unique
    | join("\n")' <<<"$detail")"

  findings_count=0
  sections=""
  if [ -n "$failing_checks" ]; then
    findings_count=$((findings_count + $(count_lines "$failing_checks")))
    sections+="## Failing CI checks"$'\n\n'"$failing_checks"$'\n\n'
  fi
  if [ -n "$conflict_reason" ]; then
    findings_count=$((findings_count + 1))
    sections+="## Merge conflict"$'\n\n'"- $conflict_reason"$'\n\n'
  fi
  if [ -n "$changes_requested" ]; then
    findings_count=$((findings_count + $(count_lines "$changes_requested")))
    sections+="## Changes requested"$'\n\n'"$changes_requested"$'\n\n'
  fi

  # --- AI counter-check: verify the diff with the local Kilo CLI ---
  ai_status="skipped"
  ai_text=""
  ai_reason=""
  ai_detail=""
  ai_note="skipped (no diff)"
  ai_diff="$(mktemp "${TMPDIR:-/tmp}/pr${number}.diff.XXXXXX")"
  ai_out="$(mktemp "${TMPDIR:-/tmp}/pr${number}.ai.XXXXXX")"
  ai_err="$(mktemp "${TMPDIR:-/tmp}/pr${number}.aierr.XXXXXX")"
  if ! gh pr diff "$number" -R "$REPO" > "$ai_diff" 2>/dev/null; then
    ai_status="failed"
    ai_reason="could not fetch PR diff (gh pr diff failed)"
  elif [ ! -s "$ai_diff" ]; then
    log "PR #$number: diff is empty; skipping AI counter-check"
  else
    if ! bunx @kilocode/cli --version >/dev/null 2>&1; then
      ai_status="failed"
      ai_reason="sanity check failed: bunx @kilocode/cli is not runnable"
    elif ! bunx @kilocode/cli models "$AI_PROVIDER" 2>/dev/null | grep -qF "$AI_MODEL_ID"; then
      ai_status="failed"
      ai_reason="sanity check failed: model $AI_MODEL_ID not resolvable via kilo models"
    else
      [ -f "$AI_CONFIG" ] || printf '%s\n' \
        '{"$schema":"https://app.kilo.ai/config.json","sandbox":{"enabled":false}}' > "$AI_CONFIG"
      pr_title="$(jq -r '.title // ""' <<<"$detail")"
      ai_prompt="Counter-verify pull request #${number} titled \"${pr_title}\" in repository ${REPO}. The complete PR diff is attached to this message. Verify that the changes are sound and check for anything problematic or overlooked: bugs, security issues, broken functionality, regressions, missing edge cases, unintended behavior changes. Ignore pure style preferences. If the changes are sound and nothing is problematic or overlooked, reply with a single line containing exactly: OK. Otherwise reply with ISSUES on the first line, followed by a concise markdown summary of each real problem with a file/line reference. You may run read-only commands such as gh pr view or gh api for extra context if needed."
      log "PR #$number: running AI counter-check with $AI_MODEL (reasoning: $AI_VARIANT)"
      with_timeout "$AI_TIMEOUT" env KILO_CONFIG="$AI_CONFIG" bunx @kilocode/cli run \
        "$ai_prompt" \
        -m "$AI_MODEL" --variant "$AI_VARIANT" --auto --format json \
        --title "PR #${number} counter-check" \
        -f "$ai_diff" > "$ai_out" 2> "$ai_err" &
      ai_pid=$!
      wait "$ai_pid" && AI_RC=0 || AI_RC=$?
      AI_TEXT="$(jq -rs '[.[] | select(.type=="text") | .part.text] | join("\n")' "$ai_out" 2>/dev/null)" || AI_TEXT=""
      ai_detail="$(tail -n 8 "$ai_err" 2>/dev/null || true)"
      if [ "$AI_RC" = "124" ]; then
        ai_status="failed"
        ai_reason="kilo run timed out after ${AI_TIMEOUT}s"
      elif [ "$AI_RC" != "0" ]; then
        ai_status="failed"
        ai_reason="kilo run exited with code $AI_RC"
      elif [ -z "$AI_TEXT" ]; then
        ai_status="failed"
        ai_reason="kilo run produced no assistant output"
      else
        ai_verdict=""
        while IFS= read -r ai_line; do
          ai_up="$(printf '%s' "$ai_line" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
          case "$ai_up" in
            OK|OK.|OK:|OK!) ai_verdict="ok"; break ;;
            ISSUES*) ai_verdict="issues"; break ;;
          esac
        done <<<"$AI_TEXT"
        case "$ai_verdict" in
          ok) ai_status="ok"; ai_note="OK" ;;
          issues)
            ai_status="issues"
            ai_text="$AI_TEXT"
            ai_note="issues found (see below)"
            ;;
          *)
            ai_status="failed"
            ai_reason="unexpected AI reply format (no OK/ISSUES verdict line)"
            ;;
        esac
      fi
    fi
  fi
  rm -f "$ai_diff" "$ai_out" "$ai_err"

  if [ "$ai_status" = "failed" ]; then
    bump_retry "$number" "ai-failed"
    if [ "$BUMP_RESULT" -ge "$RETRY_LIMIT" ]; then
      {
        echo "# PR #$number - AI counter-check failed"
        echo
        echo "_This is an AI/tooling failure, **not** a verdict on the PR. Bot check \`$BOT_CHECK_NAME\`: SUCCESS. Scanned: $(now_iso)._"
        echo
        echo "- Model: \`$AI_MODEL\` (reasoning: $AI_VARIANT)"
        echo "- Reason: $ai_reason"
        if [ -n "$ai_detail" ]; then
          echo "- Last CLI output:"
          echo
          echo '```'
          printf '%s\n' "$ai_detail"
          echo '```'
        fi
        printf '%s' "$sections"
        echo "---"
        echo
        echo "_Bot review report: $(jq -r '.detailsUrl // ""' <<<"$check_json")_"
      } > "$out_file"
      log "PR #$number: AI counter-check failed after $BUMP_RESULT cycles -> ai-failed (see PR${number}.md)"
      notify "PR #$number needs attention: AI counter-check failed (AI issue, not a PR problem)" "https://github.com/$REPO/pull/$number"
      record "$number" "$pr_author" "ai-failed" "\"PR${number}.md\"" "$BUMP_RESULT"
      clear_retry "$number"
    else
      log "PR #$number: AI counter-check failed ($ai_reason); retrying (cycle $BUMP_RESULT/$RETRY_LIMIT)"
    fi
    continue
  fi

  if [ "$ai_status" = "issues" ]; then
    findings_count=$((findings_count + 1))
    sections+="## AI counter-check findings"$'\n\n'"$ai_text"$'\n\n'
  fi

  if [ "$findings_count" -gt 0 ]; then
    {
      echo "# PR #$number - findings"
      echo
      echo "_Bot check \`$BOT_CHECK_NAME\`: SUCCESS. AI counter-check: $ai_note. Scanned: $(now_iso)._"
      echo
      printf '%s' "$sections"
      echo "---"
      echo
      echo "_Bot review report: $(jq -r '.detailsUrl // ""' <<<"$check_json")_"
    } > "$out_file"
    findings_file="\"PR${number}.md\""
    notify_msg="PR #$number is ready for review - $findings_count findings, see PR${number}.md"
  else
    rm -f "$out_file"
  fi

  log "PR #$number: bot check OK; AI counter-check: $ai_status; $findings_count finding(s)"
  notify "$notify_msg" "https://github.com/$REPO/pull/$number"
  record "$number" "$pr_author" "ready" "$findings_file" 0
done < <(jq -c '.[]' <<<"$authors_unknown")

# --- Persist state atomically ---
jq . <<<"$state" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
jq . <<<"$retries" > "$RETRY_FILE.tmp" && mv "$RETRY_FILE.tmp" "$RETRY_FILE"
log "state persisted: $(jq 'length' <<<"$state") PRs tracked, $(jq 'length' <<<"$retries") awaiting retry"
log "done"
