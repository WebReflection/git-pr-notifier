#!/usr/bin/env bash
# git-pr-notifier - removes the cron job and kills any in-flight check.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER="# git-pr-notifier-job"
# Matches entries from this marker and from any previous personal marker.
CRON_TAG_RE='(pr-review-job|pr-notifier-job|check_prs\.sh)'
LOCK_DIR="$SCRIPT_DIR/state/locks/.check.lock"
PID_FILE="$LOCK_DIR/pid"

if ! crontab -l 2>/dev/null | grep -qE "$CRON_TAG_RE"; then
  echo "not installed"
  exit 0
fi

remaining="$(crontab -l 2>/dev/null | grep -vE "$CRON_TAG_RE" || true)"
if [ -n "$remaining" ]; then
  printf '%s\n' "$remaining" | crontab -
else
  printf '' | crontab -
fi
echo "Cron job removed."

if [ -f "$PID_FILE" ]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    if kill "$pid" 2>/dev/null; then
      echo "Killed in-flight check (pid $pid)."
    else
      echo "WARN: could not kill in-flight check (pid $pid)."
    fi
  fi
fi
rm -rf "$LOCK_DIR"
