#!/bin/sh
# Canonical VM101 LOCAL_REPAIR watcher. BusyBox ash compatible.
set -u

VM101_CONF="${VM101_CONF:-/etc/router-egress-vm101.conf}"
[ -r "$VM101_CONF" ] && . "$VM101_CONF"

ENABLED="${LOCAL_REPAIR_ENABLED:-0}"
MODE="${LOCAL_REPAIR_MODE:---dry-run}"
INTERVAL_SEC="${HEALTH_CHECK_INTERVAL_SEC:-60}"
FAIL_THRESHOLD="${HEALTH_FAILURES_BEFORE_DOWN:-2}"
COOLDOWN_SEC="${LOCAL_REPAIR_COOLDOWN_SEC:-900}"
SLOTS_CONF="${SLOTS_CONF:-/etc/router-egress-slots.d/slots.conf}"
STATE_ROOT="${STATE_DIR:-/var/lib/router-egress-recovery}"
WATCH_STATE_DIR="$STATE_ROOT/health-watch"
LOG="${HEALTH_REPAIR_LOG:-/var/log/router-egress-health-repair.log}"
DISPATCHER="${RECOVERY_DISPATCHER:-/usr/local/sbin/router-egress-recovery-dispatcher.sh}"

ONCE=false
FORCE_SLOT=""
RUN_MODE=loop
while [ "$#" -gt 0 ]; do
    case "$1" in
        --once) ONCE=true; RUN_MODE=once; shift ;;
        --dry-run) MODE=--dry-run; shift ;;
        --commit) MODE=--commit; shift ;;
        --force-slot)
            [ "$#" -ge 2 ] || { echo 'ERROR=force_slot_value_missing' >&2; exit 2; }
            FORCE_SLOT="$2"; shift 2 ;;
        *) echo "ERROR=unsupported_argument:$1" >&2; exit 2 ;;
    esac
done

case "$MODE" in --dry-run|--commit) ;; *) echo "ERROR=invalid_mode:$MODE" >&2; exit 2 ;; esac
case "$FAIL_THRESHOLD:$INTERVAL_SEC:$COOLDOWN_SEC" in *[!0-9:]*) echo 'ERROR=invalid_numeric_configuration' >&2; exit 2 ;; esac
[ -r "$SLOTS_CONF" ] || { echo "ERROR=slots_conf_missing:$SLOTS_CONF" >&2; exit 2; }
[ -x "$DISPATCHER" ] || { echo "ERROR=dispatcher_missing:$DISPATCHER" >&2; exit 2; }
mkdir -p "$WATCH_STATE_DIR" "$(dirname "$LOG")" || exit 2

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
uint_or_zero() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

slot_ok() {
    iface="$1"
    targets="$2"
    count="$3"
    timeout="$4"
    ip link show "$iface" >/dev/null 2>&1 || return 1
    old_ifs="$IFS"; IFS=','
    for target in $targets; do
        IFS="$old_ifs"
        [ -n "$target" ] || continue
        ping -I "$iface" -c "$count" -W "$timeout" "$target" >/dev/null 2>&1 || return 1
        IFS=','
    done
    IFS="$old_ifs"
    return 0
}

