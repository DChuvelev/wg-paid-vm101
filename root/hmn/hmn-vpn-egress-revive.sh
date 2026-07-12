#!/bin/ash
set -u

BASE="/root/hmn"
STATE="$BASE/state"
LOGDIR="$BASE/logs"
LOG="$LOGDIR/vpn-egress-revive-last.log"
STAMP="$STATE/last-vpn-egress-revive"
LOCK="/tmp/hmn-vpn-egress-revive.lock"
MAINT="/tmp/hmn-vpn-maintenance"

OVERRIDE="$BASE/hmn-vpn-user-override.sh"
MANAGER="/usr/bin/vpn-egress-manager.sh"

mkdir -p "$STATE" "$LOGDIR"

say() {
  echo "$(date -Iseconds) $*"
}

get_table_dev() {
  ip -4 route show table 200 | awk '
    /^default / {
      for (i=1; i<=NF; i++) {
        if ($i=="dev") { print $(i+1); exit }
      }
    }
  '
}

strict_probe() {
  IP="$1"
  LOGF="/tmp/hmn-revive-ping-${IP}.$$"

  ping -4 -c 3 -W 2 -I 10.200.0.2 "$IP" > "$LOGF" 2>&1 || true
  cat "$LOGF"

  LOSS="$(sed -n 's/.* \([0-9][0-9]*%\) packet loss.*/\1/p' "$LOGF" | tail -n1)"
  rm -f "$LOGF"

  [ "$LOSS" = "0%" ]
}

wait_table_default() {
  WANT="$1"
  i=0
  while [ "$i" -lt 12 ]; do
    DEV="$(get_table_dev)"
    if [ "$DEV" = "$WANT" ]; then
      echo "table200_default_ok=$DEV"
      return 0
    fi

    echo "table200_default_wait i=$i current=${DEV:-none} want=$WANT"

    # Re-run manager first; if it is still racing with netifd, explicitly reassert
    # only for the selected managed slot. This does not change UCI configs.
    if [ -x "$MANAGER" ]; then
      "$MANAGER" >/dev/null 2>&1 || true
    fi

    case "$WANT" in
      vpn1|vpn2)
        if ip link show "$WANT" >/dev/null 2>&1; then
          ip -4 route replace default dev "$WANT" table 200 2>/dev/null || true
          ip -4 route flush cache 2>/dev/null || true
        fi
        ;;
    esac

    sleep 2
    i=$((i + 1))
  done

  DEV="$(get_table_dev)"
  echo "ERROR: table200_default_missing final=${DEV:-none} want=$WANT"
  return 1
}

run_body() {
  echo "=== hmn-vpn-egress-revive ==="
  say "start"

  if ! mkdir "$LOCK" 2>/dev/null; then
    say "ERROR: revive already running"
    echo "status=already_running" > "$STAMP"
    return 2
  fi

  CRON_WAS_RUNNING=0
  if /etc/init.d/cron status 2>/dev/null | grep -q running; then
    CRON_WAS_RUNNING=1
  fi

  cleanup() {
    rm -f "$MAINT"
    if [ "$CRON_WAS_RUNNING" -eq 1 ]; then
      /etc/init.d/cron start >/dev/null 2>&1 || true
    fi
    rmdir "$LOCK" 2>/dev/null || true
  }
  trap cleanup EXIT INT TERM

  echo
  echo "=== freeze short automation window ==="
  /etc/init.d/cron stop >/dev/null 2>&1 || true
  touch "$MAINT"

  echo
  echo "=== pre-state ==="
  echo "override_status=$($OVERRIDE status 2>/dev/null | awk -F= '/^status=/{print $2; exit}' || echo unknown)"
  echo "active_slot=$(cat "$STATE/active-slot" 2>/dev/null || true)"
  echo "table_dev=$(get_table_dev)"
  cat /tmp/vpn-egress-current.state 2>/dev/null || true
  ip -4 route show table 200

  echo
  echo "=== clear manual override if active ==="
  if [ -x "$OVERRIDE" ] && "$OVERRIDE" status 2>/dev/null | grep -q '^status=active'; then
    "$OVERRIDE" clear || true
    sleep 2
  else
    echo "manual_override=not_active"
  fi

  TABLE_DEV="$(get_table_dev)"
  ACTIVE_SLOT="$(cat "$STATE/active-slot" 2>/dev/null || true)"

  TARGET=""
  case "$TABLE_DEV" in
    vpn1|vpn2) TARGET="$TABLE_DEV" ;;
  esac

  if [ -z "$TARGET" ]; then
    case "$ACTIVE_SLOT" in
      vpn1|vpn2) TARGET="$ACTIVE_SLOT" ;;
    esac
  fi

  if [ -z "$TARGET" ]; then
    TARGET="vpn1"
  fi

  echo
  echo "=== restart active interface ==="
  echo "target=$TARGET"

  ifdown "$TARGET" 2>/dev/null || true
  sleep 3
  ifup "$TARGET" 2>/dev/null || true
  sleep 12

  echo
  echo "=== run vpn-egress-manager ==="
  if [ -x "$MANAGER" ]; then
    "$MANAGER" || true
  else
    echo "ERROR: manager not executable: $MANAGER"
    return 1
  fi

  echo
  echo "=== wait table 200 default ==="
  if ! wait_table_default "$TARGET"; then
    FINAL_DEV="$(get_table_dev)"
    cat /tmp/vpn-egress-current.state 2>/dev/null || true
    ip -4 route show table 200
    {
      echo "status=failed"
      echo "finished_at=$(date -Iseconds)"
      echo "target=$TARGET"
      echo "final_table_dev=$FINAL_DEV"
      echo "reason=table200_default_missing"
    } > "$STAMP"
    say "REVIVE_FAILED_TABLE200"
    return 1
  fi

  echo
  echo "=== post-state ==="
  FINAL_DEV="$(get_table_dev)"
  echo "final_table_dev=$FINAL_DEV"
  cat /tmp/vpn-egress-current.state 2>/dev/null || true
  ip -4 route show table 200

  echo
  echo "=== strict traffic check ==="
  OK1=0
  OK2=0

  echo "--- 9.9.9.9 ---"
  if strict_probe 9.9.9.9; then OK1=1; fi

  echo
  echo "--- 1.1.1.1 ---"
  if strict_probe 1.1.1.1; then OK2=1; fi

  {
    echo "status=$([ "$OK1" -eq 1 ] && [ "$OK2" -eq 1 ] && echo ok || echo failed)"
    echo "finished_at=$(date -Iseconds)"
    echo "target=$TARGET"
    echo "final_table_dev=$FINAL_DEV"
    echo "probe_9_9_9_9=$OK1"
    echo "probe_1_1_1_1=$OK2"
  } > "$STAMP"

  if [ "$OK1" -eq 1 ] && [ "$OK2" -eq 1 ]; then
    say "REVIVE_OK"
    return 0
  fi

  say "REVIVE_FAILED"
  return 1
}

(
  run_body
  RC="$?"
  echo
  echo "revive_rc=$RC"
  exit "$RC"
) > "$LOG" 2>&1

RC="$?"
cat "$LOG"
exit "$RC"
