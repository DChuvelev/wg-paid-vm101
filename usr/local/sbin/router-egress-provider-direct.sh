#!/bin/sh
# R20Q-P: service-owned durable provider acquisition worker over VM101 direct WAN.
# BusyBox ash compatible. Request mode is fast; provider download runs only in worker tick/loop.
set -u
umask 077
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

MAIN_CONFIG="${ROUTER_PROVIDER_DIRECT_MAIN_CONFIG:-/etc/router-egress-vm101.conf}"
CONFIG="${ROUTER_PROVIDER_DIRECT_CONFIG:-/etc/router-egress-provider-direct.conf}"
[ -r "$MAIN_CONFIG" ] || { echo RESULT=STOP_R20QP_MAIN_CONFIG_MISSING; exit 70; }
[ -r "$CONFIG" ] || { echo RESULT=STOP_R20QP_PROVIDER_CONFIG_MISSING; exit 70; }
. "$MAIN_CONFIG"
. "$CONFIG"

ENABLED="${ROUTER_PROVIDER_DIRECT_ENABLED:-${PROVIDER_DIRECT_ENABLED:-0}}"
TICK_SEC="${ROUTER_PROVIDER_DIRECT_TICK_SEC:-${PROVIDER_DIRECT_TICK_SEC:-30}}"
RETRY_SEC="${ROUTER_PROVIDER_DIRECT_RETRY_INTERVAL_SEC:-${PROVIDER_DIRECT_RETRY_INTERVAL_SEC:-600}}"
READY_REUSE_SEC="${ROUTER_PROVIDER_DIRECT_READY_REUSE_SEC:-${PROVIDER_DIRECT_READY_REUSE_SEC:-900}}"
STATE_DIR="${ROUTER_PROVIDER_DIRECT_STATE_DIR:-${PROVIDER_DIRECT_STATE_DIR:-/etc/router-egress-provider-direct}}"
STATE_FILE="${ROUTER_PROVIDER_DIRECT_STATE_FILE:-${PROVIDER_DIRECT_STATE_FILE:-$STATE_DIR/state.kv}}"
LOCK_DIR="${ROUTER_PROVIDER_DIRECT_LOCK_DIR:-${PROVIDER_DIRECT_LOCK_DIR:-/var/run/router-egress-provider-direct.lock}}"
DIRECT_STATE="${ROUTER_PROVIDER_DIRECT_DIRECT_STATE:-${PROVIDER_DIRECT_DIRECT_STATE:-/etc/router-wgpay-direct/state.kv}}"
STATUS_CMD="${ROUTER_PROVIDER_DIRECT_STATUS_CMD:-${PROVIDER_DIRECT_STATUS_CMD:-/usr/local/sbin/router-egress-slots-status.sh}}"
DOWNLOAD_CMD="${ROUTER_PROVIDER_DIRECT_DOWNLOAD_CMD:-${PROVIDER_DIRECT_DOWNLOAD_CMD:-/root/hmn/hmn-download-all-awg.sh}}"
STATE_HELPER="${ROUTER_PROVIDER_DIRECT_RECOVERY_STATE_HELPER:-${PROVIDER_DIRECT_RECOVERY_STATE_HELPER:-/usr/local/lib/router-egress-recovery-state.sh}}"
DIRECT_IFACE="${ROUTER_PROVIDER_DIRECT_INTERFACE:-${PROVIDER_DIRECT_INTERFACE:-eth0}}"
NETWORK_CONFIG="${ROUTER_PROVIDER_DIRECT_NETWORK_CONFIG:-${PROVIDER_DIRECT_NETWORK_CONFIG:-/etc/config/network}}"
PROVIDER_ROOT="${ROUTER_PROVIDER_DIRECT_PROVIDER_ROOT:-${PROVIDER_DIRECT_PROVIDER_ROOT:-/root/hmn}}"
LOG="${ROUTER_PROVIDER_DIRECT_LOG:-${PROVIDER_DIRECT_LOG:-/var/log/router-egress-provider-direct.log}}"
NOW="${ROUTER_PROVIDER_DIRECT_NOW_EPOCH:-$(date +%s)}"
SCHEMA=router-egress-provider-direct-state-v1

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
valid_id() { printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_.:-]{1,128}$'; }
for value in "$TICK_SEC" "$RETRY_SEC" "$READY_REUSE_SEC" "$NOW"; do
    is_uint "$value" || { echo RESULT=STOP_R20QP_NUMERIC_CONFIG_INVALID; exit 70; }
