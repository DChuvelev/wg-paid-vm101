#!/bin/ash

set -u

MODE="${1:-dry-run}"
BASE="/root/hmn"
LOGDIR="$BASE/logs"
PING_IP="${HMN_REFRESH_PING_IP:-9.9.9.9}"

DOWNLOAD="$BASE/hmn-download-all-awg.sh"
TESTER="$BASE/hmn-test-all-awg.sh"
RANKER="$BASE/hmn-rank-awg.sh"
PLANNER="$BASE/hmn-plan-selected.sh"
APPLY="$BASE/hmn-apply-selected.sh"

case "$MODE" in
  dry-run|run)
    ;;
  *)
    echo "ERROR: mode must be dry-run or run"
    echo "Usage:"
    echo "  /root/hmn/hmn-refresh-awg.sh dry-run"
    echo "  /root/hmn/hmn-refresh-awg.sh run"
    exit 1
    ;;
esac

mkdir -p "$LOGDIR"
chmod 700 "$LOGDIR"

LOCKDIR="/tmp/hmn-refresh-awg.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  echo "ERROR: another hmn-refresh-awg run is already active: $LOCKDIR"
  exit 1
fi

cleanup_lock() {
  rmdir "$LOCKDIR" 2>/dev/null || true
}

trap cleanup_lock EXIT INT TERM

say() {
  echo
  echo "=== $* ==="
}

fail() {
  echo
  echo "ERROR: $*"
  exit 1
}

run_cmd() {
  echo
  echo "+ $*"
  if [ "$MODE" = "run" ]; then
    "$@"
  else
    echo "[dry-run] not executed"
  fi
}

get_table_default_dev() {
  ip route show table 200 | awk '
    /^default / {
      for (i = 1; i <= NF; i++) {
        if ($i == "dev") {
          print $(i+1)
          exit
        }
      }
    }
  '
}

say "HideMyName AWG refresh wrapper"
echo "mode: $MODE"
echo "date: $(date -Iseconds 2>/dev/null || date)"

say "preflight: scripts"
for S in "$DOWNLOAD" "$TESTER" "$RANKER" "$PLANNER" "$APPLY"; do
  [ -x "$S" ] || fail "missing or not executable: $S"
  ls -lh "$S"
done

say "preflight: runtime state"
CRON_STATUS="$(/etc/init.d/cron status 2>/dev/null || true)"
echo "cron: $CRON_STATUS"

if [ -e /tmp/hmn-vpn-maintenance ]; then
  fail "maintenance flag exists: /tmp/hmn-vpn-maintenance"
fi

for F in /tmp/vpn-egress-skip-active /tmp/vpn-egress-skip-primary /tmp/vpn-egress-force-wan /root/vpn-egress-force-wan; do
  if [ -e "$F" ]; then
    fail "temporary control flag exists: $F"
  fi
done

ACTIVE="$(cat "$BASE/state/active-slot" 2>/dev/null || true)"
case "$ACTIVE" in
  vpn1|vpn2) ;;
  *) fail "bad active slot: $ACTIVE" ;;
esac

TABLE_DEV="$(get_table_default_dev)"
echo "active slot: $ACTIVE"
echo "table 200 default dev: $TABLE_DEV"
ip route show table 200

if [ "$TABLE_DEV" != "$ACTIVE" ]; then
  fail "table 200 default dev does not match active slot"
fi

echo
echo "active tunnel:"
/usr/bin/amneziawg show "$ACTIVE" 2>/dev/null || fail "cannot show active tunnel $ACTIVE"

echo
echo "active traffic check:"
ping -4 -c 3 -W 2 -I 10.200.0.2 "$PING_IP" || fail "active traffic check failed"

say "current selected plan before refresh"
"$PLANNER" || fail "planner failed before refresh"

say "planned pipeline"
echo "1. download fresh AWG configs through active VPN interface"
echo "2. test all latest configs through vpn_test"
echo "3. rank tested configs and write selected"
echo "4. show selected plan"
echo "5. apply selected in standby-only mode"
echo "6. final report"

if [ "$MODE" = "dry-run" ]; then
  say "dry-run command list"
  run_cmd "$DOWNLOAD"
  run_cmd "$TESTER"
  run_cmd "$RANKER"
  run_cmd "$PLANNER"
  run_cmd "$APPLY" standby-only

  say "dry-run final state, no changes expected"
  /etc/init.d/cron status || true
  ls -l /tmp/hmn-vpn-maintenance 2>/dev/null || echo "no maintenance flag"
  cat "$BASE/state/active-slot"
  ip route show table 200
  ip route show | grep -E 'vpn1|vpn2|vpn_test' || true
  exit 0
fi

TS="$(date +%Y%m%d-%H%M%S)"
REPORT="$LOGDIR/hmn-refresh-awg-$TS.report.txt"

say "run: download fresh AWG configs"
"$DOWNLOAD" || fail "download failed"

say "run: test latest AWG configs"
"$TESTER" || fail "tester failed"

say "run: rank and select"
"$RANKER" || fail "ranker failed"

say "run: selected plan after rank"
"$PLANNER" || fail "planner failed after rank"

say "run: apply selected standby-only"
"$APPLY" standby-only || fail "apply-selected standby-only failed"

say "final report"
{
  echo "timestamp=$TS"
  echo
  echo "cron:"
  /etc/init.d/cron status || true
  echo
  echo "maintenance:"
  ls -l /tmp/hmn-vpn-maintenance 2>/dev/null || echo "no maintenance flag"
  echo
  echo "active-slot:"
  cat "$BASE/state/active-slot"
  echo
  echo "table 200:"
  ip route show table 200
  echo
  echo "route get:"
  ip route get "$PING_IP" from 10.200.0.2
  echo
  echo "vpn1 endpoint/config:"
  uci -q get network.vpn1.hmn_endpoint || true
  uci -q get network.vpn1.hmn_source_config || true
  echo
  echo "vpn2 endpoint/config:"
  uci -q get network.vpn2.hmn_endpoint || true
  uci -q get network.vpn2.hmn_source_config || true
  echo
  echo "selected:"
  cat "$BASE/cache/selected-awg1-latest.tsv" 2>/dev/null || true
  echo
  echo "planner:"
  "$PLANNER" || true
  echo
  echo "quarantine:"
  cat "$BASE/cache/quarantine-awg1-latest.tsv" 2>/dev/null || echo "no quarantine file"
  echo
  echo "main routes containing vpn1/vpn2/vpn_test:"
  ip route show | grep -E 'vpn1|vpn2|vpn_test' || true
} | tee "$REPORT"

chmod 600 "$REPORT"

say "refresh completed"
echo "report: $REPORT"
