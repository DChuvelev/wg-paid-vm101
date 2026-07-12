#!/bin/ash

set -eu

SELECTED="${HMN_SELECTED_FILE:-/root/hmn/cache/selected-awg1-latest.tsv}"

if [ ! -f "$SELECTED" ]; then
  echo "ERROR: selected file not found:"
  echo "  $SELECTED"
  exit 1
fi

ACTIVE="$(cat /root/hmn/state/active-slot 2>/dev/null || true)"

case "$ACTIVE" in
  vpn1) STANDBY="vpn2" ;;
  vpn2) STANDBY="vpn1" ;;
  *)
    echo "ERROR: unknown active slot: $ACTIVE"
    exit 1
    ;;
esac

ACTIVE_ENDPOINT="$(uci -q get network.$ACTIVE.hmn_endpoint || true)"
STANDBY_ENDPOINT="$(uci -q get network.$STANDBY.hmn_endpoint || true)"

BEST_FILE="$(awk -F '\t' 'NR==2 {print $2}' "$SELECTED")"
BEST_ENDPOINT="$(awk -F '\t' 'NR==2 {print $3}' "$SELECTED")"
BEST_AVG="$(awk -F '\t' 'NR==2 {print $4}' "$SELECTED")"
BEST_CONFIG="$(awk -F '\t' 'NR==2 {print $5}' "$SELECTED")"

SECOND_FILE="$(awk -F '\t' 'NR==3 {print $2}' "$SELECTED")"
SECOND_ENDPOINT="$(awk -F '\t' 'NR==3 {print $3}' "$SELECTED")"
SECOND_AVG="$(awk -F '\t' 'NR==3 {print $4}' "$SELECTED")"
SECOND_CONFIG="$(awk -F '\t' 'NR==3 {print $5}' "$SELECTED")"

echo "Selected file:"
echo "  $SELECTED"
echo
echo "Runtime:"
echo "  active slot:      $ACTIVE"
echo "  active endpoint:  $ACTIVE_ENDPOINT"
echo "  standby slot:     $STANDBY"
echo "  standby endpoint: $STANDBY_ENDPOINT"
echo
echo "Selected candidates:"
echo "  best:   $BEST_ENDPOINT | $BEST_FILE | avg=$BEST_AVG"
echo "  second: $SECOND_ENDPOINT | $SECOND_FILE | avg=$SECOND_AVG"
echo
echo "Plan:"

if [ "$ACTIVE_ENDPOINT" = "$BEST_ENDPOINT" ]; then
  if [ "$STANDBY_ENDPOINT" = "$SECOND_ENDPOINT" ]; then
    echo "  Active slot already has best candidate."
    echo "  Standby slot already has second candidate."
    echo "  Action: do nothing."
  else
    echo "  Active slot already has best candidate."
    echo "  Standby slot should be loaded with second candidate:"
    echo "    load $SECOND_CONFIG into $STANDBY"
    echo "  Action: load standby only, then test."
  fi
elif [ "$ACTIVE_ENDPOINT" = "$SECOND_ENDPOINT" ]; then
  if [ "$STANDBY_ENDPOINT" = "$BEST_ENDPOINT" ]; then
    echo "  Active slot has second candidate."
    echo "  Standby slot already has best candidate."
    echo "  Action: do nothing automatically; optional manual promote after policy decision."
  else
    echo "  Active slot has second candidate."
    echo "  Standby slot should be loaded with best candidate:"
    echo "    load $BEST_CONFIG into $STANDBY"
    echo "  Action: load standby only, then test."
  fi
else
  echo "  Active endpoint is not in top two selected candidates."
  if [ "$STANDBY_ENDPOINT" = "$BEST_ENDPOINT" ]; then
    echo "  Standby slot already has best candidate."
    echo "  Action: do nothing automatically; optional manual promote after policy decision."
  elif [ "$STANDBY_ENDPOINT" = "$SECOND_ENDPOINT" ]; then
    echo "  Standby slot has second candidate, but best candidate is available."
    echo "  Action: load best candidate into standby, then test:"
    echo "    load $BEST_CONFIG into $STANDBY"
  else
    echo "  Standby slot should be loaded with best candidate:"
    echo "    load $BEST_CONFIG into $STANDBY"
    echo "  Action: load standby only, then test."
  fi
fi

echo
echo "No changes were made."
