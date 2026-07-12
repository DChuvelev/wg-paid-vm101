#!/bin/ash

set -u

BASE="/root/hmn"
STATE="$BASE/state"
LOGDIR="$BASE/logs"

REFRESH="$BASE/hmn-refresh-pool-safe.sh"

RETRY_FLAG="$STATE/refresh-retry-needed"
RETRY_REASON="$STATE/refresh-retry-reason"

RETRY_LOCK="/tmp/hmn-refresh-retry.lock"
REFRESH_LOCK="/tmp/hmn-refresh-pool-safe.lock"
LOWWATER_LOCK="/tmp/hmn-pool-low-watermark-check.lock"
MANAGER_LOCK="/tmp/vpn-egress-manager.lock"
MAINT="/tmp/hmn-vpn-maintenance"

MANAGER_WAIT_MAX="${MANAGER_WAIT_MAX:-180}"
MANAGER_WAIT_STEP="${MANAGER_WAIT_STEP:-3}"

LOG="$LOGDIR/cron-refresh-retry-last.log"
RCFILE="/tmp/hmn-refresh-retry.rc.$$"

mkdir -p "$STATE" "$LOGDIR"

say() {
  echo "$(date -Iseconds) $*"
}

run_body() {
  echo "=== hmn-refresh-retry-cron ==="
  echo "mode=run"
  echo "manager_wait_max=$MANAGER_WAIT_MAX"
  echo "manager_wait_step=$MANAGER_WAIT_STEP"

  if ! mkdir "$RETRY_LOCK" 2>/dev/null; then
    say "another retry instance is already running: $RETRY_LOCK"
    echo "decision=SKIP_RETRY_ALREADY_RUNNING"
    return 0
  fi
  trap 'rmdir "$RETRY_LOCK" 2>/dev/null || true' EXIT INT TERM

  echo
  echo "=== retry flag ==="
  if [ ! -e "$RETRY_FLAG" ]; then
    echo "retry_needed=no"
    echo "NO_RETRY_NEEDED" > "$STATE/last-refresh-retry-decision"
    date -Iseconds > "$STATE/last-refresh-retry-checked-at"
    return 0
  fi

  echo "retry_needed_at=$(cat "$RETRY_FLAG" 2>/dev/null || true)"
  echo "retry_reason=$(cat "$RETRY_REASON" 2>/dev/null || echo unknown)"
  echo "RETRY_NEEDED" > "$STATE/last-refresh-retry-decision"
  date -Iseconds > "$STATE/last-refresh-retry-checked-at"

  echo
  echo "=== hard overlap guards ==="
  [ -d "$REFRESH_LOCK" ] && REFRESH_LOCK_PRESENT=1 || REFRESH_LOCK_PRESENT=0
  [ -e "$MAINT" ] && MAINT_PRESENT=1 || MAINT_PRESENT=0
  [ -d "$LOWWATER_LOCK" ] && LOWWATER_LOCK_PRESENT=1 || LOWWATER_LOCK_PRESENT=0

  echo "refresh_lock_present=$REFRESH_LOCK_PRESENT"
  echo "maintenance_present=$MAINT_PRESENT"
  echo "lowwater_lock_present=$LOWWATER_LOCK_PRESENT"

  if [ "$REFRESH_LOCK_PRESENT" -eq 1 ] || [ "$MAINT_PRESENT" -eq 1 ]; then
    echo "decision=SKIP_REFRESH_OR_VALIDATION_RUNNING"
    echo "SKIP_REFRESH_OR_VALIDATION_RUNNING" > "$STATE/last-refresh-retry-decision"
    return 0
  fi

  if [ "$LOWWATER_LOCK_PRESENT" -eq 1 ]; then
    echo "decision=SKIP_LOWWATER_CHECK_RUNNING"
    echo "SKIP_LOWWATER_CHECK_RUNNING" > "$STATE/last-refresh-retry-decision"
    return 0
  fi

  echo
  echo "=== wait for manager window ==="
  WAITED=0
  while [ -d "$MANAGER_LOCK" ] && [ "$WAITED" -lt "$MANAGER_WAIT_MAX" ]; do
    echo "manager lock present; waited=${WAITED}s; sleeping ${MANAGER_WAIT_STEP}s"
    sleep "$MANAGER_WAIT_STEP"
    WAITED=$((WAITED + MANAGER_WAIT_STEP))
  done

  if [ -d "$MANAGER_LOCK" ]; then
    echo "decision=SKIP_MANAGER_LOCK_TIMEOUT"
    echo "SKIP_MANAGER_LOCK_TIMEOUT" > "$STATE/last-refresh-retry-decision"
    return 0
  fi

  echo "manager window ok after ${WAITED}s"

  echo
  echo "=== final guards before refresh ==="
  if [ -d "$REFRESH_LOCK" ] || [ -e "$MAINT" ] || [ -d "$LOWWATER_LOCK" ]; then
    echo "decision=SKIP_OVERLAP_STARTED_WHILE_WAITING"
    echo "SKIP_OVERLAP_STARTED_WHILE_WAITING" > "$STATE/last-refresh-retry-decision"
    return 0
  fi

  if [ ! -x "$REFRESH" ]; then
    echo "ERROR: refresh wrapper missing/not executable: $REFRESH"
    echo "ERROR_NO_REFRESH_WRAPPER" > "$STATE/last-refresh-retry-decision"
    return 1
  fi

  echo
  echo "=== run retry fresh-download ==="
  echo "cmd=$REFRESH fresh-download"
  date -Iseconds > "$STATE/last-refresh-retry-started-at"

  "$REFRESH" fresh-download
  RC="$?"

  echo "$RC" > "$STATE/last-refresh-retry-rc"
  date -Iseconds > "$STATE/last-refresh-retry-finished-at"

  echo
  echo "refresh_rc=$RC"
  echo "refresh_status=$(cat "$STATE/refresh-status" 2>/dev/null || echo unknown)"
  echo "last_fresh_download_rc=$(cat "$STATE/last-fresh-download-rc" 2>/dev/null || echo unknown)"

  if [ -e "$RETRY_FLAG" ]; then
    echo "retry_flag_after=still_present"
    echo "RETRY_STILL_NEEDED" > "$STATE/last-refresh-retry-decision"
  else
    echo "retry_flag_after=cleared"
    echo "RETRY_CLEARED" > "$STATE/last-refresh-retry-decision"
  fi

  return "$RC"
}

(
  run_body
  echo "$?" > "$RCFILE"
) > "$LOG" 2>&1

RC="$(cat "$RCFILE" 2>/dev/null || echo 99)"
rm -f "$RCFILE"

exit "$RC"
