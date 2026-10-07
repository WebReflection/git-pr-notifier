#!/usr/bin/env bash
# git-pr-notifier - idempotent cron installer.
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
