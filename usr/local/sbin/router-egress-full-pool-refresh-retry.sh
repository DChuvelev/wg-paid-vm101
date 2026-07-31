#!/bin/sh
# R20Q-U-B1 single-owner pending full-refresh and due degraded retry controller.
set -u

VM101_CONF="${ROUTER_EGRESS_VM101_CONF:-/etc/router-egress-vm101.conf}"
STATE_HELPER="${ROUTER_EGRESS_RECOVERY_STATE_HELPER:-/usr/local/lib/router-egress-recovery-state.sh}"
RUN_MODE=tick
NOW_EPOCH=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tick|--once) RUN_MODE=tick ;;
        --loop) RUN_MODE=loop ;;
        --now-epoch) shift; [ "$#" -gt 0 ] || { echo RESULT=STOP_R20QUB_REFRESH_OWNER_ARGUMENT_MISSING; exit 2; }; NOW_EPOCH="$1" ;;
        --help|-h) echo 'Usage: router-egress-full-pool-refresh-retry.sh [--tick|--loop] [--now-epoch EPOCH]'; exit 0 ;;
        *) echo RESULT=STOP_R20QUB_REFRESH_OWNER_UNKNOWN_ARGUMENT; echo "ARGUMENT=$1"; exit 2 ;;
    esac
    shift
done

[ -r "$VM101_CONF" ] || { echo RESULT=STOP_R20QUB_REFRESH_OWNER_CONFIG_MISSING; exit 20; }
[ -r "$STATE_HELPER" ] || { echo RESULT=STOP_R20QUB_REFRESH_OWNER_STATE_HELPER_MISSING; exit 20; }
. "$VM101_CONF"
. "$STATE_HELPER"

ORCHESTRATOR="${FULL_POOL_REFRESH_ORCHESTRATOR:-/usr/local/sbin/router-egress-full-pool-refresh.sh}"
TICK_SEC="${HMN_REFRESH_RETRY_TICK_SEC:-60}"
LOG="${FULL_POOL_REFRESH_RETRY_LOG:-/var/log/router-egress-full-pool-refresh-retry.log}"
case "$TICK_SEC" in ''|*[!0-9]*) echo RESULT=STOP_R20QUB_REFRESH_OWNER_TICK_INVALID; exit 20;; esac
[ "$TICK_SEC" -gt 0 ] || { echo RESULT=STOP_R20QUB_REFRESH_OWNER_TICK_INVALID; exit 20; }

owner_log() {
    mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" "$*" >> "$LOG" 2>/dev/null || true
}

run_orchestrator() {
    operation="$1" now="$2"
    out="/tmp/router-egress-refresh-owner.$$.out"
    err="/tmp/router-egress-refresh-owner.$$.err"
    if [ "$operation" = pending ]; then
        if ROUTER_EGRESS_COORDINATOR_LOCK_HELD=1 "$ORCHESTRATOR" --run-if-due --now-epoch "$now" >"$out" 2>"$err"; then rc=0; else rc=$?; fi
    else
        if ROUTER_EGRESS_COORDINATOR_LOCK_HELD=1 ROUTER_EGRESS_RETRY_CONTROLLER=1 "$ORCHESTRATOR" --retry --now-epoch "$now" >"$out" 2>"$err"; then rc=0; else rc=$?; fi
    fi
    cat "$out"
    cat "$err" >&2
    result="$(sed -n 's/^RESULT=//p' "$out" | tail -n1)"
    attempt="$(sed -n 's/^ATTEMPT_ID=//p' "$out" | tail -n1)"
    rm -f "$out" "$err"
    echo "OWNER_ORCHESTRATOR_RESULT=$result"
    echo "OWNER_ATTEMPT_ID=$attempt"
    return "$rc"
}

