#!/bin/ash

set -eu

CONF="${1:-}"
ACTION="${2:-}"

if [ -z "$CONF" ]; then
  CONF="$(ls -t /root/hmn/configs/awg1/latest/*.conf 2>/dev/null | head -n 1 || true)"
fi

if [ -z "$CONF" ] || [ ! -f "$CONF" ]; then
  echo "ERROR: не найден .conf"
  echo
  echo "Использование:"
  echo "  /root/hmn/hmn-load-vpn-test.sh /path/to/config.conf"
  echo "  /root/hmn/hmn-load-vpn-test.sh /path/to/config.conf up"
  echo
  echo "Или без аргумента — возьмёт первый файл из:"
  echo "  /root/hmn/configs/awg1/latest/"
  exit 1
fi

getv() {
  KEY="$1"
  awk -v key="$KEY" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, "", $0)
      sub(/[[:space:]]*$/, "", $0)
      print $0
      exit
    }
  ' "$CONF"
}

PRIVATE_KEY="$(getv PrivateKey)"
ADDRESS="$(getv Address)"
DNS="$(getv DNS)"
JC="$(getv Jc)"
JMIN="$(getv Jmin)"
JMAX="$(getv Jmax)"
S1="$(getv S1)"
S2="$(getv S2)"
H1="$(getv H1)"
H2="$(getv H2)"
H3="$(getv H3)"
H4="$(getv H4)"

PUBLIC_KEY="$(getv PublicKey)"
ALLOWED_IPS="$(getv AllowedIPs)"
ENDPOINT="$(getv Endpoint)"
KEEPALIVE="$(getv PersistentKeepalive)"

ENDPOINT_HOST="${ENDPOINT%:*}"
ENDPOINT_PORT="${ENDPOINT##*:}"

if [ -z "$PRIVATE_KEY" ] || [ -z "$ADDRESS" ] || [ -z "$PUBLIC_KEY" ] || [ -z "$ENDPOINT_HOST" ] || [ -z "$ENDPOINT_PORT" ]; then
  echo "ERROR: конфиг не удалось распарсить."
  echo
  echo "CONF=$CONF"
  echo "Address=$ADDRESS"
  echo "PrivateKey=${PRIVATE_KEY:+loaded}"
  echo "PublicKey=${PUBLIC_KEY:+loaded}"
  echo "Endpoint=$ENDPOINT"
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"

# HMN_DUPLICATE_ACTIVE_SLOT_GUARD_V1
# Do not load the same AWG endpoint/config into vpn_user if it is already present
# in managed egress slots. Running the same remote tunnel twice on different
# interfaces can break routing/handshake behavior.
check_duplicate_active_slots() {
  TARGET_EP="${ENDPOINT_HOST}:${ENDPOINT_PORT}"
  TARGET_CONF_BASE="$(basename "${CONF:-}" 2>/dev/null || echo "")"

  for SLOT in vpn1 vpn2 vpn3 vpn4; do
    [ "$SLOT" = "vpn_user" ] && continue

    # Compare by interface metadata if present.
    SLOT_SRC="$(uci -q get network.${SLOT}.hmn_source_config || true)"
    if [ -n "$TARGET_CONF_BASE" ] && [ -n "$SLOT_SRC" ]; then
      SLOT_SRC_BASE="$(basename "$SLOT_SRC" 2>/dev/null || echo "")"
      if [ "$TARGET_CONF_BASE" = "$SLOT_SRC_BASE" ]; then
        echo "ERROR: selected config already loaded in $SLOT: $TARGET_CONF_BASE"
        exit 1
      fi
    fi

    # Compare by peer endpoint in amneziawg slot section.
    SEC="$(uci -q show network | sed -n "s/^\(network\.@amneziawg_${SLOT}\[[0-9][0-9]*\]\)=amneziawg_${SLOT}$/\1/p" | head -n 1)"
    if [ -n "$SEC" ]; then
      EH="$(uci -q get ${SEC}.endpoint_host || true)"
      EP="$(uci -q get ${SEC}.endpoint_port || true)"
      if [ -n "$EH" ] && [ -n "$EP" ] && [ "$TARGET_EP" = "$EH:$EP" ]; then
        echo "ERROR: selected endpoint already loaded in $SLOT: $TARGET_EP"
        exit 1
      fi
    fi
  done
}

check_duplicate_active_slots

BACKUP="/root/hmn/backups/network-before-vpn_user-$TS"

mkdir -p /root/hmn/backups
chmod 700 /root/hmn /root/hmn/backups

cp /etc/config/network "$BACKUP"
chmod 600 "$BACKUP"

echo "Backup:"
echo "  $BACKUP"
echo
echo "Loading config into vpn_user:"
echo "  $CONF"
echo
echo "Parsed:"
echo "  Address:  $ADDRESS"
echo "  Endpoint: $ENDPOINT"
echo "  DNS:      ${DNS:-none}"
echo "  AWG:      Jc=$JC Jmin=$JMIN Jmax=$JMAX S1=$S1 S2=$S2"
echo

