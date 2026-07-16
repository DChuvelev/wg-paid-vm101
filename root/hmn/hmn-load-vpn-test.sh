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
BACKUP="/root/hmn/backups/network-before-vpn_test-$TS"

mkdir -p /root/hmn/backups
chmod 700 /root/hmn /root/hmn/backups

cp /etc/config/network "$BACKUP"
chmod 600 "$BACKUP"

echo "Backup:"
echo "  $BACKUP"
echo
echo "Loading config into vpn_test:"
echo "  $CONF"
echo
echo "Parsed:"
echo "  Address:  $ADDRESS"
echo "  Endpoint: $ENDPOINT"
echo "  DNS:      ${DNS:-none}"
echo "  AWG:      Jc=$JC Jmin=$JMIN Jmax=$JMAX S1=$S1 S2=$S2"
echo

ifdown vpn_test 2>/dev/null || true

uci -q delete network.vpn_test

while :; do
  SEC="$(uci -q show network | sed -n 's/^\(network\.@amneziawg_vpn_test\[[0-9][0-9]*\]\)=amneziawg_vpn_test$/\1/p' | head -n 1)"
  [ -n "$SEC" ] || break
  uci -q delete "$SEC"
done

uci set network.vpn_test='interface'
uci set network.vpn_test.proto='amneziawg'
uci set network.vpn_test.private_key="$PRIVATE_KEY"
uci set network.vpn_test.awg_jc="$JC"
uci set network.vpn_test.awg_jmin="$JMIN"
uci set network.vpn_test.awg_jmax="$JMAX"
uci set network.vpn_test.awg_s1="$S1"
uci set network.vpn_test.awg_s2="$S2"
uci set network.vpn_test.awg_h1="$H1"
uci set network.vpn_test.awg_h2="$H2"
uci set network.vpn_test.awg_h3="$H3"
uci set network.vpn_test.awg_h4="$H4"

uci set network.vpn_test.auto='0'
uci set network.vpn_test.disabled='0'
uci set network.vpn_test.delegate='0'
uci set network.vpn_test.peerdns='0'
uci set network.vpn_test.defaultroute='0'

uci add_list network.vpn_test.addresses="$ADDRESS"

if [ -n "${DNS:-}" ]; then
  OLDIFS="$IFS"
  IFS=','
  for D in $DNS; do
    D="$(echo "$D" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$D" ] && uci add_list network.vpn_test.dns="$D"
  done
  IFS="$OLDIFS"
fi

PEER="$(uci add network amneziawg_vpn_test)"
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

uci set network.vpn_test.hmn_role='test_slot'
uci set network.vpn_test.hmn_source_config="$CONF"
uci set network.vpn_test.hmn_loaded_at="$(date -Iseconds)"
uci set network.vpn_test.hmn_endpoint="$ENDPOINT"

uci commit network

/etc/init.d/network reload

echo
echo "vpn_test loaded."
echo
uci show network.vpn_test
echo
uci show network | grep -E '=amneziawg_vpn_test|@amneziawg_vpn_test.*public_key|@amneziawg_vpn_test.*allowed_ips|@amneziawg_vpn_test.*route_allowed_ips|@amneziawg_vpn_test.*endpoint_host|@amneziawg_vpn_test.*endpoint_port|@amneziawg_vpn_test.*persistent_keepalive'
echo

echo

if [ "$ACTION" = "up" ]; then
  echo "Bringing vpn_test up..."
  ifup vpn_test
  sleep 5

  echo
  echo "Link:"
  ip link show vpn_test 2>/dev/null || true

  echo
  echo "AWG/WG show:"
  awg show vpn_test 2>/dev/null || wg show vpn_test 2>/dev/null || true

  echo
else
  echo "Не поднимал интерфейс."
  echo "Чтобы поднять:"
  echo "  ifup vpn_test"
fi
