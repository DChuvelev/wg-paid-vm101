#!/bin/sh
set -u

STATE_DIR="/root/hmn/state"
STATE="$STATE_DIR/vpn-user-override.state"
LOG="/root/hmn/logs/vpn-user-override.log"
LOCKDIR="/tmp/hmn-vpn-user-override.lock"

OK_LIST="/root/hmn/cache/ok-awg1-strict-latest.tsv"
LOADER="/root/hmn/hmn-load-vpn-user.sh"
MANAGER="/usr/bin/vpn-egress-manager.sh"

ROUTE_STATE_FILE="/tmp/vpn-egress-current.state"

log() {
  mkdir -p /root/hmn/logs
  echo "$(date -Iseconds 2>/dev/null || date) $*" >> "$LOG"
  logger -t vpn-user-override "$*" 2>/dev/null || true
}

die() {
  echo "ERROR: $*" >&2
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<EOF
Usage:
  $0 list
  $0 status
  $0 activate <config-file-or-path-or-rank> <minutes>
  $0 clear
  $0 tick
  $0 manager-guard
EOF
}

lock_or_die() {
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    die "lock busy: $LOCKDIR"
  fi
  trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT INT TERM
}

now_epoch() {
  date +%s
}

load_state() {
  status=""
  config_file=""
  config_path=""
  endpoint=""
  activated_at_epoch=""
  expires_at_epoch=""
  minutes=""
  prev_default_dev=""

  [ -f "$STATE" ] && . "$STATE" 2>/dev/null || true
}

current_table200_default_dev() {
  ip -4 route show table 200 2>/dev/null | sed -n 's/^default dev \([^ ]*\).*/\1/p' | head -n 1
}

vpn_user_link_exists() {
  ip link show vpn_user >/dev/null 2>&1
}

ensure_vpn_user_route() {
  vpn_user_link_exists || return 1
  ip -4 route replace default dev vpn_user table 200
  echo "VPN_USER_OVERRIDE vpn_user | default dev vpn_user scope link" > "$ROUTE_STATE_FILE"
  return 0
}

cleanup_probe_routes() {
  ip -4 route del 9.9.9.9/32 dev vpn_user 2>/dev/null || true
  ip -4 route del 1.1.1.1/32 dev vpn_user 2>/dev/null || true
}

strict_health_vpn_user() {
  vpn_user_link_exists || {
    echo "vpn_user link is missing"
    return 1
  }

  cleanup_probe_routes
  ip -4 route replace 9.9.9.9/32 dev vpn_user
  ip -4 route replace 1.1.1.1/32 dev vpn_user

  OK=1

  for IP in 9.9.9.9 1.1.1.1; do
    echo "=== ping $IP via vpn_user ==="
    OUT="$(ping -4 -I vpn_user -c 3 -W 2 "$IP" 2>&1 || true)"
    echo "$OUT"
    echo "$OUT" | grep -q " 0% packet loss" || OK=0
  done

  cleanup_probe_routes

  [ "$OK" = "1" ]
}

resolve_config() {
  ARG="$1"

  [ -f "$OK_LIST" ] || die "OK list not found: $OK_LIST"

  CONFIG_PATH=""
  CONFIG_FILE=""
  ENDPOINT=""
  AVG_MS=""

  if echo "$ARG" | grep -q '^/'; then
    CONFIG_PATH="$(awk -F '\t' -v c="$ARG" 'NR > 1 && $6 == c { print $6; exit }' "$OK_LIST")"
  else
    CONFIG_PATH="$(awk -F '\t' -v a="$ARG" 'NR > 1 && ($1 == a || $2 == a || $6 == a) { print $6; exit }' "$OK_LIST")"
  fi

  [ -n "$CONFIG_PATH" ] || die "config not found in current strict OK list: $ARG"
  [ -f "$CONFIG_PATH" ] || die "config path from OK list does not exist: $CONFIG_PATH"

  CONFIG_FILE="$(basename "$CONFIG_PATH")"
  ENDPOINT="$(awk -F '\t' -v c="$CONFIG_PATH" 'NR > 1 && $6 == c { print $3; exit }' "$OK_LIST")"
  AVG_MS="$(awk -F '\t' -v c="$CONFIG_PATH" 'NR > 1 && $6 == c { print $4; exit }' "$OK_LIST")"
}

cmd_list() {
  [ -f "$OK_LIST" ] || die "OK list not found: $OK_LIST"
  cat "$OK_LIST"
}

