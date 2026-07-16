#!/bin/sh
# STEP_050M07R15A_LEGACY_EXECUTION_FREEZE_AND_CLEAN_FOUNDATION
set -u

SLOTS_CONF="${SLOTS_CONF:-/etc/router-egress-slots.d/slots.conf}"

[ -r "$SLOTS_CONF" ] || {
    echo "BLOCK: slots_conf_missing:$SLOTS_CONF"
    exit 2
}

slot_pref() {
    case "$1" in
        egress1) echo 10011 ;;
        egress2) echo 10012 ;;
        egress3) echo 10013 ;;
        egress4) echo 10014 ;;
        egress5) echo 10015 ;;
        *) return 1 ;;
    esac
}

slot_line() {
    slot="$1"
    grep -Ev '^[[:space:]]*(#|$)' "$SLOTS_CONF" | awk -v wanted="$slot" '$1 == wanted { print; exit }'
}

ensure_link() {
    iface="$1"
    ip link show "$iface" >/dev/null 2>&1 || {
        echo "BLOCK: missing_iface_$iface"
        return 10
    }
}

ensure_rule() {
    pref="$1"
    mark="$2"
    table="$3"
    ip rule show | grep -E "fwmark $mark.*lookup $table|fwmark $mark/0xffffffff.*lookup $table" >/dev/null && return 0
    ip rule add pref "$pref" fwmark "$mark" lookup "$table"
}

apply_one() {
    slot="$1"
    line="$(slot_line "$slot")"
    [ -n "$line" ] || {
        echo "BLOCK: slot_not_found_$slot"
        return 3
    }

    set -- $line
    slot_id="$1"
    iface="$2"
    table="$3"
    mark="$4"
    enabled="${11}"

    [ "$enabled" = "1" ] || {
        echo "SKIP: slot_disabled_$slot"
        return 0
    }

    pref="$(slot_pref "$slot_id")" || {
        echo "BLOCK: unsupported_slot_$slot_id"
        return 4
    }

    ensure_link "$iface" || return $?
    ip route replace default dev "$iface" table "$table" || return 11
    ensure_rule "$pref" "$mark" "$table" || return 12

    ip route show table "$table" | grep -Eq "default[[:space:]].*dev[[:space:]]+${iface}([[:space:]]|$)" || {
        echo "BLOCK: table_${table}_default_${iface}_missing"
        return 20
    }
    ip rule show | grep -E "fwmark $mark.*lookup $table|fwmark $mark/0xffffffff.*lookup $table" >/dev/null || {
        echo "BLOCK: table_${table}_mark_${mark}_rule_missing"
        return 21
    }

    echo "applied_slot=$slot_id iface=$iface table=$table mark=$mark"
}

stop_one() {
    slot="$1"
    line="$(slot_line "$slot")"
    [ -n "$line" ] || return 0

    set -- $line
    slot_id="$1"
    table="$3"
    mark="$4"
    pref="$(slot_pref "$slot_id")" || return 1

    while ip rule show | grep -E "fwmark $mark.*lookup $table|fwmark $mark/0xffffffff.*lookup $table" >/dev/null; do
        ip rule del fwmark "$mark" lookup "$table" 2>/dev/null \
            || ip rule del pref "$pref" 2>/dev/null \
            || break
    done
    ip route flush table "$table" 2>/dev/null || true
    echo "stopped_slot=$slot_id table=$table mark=$mark"
}

all_slots() {
    grep -Ev '^[[:space:]]*(#|$)' "$SLOTS_CONF" | awk '$11 == 1 { print $1 }'
}

apply_routes() {
    requested="${1:-}"
    if [ -n "$requested" ]; then
        apply_one "$requested" || return $?
    else
        for slot in $(all_slots); do
            apply_one "$slot" || return $?
        done
    fi
    ip route flush cache 2>/dev/null || true
    echo "applied_router_egress_slots_5=1"
    echo "legacy_table200_dependency=false"
}

stop_routes() {
    requested="${1:-}"
    if [ -n "$requested" ]; then
        stop_one "$requested" || return $?
    else
        for slot in $(all_slots); do
            stop_one "$slot" || return $?
        done
    fi
    echo "stopped_router_egress_slots_5=1"
}

show_status() {
    requested="${1:-}"
    if [ -n "$requested" ]; then
        line="$(slot_line "$requested")"
        [ -n "$line" ] || return 3
        set -- $line
        echo "--- slot $1 iface $2 table $3 mark $4 ---"
        ip rule show | grep -E "fwmark $4.*lookup $3|fwmark $4/0xffffffff.*lookup $3" || true
        ip route show table "$3" || true
    else
        ip rule show | grep -E 'fwmark 0x20[1-5]|lookup 20[1-5]' || true
        for table in 201 202 203 204 205; do
            echo "--- table $table ---"
            ip route show table "$table" || true
        done
    fi
}

command="${1:-start}"
requested="${2:-}"
case "$command" in
    start|restart|reload) apply_routes "$requested" ;;
    stop) stop_routes "$requested" ;;
    status) show_status "$requested" ;;
    *)
        echo "usage: $0 {start|stop|restart|reload|status} [egress1..egress5]"
        exit 1
        ;;
esac
