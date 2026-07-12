#!/bin/ash
set -eu

SLOT="${1:-}"
CONF="${2:-}"
ACTION="${3:-dry-run}"

case "$SLOT" in
  vpn1|vpn2|vpn3|vpn4|vpn5) ;;
  *)
    echo "ERROR: slot must be vpn1..vpn5" >&2
    echo "Usage:" >&2
    echo "  hmn-load-egress-slot.sh vpn3 /path/to/config.conf dry-run" >&2
    echo "  hmn-load-egress-slot.sh vpn3 /path/to/config.conf load" >&2
    echo "  hmn-load-egress-slot.sh vpn3 /path/to/config.conf load-up" >&2
    exit 1
    ;;
esac

case "$ACTION" in
  dry-run|load|load-up) ;;
  *)
    echo "ERROR: action must be dry-run, load, or load-up" >&2
    exit 1
    ;;
esac

if [ -z "$CONF" ] || [ ! -f "$CONF" ]; then
  echo "ERROR: config not found: $CONF" >&2
  exit 1
fi

getv() {
  KEY="$1"
  awk -v key="$KEY" '
    { sub(/\r$/, "", $0) }
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
  echo "ERROR: config parse failed" >&2
  echo "CONF=$CONF" >&2
  echo "Address=$ADDRESS" >&2
  echo "Endpoint=$ENDPOINT" >&2
  exit 1
fi

echo "HMN generic egress slot loader"
echo "slot=$SLOT"
echo "config=$CONF"
echo "endpoint=$ENDPOINT"
echo "address=$ADDRESS"
echo "action=$ACTION"

if [ "$ACTION" = "dry-run" ]; then
  echo "DRY_RUN=YES"
  echo "No changes applied."
  exit 0
fi

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hmn/backups/network-before-egress-load-${SLOT}-$TS"

mkdir -p /root/hmn/backups
chmod 700 /root/hmn /root/hmn/backups
cp /etc/config/network "$BACKUP"
chmod 600 "$BACKUP"

echo "Backup: $BACKUP"

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

uci set network."$SLOT".hmn_role='egress_pool_slot'
uci set network."$SLOT".hmn_source_config="$CONF"
uci set network."$SLOT".hmn_loaded_at="$(date -Iseconds)"
uci set network."$SLOT".hmn_endpoint="$ENDPOINT"

uci commit network

echo "Loaded slot $SLOT."
echo "Slot remains down unless action=load-up."

if [ "$ACTION" = "load-up" ]; then
  echo "Bringing $SLOT up..."
  ifup "$SLOT"
  sleep 10
  /usr/bin/amneziawg show "$SLOT" 2>/dev/null || true
fi
