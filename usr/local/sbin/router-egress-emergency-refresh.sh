#!/bin/sh
set -u

CONF="${EMERGENCY_CONF:-/etc/router-egress-emergency-refresh.conf}"
[ -r "$CONF" ] && . "$CONF"

EMERGENCY_DAILY_FAIL_THRESHOLD="${EMERGENCY_DAILY_FAIL_THRESHOLD:-5}"
EMERGENCY_COOLDOWN_SECONDS="${EMERGENCY_COOLDOWN_SECONDS:-600}"
EMERGENCY_COMMIT_ENABLED="${EMERGENCY_COMMIT_ENABLED:-false}"
EMERGENCY_DIRECT_FAILOPEN_ENABLED="${EMERGENCY_DIRECT_FAILOPEN_ENABLED:-false}"

EMERGENCY_STATE_HELPER="${EMERGENCY_STATE_HELPER:-/usr/local/lib/router-egress-recovery-state.sh}"
EMERGENCY_REFRESH_CMD="${EMERGENCY_REFRESH_CMD:-/root/hmn/hmn-refresh-pool-safe.sh}"
EMERGENCY_PLANNER_CMD="${EMERGENCY_PLANNER_CMD:-/usr/local/sbin/router-egress-hmn-plan-top5.sh}"
EMERGENCY_REBALANCE_APPLY_CMD="${EMERGENCY_REBALANCE_APPLY_CMD:-/usr/local/sbin/router-egress-hmn-rebalance-top5-apply.sh}"
EMERGENCY_WATCHER_CMD="${EMERGENCY_WATCHER_CMD:-/usr/local/sbin/router-egress-health-repair-watch.sh}"
EMERGENCY_CONFIRM_TOKEN="${EMERGENCY_CONFIRM_TOKEN:-EMERGENCY_HMN_REFRESH}"
EMERGENCY_LOCK_DIR="${EMERGENCY_LOCK_DIR:-/var/lock/router-egress-emergency-refresh.lock}"
EMERGENCY_LOG="${EMERGENCY_LOG:-/var/log/router-egress-emergency-refresh.log}"

mode="dry-run"
force=false
confirm=""
emit_watcher=false
emit_planner=true

prev=""
for arg in "$@"; do
  if [ "$prev" = "confirm" ]; then
    confirm="$arg"
    prev=""
    continue
  fi
  case "$arg" in
    --dry-run|--dryrun)
      mode="dry-run"
      ;;
    --check|--status)
      mode="dry-run"
      ;;
    --commit|--apply)
      mode="commit"
      ;;
    --selftest)
      mode="selftest"
      ;;
    --force)
      force=true
      ;;
    --with-watcher)
      emit_watcher=true
      ;;
    --no-planner)
      emit_planner=false
      ;;
    --confirm)
      prev="confirm"
      ;;
  esac
done

json_s() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

json_bool() {
  case "$1" in
    true|yes|1) echo true ;;
    *) echo false ;;
  esac
}

now_epoch() {
  date +%s
}

helper_ok=false
if [ -r "$EMERGENCY_STATE_HELPER" ]; then
  . "$EMERGENCY_STATE_HELPER"
  if reg_init_state >/dev/null 2>&1; then
    helper_ok=true
  fi
fi

get_state() {
  key="$1"
  def="${2:-0}"
  if [ "$helper_ok" = "true" ]; then
    reg_get_state "$key" "$def" 2>/dev/null || echo "$def"
  else
    echo "$def"
  fi
}

set_state() {
  key="$1"
  val="$2"
  if [ "$helper_ok" = "true" ]; then
    reg_set_state "$key" "$val" >/dev/null 2>&1 || true
  fi
}

daily_count() {
  if [ "$helper_ok" = "true" ]; then
    reg_daily_repair_get 2>/dev/null || echo 0
  else
    echo 0
  fi
}

count_healthy_slots() {
  c=0
  for iface in vpn1 vpn2 vpn3 vpn4 vpn5; do
    if ip link show dev "$iface" >/dev/null 2>&1 && ping -I "$iface" -c 1 -W 3 1.1.1.1 >/tmp/emergency-refresh-ping-${iface}.$$ 2>/dev/null; then
      c=$((c + 1))
    fi
    rm -f /tmp/emergency-refresh-ping-${iface}.$$ 2>/dev/null || true
  done
  echo "$c"
}

