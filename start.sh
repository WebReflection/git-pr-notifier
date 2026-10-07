#!/usr/bin/env bash
# git-pr-notifier - idempotent cron installer; './start.sh clean' performs
# log/state maintenance without touching the cron entry.
# Safe to run repeatedly: always results in exactly one cron entry.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER="# git-pr-notifier-job"
# Matches entries from this marker and from any previous personal marker so
# rerunning this script replaces older installations cleanly.
CRON_TAG_RE='(pr-review-job|pr-notifier-job|check_prs\.sh)'
CRON_LINE="*/2 * * * * $SCRIPT_DIR/check_prs.sh >> $SCRIPT_DIR/cron_check.log 2>&1"

fail() { echo "ERROR: $*" >&2; exit 1; }

# --- ./start.sh clean: log/state maintenance (does not touch the cron entry) ---
# Erases cron_check.log. In state/, parsed_prs.json and retries.json are kept
# because they make the bootstrap faster; when neither exists the whole state
# folder is removed instead. A refused clean means a check is in flight.
case "${1:-}" in
  "") ;;
  clean)
    PID_FILE="$SCRIPT_DIR/state/locks/.check.lock/pid"
    if [ -f "$PID_FILE" ]; then
      pid="$(cat "$PID_FILE" 2>/dev/null || true)"
      if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        fail "a check is in flight (pid $pid); wait for it to finish or run ./stop.sh first"
      fi
    fi
    rm -f "$SCRIPT_DIR/cron_check.log"
    if [ -f "$SCRIPT_DIR/state/parsed_prs.json" ] || [ -f "$SCRIPT_DIR/state/retries.json" ]; then
      find "$SCRIPT_DIR/state" -mindepth 1 -maxdepth 1 \
        ! -name 'parsed_prs.json' ! -name 'retries.json' -exec rm -rf {} +
      echo "Cleaned cron_check.log and transient state; kept state/parsed_prs.json and state/retries.json"
    else
      rm -rf "$SCRIPT_DIR/state"
      echo "Cleaned cron_check.log and removed the whole state folder (no json state to keep)"
    fi
    exit 0
    ;;
  *) fail "usage: ./start.sh [clean]" ;;
esac

for dep in gh jq osascript crontab; do
  command -v "$dep" >/dev/null 2>&1 || fail "required dependency not found: $dep"
done

if ! gh api rate_limit -q .resources.core.remaining >/dev/null 2>&1; then
  gh api rate_limit 2>&1 | head -3 >&2 || true
  fail "gh API check failed (see output above) - run 'gh auth login' or fix gh_token.env, then rerun"
fi

# If already installed, remove the existing entry first (stop-then-install).
if crontab -l 2>/dev/null | grep -qE "$CRON_TAG_RE"; then
  echo "Existing installation found - removing it first"
  "$SCRIPT_DIR/stop.sh"
fi

{
  crontab -l 2>/dev/null | grep -vE "$CRON_TAG_RE" || true
  echo "$MARKER"
  echo "$CRON_LINE"
} | crontab -

echo "Installed cron entry:"
crontab -l | grep -A1 -F "$MARKER"

echo "Running first check now..."
"$SCRIPT_DIR/check_prs.sh"

echo "Done. The watcher runs every 2 minutes; log: $SCRIPT_DIR/cron_check.log"
