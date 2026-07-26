#!/bin/sh
set -u
umask 077
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
CONFIG="${ROUTER_TOPOLOGY_DELIVERY_CONFIG:-/etc/router-wgpay-topology-delivery.conf}"
[ -r "$CONFIG" ] || { echo 'transport config missing' >&2; exit 70; }
. "$CONFIG"
HOST="${ROUTER_TOPOLOGY_DELIVERY_SSH_HOST:-${TOPOLOGY_DELIVERY_SSH_HOST}}"
PORT="${ROUTER_TOPOLOGY_DELIVERY_SSH_PORT:-${TOPOLOGY_DELIVERY_SSH_PORT}}"
USER_NAME="${ROUTER_TOPOLOGY_DELIVERY_SSH_USER:-${TOPOLOGY_DELIVERY_SSH_USER}}"
IDENTITY="${ROUTER_TOPOLOGY_DELIVERY_SSH_IDENTITY:-${TOPOLOGY_DELIVERY_SSH_IDENTITY}}"
IDLE="${ROUTER_TOPOLOGY_DELIVERY_SSH_IDLE_TIMEOUT_SEC:-${TOPOLOGY_DELIVERY_SSH_IDLE_TIMEOUT_SEC:-20}}"
[ -r "$IDENTITY" ] || { echo 'transport identity missing' >&2; exit 70; }
case "$PORT:$IDLE" in *[!0-9:]*|:*|*:) echo 'transport numeric config invalid' >&2; exit 64;; esac
exec /usr/bin/ssh -T -p "$PORT" -l "$USER_NAME" -i "$IDENTITY" -K 5 -I "$IDLE" "$HOST"
