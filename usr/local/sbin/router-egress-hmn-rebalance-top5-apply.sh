#!/bin/sh
set -u

SLOTS_CONF="${SLOTS_CONF:-/etc/router-egress-slots.d/slots.conf}"
CACHE_DIR="${CACHE_DIR:-/root/hmn/cache}"
STATE_DIR="${STATE_DIR:-/var/lib/router-egress-recovery}"
LOG="${LOG:-/var/log/router-egress-rebalance-top5.log}"
MAX_POOL_AGE_SEC="${MAX_POOL_AGE_SEC:-129600}"
PREFERRED_POOL_FILES="${PREFERRED_POOL_FILES:-ok-awg1-strict-foreign-latest.tsv ok-awg1-strict-all-latest.tsv}"
POST_APPLY_SLEEP_SEC="${POST_APPLY_SLEEP_SEC:-12}"
MODE="--dry-run"
CONFIRM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE="--dry-run"; shift ;;
    --commit) MODE="--commit"; shift ;;
    --confirm) CONFIRM="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

strict_ping() {
  iface="$1"
  ok=true
  for target in 1.1.1.1 8.8.8.8; do
    ping -I "$iface" -c 3 -W 2 "$target" >/tmp/rebalance-ping.out 2>/tmp/rebalance-ping.err
    rc=$?
    recv="$(grep -Eo '[0-9]+ packets received' /tmp/rebalance-ping.out 2>/dev/null | awk '{print $1}' | tail -1)"
    [ -n "$recv" ] || recv=0
    [ "$rc" = "0" ] && [ "$recv" = "3" ] || ok=false
  done
  rm -f /tmp/rebalance-ping.out /tmp/rebalance-ping.err
  [ "$ok" = "true" ]
}

now="$(date +%s)"
pool=""
pool_age=999999999
pool_endpoints=0

for name in $PREFERRED_POOL_FILES; do
  f="${CACHE_DIR}/${name}"
  [ -s "$f" ] || continue
  epc="$(awk -F '\t' 'NR>1 && $3 ~ /:[0-9][0-9]*$/ {n++} END{print n+0}' "$f" 2>/dev/null)"
  [ "$epc" -ge 5 ] || continue
  mt="$(date -r "$f" +%s 2>/dev/null || echo 0)"
  age=$((now - mt))
  [ "$age" -le "$MAX_POOL_AGE_SEC" ] || continue
  pool="$f"
  pool_age="$age"
  pool_endpoints="$epc"
  break
done

tmp_top="/tmp/rebalance-top.$$"
tmp_current="/tmp/rebalance-current.$$"
tmp_missing="/tmp/rebalance-missing.$$"
tmp_plan="/tmp/rebalance-plan.$$"
trap 'rm -f "$tmp_top" "$tmp_current" "$tmp_missing" "$tmp_plan"' EXIT

: > "$tmp_top"
: > "$tmp_current"
: > "$tmp_missing"
: > "$tmp_plan"

if [ -n "$pool" ]; then
  awk -F '\t' '
    NR==1 {next}
    $3 ~ /:[0-9][0-9]*$/ {
      rank=$1; file=$2; ep=$3; avg=$4; loss=$5; cfg=$6
      if (!(ep in seen)) {
        seen[ep]=1
        print rank "\t" avg "\t" ep "\t" file "\t" loss "\t" cfg
      }
    }
  ' "$pool" | sort -n -k1,1 | head -5 > "$tmp_top"
fi

grep -Ev '^[[:space:]]*(#|$)' "$SLOTS_CONF" 2>/dev/null | awk '{print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7}' | while IFS="$(printf '\t')" read -r slot iface table mark dscp provider adapter; do
  cur="$(uci -q get network.${iface}.hmn_endpoint 2>/dev/null || true)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$slot" "$iface" "$table" "$mark" "$dscp" "$provider" "$adapter" "$cur"
done > "$tmp_current"

awk -F '\t' '
  NR==FNR {cur[$8]=1; next}
  !($3 in cur) {print}
' "$tmp_current" "$tmp_top" > "$tmp_missing"

awk -F '\t' '
  NR==FNR {
    top_ep[$3]=1
    top_rank[$3]=$1
    top_avg[$3]=$2
    top_file[$3]=$4
    next
  }
  FILENAME==ARGV[2] {
    missing[++m]=$3
    missing_rank[m]=$1
    missing_avg[m]=$2
    missing_file[m]=$4
    next
  }
  FILENAME==ARGV[3] {
    slot=$1; iface=$2; table=$3; mark=$4; dscp=$5; provider=$6; adapter=$7; cur=$8
    if (cur in top_ep) {
      target=cur; change="false"; rank=top_rank[cur]; avg=top_avg[cur]; file=top_file[cur]
    } else {
      mi++
      target=missing[mi]; change="true"; rank=missing_rank[mi]; avg=missing_avg[mi]; file=missing_file[mi]
    }
    if (target == "") { target=cur; change="false"; rank=""; avg=""; file="" }
    print slot "\t" iface "\t" table "\t" mark "\t" dscp "\t" provider "\t" adapter "\t" cur "\t" target "\t" change "\t" rank "\t" avg "\t" file
  }
