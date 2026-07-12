#!/bin/ash

set -eu

SLOT="${1:-}"
CONF="${2:-}"
ACTION="${3:-}"

case "$SLOT" in
  vpn1|vpn2) ;;
  *)
    echo "ERROR: slot должен быть vpn1 или vpn2"
    echo "Использование:"
    echo "  /root/hmn/hmn-load-vpn-slot.sh vpn2 /path/to/config.conf"
    echo "  /root/hmn/hmn-load-vpn-slot.sh vpn2 /path/to/config.conf up"
    exit 1
    ;;
esac

if [ -z "$CONF" ] || [ ! -f "$CONF" ]; then
  echo "ERROR: не найден config:"
  echo "  $CONF"
  exit 1
fi

ACTIVE="$(ip route show table 200 | awk '/^default dev /{print $3; exit}')"

if [ "$SLOT" = "$ACTIVE" ] && [ "${HMN_ALLOW_ACTIVE_RELOAD:-0}" != "1" ]; then
  echo "ERROR: refusing to reload active slot: $SLOT"
  echo "Current table 200 active slot: $ACTIVE"
  echo
  echo "Для blue/green сначала грузи конфиг в неактивный слот."
  echo "Если очень надо принудительно:"
  echo "  HMN_ALLOW_ACTIVE_RELOAD=1 /root/hmn/hmn-load-vpn-slot.sh $SLOT $CONF"
  exit 1
fi

getv() {
  KEY="$1"
  awk -v key="$KEY" '
    {
      sub(/\r$/, "", $0)
    }
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
  echo "CONF=$CONF"
  echo "Address=$ADDRESS"
  echo "PrivateKey=${PRIVATE_KEY:+loaded}"
  echo "PublicKey=${PUBLIC_KEY:+loaded}"
  echo "Endpoint=$ENDPOINT"
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hmn/backups/network-before-load-${SLOT}-$TS"

mkdir -p /root/hmn/backups
chmod 700 /root/hmn /root/hmn/backups

cp /etc/config/network "$BACKUP"
chmod 600 "$BACKUP"

echo "Backup:"
echo "  $BACKUP"
echo
echo "Loading into slot:"
echo "  slot:     $SLOT"
echo "  config:   $CONF"
echo "  endpoint: $ENDPOINT"
echo "  address:  $ADDRESS"
echo "  active table 200 before load: ${ACTIVE:-none}"
echo

ifdown "$SLOT" 2>/dev/null || true

uci -q delete network."$SLOT" || true

while :; do
  SEC="$(uci -q show network | sed -n "s/^\(network\.@amneziawg_${SLOT}\[[0-9][0-9]*\]\)=amneziawg_${SLOT}$/\1/p" | head -n 1)"
  [ -n "$SEC" ] || break
  uci -q delete "$SEC"
done

uci set network."$SLOT"='interface'
uci set network."$SLOT".proto='amneziawg'
uci set network."$SLOT".private_key="$PRIVATE_KEY"
uci set network."$SLOT".awg_jc="$JC"
uci set network."$SLOT".awg_jmin="$JMIN"
uci set network."$SLOT".awg_jmax="$JMAX"
uci set network."$SLOT".awg_s1="$S1"
uci set network."$SLOT".awg_s2="$S2"
uci set network."$SLOT".awg_h1="$H1"
uci set network."$SLOT".awg_h2="$H2"
uci set network."$SLOT".awg_h3="$H3"
uci set network."$SLOT".awg_h4="$H4"

uci set network."$SLOT".auto='0'
uci set network."$SLOT".disabled='0'
uci set network."$SLOT".delegate='0'
uci set network."$SLOT".peerdns='0'
uci set network."$SLOT".defaultroute='0'

uci add_list network."$SLOT".addresses="$ADDRESS"

if [ -n "${DNS:-}" ]; then
  OLDIFS="$IFS"
  IFS=','
  for D in $DNS; do
    D="$(echo "$D" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$D" ] && uci add_list network."$SLOT".dns="$D"
  done
  IFS="$OLDIFS"
fi

PEER="$(uci add network "amneziawg_${SLOT}")"
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

uci set network."$SLOT".hmn_role='active_spare_slot'
uci set network."$SLOT".hmn_source_config="$CONF"
uci set network."$SLOT".hmn_loaded_at="$(date -Iseconds)"
uci set network."$SLOT".hmn_endpoint="$ENDPOINT"

uci commit network

echo "Loaded. Slot is still down unless ACTION=up."
echo
uci show network."$SLOT" | sed "s/private_key='[^']*'/private_key='***hidden***'/"
echo
uci show network | grep -E "=amneziawg_${SLOT}|@amneziawg_${SLOT}.*description|@amneziawg_${SLOT}.*allowed_ips|@amneziawg_${SLOT}.*route_allowed_ips|@amneziawg_${SLOT}.*endpoint_host|@amneziawg_${SLOT}.*endpoint_port|@amneziawg_${SLOT}.*persistent_keepalive"

echo
echo "table 200 after load:"
ip route show table 200

if [ "$ACTION" = "up" ]; then
  echo
  echo "Bringing $SLOT up..."
  ifup "$SLOT"
  sleep 10
  /usr/bin/amneziawg show "$SLOT" 2>/dev/null || true
fi
