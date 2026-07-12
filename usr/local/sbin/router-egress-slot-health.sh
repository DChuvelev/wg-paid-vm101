#!/bin/sh
set -u

MODE="${1:---dry-run}"
MON_CONF="${ROUTER_EGRESS_SLOT_HEALTH_CONF:-/etc/router-egress-slot-health.conf}"
[ -f "$MON_CONF" ] && . "$MON_CONF"

SLOTS_CONF="${SLOTS_CONF:-/etc/router-egress-slots.d/slots.conf}"
STATE_DIR="${STATE_DIR:-/var/lib/router-egress-slot-health}"
STATE_JSONL="${STATE_JSONL:-${STATE_DIR}/status.jsonl}"
STATUS_KV="${STATUS_KV:-${STATE_DIR}/status.kv}"
LAST_JSON="${LAST_JSON:-${STATE_DIR}/last.json}"
LOG="${LOG:-/var/log/router-egress-slot-health.log}"

mkdir -p "$STATE_DIR" "$(dirname "$LOG")" 2>/dev/null || true

now="$(date +%s)"
iso="$(date -Is 2>/dev/null || date)"

tmp="/tmp/router-egress-slot-health.$$"
tmpjson="/tmp/router-egress-slot-health.$$.json"
trap 'rm -f "$tmp" "$tmpjson"' EXIT
: > "$tmp"

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

if [ ! -f "$SLOTS_CONF" ]; then
  echo "slots_conf_missing=$SLOTS_CONF" >&2
  exit 66
fi

enabled_count=0
good_count=0
bad_count=0
degraded_count=0
missing_count=0
overall_ok=true

grep -Ev '^[[:space:]]*(#|$)' "$SLOTS_CONF" | while read -r slot_id iface table mark dscp provider repair_adapter health_targets strict_count strict_timeout enabled rest; do
  [ -n "$slot_id" ] || continue
  [ "${enabled:-0}" = "1" ] || continue

  enabled_count=$((enabled_count + 1))
  iface_exists=false
  operstate="missing"
  route_ok=false
  endpoint=""
  addr=""
  status="good"
  fail_reasons=""
  target_results=""

  if ip link show "$iface" >/dev/null 2>&1; then
    iface_exists=true
    operstate="$(cat /sys/class/net/$iface/operstate 2>/dev/null || echo unknown)"
    addr="$(ip -br addr show dev "$iface" 2>/dev/null | sed -E 's#([A-Za-z0-9+/=]{20,})#KEYMASK#g' | tr -s ' ' ' ' | sed 's/[[:space:]]*$//')"
    endpoint="$(wg show "$iface" endpoints 2>/dev/null | sed -E 's#([A-Za-z0-9+/=]{20,})#KEYMASK#g' | tr '\n' ';' | sed 's/;$//')"
  else
    missing_count=$((missing_count + 1))
    status="bad"
    fail_reasons="${fail_reasons}missing_interface;"
  fi

  if ip route show table "$table" 2>/dev/null | grep -q "dev $iface"; then
    route_ok=true
  else
    status="bad"
    fail_reasons="${fail_reasons}route_table_${table}_missing_dev_${iface};"
  fi

  IFS_SAVE="$IFS"
  IFS=','
  for target in $health_targets; do
    IFS="$IFS_SAVE"
    target="$(echo "$target" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$target" ] || continue

    rc=99
    recv=0
    avg=""

    if [ "$iface_exists" = "true" ]; then
      out="/tmp/router-egress-slot-health-${slot_id}-${target//./_}.$$"
      err="/tmp/router-egress-slot-health-${slot_id}-${target//./_}.$$.err"
      ping -I "$iface" -c "$strict_count" -W "$strict_timeout" "$target" > "$out" 2> "$err"
      rc=$?
      recv="$(grep -Eo '[0-9]+ packets received' "$out" 2>/dev/null | awk '{print $1}' | tail -1)"
      [ -n "$recv" ] || recv=0
      avg="$(grep -Eo 'round-trip min/avg/max[^=]* = [^ ]+' "$out" 2>/dev/null | sed -E 's/.*= [0-9.]+\/([0-9.]+)\/.*/\1/' | tail -1)"
      [ -n "$avg" ] || avg=""
      rm -f "$out" "$err"
    fi

    if [ "$rc" != "0" ] || [ "$recv" != "$strict_count" ]; then
      status="bad"
      fail_reasons="${fail_reasons}${target}:rc=${rc}:recv=${recv}_expected_${strict_count};"
    fi

    target_results="${target_results}${target},rc=${rc},recv=${recv},avg=${avg}|"
  done
  IFS="$IFS_SAVE"

  if [ "$status" = "good" ]; then
    good_count=$((good_count + 1))
  else
    bad_count=$((bad_count + 1))
    overall_ok=false
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$slot_id" "$iface" "$table" "$mark" "$dscp" "$provider" "$repair_adapter" "$health_targets" \
    "$strict_count" "$strict_timeout" "$iface_exists" "$operstate" "$route_ok" "$status" "$target_results" "$fail_reasons" >> "$tmp"