json_external_status() {
  cmd="$1"
  if [ -x "$cmd" ]; then
    echo true
  else
    echo false
  fi
}

threshold_reached() {
  cnt="$1"
  [ "$cnt" -ge "$EMERGENCY_DAILY_FAIL_THRESHOLD" ] 2>/dev/null
}

cooldown_remaining() {
  now="$(now_epoch)"
  last="$(get_state last_emergency_refresh_epoch 0)"
  elapsed=$((now - last))
  if [ "$elapsed" -lt "$EMERGENCY_COOLDOWN_SECONDS" ] 2>/dev/null; then
    echo $((EMERGENCY_COOLDOWN_SECONDS - elapsed))
  else
    echo 0
  fi
}

emit_json() {
  decision="$1"
  reason="$2"
  cnt="$(daily_count)"
  cd_rem="$(cooldown_remaining)"
  healthy_slots="$(count_healthy_slots)"
  last_status="$(get_state last_emergency_refresh_status NONE)"
  last_epoch="$(get_state last_emergency_refresh_epoch 0)"

  echo "{"
  echo "  \"schema\": \"router-egress-emergency-refresh-v1\","
  echo "  \"mode\": \"$(json_s "$mode")\","
  echo "  \"decision\": \"$(json_s "$decision")\","
  echo "  \"reason\": \"$(json_s "$reason")\","
  echo "  \"daily_fail_count\": $cnt,"
  echo "  \"daily_fail_threshold\": $EMERGENCY_DAILY_FAIL_THRESHOLD,"
  echo "  \"threshold_reached\": $(threshold_reached "$cnt" && echo true || echo false),"
  echo "  \"force\": $(json_bool "$force"),"
  echo "  \"cooldown_seconds\": $EMERGENCY_COOLDOWN_SECONDS,"
  echo "  \"cooldown_remaining\": $cd_rem,"
  echo "  \"healthy_vpn_slots\": $healthy_slots,"
  echo "  \"commit_enabled\": $(json_bool "$EMERGENCY_COMMIT_ENABLED"),"
  echo "  \"direct_failopen_enabled\": $(json_bool "$EMERGENCY_DIRECT_FAILOPEN_ENABLED"),"
  echo "  \"direct_failopen_action\": \"disabled_not_allowed_in_step050f\","
  echo "  \"helper_ok\": $(json_bool "$helper_ok"),"
  echo "  \"refresh_cmd\": \"$(json_s "$EMERGENCY_REFRESH_CMD")\","
  echo "  \"refresh_cmd_exists\": $(json_external_status "$EMERGENCY_REFRESH_CMD"),"
  echo "  \"planner_cmd\": \"$(json_s "$EMERGENCY_PLANNER_CMD")\","
  echo "  \"planner_cmd_exists\": $(json_external_status "$EMERGENCY_PLANNER_CMD"),"
  echo "  \"rebalance_apply_cmd\": \"$(json_s "$EMERGENCY_REBALANCE_APPLY_CMD")\","
  echo "  \"rebalance_apply_cmd_exists\": $(json_external_status "$EMERGENCY_REBALANCE_APPLY_CMD"),"
  echo "  \"watcher_cmd\": \"$(json_s "$EMERGENCY_WATCHER_CMD")\","
  echo "  \"watcher_cmd_exists\": $(json_external_status "$EMERGENCY_WATCHER_CMD"),"
  echo "  \"last_emergency_refresh_status\": \"$(json_s "$last_status")\","
  echo "  \"last_emergency_refresh_epoch\": $last_epoch"
  echo "}"
}

acquire_lock() {
  if mkdir "$EMERGENCY_LOCK_DIR" 2>/dev/null; then
    return 0
  fi
  return 1
}

release_lock() {
  rmdir "$EMERGENCY_LOCK_DIR" 2>/dev/null || true
}

selftest() {
  cnt="$(daily_count)"
  cd_rem="$(cooldown_remaining)"
  if threshold_reached "$cnt"; then
    decision="would_run_emergency_refresh"
  else
    decision="below_threshold_noop"
  fi
  emit_json "$decision" "selftest_uses_current_REG_STATE_DIR_only"
}

