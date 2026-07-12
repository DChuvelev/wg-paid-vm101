#!/bin/ash

set -eu

MODE="${1:-dry-run}"
SELECTED="${HMN_SELECTED_FILE:-/root/hmn/cache/selected-awg1-latest.tsv}"
QUARANTINE="${HMN_QUARANTINE_FILE:-/root/hmn/cache/quarantine-awg1-latest.tsv}"
PING_IP="${HMN_STANDBY_PING_IP:-9.9.9.9}"
MAINTENANCE_FILE="/tmp/hmn-vpn-maintenance"

case "$MODE" in
  dry-run|standby-only)
    ;;
  *)
    echo "ERROR: mode must be dry-run or standby-only"
    echo "Usage:"
    echo "  /root/hmn/hmn-apply-selected.sh dry-run"
    echo "  /root/hmn/hmn-apply-selected.sh standby-only"
    exit 1
    ;;
esac

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
ACTIVE_CONFIG="$(uci -q get network.$ACTIVE.hmn_source_config || true)"

STANDBY_ENDPOINT="$(uci -q get network.$STANDBY.hmn_endpoint || true)"
STANDBY_CONFIG="$(uci -q get network.$STANDBY.hmn_source_config || true)"

BEST_FILE="$(awk -F '\t' 'NR==2 {print $2}' "$SELECTED")"
BEST_ENDPOINT="$(awk -F '\t' 'NR==2 {print $3}' "$SELECTED")"
BEST_AVG="$(awk -F '\t' 'NR==2 {print $4}' "$SELECTED")"
BEST_CONFIG="$(awk -F '\t' 'NR==2 {print $5}' "$SELECTED")"

SECOND_FILE="$(awk -F '\t' 'NR==3 {print $2}' "$SELECTED")"
SECOND_ENDPOINT="$(awk -F '\t' 'NR==3 {print $3}' "$SELECTED")"
SECOND_AVG="$(awk -F '\t' 'NR==3 {print $4}' "$SELECTED")"
SECOND_CONFIG="$(awk -F '\t' 'NR==3 {print $5}' "$SELECTED")"

if [ -z "$BEST_ENDPOINT" ] || [ -z "$BEST_CONFIG" ] || [ -z "$SECOND_ENDPOINT" ] || [ -z "$SECOND_CONFIG" ]; then
  echo "ERROR: selected file does not contain two candidates:"
  echo "  $SELECTED"
  cat "$SELECTED"
  exit 1
fi

if [ "$ACTIVE_ENDPOINT" = "$BEST_ENDPOINT" ]; then
  DESIRED_FILE="$SECOND_FILE"
  DESIRED_ENDPOINT="$SECOND_ENDPOINT"
  DESIRED_AVG="$SECOND_AVG"
  DESIRED_CONFIG="$SECOND_CONFIG"
  REASON="active_has_best_use_second_as_standby"
elif [ "$ACTIVE_ENDPOINT" = "$SECOND_ENDPOINT" ]; then
  DESIRED_FILE="$BEST_FILE"
  DESIRED_ENDPOINT="$BEST_ENDPOINT"
  DESIRED_AVG="$BEST_AVG"
  DESIRED_CONFIG="$BEST_CONFIG"
  REASON="active_has_second_use_best_as_standby"
else
  DESIRED_FILE="$BEST_FILE"
  DESIRED_ENDPOINT="$BEST_ENDPOINT"
  DESIRED_AVG="$BEST_AVG"
  DESIRED_CONFIG="$BEST_CONFIG"
  REASON="active_not_in_selected_use_best_as_standby"
fi

if [ ! -f "$DESIRED_CONFIG" ]; then
  echo "ERROR: desired standby config not found:"
  echo "  $DESIRED_CONFIG"
  exit 1
fi

NEED_LOAD=0
if [ "$STANDBY_ENDPOINT" != "$DESIRED_ENDPOINT" ]; then
  NEED_LOAD=1
fi

echo "Mode:"
echo "  $MODE"
echo

echo "Runtime:"
echo "  active slot:       $ACTIVE"
echo "  active endpoint:   $ACTIVE_ENDPOINT"
echo "  active config:     $ACTIVE_CONFIG"
echo "  standby slot:      $STANDBY"
echo "  standby endpoint:  $STANDBY_ENDPOINT"
echo "  standby config:    $STANDBY_CONFIG"
echo

echo "Selected:"
echo "  best:              $BEST_ENDPOINT | avg=$BEST_AVG | $BEST_FILE"
echo "  second:            $SECOND_ENDPOINT | avg=$SECOND_AVG | $SECOND_FILE"
echo

