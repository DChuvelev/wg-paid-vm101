#!/bin/ash

set -eu

BASE="/root/hmn"
ENV_FILE="$BASE/hmn.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: нет $ENV_FILE"
  echo "Сначала запусти:"
  echo "  /root/hmn/hmn-set-code.sh"
  exit 1
fi

HMN_REQUEST_IFACE_CALLER_SET="${HMN_REQUEST_IFACE+x}"
HMN_REQUEST_IFACE_CALLER_VALUE="${HMN_REQUEST_IFACE-}"

. "$ENV_FILE"

AWG_PARAM="${HMN_AWG_PARAM:-1}"
SERVERLIST_URL="${HMN_SERVERLIST_URL:-https://hide-my-name.net/api/serverlist.php?out=js&wg}"
CONFIG_URL="${HMN_CONFIG_URL:-https://hide-my-name.net/api/vpn_get_config_wg.php}"

if [ -z "${HMN_ACCESS_CODE:-}" ]; then
  echo "ERROR: HMN_ACCESS_CODE пустой в $ENV_FILE"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: нужен curl"
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
  echo "Optional table 200 routes:"
  ip route show table 200 2>/dev/null || true
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$BASE/runs/$TS"
CONFIG_DIR="$BASE/configs/awg${AWG_PARAM}/$TS"
LATEST_DIR="$BASE/configs/awg${AWG_PARAM}/latest"

mkdir -p "$RUN_DIR" "$CONFIG_DIR" "$BASE/cache" "$BASE/runs" "$BASE/configs/awg${AWG_PARAM}"
chmod 700 "$BASE" "$RUN_DIR" "$CONFIG_DIR" "$BASE/cache" "$BASE/runs" "$BASE/configs/awg${AWG_PARAM}"

SERVERLIST_FILE="$RUN_DIR/serverlist.json"
CANDIDATES_FILE="$RUN_DIR/wg-candidates.tsv"
WORKING_FILE="$RUN_DIR/working-awg${AWG_PARAM}.tsv"
FAIL_FILE="$RUN_DIR/fail-awg${AWG_PARAM}.tsv"
SUMMARY_FILE="$RUN_DIR/summary.txt"

echo "HideMyName download all AWG configs"
echo
echo "AWG parameter: awg=$AWG_PARAM"
echo "Request interface: $ACTIVE"
echo "Run dir: $RUN_DIR"
echo "Config dir: $CONFIG_DIR"
echo

echo "0/4 Проверяю доступ к hide-my-name.net через $ACTIVE..."

if ! curl -4 --http1.1 --interface "$ACTIVE" \
  -I --connect-timeout 10 --max-time 25 \
  https://hide-my-name.net/ >/dev/null 2>&1; then
  echo "ERROR: hide-my-name.net не открывается через $ACTIVE"
  exit 1
fi

echo "OK."
echo

echo "1/4 Скачиваю serverlist..."

curl -4 --http1.1 --interface "$ACTIVE" \
  -sS -L --connect-timeout 10 --max-time 45 \
  -H "Origin: https://hide-my-name.net" \
  -H "Referer: https://hide-my-name.net/vpn/router/" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "code=$HMN_ACCESS_CODE" \
  --data "routers=1" \
  "$SERVERLIST_URL" \
  -o "$SERVERLIST_FILE"

chmod 600 "$SERVERLIST_FILE"
cp "$SERVERLIST_FILE" "$BASE/cache/serverlist-latest.json"
chmod 600 "$BASE/cache/serverlist-latest.json"

if [ ! -s "$SERVERLIST_FILE" ]; then
  echo "ERROR: serverlist пустой."
  exit 1
fi

if ! grep -q '"wg"' "$SERVERLIST_FILE"; then
  echo "ERROR: в serverlist не найден services.wg."
  echo "Первые 1000 символов:"
  head -c 1000 "$SERVERLIST_FILE"
  echo
  exit 1
fi

echo "OK:"
echo "  $SERVERLIST_FILE"
echo

echo "2/4 Извлекаю все WG-кандидаты из services.wg..."

: > "$CANDIDATES_FILE"

