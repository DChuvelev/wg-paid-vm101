#!/bin/sh
set -u
umask 077
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

TABLE="${ROUTER_WGPAY_MAPPER_TABLE:-router_egress_dscp_canary}"
SLOTS_FILE="${ROUTER_WGPAY_SLOTS_FILE:-/etc/router-egress-slots.d/slots.conf}"
STATE_FILE="${ROUTER_WGPAY_FALLBACK_STATE_FILE:-/etc/router-wgpay-fallback/state.kv}"
LIB="${ROUTER_WGPAY_FALLBACK_LIB:-/usr/local/lib/router-wgpay-fallback-map.sh}"
LOCK_FILE="${ROUTER_WGPAY_FALLBACK_LOCK_FILE:-/var/run/router-wgpay-fallback.lock}"
NFT_BIN="${ROUTER_WGPAY_NFT_BIN:-nft}"
IP_BIN="${ROUTER_WGPAY_IP_BIN:-ip}"
AWG_BIN="${ROUTER_WGPAY_AWG_BIN:-/usr/bin/amneziawg}"
INPUT_IFACE="${ROUTER_WGPAY_INPUT_IFACE:-eth1}"
INPUT_SOURCE="${ROUTER_WGPAY_INPUT_SOURCE:-10.200.0.1}"

[ -r "$LIB" ] || { echo 'RESULT=STOP_FALLBACK_LIBRARY_MISSING'; exit 70; }
# shellcheck disable=SC1090
. "$LIB"