done

# Recompute because the while loop above may run in a subshell on ash.
enabled_count="$(wc -l < "$tmp" | tr -d ' ')"
good_count="$(awk -F '\t' '$14=="good"{c++} END{print c+0}' "$tmp")"
bad_count="$(awk -F '\t' '$14!="good"{c++} END{print c+0}' "$tmp")"
missing_count="$(awk -F '\t' '$11!="true"{c++} END{print c+0}' "$tmp")"
[ "$bad_count" = "0" ] && overall_ok=true || overall_ok=false

{
  echo "{"
  echo '  "schema": "router-egress-slot-health-v1",'
  echo "  \"mode\": \"$(json_escape "$MODE")\","
  echo "  \"epoch\": $now,"
  echo "  \"iso\": \"$(json_escape "$iso")\","
  echo "  \"slots_conf\": \"$(json_escape "$SLOTS_CONF")\","
  echo "  \"overall_ok\": $overall_ok,"
  echo "  \"enabled_count\": $enabled_count,"
  echo "  \"good_count\": $good_count,"
  echo "  \"bad_count\": $bad_count,"
  echo "  \"missing_count\": $missing_count,"
  echo '  "slots": ['

  first=1
  while IFS="$(printf '\t')" read -r slot_id iface table mark dscp provider repair_adapter health_targets strict_count strict_timeout iface_exists operstate route_ok status target_results fail_reasons; do
    [ "$first" = "0" ] && echo ","
    first=0
    printf '    {"slot_id":"%s","interface":"%s","table":"%s","mark":"%s","dscp":"%s","provider":"%s","repair_adapter":"%s","health_targets":"%s","strict_count":%s,"strict_timeout":%s,"iface_exists":%s,"operstate":"%s","route_ok":%s,"status":"%s","target_results":"%s","fail_reasons":"%s"}' \
      "$(json_escape "$slot_id")" "$(json_escape "$iface")" "$(json_escape "$table")" "$(json_escape "$mark")" \
      "$(json_escape "$dscp")" "$(json_escape "$provider")" "$(json_escape "$repair_adapter")" "$(json_escape "$health_targets")" \
      "$strict_count" "$strict_timeout" "$iface_exists" "$(json_escape "$operstate")" "$route_ok" "$(json_escape "$status")" \
      "$(json_escape "$target_results")" "$(json_escape "$fail_reasons")"
  done < "$tmp"

  echo
  echo "  ],"
  echo '  "summary": {'
  echo '    "health_layer": "generic",'
  echo '    "repair_layer": "separate_provider_adapter",'
  echo '    "apply_performed": false,'
  echo '    "apply_reason": "dry_run_status_only"'
  echo "  }"
  echo "}"
} > "$tmpjson"

cat "$tmpjson"
cat "$tmpjson" >> "$STATE_JSONL"
cp "$tmpjson" "$LAST_JSON"

{
  echo "schema=router-egress-slot-health-v1"
  echo "epoch=$now"
  echo "iso=$iso"
  echo "mode=$MODE"
  echo "slots_conf=$SLOTS_CONF"
  echo "overall_ok=$overall_ok"
  echo "enabled_count=$enabled_count"
  echo "good_count=$good_count"
  echo "bad_count=$bad_count"
  echo "missing_count=$missing_count"
  while IFS="$(printf '\t')" read -r slot_id iface table mark dscp provider repair_adapter health_targets strict_count strict_timeout iface_exists operstate route_ok status target_results fail_reasons; do
    echo "slot.${slot_id}.interface=$iface"
    echo "slot.${slot_id}.table=$table"
    echo "slot.${slot_id}.mark=$mark"
    echo "slot.${slot_id}.dscp=$dscp"
    echo "slot.${slot_id}.provider=$provider"
    echo "slot.${slot_id}.repair_adapter=$repair_adapter"
    echo "slot.${slot_id}.iface_exists=$iface_exists"
    echo "slot.${slot_id}.route_ok=$route_ok"
    echo "slot.${slot_id}.status=$status"
    echo "slot.${slot_id}.target_results=$target_results"
    echo "slot.${slot_id}.fail_reasons=$fail_reasons"
  done < "$tmp"
} > "$STATUS_KV"

echo "router-egress-slot-health ts=$iso mode=$MODE overall_ok=$overall_ok good=$good_count bad=$bad_count enabled=$enabled_count apply_performed=false" >> "$LOG"

exit 0
