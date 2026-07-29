#!/bin/sh
# R20Q-N: service-owned cached retained-config bootstrap controller for VM101.
# BusyBox ash compatible. It never performs provider acquisition or heavy full refresh.
set -u
umask 077
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

MAIN_CONFIG="${ROUTER_BOOTSTRAP_MAIN_CONFIG:-/etc/router-egress-vm101.conf}"
CONFIG="${ROUTER_BOOTSTRAP_CONFIG:-/etc/router-egress-zero-healthy-bootstrap.conf}"
[ -r "$MAIN_CONFIG" ] || { echo RESULT=STOP_R20QN_MAIN_CONFIG_MISSING; exit 70; }
[ -r "$CONFIG" ] || { echo RESULT=STOP_R20QN_BOOTSTRAP_CONFIG_MISSING; exit 70; }
. "$MAIN_CONFIG"
. "$CONFIG"

ENABLED="${ROUTER_BOOTSTRAP_ENABLED:-${BOOTSTRAP_CONTROLLER_ENABLED:-0}}"
TICK_SEC="${ROUTER_BOOTSTRAP_TICK_SEC:-${BOOTSTRAP_CONTROLLER_TICK_SEC:-30}}"
STATE_DIR="${ROUTER_BOOTSTRAP_STATE_DIR:-${BOOTSTRAP_CONTROLLER_STATE_DIR:-/etc/router-egress-zero-healthy-bootstrap}}"
STATE_FILE="${ROUTER_BOOTSTRAP_STATE_FILE:-${BOOTSTRAP_CONTROLLER_STATE_FILE:-$STATE_DIR/state.kv}}"
LOCK_DIR="${ROUTER_BOOTSTRAP_LOCK_DIR:-${BOOTSTRAP_CONTROLLER_LOCK_DIR:-/var/run/router-egress-zero-healthy-bootstrap.lock}}"
DIRECT_STATE="${ROUTER_BOOTSTRAP_DIRECT_STATE:-${BOOTSTRAP_CONTROLLER_DIRECT_STATE:-/etc/router-wgpay-direct/state.kv}}"
STATUS_CMD="${ROUTER_BOOTSTRAP_STATUS_CMD:-${BOOTSTRAP_CONTROLLER_STATUS_CMD:-/usr/local/sbin/router-egress-slots-status.sh}}"
DISPATCHER="${ROUTER_BOOTSTRAP_DISPATCHER:-${BOOTSTRAP_CONTROLLER_DISPATCHER:-/usr/local/sbin/router-egress-recovery-dispatcher.sh}}"
STATE_HELPER="${ROUTER_BOOTSTRAP_RECOVERY_STATE_HELPER:-${BOOTSTRAP_CONTROLLER_RECOVERY_STATE_HELPER:-/usr/local/lib/router-egress-recovery-state.sh}}"
LOG="${ROUTER_BOOTSTRAP_LOG:-${BOOTSTRAP_CONTROLLER_LOG:-/var/log/router-egress-zero-healthy-bootstrap.log}}"
REASON="${ROUTER_BOOTSTRAP_REASON:-${BOOTSTRAP_CONTROLLER_REASON:-zero_healthy_cached_bootstrap}}"
SLOT="${ROUTER_BOOTSTRAP_SLOT:-${BOOTSTRAP_SLOT:-egress1}}"
RETRY_SEC="${ROUTER_BOOTSTRAP_RETRY_INTERVAL_SEC:-${BOOTSTRAP_RETRY_INTERVAL_SEC:-300}}"
CANDIDATE_RETRIES="${ROUTER_BOOTSTRAP_CANDIDATE_RETRY_COUNT:-${BOOTSTRAP_CANDIDATE_RETRY_COUNT:-3}}"
NOW="${ROUTER_BOOTSTRAP_NOW_EPOCH:-$(date +%s)}"
SCHEMA=router-egress-zero-healthy-bootstrap-state-v1

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
for value in "$TICK_SEC" "$RETRY_SEC" "$CANDIDATE_RETRIES" "$NOW"; do
    is_uint "$value" || { echo RESULT=STOP_R20QN_NUMERIC_CONFIG_INVALID; exit 70; }
done
[ "$TICK_SEC" -gt 0 ] || TICK_SEC=30
[ "$RETRY_SEC" -gt 0 ] || RETRY_SEC=300
[ "$CANDIDATE_RETRIES" -gt 0 ] || CANDIDATE_RETRIES=1
case "$SLOT" in egress[1-5]) ;; *) echo RESULT=STOP_R20QN_BOOTSTRAP_SLOT_INVALID; exit 70 ;; esac

