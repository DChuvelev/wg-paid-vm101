#!/bin/sh
set -u

TABLE="router_egress_dscp_canary"

check_route() {
  table="$1"
  iface="$2"
  ip route show table "$table" | grep -E "default .* dev $iface|default dev $iface" >/dev/null || {
    echo "BLOCK: table${table}_not_${iface}"
    exit "$3"
  }
}

case "${1:-start}" in
  start|restart|reload)
    check_route 201 vpn1 21
    check_route 202 vpn2 22
    check_route 203 vpn3 23
    check_route 204 vpn4 24
    check_route 205 vpn5 25

    ip route show table 200 | grep -F "default dev vpn1" >/dev/null || {
      echo "BLOCK: legacy_table200_default_vpn1_missing"
      exit 30
    }

    nft delete table inet "$TABLE" 2>/dev/null || true
    nft add table inet "$TABLE"
    nft add chain inet "$TABLE" prerouting '{ type filter hook prerouting priority mangle; policy accept; }'
    nft add chain inet "$TABLE" postrouting '{ type filter hook postrouting priority mangle; policy accept; }'

    nft add rule inet "$TABLE" prerouting iifname "eth1" ip saddr 10.200.0.1 ip dscp cs1 meta mark set 0x203 counter comment "STEP_036I_DSCP_CS1_TO_FW_MARK_0x203"
    nft add rule inet "$TABLE" prerouting iifname "eth1" ip saddr 10.200.0.1 ip dscp cs2 meta mark set 0x204 counter comment "STEP_036I_DSCP_CS2_TO_FW_MARK_0x204"
    nft add rule inet "$TABLE" prerouting iifname "eth1" ip saddr 10.200.0.1 ip dscp cs3 meta mark set 0x205 counter comment "STEP_036I_DSCP_CS3_TO_FW_MARK_0x205"
    nft add rule inet "$TABLE" prerouting iifname "eth1" ip saddr 10.200.0.1 ip dscp cs4 meta mark set 0x201 counter comment "STEP_036I_DSCP_CS4_TO_FW_MARK_0x201"
    nft add rule inet "$TABLE" prerouting iifname "eth1" ip saddr 10.200.0.1 ip dscp cs5 meta mark set 0x202 counter comment "STEP_036I_DSCP_CS5_TO_FW_MARK_0x202"

    nft add rule inet "$TABLE" postrouting meta mark 0x203 ip dscp cs1 ip dscp set cs0 counter comment "STEP_036I_CLEAR_DSCP_CS1_MARK_0x203"
    nft add rule inet "$TABLE" postrouting meta mark 0x204 ip dscp cs2 ip dscp set cs0 counter comment "STEP_036I_CLEAR_DSCP_CS2_MARK_0x204"
    nft add rule inet "$TABLE" postrouting meta mark 0x205 ip dscp cs3 ip dscp set cs0 counter comment "STEP_036I_CLEAR_DSCP_CS3_MARK_0x205"
    nft add rule inet "$TABLE" postrouting meta mark 0x201 ip dscp cs4 ip dscp set cs0 counter comment "STEP_036I_CLEAR_DSCP_CS4_MARK_0x201"
    nft add rule inet "$TABLE" postrouting meta mark 0x202 ip dscp cs5 ip dscp set cs0 counter comment "STEP_036I_CLEAR_DSCP_CS5_MARK_0x202"

    echo "applied_vm101_5class_mapper=1"
    ;;

  stop)
    nft delete table inet "$TABLE" 2>/dev/null || true
    echo "stopped_vm101_5class_mapper=1"
    ;;

  status)
    nft list table inet "$TABLE" 2>/dev/null
    ;;

  *)
    echo "usage: $0 {start|stop|restart|reload|status}"
    exit 1
    ;;
esac