if [ "$mode" = "selftest" ]; then
  selftest
  exit 0
fi

cnt="$(daily_count)"
cd_rem="$(cooldown_remaining)"

if [ "$mode" = "dry-run" ]; then
  if [ "$force" = "true" ] || threshold_reached "$cnt"; then
    if [ "$cd_rem" -gt 0 ]; then
      emit_json "cooldown_active" "threshold_or_force_reached_but_cooldown_active"
    else
      emit_json "would_run_emergency_refresh" "threshold_or_force_reached_no_commit_in_dry_run"
    fi
  else
    emit_json "below_threshold_noop" "daily_fail_count_below_threshold"
  fi
  exit 0
fi

if [ "$mode" = "commit" ]; then
  if [ "$EMERGENCY_COMMIT_ENABLED" != "true" ]; then
    emit_json "commit_disabled_in_step050f" "skeleton_installed_but_commit_disabled_until_reviewed_followup"
    exit 0
  fi

  if [ "$confirm" != "$EMERGENCY_CONFIRM_TOKEN" ]; then
    emit_json "missing_or_wrong_confirm_token" "commit_requires_exact_confirm_token"
    exit 0
  fi

  if [ "$force" != "true" ] && ! threshold_reached "$cnt"; then
    emit_json "below_threshold_noop" "daily_fail_count_below_threshold"
    exit 0
  fi

  if [ "$cd_rem" -gt 0 ]; then
    emit_json "cooldown_active" "emergency_refresh_cooldown_active"
    exit 0
  fi

  if ! acquire_lock; then
    emit_json "lock_busy" "another_emergency_refresh_is_running"
    exit 0
  fi

  now="$(now_epoch)"
  set_state mode EMERGENCY_REFRESH
  set_state last_emergency_refresh_epoch "$now"
  mkdir -p "$(dirname "$EMERGENCY_LOG")" 2>/dev/null || true
  printf '%s action=emergency_refresh_start count=%s threshold=%s direct_failopen=false\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" "$cnt" "$EMERGENCY_DAILY_FAIL_THRESHOLD" >> "$EMERGENCY_LOG" 2>/dev/null || true

  if [ ! -x "$EMERGENCY_REFRESH_CMD" ]; then
    set_state last_emergency_refresh_status refresh_cmd_missing
    release_lock
    emit_json "refresh_cmd_missing" "configured_refresh_command_missing"
    exit 0
  fi

  "$EMERGENCY_REFRESH_CMD" >> "$EMERGENCY_LOG" 2>&1
  refresh_rc=$?

  if [ "$refresh_rc" = "0" ]; then
    set_state last_emergency_refresh_status refresh_ok_rebalance_pending
    if [ -x "$EMERGENCY_REBALANCE_APPLY_CMD" ]; then
      "$EMERGENCY_REBALANCE_APPLY_CMD" --commit --confirm REBALANCE_TOP5_DAILY >> "$EMERGENCY_LOG" 2>&1
      rebalance_rc=$?
      set_state last_emergency_rebalance_rc "$rebalance_rc"
    else
      rebalance_rc=127
      set_state last_emergency_rebalance_rc "$rebalance_rc"
    fi
    if [ "$rebalance_rc" = "0" ]; then
      set_state mode NORMAL
      set_state last_emergency_refresh_status refresh_ok_rebalance_ok
      release_lock
      emit_json "refresh_ok_rebalance_ok" "fresh_pool_and_top5_rebalance_completed"
      exit 0
    else
      set_state mode DEGRADED_NO_FRESH_POOL
      set_state last_emergency_refresh_status refresh_ok_rebalance_failed
      release_lock
      emit_json "refresh_ok_rebalance_failed" "refresh_succeeded_but_rebalance_failed_no_direct_failopen"
      exit 0
    fi
  else
    set_state mode DEGRADED_NO_FRESH_POOL
    set_state last_emergency_refresh_status refresh_failed
    set_state last_emergency_refresh_rc "$refresh_rc"
    release_lock
    emit_json "refresh_failed_degraded_no_direct" "refresh_failed_but_direct_failopen_disabled_in_state_machine"
    exit 0
  fi
fi

emit_json "unknown_mode" "unsupported_mode"
exit 0