kv_get() {
    key="$1"; file="$2"
    sed -n "s/^${key}=//p" "$file" 2>/dev/null | tail -n1
}
json_get_string() {
    key="$1"
    sed -n "s/.*\"${key}\": \"\([^\"]*\)\".*/\1/p" | head -n1
}
json_get_uint() {
    key="$1"
    sed -n "s/.*\"${key}\":[[:space:]]*\([0-9][0-9]*\).*/\1/p" | tail -n1
}
process_token() {
    pid="$1"; [ -r "/proc/$pid/stat" ] || return 1
    awk '{print $22}' "/proc/$pid/stat" 2>/dev/null
}
lock_acquire() {
    parent="$(dirname "$LOCK_DIR")"; mkdir -p "$parent" 2>/dev/null || return 1
    if mkdir "$LOCK_DIR" 2>/dev/null; then :; else
        old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        old_token="$(cat "$LOCK_DIR/process_token" 2>/dev/null || true)"
        live_token=''
        case "$old_pid" in ''|*[!0-9]*) ;; *) live_token="$(process_token "$old_pid" 2>/dev/null || true)" ;; esac
        [ -n "$old_token" ] && [ "$live_token" = "$old_token" ] && return 1
        rm -rf "$LOCK_DIR" 2>/dev/null || return 1
        mkdir "$LOCK_DIR" 2>/dev/null || return 1
    fi
    printf '%s\n' "$$" > "$LOCK_DIR/pid" || { rm -rf "$LOCK_DIR"; return 1; }
    process_token "$$" > "$LOCK_DIR/process_token" 2>/dev/null || : > "$LOCK_DIR/process_token"
    return 0
}
lock_release() {
    [ "$(cat "$LOCK_DIR/pid" 2>/dev/null || true)" = "$$" ] || return 1
    rm -rf "$LOCK_DIR"
}
atomic_write() {
    src="$1"; dst="$2"; mkdir -p "$(dirname "$dst")" || return 1
    cp "$src" "$dst.new.$$" && chmod 600 "$dst.new.$$" && mv "$dst.new.$$" "$dst"
}
state_get() { kv_get "$1" "$STATE_FILE"; }
write_state() {
    state_mode="$1"; result="$2"; reason="$3"; candidate="$4"; before="$5"; after="$6"; next_epoch="$7"; attempts="$8"; refresh_result="$9"
    mkdir -p "$STATE_DIR" || return 1; chmod 700 "$STATE_DIR" 2>/dev/null || true
    tmp="$STATE_DIR/state.$$"
    {
        echo schema="$SCHEMA"
        echo mode="$state_mode"
        echo updated_epoch="$NOW"
        echo last_attempt_epoch="$NOW"
        echo next_attempt_epoch="$next_epoch"
        echo attempt_count="$attempts"
        echo last_result="$result"
        echo last_reason="$reason"
        echo bootstrap_slot="$SLOT"
        echo candidate_endpoint="$candidate"
        echo healthy_before="$before"
        echo healthy_after="$after"
        echo refresh_request_result="$refresh_result"
    } > "$tmp" || return 1
    atomic_write "$tmp" "$STATE_FILE" || return 1
    rm -f "$tmp"
}
log_event() {
    mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" "$*" >> "$LOG" 2>/dev/null || true
}
healthy_count() {
    output="$($STATUS_CMD 2>/dev/null || true)"
    value="$(printf '%s\n' "$output" | json_get_uint healthy)"
    is_uint "$value" || return 1
    [ "$value" -le 5 ] || return 1
    printf '%s\n' "$value"
}
direct_required() {
    [ -s "$DIRECT_STATE" ] || return 1
    [ "$(kv_get direct_required "$DIRECT_STATE")" = true ]
}
emit_noop() {
    result="$1"; healthy="$2"
    echo RESULT="$result"
    echo BOOTSTRAP_SLOT="$SLOT"
    echo HEALTHY_SLOT_COUNT="$healthy"
    echo BOOTSTRAP_ACTION_PERFORMED=false
}
refresh_result_ok() {
    case "$1" in
        REQUESTED|NOOP_ALREADY_PENDING|NOOP_ALREADY_RUNNING|NOOP_RETRY_ACTIVE) return 0 ;;
        *) return 1 ;;
    esac
}
request_refresh() {
    . "$STATE_HELPER"
    reg_request_full_refresh "$REASON" "$SLOT" 2>/dev/null
}

