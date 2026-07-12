#!/bin/ash

set -u

BASE="/root/hmn"
STATE="$BASE/state"
CACHE="$BASE/cache"
LOGDIR="$BASE/logs"

STRICT="${STRICT:-$CACHE/ok-awg1-strict-foreign-latest.tsv}"
LOW_PERCENT="${LOW_PERCENT:-20}"
MIN_AVAILABLE="${MIN_AVAILABLE:-2}"

REFRESH="$BASE/hmn-refresh-pool-safe.sh"

REFRESH_LOCK="/tmp/hmn-refresh-pool-safe.lock"
MANAGER_LOCK="/tmp/vpn-egress-manager.lock"
CHECK_LOCK="/tmp/hmn-pool-low-watermark-check.lock"
MAINT="/tmp/hmn-vpn-maintenance"

MANAGER_WAIT_MAX="${MANAGER_WAIT_MAX:-180}"
MANAGER_WAIT_STEP="${MANAGER_WAIT_STEP:-3}"

MODE="${1:-dry-run}"

TS="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/low-watermark-last.log"
RCFILE="/tmp/hmn-low-watermark.rc.$$"

mkdir -p "$STATE" "$CACHE" "$LOGDIR"

say() {
  echo "$(date -Iseconds) $*"
}

run_body() {
  echo "=== hmn-pool-low-watermark-check ==="
  echo "mode=$MODE"
  echo "strict=$STRICT"
  echo "low_percent=$LOW_PERCENT"
  echo "min_available=$MIN_AVAILABLE"
  echo "manager_wait_max=$MANAGER_WAIT_MAX"
  echo "manager_wait_step=$MANAGER_WAIT_STEP"

  case "$MODE" in
    dry-run|run) ;;
    *)
      echo "ERROR: allowed modes: dry-run | run"
      return 64
      ;;
  esac

  if ! mkdir "$CHECK_LOCK" 2>/dev/null; then
    say "another low-watermark checker is already running: $CHECK_LOCK"
    echo "decision=SKIP_CHECK_ALREADY_RUNNING"
    return 0
  fi
  trap 'rmdir "$CHECK_LOCK" 2>/dev/null || true' EXIT INT TERM

  if [ ! -s "$STRICT" ]; then
    echo "ERROR: strict foreign table missing/empty: $STRICT"
    echo "decision=ERROR_NO_STRICT_TABLE"
    return 1
  fi

  TMP_EPS="/tmp/hmn-lowwater-eps.$$"
  TMP_BAD="/tmp/hmn-lowwater-bad.$$"

  awk -F '\t' 'NR > 1 && $3 != "" { print $3 }' "$STRICT" > "$TMP_EPS"

  TOTAL="$(wc -l < "$TMP_EPS" | tr -d ' ')"

  BAD_FILE="$STATE/bad-endpoints-$(date +%Y%m%d).txt"
  if [ -s "$BAD_FILE" ]; then
    awk '{print $1}' "$BAD_FILE" > "$TMP_BAD"
  else
    : > "$TMP_BAD"
  fi

  VPN1_EP="$(uci -q get network.vpn1.hmn_endpoint || true)"
  VPN2_EP="$(uci -q get network.vpn2.hmn_endpoint || true)"
  ACTIVE_SLOT="$(cat "$STATE/active-slot" 2>/dev/null || true)"

  AVAILABLE=0
  USED=0
  BAD_IN_TABLE=0

  while read -r EP; do
    [ -n "$EP" ] || continue

    IS_USED=0
    IS_BAD=0

    if [ "$EP" = "$VPN1_EP" ] || [ "$EP" = "$VPN2_EP" ]; then
      IS_USED=1
    fi

    if grep -qxF "$EP" "$TMP_BAD" 2>/dev/null; then
      IS_BAD=1
    fi

    if [ "$IS_USED" -eq 1 ]; then
      USED=$((USED + 1))
    elif [ "$IS_BAD" -eq 1 ]; then
      BAD_IN_TABLE=$((BAD_IN_TABLE + 1))
    else
      AVAILABLE=$((AVAILABLE + 1))
    fi
  done < "$TMP_EPS"

  rm -f "$TMP_EPS" "$TMP_BAD"

  if [ "$TOTAL" -le 0 ]; then
    echo "ERROR: no endpoints in strict foreign table"
    echo "decision=ERROR_EMPTY_STRICT_TABLE"
    return 1
  fi

  THRESHOLD=$(( (TOTAL * LOW_PERCENT + 99) / 100 ))
  if [ "$THRESHOLD" -lt "$MIN_AVAILABLE" ]; then
    THRESHOLD="$MIN_AVAILABLE"
  fi

  echo
  echo "=== pool numbers ==="
  echo "foreign_total=$TOTAL"
  echo "vpn1_ep=$VPN1_EP"
  echo "vpn2_ep=$VPN2_EP"
  echo "active_slot=$ACTIVE_SLOT"
  echo "used_by_slots=$USED"
  echo "bad_in_table=$BAD_IN_TABLE"
  echo "available=$AVAILABLE"
  echo "threshold=$THRESHOLD"

  {
    echo "checked_at=$(date -Iseconds)"
    echo "foreign_total=$TOTAL"
    echo "used_by_slots=$USED"
    echo "bad_in_table=$BAD_IN_TABLE"
    echo "available=$AVAILABLE"
    echo "threshold=$THRESHOLD"
    echo "active_slot=$ACTIVE_SLOT"
  } > "$STATE/last-low-watermark-check"

  echo
  echo "=== initial overlap guards ==="
  [ -d "$REFRESH_LOCK" ] && REFRESH_LOCK_PRESENT=1 || REFRESH_LOCK_PRESENT=0
  [ -e "$MAINT" ] && MAINT_PRESENT=1 || MAINT_PRESENT=0
  [ -d "$MANAGER_LOCK" ] && MANAGER_LOCK_PRESENT=1 || MANAGER_LOCK_PRESENT=0
  echo "refresh_lock_present=$REFRESH_LOCK_PRESENT"
  echo "maintenance_present=$MAINT_PRESENT"
  echo "manager_lock_present=$MANAGER_LOCK_PRESENT"

  echo
  echo "=== decision ==="
  if [ "$AVAILABLE" -gt "$THRESHOLD" ]; then
    echo "decision=ENOUGH_CANDIDATES"
    echo "action=none"
    echo "ENOUGH_CANDIDATES" > "$STATE/last-low-watermark-decision"
    return 0
  fi

  echo "decision=LOW_WATERMARK"
  echo "LOW_WATERMARK" > "$STATE/last-low-watermark-decision"

  if [ "$MODE" = "dry-run" ]; then
    echo "action=dry-run-would-refresh-after-safe-window"
    return 0
  fi

  if [ "$REFRESH_LOCK_PRESENT" -eq 1 ] || [ "$MAINT_PRESENT" -eq 1 ]; then
    echo "action=skip-refresh-or-validation-already-running"
    echo "SKIP_REFRESH_RUNNING" > "$STATE/last-low-watermark-decision"
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
    echo "action=skip-manager-lock-still-present-after-${WAITED}s"
    echo "SKIP_MANAGER_LOCK_TIMEOUT" > "$STATE/last-low-watermark-decision"
    return 0
  fi

  echo "manager window ok after ${WAITED}s"

  echo
  echo "=== final overlap guards before refresh ==="
  if [ -d "$REFRESH_LOCK" ] || [ -e "$MAINT" ]; then
    echo "action=skip-refresh-or-validation-started-while-waiting"
    echo "SKIP_REFRESH_STARTED_WHILE_WAITING" > "$STATE/last-low-watermark-decision"
    return 0
  fi

  if [ ! -x "$REFRESH" ]; then
    echo "ERROR: refresh wrapper missing/not executable: $REFRESH"
    echo "ERROR_NO_REFRESH_WRAPPER" > "$STATE/last-low-watermark-decision"
    return 1
  fi

  echo "action=run-refresh: $REFRESH fresh-download"
  date -Iseconds > "$STATE/last-low-watermark-refresh-started-at"

  "$REFRESH" fresh-download
  RC="$?"

  echo "$RC" > "$STATE/last-low-watermark-refresh-rc"
  date -Iseconds > "$STATE/last-low-watermark-refresh-finished-at"

  echo "refresh_rc=$RC"

  if [ "$RC" -eq 0 ]; then
    echo "REFRESH_OK" > "$STATE/last-low-watermark-decision"
  else
    echo "REFRESH_FAILED" > "$STATE/last-low-watermark-decision"
  fi

  return "$RC"
}

(
  run_body
  echo "$?" > "$RCFILE"
) 2>&1 | tee "$LOG"

RC="$(cat "$RCFILE" 2>/dev/null || echo 99)"
rm -f "$RCFILE"

exit "$RC"