cmd_status() {
  load_state

  NOW="$(now_epoch)"
  DEV="$(current_table200_default_dev)"

  echo "status=${status:-inactive}"
  echo "now_epoch=$NOW"
  echo "table200_default_dev=${DEV:-}"
  echo "state_file=$STATE"

  if [ -f "$STATE" ]; then
    echo "state_exists=1"
    echo "config_file=${config_file:-}"
    echo "config_path=${config_path:-}"
    echo "endpoint=${endpoint:-}"
    echo "activated_at_epoch=${activated_at_epoch:-}"
    echo "expires_at_epoch=${expires_at_epoch:-}"
    echo "minutes=${minutes:-}"
    echo "prev_default_dev=${prev_default_dev:-}"

    if [ -n "${expires_at_epoch:-}" ]; then
      REMAIN=$((expires_at_epoch - NOW))
      [ "$REMAIN" -lt 0 ] && REMAIN=0
      echo "remaining_seconds=$REMAIN"
    fi
  else
    echo "state_exists=0"
  fi

  echo
  echo "=== network.vpn_user safe ==="
  uci show network.vpn_user 2>/dev/null \
    | grep -vE "\.(private_key|public_key|preshared_key|password|secret|token|key)='" \
    || true

  echo
  echo "=== table 200 ==="
  cat "$ROUTE_STATE_FILE" 2>/dev/null || true
  ip -4 route show table 200 2>/dev/null || true
}

write_state() {
  mkdir -p "$STATE_DIR"

  TMP="${STATE}.tmp.$$"
  {
    echo "status='active'"
    echo "config_file='$CONFIG_FILE'"
    echo "config_path='$CONFIG_PATH'"
    echo "endpoint='$ENDPOINT'"
    echo "avg_ms='${AVG_MS:-}'"
    echo "activated_at_epoch='$NOW'"
    echo "expires_at_epoch='$EXPIRES'"
    echo "minutes='$MINUTES'"
    echo "prev_default_dev='$PREV_DEFAULT_DEV'"
  } > "$TMP"

  mv "$TMP" "$STATE"
  chmod 600 "$STATE"
}

cmd_activate() {
  [ $# -eq 2 ] || {
    usage
    exit 1
  }

  ARG="$1"
  MINUTES="$2"

  case "$MINUTES" in
    ''|*[!0-9]*) die "minutes must be numeric" ;;
  esac

  [ "$MINUTES" -ge 1 ] || die "minutes must be >= 1"
  [ "$MINUTES" -le 1440 ] || die "minutes must be <= 1440"

  [ -x "$LOADER" ] || die "loader missing or not executable: $LOADER"

  lock_or_die
  resolve_config "$ARG"

  NOW="$(now_epoch)"
  EXPIRES=$((NOW + MINUTES * 60))
  PREV_DEFAULT_DEV="$(current_table200_default_dev)"

  log "activate requested config=$CONFIG_FILE endpoint=$ENDPOINT minutes=$MINUTES prev_default_dev=${PREV_DEFAULT_DEV:-}"

  echo "=== load config into vpn_user ==="
  "$LOADER" "$CONFIG_PATH" up

  echo
  echo "=== wait for vpn_user ==="
  sleep 3
  ip -br addr show vpn_user 2>/dev/null || ip addr show vpn_user 2>/dev/null || true

  echo
  echo "=== strict health check ==="
  if ! strict_health_vpn_user; then
    ifdown vpn_user 2>/dev/null || true
    die "strict health failed for vpn_user"
  fi

  echo
  echo "=== activate table 200 override ==="
  ensure_vpn_user_route || die "failed to set table 200 default dev vpn_user"

  write_state

  log "activated config=$CONFIG_FILE endpoint=$ENDPOINT until_epoch=$EXPIRES"

  echo
  echo "ACTIVATE_OK"
  cmd_status
}

cmd_clear() {
  lock_or_die
  load_state

  log "clear requested status=${status:-inactive} config=${config_file:-}"

  rm -f "$STATE"

  if [ "$(current_table200_default_dev)" = "vpn_user" ]; then
    ip -4 route del default table 200 2>/dev/null || true
  fi

  ifdown vpn_user 2>/dev/null || true

  if [ -x "$MANAGER" ]; then
    "$MANAGER" >/dev/null 2>&1 || true
  fi

  log "clear done"

  echo "CLEAR_OK"
  cmd_status
}

cmd_tick() {
  load_state

  [ "${status:-}" = "active" ] || exit 0
  [ -n "${expires_at_epoch:-}" ] || exit 0

  NOW="$(now_epoch)"

  if [ "$NOW" -ge "$expires_at_epoch" ]; then
    log "override expired config=${config_file:-}"
    cmd_clear >/dev/null 2>&1 || true
    exit 0
  fi

  if vpn_user_link_exists; then
    ensure_vpn_user_route >/dev/null 2>&1 || true
  fi

  exit 0
}

cmd_manager_guard() {
  load_state

  [ "${status:-}" = "active" ] || exit 1
  [ -n "${expires_at_epoch:-}" ] || exit 1

  NOW="$(now_epoch)"
  [ "$NOW" -lt "$expires_at_epoch" ] || exit 1

  vpn_user_link_exists || exit 1

  ensure_vpn_user_route >/dev/null 2>&1 || exit 1
  exit 0
}

CMD="${1:-}"

case "$CMD" in
  list)
    shift
    cmd_list "$@"
    ;;
  status)
    shift
    cmd_status "$@"
    ;;
  activate)
    shift
    cmd_activate "$@"
    ;;
  clear)
    shift
    cmd_clear "$@"
    ;;
  tick)
    shift
    cmd_tick "$@"
    ;;
  manager-guard)
    shift
    cmd_manager_guard "$@"
    ;;
  *)
    usage
    exit 1
    ;;
esac
