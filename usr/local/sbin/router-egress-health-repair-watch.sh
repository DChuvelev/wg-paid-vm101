#!/bin/sh
set -u

CONF="${CONF:-/etc/router-egress-health-repair.conf}"
[ -f "$CONF" ] && . "$CONF"

ENABLED="${ENABLED:-0}"
MODE="${MODE:---dry-run}"
INTERVAL_SEC="${INTERVAL_SEC:-60}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"
COOLDOWN_SEC="${COOLDOWN_SEC:-900}"
PING_TARGETS="${PING_TARGETS:-1.1.1.1 8.8.8.8}"
STATE_DIR="${STATE_DIR:-/var/lib/router-egress-recovery/health-watch}"
LOG="${LOG:-/var/log/router-egress-health-repair.log}"
SLOTS_CONF="${SLOTS_CONF:-/etc/router-egress-slots.d/slots.conf}"
DISPATCHER="${DISPATCHER:-/usr/local/sbin/router-egress-recovery-dispatcher.sh}"

ONCE=false
FORCE_SLOT=""
RUN_MODE="loop"

while [ $# -gt 0 ]; do
  case "$1" in
    --once) ONCE=true; RUN_MODE="once"; shift ;;
    --dry-run) MODE="--dry-run"; shift ;;
    --commit) MODE="--commit"; shift ;;
    --force-slot) FORCE_SLOT="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

slot_ok() {
  slot="$1"
  iface="$2"

  ip link show "$iface" >/dev/null 2>&1 || return 1

  for target in $PING_TARGETS; do
    safe_target="$(echo "$target" | sed 's#[^A-Za-z0-9]#_#g')"
    out="/tmp/health-watch-${slot}-${iface}-${safe_target}-$$.out"
    err="/tmp/health-watch-${slot}-${iface}-${safe_target}-$$.err"

    ping -I "$iface" -c 3 -W 2 "$target" > "$out" 2> "$err"
    rc=$?
    recv="$(grep -Eo '[0-9]+ packets received' "$out" 2>/dev/null | awk '{print $1}' | tail -1)"
    [ -n "$recv" ] || recv=0

    rm -f "$out" "$err"

    [ "$rc" = "0" ] && [ "$recv" = "3" ] || return 1
  done

  return 0
}

run_once() {
  now="$(date +%s)"
  slots_file="/tmp/health-watch-slots-$$.txt"
  json_slots="/tmp/health-watch-json-slots-$$.txt"
  action_file="/tmp/health-watch-any-action-$$.txt"

  trap 'rm -f "$slots_file" "$json_slots" "$action_file"' EXIT

  : > "$json_slots"
  echo false > "$action_file"

  grep -Ev '^[[:space:]]*(#|$)' "$SLOTS_CONF" 2>/dev/null > "$slots_file"

  first=1
  while read -r slot iface table mark dscp provider adapter rest; do
    [ -n "${slot:-}" ] || continue
    [ -z "$FORCE_SLOT" ] || [ "$slot" = "$FORCE_SLOT" ] || continue

    status_ok=true
    if slot_ok "$slot" "$iface"; then
      status_ok=true
    else
      status_ok=false
    fi

    fail_file="$STATE_DIR/fail-${slot}"
    cooldown_file="$STATE_DIR/cooldown-${slot}"
    fail_count="$(cat "$fail_file" 2>/dev/null || echo 0)"
    case "$fail_count" in ''|*[!0-9]*) fail_count=0 ;; esac

    decision=""
    action="none"
    dispatcher_decision=""
    required_confirm=""

    if [ "$status_ok" = "true" ]; then
      fail_count=0
      echo 0 > "$fail_file"
      decision="healthy"
      action="none"
    else
      fail_count=$((fail_count + 1))
      echo "$fail_count" > "$fail_file"

      cooldown_until="$(cat "$cooldown_file" 2>/dev/null || echo 0)"
      case "$cooldown_until" in ''|*[!0-9]*) cooldown_until=0 ;; esac

      if [ "$fail_count" -lt "$FAIL_THRESHOLD" ]; then
        decision="fail_observed_below_threshold"
        action="none"
      elif [ "$now" -lt "$cooldown_until" ]; then
        decision="cooldown"
        action="none"
      else
        dry="$("$DISPATCHER" --dry-run --slot "$slot" --reason health_watch 2>/dev/null || true)"
        required_confirm="$(printf '%s\n' "$dry" | sed -n 's/.*"required_dispatch_confirm": "\([^"]*\)".*/\1/p' | head -1)"
        dispatcher_decision="$(printf '%s\n' "$dry" | sed -n 's/.*"decision": "\([^"]*\)".*/\1/p' | head -1)"

        if [ "$dispatcher_decision" = "dry_run_ok" ] && [ "$MODE" = "--commit" ] && [ -n "$required_confirm" ]; then
          commit="$("$DISPATCHER" --commit --slot "$slot" --reason health_watch --confirm "$required_confirm" 2>/dev/null || true)"
          dispatcher_decision="$(printf '%s\n' "$commit" | sed -n 's/.*"decision": "\([^"]*\)".*/\1/p' | head -1)"
          action="commit_dispatch"
          echo true > "$action_file"
          echo $((now + COOLDOWN_SEC)) > "$cooldown_file"
          [ "$dispatcher_decision" = "commit_ok" ] && echo 0 > "$fail_file"
          decision="$dispatcher_decision"
        else
          action="dry_run_dispatch"
          decision="$dispatcher_decision"
          if [ "$MODE" = "--dry-run" ]; then
            # Dry-run must not create real cooldown that can hide later simulation.
            :
          fi
        fi
      fi
    fi

    if [ "$first" = "1" ]; then
      first=0
    else
      echo "," >> "$json_slots"
    fi

    printf '    {"slot":"%s","iface":"%s","status_ok":%s,"fail_count":%s,"decision":"%s","action":"%s","required_confirm":"%s"}' \
      "$(json_escape "$slot")" "$(json_escape "$iface")" "$status_ok" "$fail_count" "$(json_escape "$decision")" "$(json_escape "$action")" "$(json_escape "$required_confirm")" >> "$json_slots"

    echo "health_repair ts=$(date -Is) slot=$slot iface=$iface status_ok=$status_ok fail_count=$fail_count decision=$decision action=$action mode=$MODE run_mode=$RUN_MODE" >> "$LOG"
  done < "$slots_file"

  any_action="$(cat "$action_file" 2>/dev/null || echo false)"

  echo "{"
  echo '  "schema": "router-egress-health-repair-watch-v2",'
  echo "  \"mode\": \"$(json_escape "$MODE")\","
  echo "  \"run_mode\": \"$(json_escape "$RUN_MODE")\","
  echo '  "slots": ['
  cat "$json_slots"
  echo
  echo '  ],'
  echo "  \"any_action\": $any_action"
  echo "}"
}

if [ "$ENABLED" != "1" ] && [ "$ONCE" != "true" ]; then
  echo "health_repair disabled in $CONF"
  exit 0
fi

if [ "$ONCE" = "true" ]; then
  run_once
  exit 0
fi

while true; do
  run_once > "$STATE_DIR/last.json.tmp" 2> "$STATE_DIR/last.err.tmp" || true
  mv "$STATE_DIR/last.json.tmp" "$STATE_DIR/last.json" 2>/dev/null || true
  mv "$STATE_DIR/last.err.tmp" "$STATE_DIR/last.err" 2>/dev/null || true
  sleep "$INTERVAL_SEC"
done