done
[ "$TICK_SEC" -gt 0 ] || TICK_SEC=30
[ "$RETRY_SEC" -gt 0 ] || RETRY_SEC=600
[ "$READY_REUSE_SEC" -gt 0 ] || READY_REUSE_SEC=900
case "$DIRECT_IFACE" in ''|*[!A-Za-z0-9_.:-]*) echo RESULT=STOP_R20QP_DIRECT_INTERFACE_INVALID; exit 70 ;; esac

kv_get() {
    key="$1"; file="$2"
    sed -n "s/^${key}=//p" "$file" 2>/dev/null | tail -n1
}
json_healthy() {
    sed -n 's/.*"healthy":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -n1
}
process_token() {
    pid="$1"; [ -r "/proc/$pid/stat" ] || return 1
    awk '{print $22}' "/proc/$pid/stat" 2>/dev/null
}
lock_acquire() {
    mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null || return 1
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
}
lock_release() {
    [ "$(cat "$LOCK_DIR/pid" 2>/dev/null || true)" = "$$" ] || return 1
    rm -rf "$LOCK_DIR"
}
atomic_write() {
    src="$1"; dst="$2"
    mkdir -p "$(dirname "$dst")" || return 1
    cp "$src" "$dst.new.$$" && chmod 600 "$dst.new.$$" && mv "$dst.new.$$" "$dst"
}
write_state() {
    state_mode="$1"; request_id="$2"; request_reason="$3"; attempts="$4"; next_epoch="$5"; result="$6"; pool="$7"; count="$8"; runlog="$9"
    mkdir -p "$STATE_DIR" || return 1
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    tmp="$STATE_DIR/state.$$"
    {
        echo schema="$SCHEMA"
        echo mode="$state_mode"
        echo updated_epoch="$NOW"
        echo request_id="$request_id"
        echo request_reason="$request_reason"
        echo attempt_count="$attempts"
        echo last_attempt_epoch="$NOW"
        echo next_attempt_epoch="$next_epoch"
        echo last_result="$result"
        echo transport=direct
        echo direct_interface="$DIRECT_IFACE"
        echo working_pool="$pool"
        echo working_candidate_count="$count"
        echo provider_run_log="$runlog"
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
    healthy="$(printf '%s\n' "$output" | json_healthy)"
    is_uint "$healthy" || return 1
    [ "$healthy" -le 5 ] || return 1
    printf '%s\n' "$healthy"
}
direct_required() {
    [ -s "$DIRECT_STATE" ] || return 1
    [ "$(kv_get direct_required "$DIRECT_STATE")" = true ]
}
direct_request_id() {
    source_id="$(kv_get source_vm101_generation "$DIRECT_STATE")"
    valid_id "$source_id" || return 1
    printf '%s\n' "$source_id"
}
working_pool_verify() {
    pool="$PROVIDER_ROOT/cache/working-awg1-latest.tsv"
    [ -s "$pool" ] || return 1
    expected_header="$(printf 'id\tcountry\tname\twg_ip\twg_port\tendpoint\tendpoint_match\taddress\tconfig_file')"
    [ "$(head -n1 "$pool")" = "$expected_header" ] || return 1
    valid=0
    tab="$(printf '\t')"
    while IFS="$tab" read -r id country name ip port endpoint match address config; do
        [ "$id" = id ] && continue
        [ -n "$endpoint" ] && [ -f "$config" ] || continue
        cfg_endpoint="$(awk -F'= *' '/^Endpoint[[:space:]]*=/{print $2; exit}' "$config")"
        [ "$cfg_endpoint" = "$endpoint" ] || continue
        valid=$((valid + 1))
    done < "$pool"
    [ "$valid" -gt 0 ] || return 1
    printf '%s\t%s\n' "$pool" "$valid"
}
request_emit() {
    echo RESULT="$1"
    echo REQUEST_ID="$2"
    echo PROVIDER_ACQUISITION_EXECUTED=false
    echo HEAVY_REFRESH_EXECUTED=false
}

mode="${1:---tick}"
case "$mode" in
    --status)
        if [ -s "$STATE_FILE" ]; then cat "$STATE_FILE"; else echo schema="$SCHEMA"; echo initialized=false; echo enabled="$ENABLED"; fi
        exit 0
        ;;
    --loop)
        while :; do
            loop_output="$($0 --tick 2>&1)"; loop_rc=$?
            loop_result="$(printf '%s\n' "$loop_output" | sed -n 's/^RESULT=//p' | tail -n1)"
            case "$loop_result" in
                NOOP_R20QP_PROVIDER_HEALTHY|NOOP_R20QP_PROVIDER_DIRECT_NOT_REQUIRED|NOOP_R20QP_PROVIDER_NO_REQUEST|NOOP_R20QP_PROVIDER_NOT_DUE|NOOP_R20QP_PROVIDER_READY|NOOP_R20QP_PROVIDER_LOCKED|NOOP_R20QP_PROVIDER_COORDINATOR_BUSY|NOOP_R20QP_PROVIDER_DISABLED) ;;
                *) printf '%s\n' "$loop_output" ;;
            esac
            [ "$loop_rc" -eq 0 ] || log_event "result=loop_tick_error rc=$loop_rc marker=${loop_result:-missing}"
            sleep "$TICK_SEC"
        done
        ;;
    --request)
        shift
        request_arg="${1:-}"
        reason_arg="${2:-zero_healthy_no_candidate}"
        [ "$ENABLED" = 1 ] || { request_emit NOOP_R20QP_PROVIDER_DISABLED "$request_arg"; exit 0; }
        [ -x "$STATUS_CMD" ] || { echo RESULT=STOP_R20QP_STATUS_COMMAND_MISSING; exit 70; }
        healthy="$(healthy_count)" || { echo RESULT=STOP_R20QP_STATUS_OUTPUT_INVALID; exit 70; }
        [ "$healthy" -eq 0 ] || { request_emit NOOP_R20QP_PROVIDER_HEALTHY "$request_arg"; echo HEALTHY_SLOT_COUNT="$healthy"; exit 0; }
        direct_required || { request_emit NOOP_R20QP_PROVIDER_DIRECT_NOT_REQUIRED "$request_arg"; exit 0; }
        current_id="$(direct_request_id)" || { echo RESULT=STOP_R20QP_DIRECT_SOURCE_INVALID; exit 70; }
        [ -n "$request_arg" ] || request_arg="$current_id"
        valid_id "$request_arg" || { echo RESULT=STOP_R20QP_REQUEST_ID_INVALID; exit 70; }
        [ "$request_arg" = "$current_id" ] || { echo RESULT=STOP_R20QP_REQUEST_ID_MISMATCH; exit 70; }
        if ! lock_acquire; then request_emit NOOP_R20QP_PROVIDER_LOCKED "$request_arg"; exit 0; fi
        trap 'lock_release >/dev/null 2>&1 || true' EXIT HUP INT TERM
        old_mode="$(kv_get mode "$STATE_FILE")"
        old_id="$(kv_get request_id "$STATE_FILE")"
        old_attempts="$(kv_get attempt_count "$STATE_FILE")"; is_uint "$old_attempts" || old_attempts=0
        old_next="$(kv_get next_attempt_epoch "$STATE_FILE")"; is_uint "$old_next" || old_next=0
        if [ "$old_id" = "$request_arg" ]; then
            case "$old_mode" in
                PENDING) request_emit NOOP_R20QP_PROVIDER_ALREADY_PENDING "$request_arg"; exit 0 ;;
                RUNNING)
                    write_state PENDING "$request_arg" "$reason_arg" "$old_attempts" "$NOW" STALE_RUNNING_RECOVERED '' 0 '' || { echo RESULT=STOP_R20QP_STATE_WRITE_FAILED; exit 70; }
                    request_emit REQUESTED_R20QP_PROVIDER_DIRECT "$request_arg"
                    exit 0
                    ;;
                RETRY)
                    if [ "$old_next" -gt "$NOW" ]; then request_emit NOOP_R20QP_PROVIDER_RETRY_ACTIVE "$request_arg"; echo NEXT_ATTEMPT_EPOCH="$old_next"; exit 0; fi
                    ;;
                READY)
                    if [ "$old_next" -gt "$NOW" ]; then request_emit NOOP_R20QP_PROVIDER_ALREADY_READY "$request_arg"; echo NEXT_REACQUIRE_EPOCH="$old_next"; exit 0; fi
                    ;;
            esac
        else
            old_attempts=0
        fi
        write_state PENDING "$request_arg" "$reason_arg" "$old_attempts" "$NOW" REQUESTED '' 0 '' || { echo RESULT=STOP_R20QP_STATE_WRITE_FAILED; exit 70; }
        log_event "result=requested request_id=$request_arg reason=$reason_arg"
        request_emit REQUESTED_R20QP_PROVIDER_DIRECT "$request_arg"
        exit 0
        ;;
    --tick) ;;
    *) echo 'Usage: router-egress-provider-direct.sh --request [request_id] [reason] | --tick | --loop | --status' >&2; exit 64 ;;