ifdown vpn_user 2>/dev/null || true

uci -q delete network.vpn_user 2>/dev/null || true

while :; do
  SEC="$(uci -q show network | sed -n 's/^\(network\.@amneziawg_vpn_user\[[0-9][0-9]*\]\)=amneziawg_vpn_user$/\1/p' | head -n 1)"
  [ -n "$SEC" ] || break
  uci -q delete "$SEC"
done

uci set network.vpn_user='interface'
uci set network.vpn_user.proto='amneziawg'
uci set network.vpn_user.private_key="$PRIVATE_KEY"
uci set network.vpn_user.awg_jc="$JC"
uci set network.vpn_user.awg_jmin="$JMIN"
uci set network.vpn_user.awg_jmax="$JMAX"
uci set network.vpn_user.awg_s1="$S1"
uci set network.vpn_user.awg_s2="$S2"
uci set network.vpn_user.awg_h1="$H1"
uci set network.vpn_user.awg_h2="$H2"
uci set network.vpn_user.awg_h3="$H3"
uci set network.vpn_user.awg_h4="$H4"

uci set network.vpn_user.auto='0'
uci set network.vpn_user.disabled='0'
uci set network.vpn_user.delegate='0'
uci set network.vpn_user.peerdns='0'
uci set network.vpn_user.defaultroute='0'

uci add_list network.vpn_user.addresses="$ADDRESS"

if [ -n "${DNS:-}" ]; then
  OLDIFS="$IFS"
  IFS=','
  for D in $DNS; do
    D="$(echo "$D" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$D" ] && uci add_list network.vpn_user.dns="$D"
  done
  IFS="$OLDIFS"
fi

PEER="$(uci add network amneziawg_vpn_user)"
uci set network."$PEER".description="$(basename "$CONF")"
uci set network."$PEER".public_key="$PUBLIC_KEY"

OLDIFS="$IFS"
IFS=','
for A in ${ALLOWED_IPS:-0.0.0.0/0}; do
  A="$(echo "$A" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$A" ] && uci add_list network."$PEER".allowed_ips="$A"
done
IFS="$OLDIFS"

uci set network."$PEER".route_allowed_ips='0'
uci set network."$PEER".persistent_keepalive="${KEEPALIVE:-25}"
uci set network."$PEER".endpoint_host="$ENDPOINT_HOST"
uci set network."$PEER".endpoint_port="$ENDPOINT_PORT"

uci set network.vpn_user.hmn_role='user_select_slot'
uci set network.vpn_user.hmn_source_config="$CONF"
uci set network.vpn_user.hmn_loaded_at="$(date -Iseconds)"
uci set network.vpn_user.hmn_endpoint="$ENDPOINT"

uci commit network

/etc/init.d/network reload

echo
echo "vpn_user loaded."
echo
echo "vpn_user summary:"
echo "  proto=$(uci -q get network.vpn_user.proto || true)"
echo "  address=$(uci -q get network.vpn_user.addresses || true)"
echo "  dns=$(uci -q get network.vpn_user.dns || true)"
echo "  source_config=$(uci -q get network.vpn_user.hmn_source_config || true)"
echo "  endpoint=$(uci -q get network.vpn_user.hmn_endpoint || true)"
PEER_SUM="$(uci -q show network | sed -n 's/^\(network\.@amneziawg_vpn_user\[[0-9][0-9]*\]\)=amneziawg_vpn_user$/\1/p' | head -n 1)"
if [ -n "$PEER_SUM" ]; then
  echo "  peer_section=$PEER_SUM"
  echo "  allowed_ips=$(uci -q get ${PEER_SUM}.allowed_ips || true)"
  echo "  route_allowed_ips=$(uci -q get ${PEER_SUM}.route_allowed_ips || true)"
  echo "  persistent_keepalive=$(uci -q get ${PEER_SUM}.persistent_keepalive || true)"
  echo "  peer_endpoint=$(uci -q get ${PEER_SUM}.endpoint_host || true):$(uci -q get ${PEER_SUM}.endpoint_port || true)"
fi
echo

echo "Current table 200:"
ip route show table 200
echo

if [ "$ACTION" = "up" ]; then
  echo "Bringing vpn_user up..."
  ifup vpn_user
  sleep 5

  echo
  echo "Link:"
  ip link show vpn_user 2>/dev/null || true

  echo
  echo "AWG/WG show: hidden in normal output; use explicit admin diagnostics if needed"

  echo
  echo "Table 200 after ifup:"
  ip route show table 200
else
  echo "Не поднимал интерфейс."
  echo "Чтобы поднять:"
  echo "  ifup vpn_user"
fi
