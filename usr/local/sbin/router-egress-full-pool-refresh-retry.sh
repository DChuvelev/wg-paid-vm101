#!/bin/sh
# STEP_050M07R20C durable DEGRADED_POOL controlled retry controller.
set -u

VM101_CONF="${ROUTER_EGRESS_VM101_CONF:-/etc/router-egress-vm101.conf}"
STATE_HELPER="${ROUTER_EGRESS_RECOVERY_STATE_HELPER:-/usr/local/lib/router-egress-recovery-state.sh}"
RUN_MODE=tick
NOW_EPOCH=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tick|--once) RUN_MODE=tick ;;
        --loop) RUN_MODE=loop ;;
        --now-epoch) shift; [ "$#" -gt 0 ] || { echo RESULT=STOP_R20C_RETRY_ARGUMENT_MISSING; exit 2; }; NOW_EPOCH="$1" ;;
        --help|-h) echo 'Usage: router-egress-full-pool-refresh-retry.sh [--tick|--loop] [--now-epoch EPOCH]'; exit 0 ;;
        *) echo RESULT=STOP_R20C_RETRY_UNKNOWN_ARGUMENT; echo "ARGUMENT=$1"; exit 2 ;;
    esac
    shift
done

[ -r "$VM101_CONF" ] || { echo RESULT=STOP_R20C_RETRY_CONFIG_MISSING; exit 20; }
[ -r "$STATE_HELPER" ] || { echo RESULT=STOP_R20C_RETRY_STATE_HELPER_MISSING; exit 20; }
. "$VM101_CONF"
. "$STATE_HELPER"

ORCHESTRATOR="${FULL_POOL_REFRESH_ORCHESTRATOR:-/usr/local/sbin/router-egress-full-pool-refresh.sh}"
TICK_SEC="${HMN_REFRESH_RETRY_TICK_SEC:-60}"
LOG="${FULL_POOL_REFRESH_RETRY_LOG:-/var/log/router-egress-full-pool-refresh-retry.log}"
case "$TICK_SEC" in ''|*[!0-9]*) echo RESULT=STOP_R20C_RETRY_TICK_INVALID; exit 20 ;; esac
[ "$TICK_SEC" -gt 0 ] || { echo RESULT=STOP_R20C_RETRY_TICK_INVALID; exit 20; }

retry_log() {
    mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" "$*" >>"$LOG" 2>/dev/null || true
}

