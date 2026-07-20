#!/bin/sh
set -u
CONF="${CONF:-/etc/router-egress-vm101.conf}"
[ -r "$CONF" ] && . "$CONF"
STATE_HELPER="${RECOVERY_STATE_HELPER:-/usr/local/lib/router-egress-recovery-state.sh}"
RUNTIME_HELPER="/usr/local/lib/router-egress-vm101-runtime.sh"
[ -r "$STATE_HELPER" ] && . "$STATE_HELPER"
[ -r "$RUNTIME_HELPER" ] && . "$RUNTIME_HELPER"

repair_events="$(reg_repair_events_get 2>/dev/null || echo 0)"
mode="$(reg_get_state mode UNKNOWN 2>/dev/null || echo UNKNOWN)"
full_refresh_due="$(reg_get_state full_refresh_due false 2>/dev/null || echo false)"
healthy="$(vm101_count_healthy_slots 2>/dev/null || echo 0)"
watcher_running=false
retry_controller_running=false
/etc/init.d/router-egress-health-repair status >/dev/null 2>&1 && watcher_running=true
/etc/init.d/router-egress-full-pool-refresh-retry status >/dev/null 2>&1 && retry_controller_running=true
degraded_reason="$(reg_get_state degraded_reason "" 2>/dev/null || true)"
next_refresh_epoch="$(reg_get_state next_refresh_epoch 0 2>/dev/null || echo 0)"
refresh_retry_count="$(reg_get_state refresh_retry_count 0 2>/dev/null || echo 0)"
last_retry_result="$(reg_get_state last_retry_result NONE 2>/dev/null || echo NONE)"
active_generation_id="$(reg_get_state active_generation_id "" 2>/dev/null || true)"
state_persist_match=false
[ -s "$REG_STATE_KV" ] && [ -s "$REG_PERSIST_STATE_KV" ] && cmp -s "$REG_STATE_KV" "$REG_PERSIST_STATE_KV" && state_persist_match=true

echo 'schema=router-egress-architecture-status-v1'
echo "mode=$mode"
echo 'production_loop=health_watcher_to_dispatcher_to_local_repair'
echo "watcher_running=$watcher_running"
echo "retry_controller_running=$retry_controller_running"
echo "healthy_slots=$healthy"
echo "repair_events_since_full_refresh=$repair_events"
echo "full_refresh_due=$full_refresh_due"
echo "degraded_reason=$degraded_reason"
echo "next_refresh_epoch=$next_refresh_epoch"
echo "refresh_retry_count=$refresh_retry_count"
echo "last_retry_result=$last_retry_result"
echo "active_generation_id=$active_generation_id"
echo "state_persist_match=$state_persist_match"
echo "full_pool_refresh_enabled=${FULL_POOL_REFRESH_ENABLED:-false}"
echo "direct_failopen_enabled=${DIRECT_FAILOPEN_ENABLED:-false}"
for slot in egress1 egress2 egress3 egress4 egress5; do
    case "$slot" in egress1) iface=vpn1;; egress2) iface=vpn2;; egress3) iface=vpn3;; egress4) iface=vpn4;; egress5) iface=vpn5;; esac
    ep="$(vm101_runtime_endpoint "$iface" 2>/dev/null || true)"
    echo "${slot}_interface=$iface"
    echo "${slot}_endpoint=$ep"
done
