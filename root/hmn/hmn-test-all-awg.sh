#!/bin/ash

set -u

CONFIG_DIR="${1:-/root/hmn/configs/awg1/latest}"
PROBE_IP1="${PROBE_IP1:-9.9.9.9}"
PROBE_IP2="${PROBE_IP2:-1.1.1.1}"
PING_COUNT="${PING_COUNT:-5}"
WAIT_SECONDS="${WAIT_SECONDS:-8}"
LEAVE_UP="${LEAVE_UP:-0}"

BASE="/root/hmn"
LOADER="$BASE/hmn-load-vpn-test.sh"
AWGSHOW="/usr/bin/amneziawg"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$BASE/test-runs/$RUN_ID"
RESULTS="$RUN_DIR/results.tsv"

mkdir -p "$RUN_DIR"

cleanup_route_one() {
  DEV="$1"
  IP="$2"
  ip route del "$IP/32" dev "$DEV" 2>/dev/null || true
}

cleanup_routes() {
  DEV="$1"
  cleanup_route_one "$DEV" "$PROBE_IP1"
  cleanup_route_one "$DEV" "$PROBE_IP2"
}

get_conf_endpoint() {
  awk -F'= *' '/^Endpoint[[:space:]]*=/{print $2; exit}' "$1"
}

find_up_iface_by_endpoint() {
  WANT_EP="$1"

  for IFX in vpn1 vpn2 vpn_test; do
    if "$AWGSHOW" show "$IFX" >/tmp/hmn-up-show-$$ 2>/dev/null; then
      UP_EP="$(awk '/endpoint:/{print $2; exit}' /tmp/hmn-up-show-$$)"
      if [ -n "$UP_EP" ] && [ "$UP_EP" = "$WANT_EP" ]; then
        rm -f /tmp/hmn-up-show-$$
        echo "$IFX"
        return 0
      fi
    fi
  done

  rm -f /tmp/hmn-up-show-$$
  return 1
}

probe_ip_strict() {
  DEV="$1"
  IP="$2"
  ONE_LOG="$3"
  META="$4"

  : > "$ONE_LOG"

  {
    echo "=== probe $IP dev $DEV ==="
    ip route replace "$IP/32" dev "$DEV" 2>&1
    ip route get "$IP" 2>&1
    ping -4 -c "$PING_COUNT" -W 2 -I "$DEV" "$IP" 2>&1
  } >> "$ONE_LOG" || true

  cleanup_route_one "$DEV" "$IP"

  LOSS="$(sed -n 's/.* \([0-9][0-9]*%\) packet loss.*/\1/p' "$ONE_LOG" | tail -n1)"
  AVG="$(sed -n 's/^round-trip min\/avg\/max = [^\/]*\/\([^\/]*\)\/.*/\1/p' "$ONE_LOG" | tail -n1)"

  [ -n "$LOSS" ] || LOSS="100%"
  [ -n "$AVG" ] || AVG="-"

  echo "$LOSS|$AVG" > "$META"

  [ "$LOSS" = "0%" ]
}

test_dev_strict() {
  DEV="$1"
  SHOW2="$2"
  PING_LOG="$3"

  : > "$PING_LOG"

  LOG1="/tmp/hmn-probe-${PROBE_IP1}-$$.txt"
  LOG2="/tmp/hmn-probe-${PROBE_IP2}-$$.txt"
  META1="/tmp/hmn-probe-${PROBE_IP1}-$$.meta"
  META2="/tmp/hmn-probe-${PROBE_IP2}-$$.meta"

  probe_ip_strict "$DEV" "$PROBE_IP1" "$LOG1" "$META1"
  RC1="$?"

  probe_ip_strict "$DEV" "$PROBE_IP2" "$LOG2" "$META2"
  RC2="$?"

  cat "$LOG1" >> "$PING_LOG"
  echo >> "$PING_LOG"
  cat "$LOG2" >> "$PING_LOG"

  LOSS1="$(cut -d'|' -f1 "$META1" 2>/dev/null || echo 100%)"
  AVG1="$(cut -d'|' -f2 "$META1" 2>/dev/null || echo -)"
  LOSS2="$(cut -d'|' -f1 "$META2" 2>/dev/null || echo 100%)"
  AVG2="$(cut -d'|' -f2 "$META2" 2>/dev/null || echo -)"

  rm -f "$LOG1" "$LOG2" "$META1" "$META2"

  "$AWGSHOW" show "$DEV" > "$SHOW2" 2>&1 || true

  LATEST="$(grep 'latest handshake:' "$SHOW2" | sed 's/^[[:space:]]*//' | head -n1 || true)"
  TRANSFER="$(grep 'transfer:' "$SHOW2" | sed 's/^[[:space:]]*//' | head -n1 || true)"

  if [ -z "$LATEST" ]; then
    STATUS="FAIL_NO_HANDSHAKE"
  elif [ "$RC1" = "0" ] && [ "$RC2" = "0" ]; then
    STATUS="OK"
  else
    STATUS="FAIL_PING_LOSS"
  fi

  AVG="$AVG1"
  [ "$AVG" != "-" ] || AVG="$AVG2"

  LOSS_SUMMARY="$PROBE_IP1:$LOSS1,$PROBE_IP2:$LOSS2"

  echo "$STATUS|$LATEST|$TRANSFER|$LOSS_SUMMARY|$AVG"
}