mode="${1:---tick}"
case "$mode" in
    --status)
        if [ -s "$STATE_FILE" ]; then cat "$STATE_FILE"; else echo schema="$SCHEMA"; echo initialized=false; echo enabled="$ENABLED"; fi
        exit 0
        ;;
    --loop)
        while :; do
            loop_output="$("$0" --tick 2>&1)"; loop_rc=$?
            loop_result="$(printf '%s\n' "$loop_output" | sed -n 's/^RESULT=//p' | tail -n1)"
            case "$loop_result" in
                NOOP_R20QN_BOOTSTRAP_HEALTHY|NOOP_R20QN_DIRECT_NOT_REQUIRED|NOOP_R20QN_BOOTSTRAP_NOT_DUE|NOOP_R20QN_REFRESH_HANDOFF_NOT_DUE|NOOP_R20QN_BOOTSTRAP_LOCKED|NOOP_R20QN_BOOTSTRAP_DISABLED) ;;
                *) printf '%s\n' "$loop_output" ;;
            esac
            [ "$loop_rc" -eq 0 ] || log_event "result=loop_tick_error rc=$loop_rc marker=${loop_result:-missing}"
            sleep "$TICK_SEC"
        done
        ;;
    --tick) ;;
    *) echo 'Usage: router-egress-zero-healthy-bootstrap.sh --tick|--loop|--status' >&2; exit 64 ;;
esac

[ "$ENABLED" = 1 ] || { emit_noop NOOP_R20QN_BOOTSTRAP_DISABLED 0; exit 0; }
[ -x "$STATUS_CMD" ] || { echo RESULT=STOP_R20QN_STATUS_COMMAND_MISSING; exit 70; }
[ -x "$DISPATCHER" ] || { echo RESULT=STOP_R20QN_DISPATCHER_MISSING; exit 70; }
[ -r "$STATE_HELPER" ] || { echo RESULT=STOP_R20QN_STATE_HELPER_MISSING; exit 70; }

healthy_before="$(healthy_count)" || { echo RESULT=STOP_R20QN_STATUS_OUTPUT_INVALID; exit 70; }
controller_mode="$(state_get mode 2>/dev/null || true)"
next_attempt="$(state_get next_attempt_epoch 2>/dev/null || true)"; is_uint "$next_attempt" || next_attempt=0
attempts="$(state_get attempt_count 2>/dev/null || true)"; is_uint "$attempts" || attempts=0
candidate="$(state_get candidate_endpoint 2>/dev/null || true)"

# A recovered slot must not lose the full-refresh handoff merely because the
# recovery-state write lock was briefly busy on the first request.
if [ "$healthy_before" -gt 0 ] && [ "$controller_mode" = REFRESH_HANDOFF_RETRY ]; then
    if [ "$next_attempt" -gt "$NOW" ]; then
        echo RESULT=NOOP_R20QN_REFRESH_HANDOFF_NOT_DUE
        echo NEXT_ATTEMPT_EPOCH="$next_attempt"
        echo HEALTHY_SLOT_COUNT="$healthy_before"
        echo BOOTSTRAP_ACTION_PERFORMED=false
        exit 0
    fi
    if ! lock_acquire; then emit_noop NOOP_R20QN_BOOTSTRAP_LOCKED "$healthy_before"; exit 0; fi
    trap 'lock_release >/dev/null 2>&1 || true' EXIT HUP INT TERM
    refresh_result="$(request_refresh 2>/dev/null)"; refresh_rc=$?
    if [ "$refresh_rc" -eq 0 ] && refresh_result_ok "$refresh_result"; then
        write_state RECOVERED PASS_REFRESH_HANDOFF_RETRY refresh_handoff_recovered "$candidate" "$healthy_before" "$healthy_before" 0 "$attempts" "$refresh_result" || { echo RESULT=STOP_R20QN_STATE_WRITE_FAILED; exit 70; }
        log_event "result=pass_refresh_handoff_retry slot=$SLOT healthy=$healthy_before refresh_request=$refresh_result"
        echo RESULT=PASS_R20QN_REFRESH_HANDOFF_RECOVERED
        echo HEALTHY_SLOT_COUNT="$healthy_before"
        echo REFRESH_REQUEST_RESULT="$refresh_result"
        echo BOOTSTRAP_ACTION_PERFORMED=false
        exit 0
    fi
    due=$((NOW + RETRY_SEC))
    write_state REFRESH_HANDOFF_RETRY REFRESH_REQUEST_FAILED refresh_handoff_retry "$candidate" "$healthy_before" "$healthy_before" "$due" "$attempts" "${refresh_result:-ERROR_REQUEST_FAILED}" || { echo RESULT=STOP_R20QN_STATE_WRITE_FAILED; exit 70; }
    log_event "result=refresh_handoff_retry_failed slot=$SLOT healthy=$healthy_before next_attempt_epoch=$due refresh_request=${refresh_result:-empty} rc=$refresh_rc"
    echo RESULT=RETRY_R20QN_REFRESH_HANDOFF_FAILED
    echo HEALTHY_SLOT_COUNT="$healthy_before"
    echo NEXT_ATTEMPT_EPOCH="$due"
    echo REFRESH_REQUEST_RESULT="${refresh_result:-ERROR_REQUEST_FAILED}"
    echo BOOTSTRAP_ACTION_PERFORMED=false
    exit 0
