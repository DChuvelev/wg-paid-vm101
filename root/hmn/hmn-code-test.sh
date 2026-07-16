#!/bin/ash

set -eu

ENV_FILE="/root/hmn/hmn.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: нет $ENV_FILE"
  echo "Сначала запусти:"
  echo "  /root/hmn/hmn-set-code.sh"
  exit 1
fi

HMN_REQUEST_IFACE_CALLER_SET="${HMN_REQUEST_IFACE+x}"
HMN_REQUEST_IFACE_CALLER_VALUE="${HMN_REQUEST_IFACE-}"

. "$ENV_FILE"

if [ -z "${HMN_ACCESS_CODE:-}" ]; then
  echo "ERROR: HMN_ACCESS_CODE пустой."
  exit 1
fi

RUNTIME_LIB="/usr/local/lib/router-egress-vm101-runtime.sh"

if [ ! -r "$RUNTIME_LIB" ]; then
  echo "ERROR: нет читаемой runtime library: $RUNTIME_LIB"
  exit 1
fi

. "$RUNTIME_LIB"

if [ "$HMN_REQUEST_IFACE_CALLER_SET" = "x" ]; then
  REQUEST_IFACE="$HMN_REQUEST_IFACE_CALLER_VALUE"
else
  REQUEST_IFACE="${HMN_REQUEST_IFACE:-auto}"
fi

case "$REQUEST_IFACE" in
  auto)
    ACTIVE="$(vm101_healthy_bootstrap_iface || true)"
    ;;

  vpn1|vpn2|vpn3|vpn4|vpn5)
    if ! vm101_strict_iface "$REQUEST_IFACE" 1 0; then
      echo "ERROR: requested VPN interface is invalid or unhealthy: $REQUEST_IFACE"
      exit 1
    fi

    ACTIVE="$REQUEST_IFACE"
    ;;

  *)
    echo "ERROR: requested VPN interface is invalid or unhealthy: $REQUEST_IFACE"
    exit 1
    ;;
esac

if [ -z "${ACTIVE:-}" ]; then
  echo "ERROR: не найден ни один здоровый VPN interface vpn1-vpn5."
  exit 1
fi

echo "HMN env loaded OK."
echo "AWG param: ${HMN_AWG_PARAM:-unknown}"
echo "Request interface: $ACTIVE"
echo "Access code: loaded, hidden"
echo

echo "Проверяю HideMyName serverlist API..."

TMP="/tmp/hmn-serverlist-test.$$"

curl -4 --http1.1 --interface "$ACTIVE" \
  -sS -L --connect-timeout 10 --max-time 45 \
  -H "Origin: https://hide-my-name.net" \
  -H "Referer: https://hide-my-name.net/vpn/router/" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "code=$HMN_ACCESS_CODE" \
  --data "routers=1" \
  "$HMN_SERVERLIST_URL" \
  -o "$TMP"

if grep -q '"services"' "$TMP" && grep -q '"wg"' "$TMP"; then
  echo "OK: serverlist получен, services.wg найден."
else
  echo "ERROR: ответ не похож на нормальный serverlist."
  echo
  head -c 1000 "$TMP"
  echo
  rm -f "$TMP"
  exit 1
fi

rm -f "$TMP"

echo "Тест завершён."