run_once() {
    now="$(date +%s)"
    rows="/tmp/router-egress-health-rows.$$"
    json="/tmp/router-egress-health-json.$$"
    trap 'rm -f "$rows" "$json"' EXIT HUP INT TERM
    grep -Ev '^[[:space:]]*(#|$)' "$SLOTS_CONF" >"$rows"
    : >"$json"
    first=true
    any_action=false

    while read -r slot iface table mark dscp provider adapter targets strict_count strict_timeout enabled rest; do
        [ -n "${slot:-}" ] || continue
        [ -z "$FORCE_SLOT" ] || [ "$slot" = "$FORCE_SLOT" ] || continue
        [ "$enabled" = "1" ] || continue

        strict_count="$(uint_or_zero "$strict_count")"; [ "$strict_count" -gt 0 ] || strict_count=3
        strict_timeout="$(uint_or_zero "$strict_timeout")"; [ "$strict_timeout" -gt 0 ] || strict_timeout=2
        fail_file="$WATCH_STATE_DIR/fail-$slot"
        cooldown_file="$WATCH_STATE_DIR/cooldown-$slot"
        fail_count="$(uint_or_zero "$(cat "$fail_file" 2>/dev/null || true)")"
        cooldown_until="$(uint_or_zero "$(cat "$cooldown_file" 2>/dev/null || true)")"
        health_ok=false
        decision=none
        action=none
        dispatcher_rc=0
        required_confirm=""

        if slot_ok "$iface" "$targets" "$strict_count" "$strict_timeout"; then
            health_ok=true
            fail_count=0
            echo 0 >"$fail_file"
            decision=healthy
        else
            fail_count=$((fail_count + 1))
            echo "$fail_count" >"$fail_file"
            if [ "$fail_count" -lt "$FAIL_THRESHOLD" ]; then
                decision=fail_observed_below_threshold
            elif [ "$now" -lt "$cooldown_until" ]; then
                decision=cooldown
            else
                dry_out="/tmp/router-egress-health-dry-${slot}.$$"
                dry_err="/tmp/router-egress-health-dry-${slot}.$$.err"
                set +e
                "$DISPATCHER" --dry-run --slot "$slot" --reason health_watch >"$dry_out" 2>"$dry_err"
                dry_rc=$?
                set -e
                required_confirm="$(sed -n 's/.*"required_dispatch_confirm": "\([^"]*\)".*/\1/p' "$dry_out" | head -n1)"
                dry_decision="$(sed -n 's/.*"decision": "\([^"]*\)".*/\1/p' "$dry_out" | head -n1)"
                rm -f "$dry_err"

                if [ "$dry_rc" -eq 0 ] && [ "$dry_decision" = dry_run_ok ] && [ "$MODE" = --commit ] && [ -n "$required_confirm" ]; then
                    commit_out="/tmp/router-egress-health-commit-${slot}.$$"
                    commit_err="/tmp/router-egress-health-commit-${slot}.$$.err"
                    set +e
                    "$DISPATCHER" --commit --slot "$slot" --reason health_watch --confirm "$required_confirm" >"$commit_out" 2>"$commit_err"
                    dispatcher_rc=$?
                    set -e
                    decision="$(sed -n 's/.*"decision": "\([^"]*\)".*/\1/p' "$commit_out" | head -n1)"
                    [ -n "$decision" ] || decision=commit_failed_no_decision
                    action=commit_dispatch
                    any_action=true
                    echo $((now + COOLDOWN_SEC)) >"$cooldown_file"
                    if [ "$dispatcher_rc" -eq 0 ] && [ "$decision" = commit_ok ]; then
                        echo 0 >"$fail_file"
                        fail_count=0
                    fi
                    cat "$commit_err" >>"$LOG" 2>/dev/null || true
                    rm -f "$commit_out" "$commit_err"
                else
                    dispatcher_rc="$dry_rc"
                    decision="$dry_decision"
                    [ -n "$decision" ] || decision=dry_run_failed_no_decision
                    action=dry_run_dispatch
                fi
                rm -f "$dry_out"
            fi
        fi

        $first || printf ',\n' >>"$json"
        first=false
        printf '    {"slot":"%s","iface":"%s","health_ok":%s,"fail_count":%s,"decision":"%s","action":"%s","dispatcher_rc":%s,"required_confirm":"%s"}' \
            "$(json_escape "$slot")" "$(json_escape "$iface")" "$health_ok" "$fail_count" \
            "$(json_escape "$decision")" "$(json_escape "$action")" "$dispatcher_rc" \
            "$(json_escape "$required_confirm")" >>"$json"
        printf '%s slot=%s iface=%s health_ok=%s fail_count=%s decision=%s action=%s dispatcher_rc=%s mode=%s\n' \
            "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$slot" "$iface" "$health_ok" "$fail_count" \
            "$decision" "$action" "$dispatcher_rc" "$MODE" >>"$LOG"
    done <"$rows"

    printf '{\n  "schema":"router-egress-health-repair-watch-v3",\n  "mode":"%s",\n  "run_mode":"%s",\n  "any_action":%s,\n  "slots":[\n' \
        "$(json_escape "$MODE")" "$RUN_MODE" "$any_action"
    cat "$json"
    printf '\n  ]\n}\n'
}

if [ "$ENABLED" != "1" ] && [ "$ONCE" != true ]; then
    echo "health_repair disabled by $VM101_CONF"
    exit 0
fi

if [ "$ONCE" = true ]; then
    run_once
    exit 0
fi

while true; do
    run_once >"$WATCH_STATE_DIR/last.json.tmp" 2>"$WATCH_STATE_DIR/last.err.tmp" || true
    mv "$WATCH_STATE_DIR/last.json.tmp" "$WATCH_STATE_DIR/last.json" 2>/dev/null || true
    mv "$WATCH_STATE_DIR/last.err.tmp" "$WATCH_STATE_DIR/last.err" 2>/dev/null || true
    sleep "$INTERVAL_SEC"
done
