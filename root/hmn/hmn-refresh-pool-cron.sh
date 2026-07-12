#!/bin/ash

BASE="/root/hmn"
LOG="$BASE/logs/cron-refresh-pool-safe-last.log"
STATE="$BASE/state"

mkdir -p "$BASE/logs" "$STATE"

{
  echo "=== cron refresh start $(date -Iseconds) ==="
  echo "cmd=/root/hmn/hmn-refresh-pool-safe.sh fresh-download"
  echo

  /root/hmn/hmn-refresh-pool-safe.sh fresh-download
  RC="$?"

  echo
  echo "refresh_rc=$RC"
  echo "=== cron refresh done $(date -Iseconds) ==="
} > "$LOG" 2>&1

echo "$RC" > "$STATE/last-cron-refresh-rc"
date -Iseconds > "$STATE/last-cron-refresh-finished-at"

exit "$RC"
