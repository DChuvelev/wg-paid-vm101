#!/bin/ash

set -u

BASE="/root/hmn"
TABLE="${TABLE:-$BASE/cache/ok-awg1-strict-foreign-latest.tsv}"
SELECTED="${SELECTED:-$BASE/cache/selected-awg1-latest.tsv}"
LOADER="${LOADER:-$BASE/hmn-load-vpn-slot.sh}"
PING_COUNT="${PING_COUNT:-5}"
DRY_RUN="${DRY_RUN:-0}"

SLOT="${1:-}"
ACTIVE_SLOT="${2:-}"

if [ -z "$SLOT" ] || [ -z "$ACTIVE_SLOT" ]; then
  echo "Usage: $0 <slot-to-refill> <active-slot>" >&2
  echo "Example: DRY_RUN=1 $0 vpn1 vpn2" >&2
  exit 2
fi

[ "$SLOT" = "vpn1" ] || [ "$SLOT" = "vpn2" ] || {
  echo "ERROR: slot must be vpn1 or vpn2" >&2
  exit 2
}

[ "$ACTIVE_SLOT" = "vpn1" ] || [ "$ACTIVE_SLOT" = "vpn2" ] || {
  echo "ERROR: active slot must be vpn1 or vpn2" >&2
  exit 2
}

[ -s "$TABLE" ] || {
  echo "ERROR: OK table missing: $TABLE" >&2
  exit 1
}

[ -x "$LOADER" ] || {
  echo "ERROR: loader missing/not executable: $LOADER" >&2
  exit 1
}

today_bad_file() {
  date +"/root/hmn/state/bad-endpoints-%Y%m%d.txt"
}

get_slot_ep() {
  S="$1"
  H="$(uci -q get network.@amneziawg_${S}[0].endpoint_host || true)"
  P="$(uci -q get network.@amneziawg_${S}[0].endpoint_port || true)"
  [ -n "$H" ] && [ -n "$P" ] && echo "$H:$P"
}

mark_bad_ep() {
  EP="$1"
  REASON="${2:-failed}"
  [ -n "$EP" ] || return 0

  mkdir -p "$BASE/state"
  BAD="$(today_bad_file)"

  grep -q "^$EP" "$BAD" 2>/dev/null && return 0
  printf "%s\t%s\t%s\n" "$EP" "$(date -Iseconds)" "$REASON" >> "$BAD"
}

is_bad_ep() {
  EP="$1"
  BAD="$(today_bad_file)"
  grep -q "^$EP" "$BAD" 2>/dev/null
}

candidate_line() {
  ACTIVE_EP="$(get_slot_ep "$ACTIVE_SLOT" || true)"
  OLD_EP="$(get_slot_ep "$SLOT" || true)"

  awk -F '\t' -v active_ep="$ACTIVE_EP" -v old_ep="$OLD_EP" -v bad_file="$(today_bad_file)" '
    BEGIN {
      while ((getline line < bad_file) > 0) {
        split(line, a, "\t")
        bad[a[1]]=1
      }
      close(bad_file)
    }

    NR > 1 {
      ep=$3
      if (ep == active_ep) next
      if (ep == old_ep) next
      if (bad[ep]) next
      print
      exit
    }
  ' "$TABLE"
}

probe_slot_strict() {
  DEV="$1"

  for IP in 9.9.9.9 1.1.1.1; do
    echo
    echo "--- strict probe $DEV $IP ---"
    ip route replace "$IP/32" dev "$DEV"
    ip route get "$IP"
    OUT="$(ping -4 -c "$PING_COUNT" -W 2 -I "$DEV" "$IP" 2>&1 || true)"
    echo "$OUT"
    ip route del "$IP/32" dev "$DEV" 2>/dev/null || true

    echo "$OUT" | grep -q ' 0% packet loss' || return 1
  done

  return 0
}

echo "=== hmn-refill-slot ==="
echo "slot_to_refill=$SLOT"
echo "active_slot=$ACTIVE_SLOT"
echo "table=$TABLE"
echo "selected=$SELECTED"
echo "dry_run=$DRY_RUN"

ACTIVE_EP="$(get_slot_ep "$ACTIVE_SLOT" || true)"
OLD_EP="$(get_slot_ep "$SLOT" || true)"

echo "active_ep=$ACTIVE_EP"
echo "old_slot_ep=$OLD_EP"