fi

if [ "$healthy_before" -gt 0 ]; then emit_noop NOOP_R20QN_BOOTSTRAP_HEALTHY "$healthy_before"; exit 0; fi
if ! direct_required; then emit_noop NOOP_R20QN_DIRECT_NOT_REQUIRED "$healthy_before"; exit 0; fi
if [ "$next_attempt" -gt "$NOW" ]; then
    echo RESULT=NOOP_R20QN_BOOTSTRAP_NOT_DUE
    echo NEXT_ATTEMPT_EPOCH="$next_attempt"
    echo HEALTHY_SLOT_COUNT="$healthy_before"
    echo BOOTSTRAP_ACTION_PERFORMED=false
    exit 0
fi

if ! lock_acquire; then emit_noop NOOP_R20QN_BOOTSTRAP_LOCKED "$healthy_before"; exit 0; fi
trap 'lock_release >/dev/null 2>&1 || true' EXIT HUP INT TERM
healthy_before="$(healthy_count)" || { echo RESULT=STOP_R20QN_STATUS_OUTPUT_INVALID; exit 70; }
if [ "$healthy_before" -gt 0 ]; then emit_noop NOOP_R20QN_BOOTSTRAP_HEALTHY "$healthy_before"; exit 0; fi
if ! direct_required; then emit_noop NOOP_R20QN_DIRECT_NOT_REQUIRED "$healthy_before"; exit 0; fi

attempts=$((attempts + 1))
write_state RUNNING RUNNING "$REASON" '' "$healthy_before" "$healthy_before" 0 "$attempts" NOT_REQUESTED || { echo RESULT=STOP_R20QN_STATE_WRITE_FAILED; exit 70; }

dry_output="$(LOCAL_REPAIR_CANDIDATE_RETRIES="$CANDIDATE_RETRIES" "$DISPATCHER" --dry-run --slot "$SLOT" --reason "$REASON" 2>&1)"; dry_rc=$?
dry_decision="$(printf '%s\n' "$dry_output" | json_get_string decision)"
dry_reason="$(printf '%s\n' "$dry_output" | json_get_string reason)"
candidate="$(printf '%s\n' "$dry_output" | json_get_string candidate_endpoint)"
confirm="$(printf '%s\n' "$dry_output" | json_get_string required_dispatch_confirm)"
if [ "$dry_rc" -ne 0 ] || [ "$dry_decision" != dry_run_ok ] || [ -z "$candidate" ] || [ -z "$confirm" ]; then
    due=$((NOW + RETRY_SEC))
    write_state RETRY NO_CACHED_CANDIDATE "${dry_reason:-dispatcher_not_ready}" "$candidate" "$healthy_before" "$healthy_before" "$due" "$attempts" NOT_REQUESTED || { echo RESULT=STOP_R20QN_STATE_WRITE_FAILED; exit 70; }
    log_event "result=no_cached_candidate slot=$SLOT reason=${dry_reason:-unknown} next_attempt_epoch=$due"
    echo RESULT=NOOP_R20QN_CACHED_BOOTSTRAP_NO_CANDIDATE
    echo BOOTSTRAP_SLOT="$SLOT"
    echo DISPATCHER_RC="$dry_rc"
    echo DISPATCHER_REASON="${dry_reason:-unknown}"
    echo NEXT_ATTEMPT_EPOCH="$due"
    echo BOOTSTRAP_ACTION_PERFORMED=false
    exit 0
