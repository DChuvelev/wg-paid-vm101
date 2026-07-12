#!/bin/ash

set -u

echo "=== hmn-validate-current-pool: retest existing local pool safely ==="

BASE="/root/hmn"
CONFIG_DIR="${1:-$BASE/configs/awg1/latest}"
TESTER="$BASE/hmn-test-all-awg.sh"
CACHE="$BASE/cache"
REPORTS="$BASE/reports"
STATE="$BASE/state"
LOGDIR="$BASE/logs"

MIN_ALL_OK="${MIN_ALL_OK:-2}"
MIN_FOREIGN_OK="${MIN_FOREIGN_OK:-2}"
EXCLUDE_REGEX="${HMN_VALIDATE_EXCLUDE_REGEX:-RU-Russia|US-USA|HK-Hong-Kong|CL-Chile|JP-Japan|PS-UAE|KR-South-Korea|South-Korea}"

MAINT="/tmp/hmn-vpn-maintenance"
BAD="$STATE/bad-endpoints-$(date +%Y%m%d).txt"
QUAR="$CACHE/quarantine-awg1-latest.tsv"

TS="$(date +%Y%m%d-%H%M%S)"
RUNLOG="$LOGDIR/validate-current-pool-$TS.log"

mkdir -p "$CACHE" "$REPORTS" "$STATE" "$LOGDIR"
chmod 700 "$BASE" "$CACHE" "$REPORTS" "$STATE" "$LOGDIR" 2>/dev/null || true

echo
echo "config_dir=$CONFIG_DIR"
echo "min_all_ok=$MIN_ALL_OK"
echo "min_foreign_ok=$MIN_FOREIGN_OK"
echo "exclude_regex=$EXCLUDE_REGEX"
echo "log=$RUNLOG"

if [ ! -d "$CONFIG_DIR" ]; then
  echo "ERROR: config dir not found: $CONFIG_DIR"
  exit 1
fi

if [ ! -x "$TESTER" ]; then
  echo "ERROR: tester missing/not executable: $TESTER"
  exit 1
fi

sh -n "$TESTER" || {
  echo "ERROR: tester syntax bad"
  exit 1
}

CRON_WAS_RUNNING=0
if /etc/init.d/cron status 2>/dev/null | grep -q running; then
  CRON_WAS_RUNNING=1
fi

MAINT_WAS_PRESENT=0
if [ -e "$MAINT" ]; then
  MAINT_WAS_PRESENT=1
fi