if [ -n "$OLD_EP" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "would_mark_bad_ep=$OLD_EP"
  else
    mark_bad_ep "$OLD_EP" "slot_refill_old_or_failed_${SLOT}"
  fi
fi

LINE="$(candidate_line || true)"

if [ -z "$LINE" ]; then
  echo "ERROR: no candidate available after exclusions"
  echo
  echo "bad endpoints today:"
  cat "$(today_bad_file)" 2>/dev/null || true
  exit 1
fi

CAND_RANK="$(echo "$LINE" | awk -F '\t' '{print $1}')"
CAND_FILE="$(echo "$LINE" | awk -F '\t' '{print $2}')"
CAND_EP="$(echo "$LINE" | awk -F '\t' '{print $3}')"
CAND_AVG="$(echo "$LINE" | awk -F '\t' '{print $4}')"
CAND_CONF="$(echo "$LINE" | awk -F '\t' '{print $6}')"

echo
echo "candidate_rank=$CAND_RANK"
echo "candidate_file=$CAND_FILE"
echo "candidate_ep=$CAND_EP"
echo "candidate_avg=$CAND_AVG"
echo "candidate_conf=$CAND_CONF"

[ -s "$CAND_CONF" ] || {
  echo "ERROR: candidate config missing: $CAND_CONF"
  exit 1
}

if [ "$DRY_RUN" = "1" ]; then
  echo
  echo "DRY_RUN=1, not loading anything"
  echo
  echo "bad endpoints today:"
  cat "$(today_bad_file)" 2>/dev/null || true
  exit 0
fi

echo
echo "=== load candidate into $SLOT ==="
ifdown "$SLOT" 2>/dev/null || true
sleep 2

"$LOADER" "$SLOT" "$CAND_CONF"

echo
echo "=== reload netifd so changed slot is visible ==="
ubus call network reload 2>/dev/null || /etc/init.d/network reload
sleep 8

echo
echo "=== restore active slot after reload ==="
ifup "$ACTIVE_SLOT" 2>/dev/null || true
sleep 8

echo "$ACTIVE_SLOT" > "$BASE/state/active-slot"
ip route replace default dev "$ACTIVE_SLOT" table 200
/usr/bin/vpn-table200-local-routes.sh 2>/dev/null || true
ip route flush cache

echo
echo "=== bring candidate slot up for strict probe ==="
ifup "$SLOT"
sleep 22

echo
echo "--- $SLOT status ---"
/usr/bin/amneziawg show "$SLOT" 2>/dev/null | sed -n '1,35p' || true

if ! ip link show "$SLOT" >/dev/null 2>&1; then
  echo "ERROR: $SLOT link absent after ifup"
  mark_bad_ep "$CAND_EP" "link_absent_after_load_${SLOT}"
  exit 1
fi

if ! probe_slot_strict "$SLOT"; then
  echo "ERROR: candidate failed strict probe"
  mark_bad_ep "$CAND_EP" "strict_probe_failed_${SLOT}"
  ifdown "$SLOT" 2>/dev/null || true
  exit 1
fi

echo
echo "=== update selected cache ==="
cp -a "$SELECTED" "$SELECTED.before-refill-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

OTHER_SLOT="$ACTIVE_SLOT"
OTHER_EP="$(get_slot_ep "$OTHER_SLOT" || true)"

{
  printf "slot\tfile\tendpoint\tavg_ms\tconfig_path\n"
  printf "%s\t%s\t%s\t%s\t%s\n" "$SLOT" "$CAND_FILE" "$CAND_EP" "$CAND_AVG" "$CAND_CONF"

  awk -F '\t' -v s="$OTHER_SLOT" -v ep="$OTHER_EP" 'NR>1 && $1==s {
    printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5
    found=1
  }
  END {
    if (!found && ep != "") {
      # leave absent rather than inventing config path
    }
  }' "$SELECTED"
} > /tmp/selected-awg1-refill.tsv

cp /tmp/selected-awg1-refill.tsv "$SELECTED"
rm -f /tmp/selected-awg1-refill.tsv

cat "$SELECTED"

echo
echo "=== leave refilled slot down as standby ==="
ifdown "$SLOT" 2>/dev/null || true
sleep 4

echo
echo "=== final route should remain active slot ==="
echo "$ACTIVE_SLOT" > "$BASE/state/active-slot"
ip route replace default dev "$ACTIVE_SLOT" table 200
/usr/bin/vpn-table200-local-routes.sh 2>/dev/null || true
ip route flush cache

cat "$BASE/state/active-slot"
ip route show table 200
ip route get 9.9.9.9 from 10.200.0.2

echo
echo "=== refill done ==="
