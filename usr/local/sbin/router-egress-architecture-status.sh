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
/etc/init.d/router-egress-health-repair status >/dev/null 2>&1 && watcher_running=true

echo 'schema=router-egress-architecture-status-v1'
echo "mode=$mode"
echo 'production_loop=health_watcher_to_dispatcher_to_local_repair'
echo "watcher_running=$watcher_running"
echo "healthy_slots=$healthy"
echo "repair_events_since_full_refresh=$repair_events"
echo "full_refresh_due=$full_refresh_due"
echo "full_pool_refresh_enabled=${FULL_POOL_REFRESH_ENABLED:-false}"
echo "direct_failopen_enabled=${DIRECT_FAILOPEN_ENABLED:-false}"
for slot in egress1 egress2 egress3 egress4 egress5; do
    case "$slot" in egress1) iface=vpn1;; egress2) iface=vpn2;; egress3) iface=vpn3;; egress4) iface=vpn4;; egress5) iface=vpn5;; esac
    ep="$(vm101_runtime_endpoint "$iface" 2>/dev/null || true)"
    echo "${slot}_interface=$iface"
    echo "${slot}_endpoint=$ep"
done