esac

[ "$ENABLED" = 1 ] || { echo RESULT=NOOP_R20QP_PROVIDER_DISABLED; echo PROVIDER_ACQUISITION_EXECUTED=false; exit 0; }
[ -x "$STATUS_CMD" ] || { echo RESULT=STOP_R20QP_STATUS_COMMAND_MISSING; exit 70; }
[ -x "$DOWNLOAD_CMD" ] || { echo RESULT=STOP_R20QP_DOWNLOAD_COMMAND_MISSING; exit 70; }
[ -r "$STATE_HELPER" ] || { echo RESULT=STOP_R20QP_STATE_HELPER_MISSING; exit 70; }
[ -e "$NETWORK_CONFIG" ] || { echo RESULT=STOP_R20QP_NETWORK_CONFIG_MISSING; exit 70; }
healthy="$(healthy_count)" || { echo RESULT=STOP_R20QP_STATUS_OUTPUT_INVALID; exit 70; }
[ "$healthy" -eq 0 ] || { echo RESULT=NOOP_R20QP_PROVIDER_HEALTHY; echo HEALTHY_SLOT_COUNT="$healthy"; echo PROVIDER_ACQUISITION_EXECUTED=false; exit 0; }
direct_required || { echo RESULT=NOOP_R20QP_PROVIDER_DIRECT_NOT_REQUIRED; echo PROVIDER_ACQUISITION_EXECUTED=false; exit 0; }
current_id="$(direct_request_id)" || { echo RESULT=STOP_R20QP_DIRECT_SOURCE_INVALID; exit 70; }
if ! lock_acquire; then echo RESULT=NOOP_R20QP_PROVIDER_LOCKED; echo PROVIDER_ACQUISITION_EXECUTED=false; exit 0; fi
trap 'lock_release >/dev/null 2>&1 || true' EXIT HUP INT TERM
state_mode="$(kv_get mode "$STATE_FILE")"
request_id="$(kv_get request_id "$STATE_FILE")"
request_reason="$(kv_get request_reason "$STATE_FILE")"; [ -n "$request_reason" ] || request_reason=zero_healthy_no_candidate
attempts="$(kv_get attempt_count "$STATE_FILE")"; is_uint "$attempts" || attempts=0
next_epoch="$(kv_get next_attempt_epoch "$STATE_FILE")"; is_uint "$next_epoch" || next_epoch=0
[ -n "$request_id" ] || { echo RESULT=NOOP_R20QP_PROVIDER_NO_REQUEST; echo PROVIDER_ACQUISITION_EXECUTED=false; exit 0; }
[ "$request_id" = "$current_id" ] || { echo RESULT=NOOP_R20QP_PROVIDER_STALE_REQUEST; echo REQUEST_ID="$request_id"; echo CURRENT_DIRECT_SOURCE="$current_id"; echo PROVIDER_ACQUISITION_EXECUTED=false; exit 0; }
case "$state_mode" in
    PENDING|RUNNING) ;;
    RETRY) [ "$next_epoch" -le "$NOW" ] || { echo RESULT=NOOP_R20QP_PROVIDER_NOT_DUE; echo NEXT_ATTEMPT_EPOCH="$next_epoch"; echo PROVIDER_ACQUISITION_EXECUTED=false; exit 0; } ;;
    READY) [ "$next_epoch" -le "$NOW" ] || { echo RESULT=NOOP_R20QP_PROVIDER_READY; echo NEXT_REACQUIRE_EPOCH="$next_epoch"; echo PROVIDER_ACQUISITION_EXECUTED=false; exit 0; } ;;
    *) echo RESULT=NOOP_R20QP_PROVIDER_NO_REQUEST; echo PROVIDER_ACQUISITION_EXECUTED=false; exit 0 ;;
