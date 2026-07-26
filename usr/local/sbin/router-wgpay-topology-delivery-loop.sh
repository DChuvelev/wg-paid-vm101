#!/bin/sh
set -u
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
CONFIG="${ROUTER_TOPOLOGY_DELIVERY_CONFIG:-/etc/router-wgpay-topology-delivery.conf}"
[ -r "$CONFIG" ] || exit 70
. "$CONFIG"
INTERVAL="${ROUTER_TOPOLOGY_DELIVERY_INTERVAL_SEC:-${TOPOLOGY_DELIVERY_INTERVAL_SEC:-10}}"
case "$INTERVAL" in ''|*[!0-9]*) exit 64 ;; esac
[ "$INTERVAL" -ge 1 ] || exit 64
while :; do
    /usr/local/sbin/router-wgpay-topology-outbox.sh --run-once || true
    sleep "$INTERVAL"
done