' "$tmp_top" "$tmp_missing" "$tmp_current" > "$tmp_plan"

changes_count="$(awk -F '\t' '$10=="true"{n++} END{print n+0}' "$tmp_plan")"
top_count="$(wc -l < "$tmp_top" 2>/dev/null || echo 0)"
decision="plan_ok"
reason="top5_pool_ready"
apply_performed=false
apply_ok=true

[ -n "$pool" ] || { decision="refuse"; reason="no_fresh_pool_with_5_endpoints"; }
[ "$top_count" = "5" ] || { decision="refuse"; reason="top_count_not_5"; }

if [ "$MODE" = "--commit" ]; then
  if [ "$CONFIRM" != "REBALANCE_TOP5_DAILY" ]; then
    decision="refuse"
    reason="missing_or_wrong_confirm"
  elif [ "$decision" = "plan_ok" ]; then
    if [ "$changes_count" = "0" ]; then
      decision="noop"
      reason="already_top5"
      apply_performed=false
    else
      decision="commit_ok"
      reason="changes_applied"
      while IFS="$(printf '\t')" read -r slot iface table mark dscp provider adapter cur target change rank avg file; do
        [ "$change" = "true" ] || continue
        apply_performed=true
        backup_dir="${STATE_DIR}/rebalance-${slot}-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$backup_dir"
        uci show network > "$backup_dir/network.uci.before" 2>/dev/null || true
        ip route show table "$table" > "$backup_dir/table.before" 2>/dev/null || true
        cat > "$backup_dir/rollback-${slot}.sh" <<EOF
#!/bin/sh
uci set network.${iface}.hmn_endpoint='${cur}'
uci commit network
ifdown ${iface} >/dev/null 2>&1 || true
ifup ${iface} >/dev/null 2>&1 || true
sleep ${POST_APPLY_SLEEP_SEC}
[ -x /usr/local/sbin/router-egress-slots-apply.sh ] && /usr/local/sbin/router-egress-slots-apply.sh >/dev/null 2>&1 || true
echo rollback_done=true
EOF
        chmod 700 "$backup_dir/rollback-${slot}.sh"

        uci set network.${iface}.hmn_endpoint="$target"
        uci commit network
        ifdown "$iface" >/dev/null 2>&1 || true
        ifup "$iface" >/dev/null 2>&1
        rc=$?
        sleep "$POST_APPLY_SLEEP_SEC"
        [ -x /usr/local/sbin/router-egress-slots-apply.sh ] && /usr/local/sbin/router-egress-slots-apply.sh >/dev/null 2>&1 || true

        if [ "$rc" != "0" ] || ! ip route show table "$table" 2>/dev/null | grep -q . || ! strict_ping "$iface"; then
          apply_ok=false
          decision="commit_failed"
          reason="slot_apply_failed_${slot}"
          "$backup_dir/rollback-${slot}.sh" >/dev/null 2>&1 || true
          break
        fi
      done < "$tmp_plan"
    fi
  fi
elif [ "$MODE" = "--dry-run" ]; then
  :
else
  decision="refuse"
  reason="unsupported_mode"
fi

echo "{"
echo '  "schema": "router-egress-hmn-rebalance-top5-v1",'
echo "  \"mode\": \"$(json_escape "$MODE")\","
echo "  \"decision\": \"$(json_escape "$decision")\","
echo "  \"reason\": \"$(json_escape "$reason")\","
echo "  \"pool\": \"$(json_escape "$pool")\","
echo "  \"pool_age_sec\": $pool_age,"
echo "  \"pool_endpoint_count\": $pool_endpoints,"
echo "  \"top_count\": $top_count,"
echo "  \"changes_count\": $changes_count,"
echo "  \"apply_performed\": $apply_performed,"
echo "  \"apply_ok\": $apply_ok,"
echo '  "plan": ['
first=1
while IFS="$(printf '\t')" read -r slot iface table mark dscp provider adapter cur target change rank avg file; do
  [ "$first" = "1" ] || echo ","
  first=0
  printf '    {"slot":"%s","iface":"%s","table":"%s","mark":"%s","dscp":"%s","provider":"%s","adapter":"%s","current":"%s","target":"%s","change":%s,"target_rank":"%s","target_avg_ms":"%s","target_file":"%s"}' \
    "$(json_escape "$slot")" "$(json_escape "$iface")" "$(json_escape "$table")" "$(json_escape "$mark")" "$(json_escape "$dscp")" \
    "$(json_escape "$provider")" "$(json_escape "$adapter")" "$(json_escape "$cur")" "$(json_escape "$target")" "$change" "$(json_escape "$rank")" "$(json_escape "$avg")" "$(json_escape "$file")"
done < "$tmp_plan"
echo
echo '  ],'
echo '  "safety": {"commit_requires_confirm": true, "per_slot_strict_check": true, "per_slot_rollback": true}'
echo "}"
echo "rebalance_top5 ts=$(date -Is) mode=$MODE decision=$decision reason=$reason changes=$changes_count apply=$apply_performed" >> "$LOG"