esac

. "$STATE_HELPER"
reg_init_state || { echo RESULT=STOP_R20QP_RECOVERY_STATE_INIT_FAILED; exit 70; }
coordinator_token="$(reg_lock_acquire recovery-coordinator.lock provider-direct 2>/dev/null || true)"
[ -n "$coordinator_token" ] || { echo RESULT=NOOP_R20QP_PROVIDER_COORDINATOR_BUSY; echo PROVIDER_ACQUISITION_EXECUTED=false; exit 0; }
trap 'reg_lock_release "$coordinator_token" >/dev/null 2>&1 || true; lock_release >/dev/null 2>&1 || true' EXIT HUP INT TERM
attempts=$((attempts + 1))
write_state RUNNING "$request_id" "$request_reason" "$attempts" 0 RUNNING '' 0 '' || { echo RESULT=STOP_R20QP_STATE_WRITE_FAILED; exit 70; }
run_dir="$STATE_DIR/runs/${NOW}-${attempts}"
mkdir -p "$run_dir" || { echo RESULT=STOP_R20QP_RUN_DIR_CREATE_FAILED; exit 70; }
chmod 700 "$run_dir" 2>/dev/null || true
run_log="$run_dir/provider-download.log"
network_backup="$run_dir/network.before"
cp -p "$NETWORK_CONFIG" "$network_backup" || { echo RESULT=STOP_R20QP_NETWORK_BACKUP_FAILED; exit 70; }
network_before="$(sha256sum "$NETWORK_CONFIG" | awk '{print $1}')"
HMN_REQUEST_IFACE=direct HMN_DIRECT_IFACE="$DIRECT_IFACE" "$DOWNLOAD_CMD" > "$run_log" 2>&1
download_rc=$?
network_after="$(sha256sum "$NETWORK_CONFIG" | awk '{print $1}')"
if [ "$network_after" != "$network_before" ]; then
    restore_ok=false
    if cp -p "$network_backup" "$NETWORK_CONFIG" && [ "$(sha256sum "$NETWORK_CONFIG" | awk '{print $1}')" = "$network_before" ]; then restore_ok=true; fi
    due=$((NOW + RETRY_SEC))
    write_state RETRY "$request_id" "$request_reason" "$attempts" "$due" NETWORK_CONFIG_CHANGED '' 0 "$run_log" || true
    log_event "result=network_config_changed request_id=$request_id restored=$restore_ok next_attempt_epoch=$due"
    echo RESULT=STOP_R20QP_PROVIDER_NETWORK_MUTATION
    echo REQUEST_ID="$request_id"
    echo NETWORK_CONFIG_RESTORED="$restore_ok"
    echo PROVIDER_ACQUISITION_EXECUTED=true
    echo HEAVY_REFRESH_EXECUTED=false
    [ "$restore_ok" = true ] && exit 70
    exit 71
