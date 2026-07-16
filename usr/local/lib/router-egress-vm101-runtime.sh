#!/bin/sh
# Canonical VM101 BusyBox-compatible runtime helpers.
# Read-only unless a function explicitly documents otherwise.

vm101_runtime_cli() {
    command -v amneziawg >/dev/null 2>&1 || return 1
    command -v amneziawg
}

vm101_runtime_peer_line() {
    iface="$1"
    cli="$(vm101_runtime_cli 2>/dev/null || true)"
    [ -n "$cli" ] || return 1
    "$cli" show "$iface" dump 2>/dev/null | sed -n '2p'
}

vm101_runtime_endpoint() {
    iface="$1"
    line="$(vm101_runtime_peer_line "$iface" 2>/dev/null || true)"
    [ -n "$line" ] || return 1
    endpoint="$(printf '%s\n' "$line" | cut -f3)"
    case "$endpoint" in ""|"(none)") return 1 ;; esac
    printf '%s\n' "$endpoint"
}

vm101_strict_iface() {
    iface="$1"
    attempts="${2:-3}"
    wait_seconds="${3:-1}"
    target="${4:-1.1.1.1}"
    attempt=1
    while [ "$attempt" -le "$attempts" ]; do
        if ping -I "$iface" -c 1 -W 3 "$target" >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        [ "$attempt" -le "$attempts" ] && sleep "$wait_seconds"
    done
    return 1
}

vm101_healthy_bootstrap_iface() {
    for candidate in vpn1 vpn2 vpn3 vpn4 vpn5; do
        if ip link show dev "$candidate" >/dev/null 2>&1 \
            && vm101_strict_iface "$candidate" 1 0; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

vm101_count_healthy_slots() {
    count=0
    for candidate in vpn1 vpn2 vpn3 vpn4 vpn5; do
        if ip link show dev "$candidate" >/dev/null 2>&1 \
            && vm101_strict_iface "$candidate" 1 0; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

vm101_routes_201_205_ok() {
    for table in 201 202 203 204 205; do
        ip route show table "$table" 2>/dev/null | grep -q '^default ' || return 1
    done
    return 0
}

vm101_storage_kb() {
    path="$1"
    df -Pk "$path" 2>/dev/null | awk 'NR == 2 {
        print "total_kb=" $2
        print "used_kb=" $3
        print "available_kb=" $4
    }'
}

vm101_require_free_kb() {
    path="$1"
    required_kb="$2"
    available="$(df -Pk "$path" 2>/dev/null | awk 'NR == 2 {print $4}')"
    case "$available:$required_kb" in *[!0-9:]*|'') return 2 ;; esac
    [ "$available" -ge "$required_kb" ]
}

vm101_file_sha256() {
    path="$1"
    sha256sum "$path" 2>/dev/null | sed 's/[[:space:]].*$//'
}