echo "Desired standby:"
echo "  slot:              $STANDBY"
echo "  endpoint:          $DESIRED_ENDPOINT"
echo "  avg:               $DESIRED_AVG"
echo "  file:              $DESIRED_FILE"
echo "  config:            $DESIRED_CONFIG"
echo "  reason:            $REASON"
echo

if [ "$NEED_LOAD" -eq 1 ]; then
  echo "Plan:"
  echo "  load desired config into inactive slot $STANDBY"
  echo "  bring $STANDBY up"
  echo "  test ping through $STANDBY"
  echo "  if OK: keep active untouched and shut standby back down"
  echo "  if FAIL: quarantine desired endpoint for current batch and rerank"
else
  echo "Plan:"
  echo "  standby already has desired endpoint"
  echo "  in standby-only mode: verify standby by bringing it up temporarily"
fi

echo

if [ "$MODE" = "dry-run" ]; then
  echo "Dry-run only. No changes were made."
  exit 0
fi

CRON_WAS_RUNNING=0
if /etc/init.d/cron status 2>/dev/null | grep -q running; then
  CRON_WAS_RUNNING=1
fi

MAINT_WAS_PRESENT=0
if [ -e "$MAINTENANCE_FILE" ]; then
  MAINT_WAS_PRESENT=1
fi

cleanup() {
  ip route del "$PING_IP/32" dev "$STANDBY" 2>/dev/null || true
  ifdown "$STANDBY" 2>/dev/null || true

  if [ "$MAINT_WAS_PRESENT" -eq 0 ]; then
    rm -f "$MAINTENANCE_FILE"
  fi

  rmdir /tmp/vpn-egress-hotplug-trigger.lock 2>/dev/null || true
  rmdir /tmp/vpn-egress-manager.lock 2>/dev/null || true

  if [ "$CRON_WAS_RUNNING" -eq 1 ]; then
    /etc/init.d/cron start >/dev/null 2>&1 || true
  fi
}

add_quarantine() {
  mkdir -p /root/hmn/cache
  chmod 700 /root/hmn/cache

  if [ ! -f "$QUARANTINE" ]; then
    printf 'endpoint\tfile\treason\tadded_at\n' > "$QUARANTINE"
  fi

  if awk -F '\t' -v ep="$DESIRED_ENDPOINT" -v f="$DESIRED_FILE" '
    NR > 1 && ($1 == ep || $2 == f) { found=1 }
    END { exit found ? 0 : 1 }
  ' "$QUARANTINE"; then
    echo "Quarantine already contains this endpoint/file."
  else
    ADDED_AT="$(date -Iseconds 2>/dev/null || date)"
    printf '%s\t%s\t%s\t%s\n' \
      "$DESIRED_ENDPOINT" \
      "$DESIRED_FILE" \
      "standby_apply_failed_current_batch" \
      "$ADDED_AT" >> "$QUARANTINE"
    chmod 600 "$QUARANTINE"
    echo "Added to quarantine:"
    echo "  $DESIRED_ENDPOINT | $DESIRED_FILE"
  fi
}

trap cleanup EXIT INT TERM

echo "Freezing automation while applying standby..."
/etc/init.d/cron stop >/dev/null 2>&1 || true
touch "$MAINTENANCE_FILE"
rm -f /tmp/vpn-egress-skip-active /tmp/vpn-egress-skip-primary /tmp/vpn-egress-force-wan /root/vpn-egress-force-wan
rmdir /tmp/vpn-egress-hotplug-trigger.lock 2>/dev/null || true
rmdir /tmp/vpn-egress-manager.lock 2>/dev/null || true

if [ "$NEED_LOAD" -eq 1 ]; then
  echo
  echo "Loading desired config into standby slot..."
  /root/hmn/hmn-load-vpn-slot.sh "$STANDBY" "$DESIRED_CONFIG"
else
  echo
  echo "No load needed; standby already points to desired endpoint."
fi

echo
echo "Bringing standby up for verification..."
ifup "$STANDBY"
sleep 12

echo
echo "Standby tunnel state:"
/usr/bin/amneziawg show "$STANDBY" 2>/dev/null || true

echo
echo "Temporary route for standby ping:"
ip route replace "$PING_IP/32" dev "$STANDBY"
ip route get "$PING_IP"

echo
echo "Ping through standby:"
if ping -4 -c 5 -W 2 -I "$STANDBY" "$PING_IP"; then
  echo
  echo "Standby verification OK."
else
  echo
  echo "ERROR: standby verification failed."
  add_quarantine
  echo
  echo "Reranking after quarantine..."
  /root/hmn/hmn-rank-awg.sh || true
  exit 2
fi

echo
echo "Active slot was not changed:"
cat /root/hmn/state/active-slot
ip route show table 200

echo
echo "Done. Cleanup will shut standby down and restore automation."