retry_tick() {
    reg_init_state || { echo RESULT=STOP_R20C_RETRY_STATE_INIT_FAILED; return 20; }
    retry_now="$NOW_EPOCH"
    [ -n "$retry_now" ] || retry_now="$(date +%s)"
    case "$retry_now" in ''|*[!0-9]*) echo RESULT=STOP_R20C_RETRY_NOW_INVALID; return 20 ;; esac

    retry_mode="$(reg_get_state mode NORMAL 2>/dev/null || echo NORMAL)"
    retry_due="$(reg_get_state next_refresh_epoch 0 2>/dev/null || echo 0)"
    case "$retry_due" in ''|*[!0-9]*) echo RESULT=STOP_R20C_RETRY_DUE_INVALID; return 20 ;; esac
    retry_last="$(reg_get_state last_retry_result NONE 2>/dev/null || echo NONE)"
    retry_refresh="$(reg_get_state last_refresh_result NONE 2>/dev/null || echo NONE)"
    if [ "$retry_mode" = NORMAL ] && [ "$retry_last" = RUNNING ] && [ "$retry_refresh" = PASS ]; then
        reg_state_update last_retry_result PASS refresh_retry_count 0 next_refresh_epoch 0 || { echo RESULT=STOP_R20C_RETRY_RECOVERY_FINALIZE_FAILED; return 20; }
        echo RESULT=PASS_R20C_RETRY_COMPLETION_RECOVERED
        return 0
    fi
    if [ "$retry_mode" != DEGRADED_POOL ]; then
        echo RESULT=NOOP_R20C_RETRY_NOT_DEGRADED
        echo "MODE=$retry_mode"
        return 0
    fi
    if [ "$retry_now" -lt "$retry_due" ]; then
        echo RESULT=NOOP_R20C_RETRY_NOT_DUE
        echo "NOW_EPOCH=$retry_now"
        echo "NEXT_REFRESH_EPOCH=$retry_due"
        return 0
    fi

    retry_coord="$(reg_lock_acquire recovery-coordinator.lock r20c-retry-controller 2>/dev/null || true)"
    if [ -z "$retry_coord" ]; then
        echo RESULT=NOOP_R20C_RETRY_COORDINATOR_BUSY
        return 0
    fi
    retry_release() {
        [ -n "$retry_coord" ] && reg_lock_release "$retry_coord" >/dev/null 2>&1 || true
        retry_coord=""
        trap - EXIT HUP INT TERM
    }
    trap retry_release EXIT HUP INT TERM

    retry_mode="$(reg_get_state mode NORMAL 2>/dev/null || echo NORMAL)"
    retry_due="$(reg_get_state next_refresh_epoch 0 2>/dev/null || echo 0)"
    if [ "$retry_mode" != DEGRADED_POOL ] || [ "$retry_now" -lt "$retry_due" ]; then
        echo RESULT=NOOP_R20C_RETRY_RECHECK_NOT_DUE
        retry_release
        return 0
    fi

    retry_count="$(reg_get_state refresh_retry_count 0 2>/dev/null || echo 0)"
    case "$retry_count" in ''|*[!0-9]*) echo RESULT=STOP_R20C_RETRY_COUNT_INVALID; retry_release; return 20 ;; esac
    retry_count=$((retry_count + 1))
    reg_state_update refresh_retry_count "$retry_count" last_retry_epoch "$retry_now" last_retry_result RUNNING || { echo RESULT=STOP_R20C_RETRY_STATE_RUNNING_FAILED; retry_release; return 20; }

    retry_out="/tmp/router-egress-full-refresh-retry.$$.out"
    retry_err="/tmp/router-egress-full-refresh-retry.$$.err"
    set +e
    ROUTER_EGRESS_COORDINATOR_LOCK_HELD=1 ROUTER_EGRESS_RETRY_CONTROLLER=1 "$ORCHESTRATOR" --retry --now-epoch "$retry_now" >"$retry_out" 2>"$retry_err"
    retry_rc=$?
    set -e
    cat "$retry_out"
    cat "$retry_err" >&2
    retry_result="$(sed -n 's/^RESULT=//p' "$retry_out" | tail -n1)"
    rm -f "$retry_out" "$retry_err"

    case "$retry_result" in
        PASS_R20C_FULL_POOL_REFRESH)
            reg_state_update last_retry_result PASS refresh_retry_count 0 next_refresh_epoch 0 || { echo RESULT=STOP_R20C_RETRY_PASS_STATE_FAILED; retry_release; return 20; }
            retry_log "result=PASS retry_count=$retry_count"
            echo RESULT=PASS_R20C_CONTROLLED_RETRY
            echo "RETRY_COUNT=$retry_count"
            retry_release
            return 0
            ;;
        STOP_R20C_ZERO_HEALTHY_SLOTS_OUT_OF_SCOPE)
            reg_state_update last_retry_result OUT_OF_SCOPE_STOP || true
            retry_log "result=OUT_OF_SCOPE_STOP retry_count=$retry_count"
            retry_release
            return "$retry_rc"
            ;;
        *)
            reg_state_update last_retry_result FAILED || { echo RESULT=STOP_R20C_RETRY_FAILURE_STATE_FAILED; retry_release; return 20; }
            retry_log "result=FAILED orchestrator_result=$retry_result retry_count=$retry_count rc=$retry_rc"
            retry_release
            [ "$retry_rc" -ne 0 ] && return "$retry_rc"
            return 1
            ;;
    esac
}

if [ "$RUN_MODE" = tick ]; then
    retry_tick
    exit $?
fi

while true; do
    NOW_EPOCH=""
    retry_tick || true
    sleep "$TICK_SEC"
done