mapper_apply() {
    mapper_tmp="${TMPDIR:-/tmp}/router-wgpay-fallback-mapper.$$"
    mapper_rows="$mapper_tmp/slots.tsv"
    mapper_batch="$mapper_tmp/nft.batch"
    mapper_dump="$mapper_tmp/nft.dump"
    trap 'rm -rf "$mapper_tmp"' EXIT HUP INT TERM
    mkdir -p "$mapper_tmp" || return 70
    rwf_slots_to_tsv "$SLOTS_FILE" "$mapper_rows" || { echo 'RESULT=STOP_SLOTS_CONFIG_INVALID'; return 71; }

    mapper_state_mode=canonical_default
    if [ -e "$STATE_FILE" ]; then
        rwf_state_validate "$STATE_FILE" "$mapper_rows" || { echo 'RESULT=STOP_FALLBACK_STATE_INVALID'; return 72; }
        mapper_state_mode=persisted
    fi

    : > "$mapper_batch"
    if "$NFT_BIN" list table inet "$TABLE" >/dev/null 2>&1; then
        printf 'delete table inet %s\n' "$TABLE" >> "$mapper_batch"
    fi
    printf 'add table inet %s\n' "$TABLE" >> "$mapper_batch"
    printf 'add chain inet %s prerouting { type filter hook prerouting priority mangle; policy accept; }\n' "$TABLE" >> "$mapper_batch"
    printf 'add chain inet %s postrouting { type filter hook postrouting priority mangle; policy accept; }\n' "$TABLE" >> "$mapper_batch"

    mapper_fallback_selectors=''
    for mapper_selector in cs1 cs2 cs3 cs4 cs5; do
        mapper_canonical_slot="$(rwf_selector_slot "$mapper_rows" "$mapper_selector")" || return 73
        if [ "$mapper_state_mode" = persisted ]; then
            mapper_target_slot="$(rwf_kv_get "effective.${mapper_selector}.slot" "$STATE_FILE")"
        else
            mapper_target_slot="$mapper_canonical_slot"
        fi
        mapper_iface="$(rwf_slot_field "$mapper_rows" "$mapper_target_slot" 3)" || return 73
        mapper_table="$(rwf_slot_field "$mapper_rows" "$mapper_target_slot" 4)" || return 73
        mapper_mark="$(rwf_slot_field "$mapper_rows" "$mapper_target_slot" 5)" || return 73

        "$IP_BIN" link show dev "$mapper_iface" >/dev/null 2>&1 || { echo "RESULT=STOP_TARGET_INTERFACE_MISSING_${mapper_iface}"; return 74; }
        "$IP_BIN" route show table "$mapper_table" | grep -E "default .* dev ${mapper_iface}|default dev ${mapper_iface}" >/dev/null 2>&1 || { echo "RESULT=STOP_TARGET_ROUTE_MISSING_${mapper_target_slot}"; return 75; }
        if [ -x "$AWG_BIN" ]; then
            "$AWG_BIN" show "$mapper_iface" dump 2>/dev/null | awk 'NR>=2 {found=1} END{exit found?0:1}' || { echo "RESULT=STOP_TARGET_AWG_PEER_MISSING_${mapper_iface}"; return 76; }
        fi

        if [ "$mapper_target_slot" != "$mapper_canonical_slot" ]; then
            if [ -n "$mapper_fallback_selectors" ]; then mapper_fallback_selectors="${mapper_fallback_selectors},${mapper_selector}"; else mapper_fallback_selectors="$mapper_selector"; fi
        fi

        printf 'add rule inet %s prerouting iifname "%s" ip saddr %s ip dscp %s meta mark set %s counter comment "R20QD_%s_TO_%s"\n' \
            "$TABLE" "$INPUT_IFACE" "$INPUT_SOURCE" "$mapper_selector" "$mapper_mark" "$mapper_selector" "$mapper_target_slot" >> "$mapper_batch"
        printf 'add rule inet %s postrouting meta mark %s ip dscp %s ip dscp set cs0 counter comment "R20QD_CLEAR_%s_%s"\n' \
            "$TABLE" "$mapper_mark" "$mapper_selector" "$mapper_selector" "$mapper_target_slot" >> "$mapper_batch"
    done

    if [ "${ROUTER_WGPAY_TEST_FAULT:-}" = nft_apply ]; then
        echo 'RESULT=STOP_INJECTED_NFT_APPLY'
        return 77
    fi
    "$NFT_BIN" -f "$mapper_batch" || { echo 'RESULT=STOP_FALLBACK_NFT_TRANSACTION'; return 78; }
    "$NFT_BIN" list table inet "$TABLE" > "$mapper_dump" 2>&1 || { echo 'RESULT=STOP_FALLBACK_NFT_VERIFY_LIST'; return 79; }
    mapper_seen=0
    for mapper_selector in cs1 cs2 cs3 cs4 cs5; do
        if [ "$mapper_state_mode" = persisted ]; then
            mapper_target_slot="$(rwf_kv_get "effective.${mapper_selector}.slot" "$STATE_FILE")"
        else
            mapper_target_slot="$(rwf_selector_slot "$mapper_rows" "$mapper_selector")"
        fi
        mapper_mark="$(rwf_slot_field "$mapper_rows" "$mapper_target_slot" 5)"
        mapper_mark_hex="${mapper_mark#0x}"
        mapper_mark_dec=$((mapper_mark))
        mapper_mark_pattern="(0[xX]0*${mapper_mark_hex}|${mapper_mark_dec})"
        grep -E "ip dscp ${mapper_selector}[[:space:]]+meta mark set[[:space:]]+${mapper_mark_pattern}([[:space:]]|$)" "$mapper_dump" >/dev/null 2>&1 || { echo "RESULT=STOP_FALLBACK_NFT_VERIFY_${mapper_selector}"; return 80; }
        grep -E "meta mark[[:space:]]+${mapper_mark_pattern}[[:space:]]+ip dscp ${mapper_selector}[[:space:]]+ip dscp set cs0([[:space:]]|$)" "$mapper_dump" >/dev/null 2>&1 || { echo "RESULT=STOP_FALLBACK_CLEAR_VERIFY_${mapper_selector}"; return 81; }
        mapper_seen=$((mapper_seen + 1))
    done
    [ "$mapper_seen" -eq 5 ] || return 82
    printf '%s\n' \
        'RESULT=PASS_VM101_ALWAYS_ON_FALLBACK_MAPPER_APPLY' \
        "MAPPER_STATE_MODE=${mapper_state_mode}" \
        "FALLBACK_SELECTORS=${mapper_fallback_selectors}" \
        'MAPPER_RULE_COUNT=5' \
        'CLEAR_RULE_COUNT=5' \
        'NFT_TRANSACTION_ATOMIC=true'
    return 0
}

case "${1:-start}" in
    start|restart|reload)
        if [ "${ROUTER_WGPAY_FALLBACK_LOCK_BYPASS:-0}" != 1 ]; then
            mkdir -p "$(dirname "$LOCK_FILE")" || exit 70
            exec 9>"$LOCK_FILE"
            flock -n 9 || { echo 'RESULT=STOP_FALLBACK_MAPPER_LOCKED'; exit 75; }
        fi
        mapper_apply
        ;;
    status)
        "$NFT_BIN" list table inet "$TABLE" 2>/dev/null
        ;;
    stop)
        "$NFT_BIN" delete table inet "$TABLE" 2>/dev/null || true
        echo 'RESULT=PASS_VM101_FALLBACK_MAPPER_STOP'
        ;;
    *)
        echo "usage: $0 {start|stop|restart|reload|status}"
        exit 64
        ;;
esac