cleanup() {
  ifdown vpn_test 2>/dev/null || true
  ip route del 9.9.9.9/32 dev vpn_test 2>/dev/null || true
  ip route del 1.1.1.1/32 dev vpn_test 2>/dev/null || true

  if [ "$MAINT_WAS_PRESENT" -eq 0 ]; then
    rm -f "$MAINT"
  fi

  rmdir /tmp/vpn-egress-hotplug-trigger.lock 2>/dev/null || true
  rmdir /tmp/vpn-egress-manager.lock 2>/dev/null || true

  if [ "$CRON_WAS_RUNNING" -eq 1 ]; then
    /etc/init.d/cron start >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT INT TERM

echo
echo "=== freeze automation during validation ==="
/etc/init.d/cron stop >/dev/null 2>&1 || true
touch "$MAINT"
rm -f /tmp/vpn-egress-skip-active /tmp/vpn-egress-skip-primary /tmp/vpn-egress-force-wan /root/vpn-egress-force-wan
rmdir /tmp/vpn-egress-hotplug-trigger.lock 2>/dev/null || true
rmdir /tmp/vpn-egress-manager.lock 2>/dev/null || true

echo
echo "=== pre-state ==="
ACTIVE="$(cat "$STATE/active-slot" 2>/dev/null || true)"
echo "active=$ACTIVE"
ip route show table 200
ip route get 9.9.9.9 from 10.200.0.2 2>&1 || true

echo
echo "=== run strict tester on current local pool ==="
RCFILE="/tmp/hmn-validate-current-pool.tester-rc.$$"
rm -f "$RCFILE"
(
  "$TESTER" "$CONFIG_DIR"
  echo "$?" > "$RCFILE"
) 2>&1 | tee "$RUNLOG"
TEST_RC="$(cat "$RCFILE" 2>/dev/null || echo 99)"
rm -f "$RCFILE"
echo "tester_rc=$TEST_RC"

if [ "$TEST_RC" != "0" ]; then
  echo "ERROR: tester failed; old strict tables left untouched"
  exit 1
fi

RESULTS="$(ls -t "$BASE"/test-runs/*/results.tsv 2>/dev/null | head -n 1 || true)"
if [ -z "$RESULTS" ] || [ ! -s "$RESULTS" ]; then
  echo "ERROR: no results.tsv found after tester; old strict tables left untouched"
  exit 1
fi

echo
echo "results=$RESULTS"

TMP_ALL_LINES="/tmp/hmn-validate-all-lines.$$"
TMP_FOREIGN_LINES="/tmp/hmn-validate-foreign-lines.$$"
OUT_ALL="$REPORTS/ok-awg1-strict-all-$TS.tsv"
OUT_FOREIGN="$REPORTS/ok-awg1-strict-foreign-$TS.tsv"

awk -F '\t' -v cfg="$CONFIG_DIR" '
NR > 1 &&
$1 == "OK" &&
$6 ~ /9\.9\.9\.9:0%/ &&
$6 ~ /1\.1\.1\.1:0%/ &&
$7 ~ /^[0-9.]+$/ {
  printf "%010.3f\t%s\t%s\t%s\t%s/%s\n", $7, $2, $3, $6, cfg, $2
}
' "$RESULTS" | sort -n > "$TMP_ALL_LINES"

awk -F '\t' -v ex="$EXCLUDE_REGEX" '$2 !~ ex { print }' "$TMP_ALL_LINES" > "$TMP_FOREIGN_LINES"

ALL_OK="$(wc -l < "$TMP_ALL_LINES" | tr -d ' ')"
FOREIGN_OK="$(wc -l < "$TMP_FOREIGN_LINES" | tr -d ' ')"

echo
echo "all_ok=$ALL_OK"
echo "foreign_ok=$FOREIGN_OK"

if [ "$ALL_OK" -lt "$MIN_ALL_OK" ] || [ "$FOREIGN_OK" -lt "$MIN_FOREIGN_OK" ]; then
  echo "ERROR: too few OK tunnels after retest; old strict tables left untouched"
  echo "min_all_ok=$MIN_ALL_OK actual=$ALL_OK"
  echo "min_foreign_ok=$MIN_FOREIGN_OK actual=$FOREIGN_OK"
  rm -f "$TMP_ALL_LINES" "$TMP_FOREIGN_LINES"
  exit 1
fi

write_ranked_table() {
  IN="$1"
  OUT="$2"

  printf "rank\tfile\tendpoint\tavg_ms\tping_loss\tconfig_path\n" > "$OUT"

  N=0
  TAB="$(printf '\t')"

  while IFS="$TAB" read -r AVG FILE EP LOSS CFG; do
    [ -n "$AVG" ] || continue
    N=$((N + 1))

    AVG_CLEAN="$(echo "$AVG" | sed 's/^0*//; s/^\./0./')"

    printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$N" "$FILE" "$EP" "$AVG_CLEAN" "$LOSS" "$CFG" >> "$OUT"
  done < "$IN"
}

write_ranked_table "$TMP_ALL_LINES" "$OUT_ALL"
write_ranked_table "$TMP_FOREIGN_LINES" "$OUT_FOREIGN"

rm -f "$TMP_ALL_LINES" "$TMP_FOREIGN_LINES"

chmod 600 "$OUT_ALL" "$OUT_FOREIGN"

echo
echo "=== publish strict tables atomically ==="
for F in \
  "$CACHE/ok-awg1-strict-all-latest.tsv" \
  "$CACHE/ok-awg1-strict-foreign-latest.tsv" \
  "$CACHE/ok-awg1-strict-latest.tsv"
do
  [ -e "$F" ] && cp -a "$F" "$F.before-validate-$TS" || true
done

cp "$OUT_ALL" "$CACHE/ok-awg1-strict-all-latest.tsv.new"
cp "$OUT_FOREIGN" "$CACHE/ok-awg1-strict-foreign-latest.tsv.new"
cp "$OUT_ALL" "$CACHE/ok-awg1-strict-latest.tsv.new"

mv "$CACHE/ok-awg1-strict-all-latest.tsv.new" "$CACHE/ok-awg1-strict-all-latest.tsv"
mv "$CACHE/ok-awg1-strict-foreign-latest.tsv.new" "$CACHE/ok-awg1-strict-foreign-latest.tsv"
mv "$CACHE/ok-awg1-strict-latest.tsv.new" "$CACHE/ok-awg1-strict-latest.tsv"

chmod 600 "$CACHE"/ok-awg1-strict*.tsv 2>/dev/null || true

echo
echo "=== reset runtime bad/quarantine for new validation generation ==="
[ -s "$BAD" ] && cp -a "$BAD" "$BAD.before-validate-$TS" || true
: > "$BAD"
chmod 600 "$BAD"

if [ -f "$QUAR" ]; then
  cp -a "$QUAR" "$QUAR.before-validate-$TS" 2>/dev/null || true
fi
printf "endpoint\tfile\treason\tadded_at\n" > "$QUAR"
chmod 600 "$QUAR"

echo
echo "=== selected consistency check, no selected changes here ==="
cat "$CACHE/selected-awg1-latest.tsv" 2>/dev/null || echo "no selected cache"

echo
for S in vpn1 vpn2; do
  EP="$(uci -q get network.$S.hmn_endpoint || true)"
  printf "%s endpoint %s: " "$S" "$EP"
  if [ -n "$EP" ] && awk -F '\t' -v ep="$EP" 'NR>1 && $3==ep {found=1} END{exit found?0:1}' "$CACHE/ok-awg1-strict-foreign-latest.tsv"; then
    echo "OK in current strict foreign table"
  else
    echo "WARN not in current strict foreign table"
  fi
done

echo
echo "=== restore active route ==="
ACTIVE="$(cat "$STATE/active-slot" 2>/dev/null || true)"
case "$ACTIVE" in
  vpn1|vpn2)
    ip route replace default dev "$ACTIVE" table 200 2>/dev/null || true
    /usr/bin/vpn-table200-local-routes.sh || true
    ip route flush cache
    ;;
esac

echo
echo "=== unfreeze and run manager once ==="
if [ "$MAINT_WAS_PRESENT" -eq 0 ]; then
  rm -f "$MAINT"
fi

/usr/bin/vpn-egress-manager.sh
echo "manager_rc=$?"

echo
echo "=== final state ==="
cat "$STATE/active-slot" 2>/dev/null || echo "no active-slot"
ip route show table 200
ip route get 9.9.9.9 from 10.200.0.2 2>&1 || true

echo
echo "--- strict all head ---"
head -n 12 "$CACHE/ok-awg1-strict-all-latest.tsv"

echo
echo "--- strict foreign head ---"
head -n 12 "$CACHE/ok-awg1-strict-foreign-latest.tsv"

echo
echo "--- bad file after reset ---"
[ -s "$BAD" ] && cat "$BAD" || echo "bad file empty"

echo
echo "=== done validate-current-pool ==="
