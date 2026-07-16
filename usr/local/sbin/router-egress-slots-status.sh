#!/bin/sh
set -u
SLOTS_CONF="${SLOTS_CONF:-/etc/router-egress-slots.d/slots.conf}"
RUNTIME_LIB="${RUNTIME_LIB:-/usr/local/lib/router-egress-vm101-runtime.sh}"
[ -r "$SLOTS_CONF" ] || { echo "RESULT=STOP_SLOTS_CONF_MISSING"; exit 1; }
[ -r "$RUNTIME_LIB" ] && . "$RUNTIME_LIB"

fail=0
healthy=0
total=0
printf '{\n  "schema":"router-egress-slots-status-v2",\n  "slots":[\n'
first=true
while read -r slot iface table mark dscp provider adapter targets strict_count strict_timeout enabled rest; do
    [ -n "${slot:-}" ] || continue
    case "$slot" in \#*) continue ;; esac
    total=$((total + 1))
    iface_exists=false
    route_ok=false
    rule_ok=false
    strict_ok=false
    endpoint=""
    ip link show "$iface" >/dev/null 2>&1 && iface_exists=true
    ip route show table "$table" 2>/dev/null | grep -Eq "default[[:space:]].*dev[[:space:]]+$iface" && route_ok=true
    ip rule show 2>/dev/null | grep -E "fwmark $mark.*lookup $table|fwmark $mark/0xffffffff.*lookup $table" >/dev/null && rule_ok=true
    if command -v vm101_strict_iface >/dev/null 2>&1 && vm101_strict_iface "$iface" 1 0; then strict_ok=true; fi
    if command -v vm101_runtime_endpoint >/dev/null 2>&1; then endpoint="$(vm101_runtime_endpoint "$iface" 2>/dev/null || true)"; fi
    if [ "$enabled" = 1 ] && [ "$iface_exists" = true ] && [ "$route_ok" = true ] && [ "$rule_ok" = true ] && [ "$strict_ok" = true ]; then
        status=healthy
        healthy=$((healthy + 1))
    else
        status=degraded
        fail=1
    fi
    $first || printf ',\n'
    first=false
    printf '    {"slot":"%s","iface":"%s","table":%s,"mark":"%s","dscp":"%s","endpoint":"%s","iface_exists":%s,"route_ok":%s,"rule_ok":%s,"strict_ok":%s,"status":"%s"}' \
        "$slot" "$iface" "$table" "$mark" "$dscp" "$endpoint" "$iface_exists" "$route_ok" "$rule_ok" "$strict_ok" "$status"
done <"$SLOTS_CONF"
printf '\n  ],\n  "total":%s,\n  "healthy":%s\n}\n' "$total" "$healthy"
[ "$fail" -eq 0 ]