fi

commit_output="$(LOCAL_REPAIR_CANDIDATE_RETRIES="$CANDIDATE_RETRIES" "$DISPATCHER" --commit --slot "$SLOT" --reason "$REASON" --confirm "$confirm" 2>&1)"; commit_rc=$?
commit_decision="$(printf '%s\n' "$commit_output" | json_get_string decision)"
commit_reason="$(printf '%s\n' "$commit_output" | json_get_string reason)"
healthy_after="$(healthy_count)" || { echo RESULT=STOP_R20QN_STATUS_OUTPUT_INVALID; exit 70; }
if [ "$commit_rc" -eq 0 ] && [ "$commit_decision" = commit_ok ] && [ "$healthy_after" -ge 1 ]; then
    refresh_result="$(request_refresh 2>/dev/null)"; refresh_rc=$?
    if [ "$refresh_rc" -eq 0 ] && refresh_result_ok "$refresh_result"; then
        write_state RECOVERED PASS_CACHED_BOOTSTRAP "${commit_reason:-dispatcher_commit_ok}" "$candidate" "$healthy_before" "$healthy_after" 0 "$attempts" "$refresh_result" || { echo RESULT=STOP_R20QN_STATE_WRITE_FAILED; exit 70; }
        log_event "result=pass_cached_bootstrap slot=$SLOT candidate=$candidate healthy_after=$healthy_after refresh_request=$refresh_result"
        echo RESULT=PASS_R20QN_CACHED_BOOTSTRAP_RECOVERED
        echo BOOTSTRAP_SLOT="$SLOT"
        echo CANDIDATE_ENDPOINT="$candidate"
        echo HEALTHY_BEFORE="$healthy_before"
        echo HEALTHY_AFTER="$healthy_after"
        echo REFRESH_REQUEST_RESULT="$refresh_result"
        echo PROVIDER_ACQUISITION_USED=false
        echo HEAVY_REFRESH_EXECUTED=false
        echo BOOTSTRAP_ACTION_PERFORMED=true
        exit 0
    fi
    due=$((NOW + RETRY_SEC))
    write_state REFRESH_HANDOFF_RETRY REFRESH_REQUEST_FAILED refresh_handoff_initial "$candidate" "$healthy_before" "$healthy_after" "$due" "$attempts" "${refresh_result:-ERROR_REQUEST_FAILED}" || { echo RESULT=STOP_R20QN_STATE_WRITE_FAILED; exit 70; }
    log_event "result=refresh_handoff_initial_failed slot=$SLOT candidate=$candidate healthy_after=$healthy_after next_attempt_epoch=$due refresh_request=${refresh_result:-empty} rc=$refresh_rc"
    echo RESULT=RETRY_R20QN_REFRESH_HANDOFF_FAILED
    echo BOOTSTRAP_SLOT="$SLOT"
    echo CANDIDATE_ENDPOINT="$candidate"
    echo HEALTHY_AFTER="$healthy_after"
    echo NEXT_ATTEMPT_EPOCH="$due"
    echo REFRESH_REQUEST_RESULT="${refresh_result:-ERROR_REQUEST_FAILED}"
    echo PROVIDER_ACQUISITION_USED=false
    echo HEAVY_REFRESH_EXECUTED=false
    echo BOOTSTRAP_ACTION_PERFORMED=true
    exit 0
fi

due=$((NOW + RETRY_SEC))
write_state RETRY COMMIT_FAILED "${commit_reason:-dispatcher_commit_failed}" "$candidate" "$healthy_before" "$healthy_after" "$due" "$attempts" NOT_REQUESTED || { echo RESULT=STOP_R20QN_STATE_WRITE_FAILED; exit 70; }
log_event "result=commit_failed slot=$SLOT candidate=$candidate rc=$commit_rc healthy_after=$healthy_after next_attempt_epoch=$due"
echo RESULT=RETRY_R20QN_CACHED_BOOTSTRAP_COMMIT_FAILED
echo BOOTSTRAP_SLOT="$SLOT"
echo CANDIDATE_ENDPOINT="$candidate"
echo DISPATCHER_RC="$commit_rc"
echo DISPATCHER_DECISION="${commit_decision:-unknown}"
echo HEALTHY_AFTER="$healthy_after"
echo NEXT_ATTEMPT_EPOCH="$due"
echo BOOTSTRAP_ACTION_PERFORMED=true
exit 0