tr -d '\n\r' < "$SERVERLIST_FILE" \
  | sed 's/},"[0-9][0-9]*":{/}\n{/g' \
  | while read -r REC; do
      echo "$REC" | grep -q '"wg"' || continue

      SERVER_ID="$(printf '%s' "$REC" \
        | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"

      COUNTRY_CODE="$(printf '%s' "$REC" \
        | sed -n 's/.*"country_code"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

      SERVER_NAME="$(printf '%s' "$REC" \
        | sed -n 's/.*"name_en"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

      WG_BLOCK="$(printf '%s' "$REC" \
        | sed -n 's/.*"wg"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p')"

      WG_IP="$(printf '%s' "$WG_BLOCK" \
        | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

      WG_PORT="$(printf '%s' "$WG_BLOCK" \
        | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"

      [ -n "$SERVER_ID" ] || continue
      [ -n "$SERVER_NAME" ] || continue
      [ -n "$WG_IP" ] || continue
      [ -n "$WG_PORT" ] || continue

      printf "%s\t%s\t%s\t%s\t%s\n" \
        "$SERVER_ID" "$COUNTRY_CODE" "$SERVER_NAME" "$WG_IP" "$WG_PORT" \
        >> "$CANDIDATES_FILE"
    done

TOTAL="$(wc -l < "$CANDIDATES_FILE" | tr -d ' ')"

if [ "$TOTAL" -eq 0 ]; then
  echo "ERROR: WG-кандидаты не найдены."
  exit 1
fi

echo "WG-кандидатов найдено:"
echo "  $TOTAL"
echo

printf "id\tcountry\tname\twg_ip\twg_port\tendpoint\tendpoint_match\taddress\tconfig_file\n" > "$WORKING_FILE"
printf "id\tcountry\tname\twg_ip\twg_port\treason\n" > "$FAIL_FILE"

echo "3/4 Скачиваю конфиги для всех WG-кандидатов..."
echo

N=0
OK=0
FAIL=0

while IFS="$(printf '\t')" read -r SERVER_ID COUNTRY_CODE SERVER_NAME WG_IP WG_PORT; do
  N=$((N + 1))
  EXPECTED_ENDPOINT="${WG_IP}:${WG_PORT}"

  SAFE_NAME="$(printf '%03d-%s-%s-%s' "$SERVER_ID" "$COUNTRY_CODE" "$SERVER_NAME" "$WG_IP" \
    | tr ' /,' '---' \
    | tr -cd 'A-Za-z0-9_.-' \
    | sed 's/--*/-/g')"

  TMP_CONFIG="$RUN_DIR/tmp-${SAFE_NAME}.conf"
  CONFIG_FILE="$CONFIG_DIR/${SAFE_NAME}-awg${AWG_PARAM}.conf"

  echo "[$N/$TOTAL] $COUNTRY_CODE | $SERVER_NAME | $EXPECTED_ENDPOINT"

  if curl -4 --http1.1 --interface "$ACTIVE" \
    -sS -L --connect-timeout 8 --max-time 35 \
    -H "Origin: https://hide-my-name.net" \
    -H "Referer: https://hide-my-name.net/vpn/router/" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "code=$HMN_ACCESS_CODE" \
    --data-urlencode "server=$WG_IP" \
    --data "awg=$AWG_PARAM" \
    "$CONFIG_URL" \
    -o "$TMP_CONFIG"; then

    if grep -q '^\[Interface\]' "$TMP_CONFIG" && grep -q '^\[Peer\]' "$TMP_CONFIG"; then
      ENDPOINT="$(awk -F'= *' '/^Endpoint[[:space:]]*=/{print $2; exit}' "$TMP_CONFIG")"
      ADDRESS="$(awk -F'= *' '/^Address[[:space:]]*=/{print $2; exit}' "$TMP_CONFIG")"

      if [ "$ENDPOINT" = "$EXPECTED_ENDPOINT" ]; then
        MATCH="yes"
      else
        MATCH="NO_expected_${EXPECTED_ENDPOINT}"
      fi

      mv "$TMP_CONFIG" "$CONFIG_FILE"
      chmod 600 "$CONFIG_FILE"

      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$SERVER_ID" "$COUNTRY_CODE" "$SERVER_NAME" "$WG_IP" "$WG_PORT" \
        "$ENDPOINT" "$MATCH" "$ADDRESS" "$CONFIG_FILE" \
        >> "$WORKING_FILE"

      OK=$((OK + 1))
      echo "  OK -> $ENDPOINT | address=$ADDRESS | match=$MATCH"
    else
      REASON="$(head -n 1 "$TMP_CONFIG" | tr '\t' ' ' | cut -c1-180)"
      rm -f "$TMP_CONFIG"

      printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$SERVER_ID" "$COUNTRY_CODE" "$SERVER_NAME" "$WG_IP" "$WG_PORT" "$REASON" \
        >> "$FAIL_FILE"

      FAIL=$((FAIL + 1))
      echo "  FAIL: $REASON"
    fi
  else
    rm -f "$TMP_CONFIG"

    printf "%s\t%s\t%s\t%s\t%s\tcurl_failed\n" \
      "$SERVER_ID" "$COUNTRY_CODE" "$SERVER_NAME" "$WG_IP" "$WG_PORT" \
      >> "$FAIL_FILE"

    FAIL=$((FAIL + 1))
    echo "  FAIL: curl_failed"
  fi

  echo
  sleep 1

