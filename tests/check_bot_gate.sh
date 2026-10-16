#!/usr/bin/env bash
# Run with: bash tests/check_bot_gate.sh
# Exercise a temporary copy of the worker, never the checkout's config or state.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/check-bot-gate.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$ROOT/check_prs.sh" "$TEST_ROOT/check_prs.sh"

HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OTHER_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
CLEAN_BODY=$'<!-- kilo-review -->\n**Status:** No Issues Found | **Recommendation:** Merge'
WARNING_BODY=$'<!-- kilo-review -->\n**Status:** 1 Issue Found | **Recommendation:** Address before merge\n| Severity | Count |\n| WARNING | 1 |\n| SUGGESTION | 0 |'
SUGGESTION_BODY=$'<!-- kilo-review -->\n**Status:** 1 Issue Found | **Recommendation:** Address before merge\n| Severity | Count |\n| WARNING | 0 |\n| SUGGESTION | 1 |'
TOTAL=0
FAILED=0

mock_reject() {
  printf 'unexpected command:' >> "$TEST_CASE_DIR/forbidden.log"
  printf ' %q' "$@" >> "$TEST_CASE_DIR/forbidden.log"
  printf '\n' >> "$TEST_CASE_DIR/forbidden.log"
  return 97
}

mock_response() {
  local kind="$1" phase=before fixture
  [ ! -f "$TEST_CASE_DIR/diff-fetched" ] || phase=after
  printf '%s:%s:%s\n' "$TEST_CYCLE" "$phase" "$kind" >> "$TEST_CASE_DIR/calls.log"
  fixture="$TEST_CASE_DIR/fixtures/$phase/$kind.json"
  [ -f "$fixture" ] || fixture="$TEST_CASE_DIR/fixtures/before/$kind.json"
  if [ ! -f "$fixture" ]; then
    mock_reject "missing fixture: $kind ($phase)"
    return 97
  fi
  command cat "$fixture"
  # A nonzero gh exit must fail closed even with otherwise valid JSON on stdout.
  if [ -f "$TEST_CASE_DIR/fixtures/$phase/$kind.fail" ]; then
    printf 'synthetic GitHub failure\n' >&2
    return 42
  fi
}

