#!/bin/sh
# R20Q-Q: reconcile durable watcher topology after a proven full-pool activation.
# BusyBox ash compatible. It does not acquire provider data or change VPN configs.
set -eu
umask 077
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

STATUS_CMD="${ROUTER_TOPOLOGY_RECONCILE_STATUS_CMD:-/usr/local/sbin/router-egress-slots-status.sh}"
SYNC_CMD="${ROUTER_TOPOLOGY_RECONCILE_SYNC_CMD:-/usr/local/sbin/router-wgpay-watcher-topology-sync.sh}"
OUTBOX_CMD="${ROUTER_TOPOLOGY_RECONCILE_OUTBOX_CMD:-/usr/local/sbin/router-wgpay-topology-outbox.sh}"
FALLBACK_STATE="${ROUTER_TOPOLOGY_RECONCILE_FALLBACK_STATE:-/etc/router-wgpay-fallback/state.kv}"
DIRECT_STATE="${ROUTER_TOPOLOGY_RECONCILE_DIRECT_STATE:-/etc/router-wgpay-direct/state.kv}"
LAST_ACK="${ROUTER_TOPOLOGY_RECONCILE_LAST_ACK:-/etc/router-wgpay-topology-delivery/last-ack.kv}"
LOCK_DIR="${ROUTER_TOPOLOGY_RECONCILE_LOCK_DIR:-/var/run/router-wgpay-topology-reconcile.lock}"

kv_get() {
    key="$1"; file="$2"
    sed -n "s/^${key}=//p" "$file" 2>/dev/null | tail -n1
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

mode="${1:---after-full-refresh}"
case "$mode" in
    --status)
        echo schema=router-wgpay-topology-reconcile-status-v1
        echo fallback_state="$FALLBACK_STATE"
        echo fallback_mode="$(kv_get mode "$FALLBACK_STATE")"
        echo healthy_slots="$(kv_get healthy_slots "$FALLBACK_STATE")"
        echo exhausted_slots="$(kv_get exhausted_slots "$FALLBACK_STATE")"
        echo direct_state_present="$([ -e "$DIRECT_STATE" ] && echo true || echo false)"
        exit 0
        ;;
    --after-full-refresh) ;;
    *) echo 'Usage: router-wgpay-topology-reconcile.sh --after-full-refresh|--status' >&2; exit 64 ;;
esac

[ -x "$STATUS_CMD" ] || { echo RESULT=STOP_R20QQ_RECONCILE_STATUS_MISSING; exit 70; }
[ -x "$SYNC_CMD" ] || { echo RESULT=STOP_R20QQ_RECONCILE_SYNC_MISSING; exit 70; }
[ -x "$OUTBOX_CMD" ] || { echo RESULT=STOP_R20QQ_RECONCILE_OUTBOX_MISSING; exit 70; }
lock_acquire || { echo RESULT=NOOP_R20QQ_RECONCILE_LOCKED; exit 75; }
trap 'lock_release >/dev/null 2>&1 || true' EXIT HUP INT TERM

set +e
status="$($STATUS_CMD 2>&1)"
status_rc=$?
set -e
total="$(printf '%s\n' "$status" | sed -n 's/.*"total":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -n1)"
healthy="$(printf '%s\n' "$status" | sed -n 's/.*"healthy":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -n1)"
if [ "$status_rc" -ne 0 ] || [ "$total" != 5 ] || [ "$healthy" != 5 ]; then
    printf '%s\n' "$status"
    echo RESULT=STOP_R20QQ_RECONCILE_FIVE_HEALTHY_NOT_PROVEN
    echo STATUS_RC="$status_rc"
    echo TOTAL_SLOTS="${total:-unknown}"
    echo HEALTHY_SLOTS="${healthy:-unknown}"
    exit 70
fi

changed_count=0
delivery_count=0
direct_exit_observed=false
for slot in egress1 egress2 egress3 egress4 egress5; do
    set +e
    sync_out="$($SYNC_CMD --bridge-clear "$slot" full_pool_refresh_reconcile 2>&1)"
    sync_rc=$?
    set -e
    printf '%s\n' "$sync_out"
    [ "$sync_rc" -eq 0 ] || { echo RESULT=STOP_R20QQ_RECONCILE_SYNC_FAILED; echo SLOT="$slot"; echo SYNC_RC="$sync_rc"; exit 71; }
    sync_result="$(printf '%s\n' "$sync_out" | sed -n 's/^RESULT=//p' | tail -n1)"
    case "$sync_result" in
        PASS_WATCHER_TOPOLOGY_SYNC) changed_count=$((changed_count + 1)) ;;
        NOOP_WATCHER_TOPOLOGY_STATE_UNCHANGED) ;;
        *) echo RESULT=STOP_R20QQ_RECONCILE_SYNC_RESULT_INVALID; echo SLOT="$slot"; echo SYNC_RESULT="${sync_result:-missing}"; exit 71 ;;
    esac

    set +e
    outbox_out="$($OUTBOX_CMD --run-once 2>&1)"
    outbox_rc=$?
    set -e
    printf '%s\n' "$outbox_out"
    [ "$outbox_rc" -eq 0 ] || { echo RESULT=STOP_R20QQ_RECONCILE_DELIVERY_FAILED; echo SLOT="$slot"; echo DELIVERY_RC="$outbox_rc"; exit 72; }
    outbox_result="$(printf '%s\n' "$outbox_out" | sed -n 's/^RESULT=//p' | tail -n1)"
    case "$outbox_result" in
        PASS_TOPOLOGY_ACK_ACCEPTED) delivery_count=$((delivery_count + 1)) ;;
        NOOP_TOPOLOGY_NOT_PENDING|NOOP_TOPOLOGY_SOURCE_ALREADY_ACKED) ;;
        *) echo RESULT=STOP_R20QQ_RECONCILE_DELIVERY_RESULT_INVALID; echo SLOT="$slot"; echo DELIVERY_RESULT="${outbox_result:-missing}"; exit 72 ;;
    esac
    if [ -f "$LAST_ACK" ]; then
        [ "$(kv_get direct_action "$LAST_ACK")" = EXIT ] && direct_exit_observed=true
        [ "$(kv_get direct_action_result "$LAST_ACK")" = PASS_DIRECT_MODE_DISABLED ] && direct_exit_observed=true
    fi
done

[ "$(kv_get mode "$FALLBACK_STATE")" = NORMAL ] || { echo RESULT=STOP_R20QQ_RECONCILE_MODE_NOT_NORMAL; exit 73; }
[ "$(kv_get healthy_slots "$FALLBACK_STATE")" = egress1,egress2,egress3,egress4,egress5 ] || { echo RESULT=STOP_R20QQ_RECONCILE_HEALTHY_SET_INVALID; exit 73; }
[ -z "$(kv_get exhausted_slots "$FALLBACK_STATE")" ] || { echo RESULT=STOP_R20QQ_RECONCILE_EXHAUSTED_REMAINS; exit 73; }
[ ! -e "$DIRECT_STATE" ] || { echo RESULT=STOP_R20QQ_RECONCILE_DIRECT_SOURCE_REMAINS; exit 73; }

echo RESULT=PASS_R20QQ_FULL_REFRESH_TOPOLOGY_RECONCILED
echo FIVE_HEALTHY_PROVED=true
echo RECONCILED_SLOT_COUNT="$changed_count"
echo DELIVERY_ACK_COUNT="$delivery_count"
echo DIRECT_EXIT_OBSERVED="$direct_exit_observed"
echo PROVIDER_ACQUISITION_EXECUTED=false
echo HEAVY_REFRESH_EXECUTED=false