done < "$CANDIDATES_FILE"

rm -f "$RUN_DIR"/tmp-*.conf 2>/dev/null || true

rm -f "$LATEST_DIR"
ln -s "$CONFIG_DIR" "$LATEST_DIR"

cp "$WORKING_FILE" "$BASE/cache/working-awg${AWG_PARAM}-latest.tsv"
cp "$FAIL_FILE" "$BASE/cache/fail-awg${AWG_PARAM}-latest.tsv"
cp "$CANDIDATES_FILE" "$BASE/cache/wg-candidates-latest.tsv"
chmod 600 "$BASE/cache/"*.tsv 2>/dev/null || true

# Successful new config batch => reset temporary quarantine for this AWG batch.
# If the download fails before this point, old latest/quarantine stay untouched.
QUARANTINE_LATEST="$BASE/cache/quarantine-awg${AWG_PARAM}-latest.tsv"
if [ -f "$QUARANTINE_LATEST" ]; then
  cp "$QUARANTINE_LATEST" "$RUN_DIR/quarantine-before-reset-awg${AWG_PARAM}.tsv" 2>/dev/null || true
  chmod 600 "$RUN_DIR/quarantine-before-reset-awg${AWG_PARAM}.tsv" 2>/dev/null || true
fi
{
  printf "endpoint\tfile\treason\tadded_at\n"
} > "$QUARANTINE_LATEST"
chmod 600 "$QUARANTINE_LATEST"

{
  echo "HideMyName AWG download summary"
  echo "timestamp=$TS"
  echo "awg=$AWG_PARAM"
  echo "request_iface=$ACTIVE"
  echo "total_candidates=$TOTAL"
  echo "ok=$OK"
  echo "fail=$FAIL"
  echo "config_dir=$CONFIG_DIR"
  echo "working_file=$WORKING_FILE"
  echo "fail_file=$FAIL_FILE"
} > "$SUMMARY_FILE"

chmod 600 "$SUMMARY_FILE"

echo
echo "4/4 Готово."
echo
echo "Всего WG-кандидатов:"
echo "  $TOTAL"
echo "Конфигов скачано:"
echo "  $OK"
echo "Ошибок:"
echo "  $FAIL"
echo
echo "Конфиги:"
echo "  $CONFIG_DIR"
echo
echo "Latest symlink:"
echo "  $LATEST_DIR"
echo
echo "Таблица рабочих:"
echo "  $WORKING_FILE"
echo
echo "Копия latest:"
echo "  $BASE/cache/working-awg${AWG_PARAM}-latest.tsv"
echo
echo "Список скачанных:"
echo

awk -F '\t' 'NR==1 {next} {
  printf "%2d. id=%s | %s | %s | %s | endpoint=%s | %s\n", NR-1, $1, $2, $3, $4 ":" $5, $6, $9
}' "$WORKING_FILE"

echo
echo "OpenWRT network config не трогали."