echo "HideMyName AWG strict zero-loss tunnel tester"
echo
echo "Config dir:    $CONFIG_DIR"
echo "Probe IPs:     $PROBE_IP1 $PROBE_IP2"
echo "Ping count:    $PING_COUNT per IP"
echo "Wait seconds:  $WAIT_SECONDS"
echo "Run dir:       $RUN_DIR"
echo

printf "status\tfile\tendpoint\tlatest_handshake\ttransfer\tping_loss\tping_rtt_avg\tshow_file\tping_file\n" > "$RESULTS"

if [ ! -d "$CONFIG_DIR" ]; then
  echo "ERROR: config dir not found: $CONFIG_DIR"
  exit 1
fi

FILES="$(find -L "$CONFIG_DIR" -type f -name '*.conf' | sort)"
TOTAL="$(echo "$FILES" | sed '/^$/d' | wc -l)"
N=0
OK=0
FAIL=0

for CONF in $FILES; do
  N=$((N + 1))
  FILE="$(basename "$CONF")"
  ENDPOINT="$(get_conf_endpoint "$CONF")"

  SHOW2="$RUN_DIR/${FILE}.show-after-ping.txt"
  PING_LOG="$RUN_DIR/${FILE}.ping.txt"
  LOAD_LOG="$RUN_DIR/${FILE}.load.txt"

  echo "[$N/$TOTAL] $FILE"
  echo "  endpoint: $ENDPOINT"

  DUP_IF="$(find_up_iface_by_endpoint "$ENDPOINT" || true)"

  if [ -n "$DUP_IF" ]; then
    echo "  endpoint already UP on $DUP_IF; testing existing interface, not starting duplicate"
    DEV="$DUP_IF"
  else
    DEV="vpn_test"

    ifdown vpn_test 2>/dev/null || true
    cleanup_routes vpn_test

    if ! "$LOADER" "$CONF" > "$LOAD_LOG" 2>&1; then
      echo "  FAIL: load_error"
      printf "FAIL_LOAD\t%s\t%s\t-\t-\t-\t-\t%s\t%s\n" "$FILE" "$ENDPOINT" "$LOAD_LOG" "$PING_LOG" >> "$RESULTS"
      FAIL=$((FAIL + 1))
      echo
      continue
    fi

    ifup vpn_test > "$RUN_DIR/${FILE}.ifup.log" 2>&1 || true
    sleep "$WAIT_SECONDS"
  fi

  RES="$(test_dev_strict "$DEV" "$SHOW2" "$PING_LOG")"

  STATUS="$(echo "$RES" | cut -d'|' -f1)"
  LATEST="$(echo "$RES" | cut -d'|' -f2)"
  TRANSFER="$(echo "$RES" | cut -d'|' -f3)"
  LOSS_SUMMARY="$(echo "$RES" | cut -d'|' -f4)"
  AVG="$(echo "$RES" | cut -d'|' -f5)"

  echo "  status=$STATUS loss=$LOSS_SUMMARY avg=$AVG"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$STATUS" "$FILE" "$ENDPOINT" "$LATEST" "$TRANSFER" "$LOSS_SUMMARY" "$AVG" "$SHOW2" "$PING_LOG" \
    >> "$RESULTS"

  if [ "$STATUS" = "OK" ]; then
    OK=$((OK + 1))
  else
    FAIL=$((FAIL + 1))
  fi

  if [ "$DEV" = "vpn_test" ] && [ "$LEAVE_UP" != "1" ]; then
    ifdown vpn_test 2>/dev/null || true
  fi

  cleanup_routes "$DEV"
  sleep 2
  echo
done

if [ "$LEAVE_UP" != "1" ]; then
  ifdown vpn_test 2>/dev/null || true
fi

echo "Готово."
echo
echo "Results:"
echo "  $RESULTS"
echo
echo "Summary:"
echo "  total=$TOTAL OK=$OK FAIL=$FAIL"
echo
echo "OK candidates:"
awk -F '\t' '$1=="OK"{print $2 " | " $3 " | loss=" $6 " | avg=" $7}' "$RESULTS"
echo
echo "Strict rejects with ping loss:"
awk -F '\t' '$1=="FAIL_PING_LOSS"{print $2 " | " $3 " | loss=" $6 " | avg=" $7}' "$RESULTS"
echo
echo
echo "main routes touching vpn_test:"
ip route show | grep vpn_test || true