gh() {
  local endpoint="" paginated=0 canonical_bot=0 owner=0 name=0 number=0 arg
  case "${1:-} ${2:-}" in
    'pr view')
      if [ "$#" -ne 7 ] || [ "$3" != 17 ] || [ "$4" != -R ] ||
          [ "$5" != example/project ] || [ "$6" != --json ]; then
        mock_reject gh "$@"
        return 97
      fi
      mock_response detail
      ;;
    'pr diff')
      if [ "$#" -ne 5 ] || [ "$3" != 17 ] || [ "$4" != -R ] || [ "$5" != example/project ]; then
        mock_reject gh "$@"
        return 97
      fi
      printf '%s:before:diff\n' "$TEST_CYCLE" >> "$TEST_CASE_DIR/calls.log"
      : > "$TEST_CASE_DIR/diff-fetched"
      # Empty diff: there is deliberately no model invocation in any test.
      ;;
    api\ *)
      for arg in "$@"; do
        case "$arg" in
          --paginate) paginated=1 ;;
          rate_limit|graphql|repos/*) endpoint="$arg" ;;
          'bot=review-bot[bot]') canonical_bot=1 ;;
          owner=example) owner=1 ;;
          name=project) name=1 ;;
          number=17) number=1 ;;
        esac
      done
      case "$endpoint" in
        rate_limit) printf '5000\n' ;;
        'repos/example/project/pulls?state=open&per_page=100')
          [ "$paginated" = 1 ] || { mock_reject gh "$@"; return 97; }
          mock_response pulls
          ;;
        repos/example/project/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/check-runs)
          [ "$paginated" = 1 ] || { mock_reject gh "$@"; return 97; }
          mock_response checks
          ;;
        'repos/example/project/issues/17/comments?per_page=100')
          [ "$paginated" = 1 ] || { mock_reject gh "$@"; return 97; }
          mock_response comments
          ;;
        graphql)
          # GraphQL author: needs the canonical suffix, unlike returned logins.
          if [ "$paginated" != 1 ] || [ "$canonical_bot" != 1 ] ||
              [ "$owner" != 1 ] || [ "$name" != 1 ] || [ "$number" != 1 ]; then
            mock_reject gh "$@"
            return 97
          fi
          mock_response graphql
          ;;
        *) mock_reject gh "$@" ;;
      esac
      ;;
    *) mock_reject gh "$@" ;;
  esac
}

mock_notification() {
  local channel="$1"
  shift
  jq -cn --arg channel "$channel" --args \
    '{channel: $channel, args: $ARGS.positional}' -- "$@" >> "$TEST_CASE_DIR/notifications.jsonl"
}
terminal-notifier() { mock_notification terminal-notifier "$@"; }
osascript() { mock_notification osascript "$@"; }
bunx() { mock_reject bunx "$@"; }

# Functions outrank the worker's real PATH prepending, including on macOS.
export -f gh terminal-notifier osascript bunx mock_reject mock_response mock_notification

start_case() {
  TOTAL=$((TOTAL + 1))
  CASE_NAME="$1"
  CASE_FAILED=0
  CYCLE=0
  CASE_DIR="$TEST_ROOT/$TOTAL"
  WORKER="$CASE_DIR/worker"
  mkdir -p "$WORKER" "$CASE_DIR/fixtures/before" "$CASE_DIR/fixtures/after" "$CASE_DIR/home" "$CASE_DIR/tmp"
  cp "$TEST_ROOT/check_prs.sh" "$WORKER/check_prs.sh"
  printf '%s\n' \
    'REPO="example/project"' 'AUTHORS="alice"' 'BOT_CHECK_NAME="Review Bot"' \
    'RETRY_LIMIT=1' 'SOUND="default"' 'AI_PROVIDER="test-provider"' \
    'AI_MODEL_ID="test-model"' 'AI_VARIANT="test"' 'AI_TIMEOUT=1' > "$WORKER/config.env"
  : > "$CASE_DIR/notifications.jsonl"
  : > "$CASE_DIR/forbidden.log"
  : > "$CASE_DIR/calls.log"
  jq -n '[{number: 17, user: {login: "alice"}, draft: false}]' > "$CASE_DIR/fixtures/before/pulls.json"
  jq -n --arg head "$HEAD" '{
    headRefOid: $head, title: "Synthetic PR", state: "OPEN", reviewDecision: "REVIEW_REQUIRED",
    mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", files: [], reviews: [],
    statusCheckRollup: [{name: "Review Bot", status: "COMPLETED", conclusion: "SUCCESS"}]
  }' > "$CASE_DIR/fixtures/before/detail.json"
  jq -n --arg head "$HEAD" '{check_runs: [{
    id: 101, name: "Review Bot", head_sha: $head, status: "completed", conclusion: "success",
    app: {id: 42, slug: "review-bot"}, completed_at: "2026-10-16T12:00:00Z",
    output: {annotations_count: 0}, details_url: "https://github.com/example/project/actions/runs/101"
  }]}' > "$CASE_DIR/fixtures/before/checks.json"
  jq -n --arg body "$CLEAN_BODY" '[{
    id: 201, user: {login: "review-bot[bot]", type: "Bot"}, performed_via_github_app: {id: 42},
    body: $body, updated_at: "2026-10-16T12:00:01Z"
  }]' > "$CASE_DIR/fixtures/before/comments.json"
  jq -n --arg head "$HEAD" '{data: {repository: {pullRequest: {
    headRefOid: $head, state: "OPEN", isDraft: false, reviewDecision: "REVIEW_REQUIRED",
    reviews: {nodes: []}, reviewThreads: {nodes: [], pageInfo: {hasNextPage: false, endCursor: null}}
  }}}}' > "$CASE_DIR/fixtures/before/graphql.json"
}

edit_fixture() {
  local phase="$1" kind="$2" filter="$3" file
  shift 3
  file="$CASE_DIR/fixtures/$phase/$kind.json"
  [ -f "$file" ] || cp "$CASE_DIR/fixtures/before/$kind.json" "$file"
  jq "$@" "$filter" "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

edit_pr() {
  local phase="$1" filter="$2"
  shift 2
  edit_fixture "$phase" graphql ".data.repository.pullRequest |= ($filter)" "$@"
}

paginate_fixture() {
  local kind="$1" first="$2" second="$3" file
  file="$CASE_DIR/fixtures/before/$kind.json"
  # gh --paginate emits separate response documents, not one merged response.
  jq -c "$first" "$file" > "$file.tmp"
  jq -c "$second" "$file" >> "$file.tmp"
  mv "$file.tmp" "$file"
}

run_worker() {
  CYCLE=$((CYCLE + 1))
  rm -f "$CASE_DIR/diff-fetched"
  WORKER_RC=0
  HOME="$CASE_DIR/home" TMPDIR="$CASE_DIR/tmp" GH_CONFIG_DIR="$CASE_DIR/home/gh" \
    GH_TOKEN=synthetic GITHUB_TOKEN=synthetic TEST_CASE_DIR="$CASE_DIR" TEST_CYCLE="$CYCLE" \
    /bin/bash "$WORKER/check_prs.sh" > "$CASE_DIR/worker.$CYCLE.log" 2>&1 || WORKER_RC=$?
}

fail() {
  printf '  FAIL %s: %s\n' "$CASE_NAME" "$*" >&2
  CASE_FAILED=1
}

assert_json() {
  local label="$1" filter="$2" file="$3"
  shift 3
  if ! jq -e "$@" "$filter" "$file" >/dev/null 2>&1; then
    fail "$label"
  fi
}

assert_calls() {
  local phase="$1" kind="$2" count="$3"
  assert_json "expected $count $phase $kind call(s) in cycle $CYCLE" \
    'split("\n") | map(select(. == $call)) | length == $count' "$CASE_DIR/calls.log" \
    -Rs --arg call "$CYCLE:$phase:$kind" --argjson count "$count"
}

assert_common() {
  [ "$WORKER_RC" = 0 ] || fail "worker exit was $WORKER_RC, expected 0"
  [ ! -s "$CASE_DIR/forbidden.log" ] || fail 'an unknown gh, model, or other forbidden call occurred'
  [ ! -e "$WORKER/state/locks/.check.lock" ] || fail 'worker lock was not cleaned up'
  [ ! -e "$WORKER/PR17.md" ] || fail 'unexpected generated findings report'
  [ ! -e "$WORKER/kilo-ai.json" ] || fail 'unexpected AI configuration generation'
  assert_json 'retry budget must remain empty' '. == {}' "$WORKER/state/retries.json"
}

assert_blocked() {
  assert_common
  assert_json 'blocked PR must not be recorded or permanently ignored' '. == {}' "$WORKER/state/parsed_prs.json"
  assert_json 'blocked PR must produce no notification of any kind' 'length == 0' "$CASE_DIR/notifications.jsonl" -s
}

assert_ready() {
  assert_common
  assert_json 'clean PR must be recorded ready without findings or retries' '
    keys == ["17"] and .["17"].author == "alice" and .["17"].decision == "ready"
    and .["17"].findings_file == null and .["17"].retries == 0
    and (.["17"].recorded_at | type == "string" and length > 0)
  ' "$WORKER/state/parsed_prs.json"
  assert_json 'exactly one ready notification must target the synthetic PR' '
    length == 1 and .[0].channel == "terminal-notifier"
    and any(.[0].args[]; contains("PR #17 is ready for review"))
    and (.[0].args | index("https://github.com/example/project/pull/17")) != null
  ' "$CASE_DIR/notifications.jsonl" -s
}

assert_clean_gate_rechecked() {
  assert_calls before diff 1
  for kind in checks comments graphql; do
    assert_calls before "$kind" 1
    assert_calls after "$kind" 1
  done
}

finish_case() {
  if [ "$CASE_FAILED" = 0 ]; then
    printf 'ok %s - %s\n' "$TOTAL" "$CASE_NAME"
  else
    FAILED=$((FAILED + 1))
    printf 'not ok %s - %s\n' "$TOTAL" "$CASE_NAME"
    for diagnostic in "$CASE_DIR"/worker.*.log "$CASE_DIR/forbidden.log" "$CASE_DIR/notifications.jsonl" \
        "$WORKER/state/parsed_prs.json" "$WORKER/state/retries.json"; do
      [ ! -f "$diagnostic" ] || { printf '  %s\n' "${diagnostic#"$CASE_DIR"/}"; command cat "$diagnostic"; }
    done
  fi
}

for scenario in \
    no-check newest-queued newest-in-progress failed-check skipped-check annotations wrong-head \
    missing-summary stale-summary foreign-summary-author foreign-summary-app human-summary unmarked-summary \
    unknown-summary history-only-clean-summary warning-summary suggestion-summary \
    clean-status-current-warning clean-status-current-suggestion latest-summary-reports-findings \
    commented-review-body changes-requested pending-review unresolved-bot-thread outdated-bot-thread \
    bot-reply-in-human-thread incomplete-thread-comments incomplete-thread-pages \
    checks-second-page-blocker comments-second-page-blocker threads-second-page-blocker \
    checks-api-failure comments-api-failure graphql-api-failure graphql-errors graphql-errors-only \
    graphql-empty-response graphql-second-page-errors; do
  start_case "$scenario"
  case "$scenario" in
    no-check) edit_fixture before checks '.check_runs = []' ;;
    newest-queued)
      edit_fixture before checks '.check_runs = [(.check_runs[0] | .id = 102 | .status = "queued" | .conclusion = null | .completed_at = null), .check_runs[0]]'
      ;;
    newest-in-progress)
      edit_fixture before checks '.check_runs += [(.check_runs[0] | .id = 102 | .status = "in_progress" | .conclusion = null | .completed_at = null)]'
      ;;
    failed-check) edit_fixture before checks '.check_runs[0].conclusion = "failure"' ;;
    skipped-check) edit_fixture before checks '.check_runs[0].conclusion = "skipped"' ;;
    annotations) edit_fixture before checks '.check_runs[0].output.annotations_count = 1' ;;
    wrong-head) edit_fixture before checks '.check_runs[0].head_sha = $head' --arg head "$OTHER_HEAD" ;;
    missing-summary) edit_fixture before comments '. = []' ;;
    stale-summary) edit_fixture before comments '.[0].updated_at = "2026-10-16T11:59:59Z"' ;;
    foreign-summary-author) edit_fixture before comments '.[0].user.login = "other-bot[bot]"' ;;
    foreign-summary-app) edit_fixture before comments '.[0].performed_via_github_app.id = 99' ;;
    human-summary) edit_fixture before comments '.[0].user.type = "User"' ;;
    unmarked-summary) edit_fixture before comments '.[0].body = "**Status:** No Issues Found | **Recommendation:** Merge"' ;;
    unknown-summary)
      edit_fixture before comments '.[0].body = "<!-- kilo-review -->\n**Status:** Unknown | **Recommendation:** Unknown"'
      ;;
    history-only-clean-summary)
      edit_fixture before comments '.[0].body = "<!-- kilo-review -->\nReview in progress.\n<!-- kilo-review-history -->\n**Status:** No Issues Found | **Recommendation:** Merge"'
      ;;
    warning-summary) edit_fixture before comments '.[0].body = $body' --arg body "$WARNING_BODY" ;;
    suggestion-summary) edit_fixture before comments '.[0].body = $body' --arg body "$SUGGESTION_BODY" ;;
    clean-status-current-warning)
      edit_fixture before comments '.[0].body += "\n| Severity | Count |\n| --- | --- |\n| WARNING | 1 |\n| SUGGESTION | 0 |"'
      ;;
    clean-status-current-suggestion)
      edit_fixture before comments '.[0].body += "\n| Severity | Count |\n| --- | --- |\n| WARNING | 0 |\n| SUGGESTION | 1 |"'
      ;;
    latest-summary-reports-findings)
      edit_fixture before comments '. += [(.[0] | .id = 202 | .updated_at = "2026-10-16T12:00:02Z" | .body = $body)]' --arg body "$WARNING_BODY"
      ;;
    commented-review-body)
      edit_pr before '.reviews.nodes = [{state: "COMMENTED", body: "**[WARNING]:** Synthetic feedback", commit: {oid: .headRefOid}}]'
      ;;
    changes-requested)
      edit_pr before '.reviews.nodes = [{state: "CHANGES_REQUESTED", body: "", commit: {oid: .headRefOid}}]'
      ;;
    pending-review)
      edit_pr before '.reviews.nodes = [{state: "PENDING", body: "", commit: {oid: .headRefOid}}]'
      ;;
    unresolved-bot-thread|outdated-bot-thread)
      edit_pr before '.reviewThreads.nodes = [{isResolved: false, isOutdated: $outdated,
        comments: {nodes: [{author: {login: "review-bot[bot]"}}], pageInfo: {hasNextPage: false}}}]' \
        --argjson outdated "$([ "$scenario" != outdated-bot-thread ] && printf false || printf true)"
      ;;
    bot-reply-in-human-thread)
      edit_pr before '.reviewThreads.nodes = [{isResolved: false, comments: {
        nodes: [{author: {login: "bob"}}, {author: {login: "review-bot"}}], pageInfo: {hasNextPage: false}}}]'
      ;;
    incomplete-thread-comments)
      edit_pr before '.reviewThreads.nodes = [{isResolved: false, comments: {
        nodes: [{author: {login: "bob"}}], pageInfo: {hasNextPage: true}}}]'
      ;;
    incomplete-thread-pages) edit_pr before '.reviewThreads.pageInfo = {hasNextPage: true, endCursor: "next"}' ;;
    checks-second-page-blocker)
      paginate_fixture checks '.' '.check_runs[0] |= (.id = 102 | .status = "queued" | .conclusion = null | .completed_at = null)'
      ;;
    comments-second-page-blocker)
      edit_fixture before comments '.[0].body = $body' --arg body "$WARNING_BODY"
      paginate_fixture comments 'map(.body = "<!-- kilo-review -->\n**Status:** No Issues Found | **Recommendation:** Merge")' \
        'map(.id = 202 | .updated_at = "2026-10-16T12:00:02Z")'
      ;;
    threads-second-page-blocker)
      paginate_fixture graphql '.data.repository.pullRequest.reviewThreads.pageInfo = {hasNextPage: true, endCursor: "next"}' \
        '.data.repository.pullRequest.reviewThreads.nodes = [{isResolved: false, comments: {
          nodes: [{author: {login: "review-bot"}}], pageInfo: {hasNextPage: false}}}]'
      ;;
    checks-api-failure) : > "$CASE_DIR/fixtures/before/checks.fail" ;;
    comments-api-failure) : > "$CASE_DIR/fixtures/before/comments.fail" ;;
    graphql-api-failure) : > "$CASE_DIR/fixtures/before/graphql.fail" ;;
    graphql-errors) edit_fixture before graphql '.errors = [{message: "Synthetic GraphQL failure"}]' ;;
    graphql-errors-only) edit_fixture before graphql '. = {data: null, errors: [{message: "Synthetic GraphQL failure"}]}' ;;
    graphql-empty-response) : > "$CASE_DIR/fixtures/before/graphql.json" ;;
    graphql-second-page-errors)
      paginate_fixture graphql '.data.repository.pullRequest.reviewThreads.pageInfo = {hasNextPage: true, endCursor: "next"}' \
        '.errors = [{message: "Synthetic second-page failure"}]'
      ;;
  esac
  run_worker
  assert_blocked
  assert_calls before checks 1
  assert_calls before diff 0
  finish_case
done

for scenario in clean-without-bot-review clean-with-historical-findings empty-commented-review resolved-bot-threads unrelated-human-threads \
    checks-paginated-clean comments-paginated-clean threads-paginated-clean; do
  start_case "$scenario"
  case "$scenario" in
    clean-with-historical-findings)
      edit_fixture before comments '.[0].body += "\n<!-- kilo-review-history -->\n**Status:** 1 Issue Found | **Recommendation:** Address before merge\n| WARNING | 1 |\n| SUGGESTION | 1 |"'
      ;;
    empty-commented-review)
      edit_pr before '.reviews.nodes = [{state: "COMMENTED", body: " \n", commit: {oid: .headRefOid}}]'
      ;;
    resolved-bot-threads)
      edit_pr before '.reviewThreads.nodes = [{isResolved: true, comments: {
        nodes: [{author: {login: "review-bot"}}], pageInfo: {hasNextPage: false}}}]'
      ;;
    unrelated-human-threads)
      edit_pr before '.reviewThreads.nodes = [{isResolved: false, comments: {
        nodes: [{author: {login: "bob"}}], pageInfo: {hasNextPage: false}}}]'
      ;;
    checks-paginated-clean)
      paginate_fixture checks '.check_runs[0].id = 102' '.check_runs[0].conclusion = "failure"'
      ;;
    comments-paginated-clean) paginate_fixture comments '[]' '.' ;;
    threads-paginated-clean)
      paginate_fixture graphql '.data.repository.pullRequest.reviewThreads.pageInfo = {hasNextPage: true, endCursor: "next"}' \
        '.data.repository.pullRequest.reviewThreads.nodes = [{isResolved: true, comments: {
          nodes: [{author: {login: "review-bot"}}], pageInfo: {hasNextPage: false}}}]'
      ;;
  esac
  run_worker
  assert_ready
  assert_clean_gate_rechecked
  finish_case
done

for scenario in head-changes-after-diff check-pending-after-diff review-pending-after-diff \
    changes-requested-after-diff commented-feedback-after-diff summary-warning-after-diff \
    inline-feedback-after-diff graphql-error-after-diff; do
  start_case "$scenario"
  case "$scenario" in
    head-changes-after-diff) edit_pr after '.headRefOid = $head' --arg head "$OTHER_HEAD" ;;
    check-pending-after-diff)
      edit_fixture after checks '.check_runs += [(.check_runs[0] | .id = 102 | .status = "in_progress" | .conclusion = null | .completed_at = null)]'
      ;;
    review-pending-after-diff)
      edit_pr after '.reviews.nodes = [{state: "PENDING", body: "", commit: {oid: .headRefOid}}]'
      ;;
    changes-requested-after-diff)
      edit_pr after '.reviews.nodes = [{state: "CHANGES_REQUESTED", body: "", commit: {oid: .headRefOid}}]'
      ;;
    commented-feedback-after-diff)
      edit_pr after '.reviews.nodes = [{state: "COMMENTED", body: "**[WARNING]:** New feedback", commit: {oid: .headRefOid}}]'
      ;;
    summary-warning-after-diff) edit_fixture after comments '.[0].body = $body' --arg body "$WARNING_BODY" ;;
    inline-feedback-after-diff)
      edit_pr after '.reviewThreads.nodes = [{isResolved: false, comments: {
        nodes: [{author: {login: "review-bot"}}], pageInfo: {hasNextPage: false}}}]'
      ;;
    graphql-error-after-diff) edit_fixture after graphql '.errors = [{message: "Synthetic recheck failure"}]' ;;
  esac
  run_worker
  assert_blocked
  assert_calls before diff 1
  assert_calls before graphql 1
  assert_calls after checks 1
  finish_case
done

start_case blocked-becomes-clean-next-cycle
edit_fixture before comments '.[0].body = $body' --arg body "$WARNING_BODY"
mkdir -p "$WORKER/state"
printf '%s\n' '{"17":{"retries":1,"kind":"bot-failed"}}' > "$WORKER/state/retries.json"
run_worker
assert_blocked
assert_calls before diff 0
edit_fixture before comments '.[0].body = $body' --arg body "$CLEAN_BODY"
run_worker
assert_ready
assert_clean_gate_rechecked
finish_case

start_case blocked-remains-silent-beyond-retry-limit
edit_fixture before checks '.check_runs = []'
run_worker
assert_blocked
run_worker
assert_blocked
assert_calls before checks 1
assert_calls before diff 0
finish_case

start_case clean-notifies-only-once
run_worker
assert_ready
assert_clean_gate_rechecked
cp "$WORKER/state/parsed_prs.json" "$CASE_DIR/first-state.json"
run_worker
assert_ready
cmp -s "$CASE_DIR/first-state.json" "$WORKER/state/parsed_prs.json" || fail 'ready state changed on repeated cycle'
assert_calls before checks 0
assert_calls before diff 0
finish_case

printf '%s tests, %s failed\n' "$TOTAL" "$FAILED"
[ "$FAILED" = 0 ]