owner_tick() {
    reg_init_state || { echo RESULT=STOP_R20QUB_REFRESH_OWNER_STATE_INIT_FAILED; return 20; }
    owner_now="$NOW_EPOCH"
    [ -n "$owner_now" ] || owner_now="$(date +%s)"
    case "$owner_now" in ''|*[!0-9]*) echo RESULT=STOP_R20QUB_REFRESH_OWNER_NOW_INVALID; return 20;; esac

    mode="$(reg_get_state mode NORMAL 2>/dev/null || echo NORMAL)"
    due="$(reg_get_state next_refresh_epoch 0 2>/dev/null || echo 0)"
    case "$due" in ''|*[!0-9]*) echo RESULT=STOP_R20QUB_REFRESH_OWNER_DUE_INVALID; return 20;; esac
    last_retry="$(reg_get_state last_retry_result NONE 2>/dev/null || echo NONE)"
    last_refresh="$(reg_get_state last_refresh_result NONE 2>/dev/null || echo NONE)"

    if [ "$mode" = NORMAL ] && [ "$last_retry" = RUNNING ] && [ "$last_refresh" = PASS ]; then
        reg_state_update last_retry_result PASS refresh_retry_count 0 next_refresh_epoch 0 || { echo RESULT=STOP_R20QUB_REFRESH_OWNER_COMPLETION_FINALIZE_FAILED; return 20; }
        echo RESULT=PASS_R20QUB_REFRESH_OWNER_COMPLETION_RECOVERED
        return 0
    fi

    operation=""
    case "$mode" in
        FULL_POOL_REFRESH_PENDING) operation=pending ;;
        DEGRADED_POOL)
            if [ "$owner_now" -lt "$due" ]; then
                owner_log "event=noop_degraded_not_due now_epoch=$owner_now next_refresh_epoch=$due"
                echo RESULT=NOOP_R20QUB_REFRESH_OWNER_DEGRADED_NOT_DUE
                echo NOW_EPOCH="$owner_now"
                echo NEXT_REFRESH_EPOCH="$due"
                return 0
            fi
            operation=retry
            ;;
        NORMAL)
            echo RESULT=NOOP_R20QUB_REFRESH_OWNER_NORMAL
            return 0
            ;;
        *)
            echo RESULT=NOOP_R20QUB_REFRESH_OWNER_MODE_NOT_ACTIONABLE
            echo MODE="$mode"
            return 0
            ;;
    esac

    coordinator="$(reg_lock_acquire recovery-coordinator.lock r20qub-refresh-owner 2>/dev/null || true)"
    if [ -z "$coordinator" ]; then
        echo RESULT=NOOP_R20QUB_REFRESH_OWNER_COORDINATOR_BUSY
        echo MODE="$mode"
        return 0
    fi
    release_owner_lock() {
        [ -n "$coordinator" ] && reg_lock_release "$coordinator" >/dev/null 2>&1 || true
        coordinator=""
        trap - EXIT HUP INT TERM
    }
    trap release_owner_lock EXIT HUP INT TERM

    mode="$(reg_get_state mode NORMAL 2>/dev/null || echo NORMAL)"
    due="$(reg_get_state next_refresh_epoch 0 2>/dev/null || echo 0)"
    case "$operation:$mode" in
        pending:FULL_POOL_REFRESH_PENDING) ;;
        retry:DEGRADED_POOL)
            [ "$owner_now" -ge "$due" ] || { echo RESULT=NOOP_R20QUB_REFRESH_OWNER_RECHECK_NOT_DUE; release_owner_lock; return 0; }
            ;;
        *)
            echo RESULT=NOOP_R20QUB_REFRESH_OWNER_RECHECK_MODE_CHANGED
            echo MODE="$mode"
            release_owner_lock
            return 0
            ;;
    esac

    if [ "$operation" = retry ]; then
        count="$(reg_get_state refresh_retry_count 0 2>/dev/null || echo 0)"
        case "$count" in ''|*[!0-9]*) echo RESULT=STOP_R20QUB_REFRESH_OWNER_COUNT_INVALID; release_owner_lock; return 20;; esac
        count=$((count + 1))
        reg_state_update refresh_retry_count "$count" last_retry_epoch "$owner_now" last_retry_result RUNNING || { echo RESULT=STOP_R20QUB_REFRESH_OWNER_RUNNING_STATE_FAILED; release_owner_lock; return 20; }
    else
        count="$(reg_get_state refresh_retry_count 0 2>/dev/null || echo 0)"
    fi

    owner_log "event=dispatch operation=$operation mode=$mode now_epoch=$owner_now retry_count=$count"
    if run_orchestrator "$operation" "$owner_now"; then orchestrator_rc=0; else orchestrator_rc=$?; fi
    post_mode="$(reg_get_state mode UNKNOWN 2>/dev/null || echo UNKNOWN)"
    post_refresh="$(reg_get_state last_refresh_result NONE 2>/dev/null || echo NONE)"

    if [ "$orchestrator_rc" -eq 0 ]; then
        if [ "$operation" = retry ] && [ "$post_mode" = NORMAL ] && [ "$post_refresh" = PASS ]; then
            reg_state_update last_retry_result PASS refresh_retry_count 0 next_refresh_epoch 0 || { echo RESULT=STOP_R20QUB_REFRESH_OWNER_PASS_STATE_FAILED; release_owner_lock; return 20; }
        fi
        owner_log "event=dispatch_complete operation=$operation rc=0 post_mode=$post_mode post_refresh=$post_refresh"
        echo RESULT=PASS_R20QUB_REFRESH_OWNER_DISPATCH
        echo OPERATION="$operation"
        echo POST_MODE="$post_mode"
        release_owner_lock
        return 0
    fi

    [ "$operation" = retry ] && reg_state_update last_retry_result FAILED >/dev/null 2>&1 || true
    owner_log "event=dispatch_failed operation=$operation rc=$orchestrator_rc post_mode=$post_mode post_refresh=$post_refresh"
    release_owner_lock
    return "$orchestrator_rc"
}

if [ "$RUN_MODE" = tick ]; then
    owner_tick
    exit $?
fi

while true; do
    NOW_EPOCH=""
    owner_tick || true
    sleep "$TICK_SEC"
done
