#!/bin/sh
set -u

ensure_link() {
  iface="$1"
  ip link show "$iface" >/dev/null 2>&1 || {
    echo "BLOCK: missing_iface_$iface"
    exit 10
  }
}

ensure_rule() {
  pref="$1"
  mark="$2"
  table="$3"

  ip rule show | grep -E "fwmark $mark.*lookup $table|fwmark $mark/0xffffffff.*lookup $table" >/dev/null && return 0

  ip rule add pref "$pref" fwmark "$mark" lookup "$table"
}

case "${1:-start}" in
  start|restart|reload)
    ensure_link vpn1
    ensure_link vpn2
    ensure_link vpn3
    ensure_link vpn4
    ensure_link vpn5

    ip route replace default dev vpn1 table 201
    ip route replace default dev vpn2 table 202
    ip route replace default dev vpn3 table 203
    ip route replace default dev vpn4 table 204
    ip route replace default dev vpn5 table 205

    ensure_rule 10011 0x201 201
    ensure_rule 10012 0x202 202
    ensure_rule 10013 0x203 203
    ensure_rule 10014 0x204 204
    ensure_rule 10015 0x205 205

    ip route flush cache 2>/dev/null || true

    ip route show table 200 | grep -F "default dev vpn1" >/dev/null || {
      echo "BLOCK: legacy_table200_default_vpn1_missing"
      exit 20
    }

    echo "applied_router_egress_slots_5=1"
    ;;

  stop)
    for mark_table in "0x201 201 10011" "0x202 202 10012" "0x203 203 10013" "0x204 204 10014" "0x205 205 10015"; do
      set -- $mark_table
      mark="$1"
      table="$2"
      pref="$3"
      while ip rule show | grep -E "fwmark $mark.*lookup $table|fwmark $mark/0xffffffff.*lookup $table" >/dev/null; do
        ip rule del fwmark "$mark" lookup "$table" 2>/dev/null || ip rule del pref "$pref" 2>/dev/null || break
      done
    done

    ip route flush table 201 2>/dev/null || true
    ip route flush table 202 2>/dev/null || true
    ip route flush table 203 2>/dev/null || true
    ip route flush table 204 2>/dev/null || true
    ip route flush table 205 2>/dev/null || true
    echo "stopped_router_egress_slots_5=1"
    ;;

  status)
    ip rule show | grep -E 'fwmark 0x20[1-5]|lookup 20[1-5]' || true
    for t in 201 202 203 204 205; do
      echo "--- table $t ---"
      ip route show table "$t" || true
    done
    ;;

  *)
    echo "usage: $0 {start|stop|restart|reload|status}"
    exit 1
    ;;
esac