fi
if [ "$download_rc" -eq 0 ]; then
    verified="$(working_pool_verify 2>/dev/null || true)"
else
    verified=''
fi
if [ -n "$verified" ]; then
    pool="$(printf '%s\n' "$verified" | awk -F '\t' '{print $1}')"
    count="$(printf '%s\n' "$verified" | awk -F '\t' '{print $2}')"
    is_uint "$count" || count=0
    ready_until=$((NOW + READY_REUSE_SEC))
    write_state READY "$request_id" "$request_reason" "$attempts" "$ready_until" PASS_PROVIDER_DIRECT "$pool" "$count" "$run_log" || { echo RESULT=STOP_R20QP_STATE_WRITE_FAILED; exit 70; }
    log_event "result=pass_provider_direct request_id=$request_id count=$count ready_until=$ready_until"
    echo RESULT=PASS_R20QP_PROVIDER_ACQUISITION_READY
    echo REQUEST_ID="$request_id"
    echo PROVIDER_REQUEST_TRANSPORT=direct
    echo PROVIDER_REQUEST_INTERFACE="$DIRECT_IFACE"
    echo WORKING_POOL="$pool"
    echo WORKING_CANDIDATE_COUNT="$count"
    echo NEXT_REACQUIRE_EPOCH="$ready_until"
    echo NETWORK_CONFIG_UNCHANGED=true
    echo PROVIDER_ACQUISITION_EXECUTED=true
    echo HEAVY_REFRESH_EXECUTED=false
    exit 0
fi

due=$((NOW + RETRY_SEC))
if [ "$download_rc" -ne 0 ]; then failure=DOWNLOAD_FAILED; else failure=WORKING_POOL_INVALID; fi
write_state RETRY "$request_id" "$request_reason" "$attempts" "$due" "$failure" '' 0 "$run_log" || { echo RESULT=STOP_R20QP_STATE_WRITE_FAILED; exit 70; }
log_event "result=provider_retry request_id=$request_id failure=$failure rc=$download_rc next_attempt_epoch=$due"
echo RESULT=RETRY_R20QP_PROVIDER_ACQUISITION_FAILED
echo REQUEST_ID="$request_id"
echo PROVIDER_DOWNLOAD_RC="$download_rc"
echo PROVIDER_FAILURE="$failure"
echo NEXT_ATTEMPT_EPOCH="$due"
echo NETWORK_CONFIG_UNCHANGED=true
echo PROVIDER_ACQUISITION_EXECUTED=true
echo HEAVY_REFRESH_EXECUTED=false
exit 0
