#!/bin/sh
set -u
umask 077
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

CONFIG="${ROUTER_WGPAY_WATCHER_CONFIG:-/etc/router-wgpay-watcher-topology.conf}"
[ -r "$CONFIG" ] || { echo RESULT=STOP_WATCHER_TOPOLOGY_CONFIG_MISSING; exit 70; }
. "$CONFIG"

STATE_DIR="${ROUTER_WGPAY_WATCHER_STATE_DIR:-$WATCHER_TOPOLOGY_STATE_DIR}"
STATE_FILE="${ROUTER_WGPAY_WATCHER_STATE_FILE:-$WATCHER_TOPOLOGY_STATE_FILE}"
LOCK_FILE="${ROUTER_WGPAY_WATCHER_LOCK_FILE:-$WATCHER_TOPOLOGY_LOCK_FILE}"
FALLBACK_STATE="${ROUTER_WGPAY_WATCHER_FALLBACK_STATE:-$WATCHER_TOPOLOGY_FALLBACK_STATE}"
FALLBACK_ACK="${ROUTER_WGPAY_WATCHER_FALLBACK_ACK:-$WATCHER_TOPOLOGY_FALLBACK_ACK}"
MAPPER_APPLY="${ROUTER_WGPAY_WATCHER_MAPPER_APPLY:-$WATCHER_TOPOLOGY_MAPPER_APPLY}"
OUTBOX="${ROUTER_WGPAY_WATCHER_OUTBOX:-$WATCHER_TOPOLOGY_OUTBOX}"
NFT_BIN="${ROUTER_WGPAY_WATCHER_NFT_BIN:-nft}"
NFT_TABLE="${ROUTER_WGPAY_WATCHER_NFT_TABLE:-$WATCHER_TOPOLOGY_NFT_TABLE}"
FALLBACK_LOCK_FILE="${ROUTER_WGPAY_WATCHER_FALLBACK_LOCK_FILE:-${WATCHER_TOPOLOGY_FALLBACK_LOCK_FILE:-/var/run/router-wgpay-fallback.lock}}"
OUTBOX_LOCK_FILE="${ROUTER_WGPAY_WATCHER_OUTBOX_LOCK_FILE:-${WATCHER_TOPOLOGY_OUTBOX_LOCK_FILE:-/var/run/router-wgpay-topology-delivery.lock}}"
NOW="${ROUTER_WGPAY_WATCHER_NOW_EPOCH:-$(date +%s)}"

mode="${1:---status}"
slot="${2:-}"
reason="${3:-manual}"
case "$mode" in
    --bridge-start|--bridge-confirm|--bridge-clear) ;;
    --status) [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || printf '%s\n' "schema=$WATCHER_TOPOLOGY_SCHEMA" 'initialized=false'; exit 0 ;;
    *) echo "Usage: $0 --bridge-start|--bridge-confirm|--bridge-clear egressN [reason] | --status" >&2; exit 64 ;;
esac
case "$slot" in egress[1-5]) ;; *) echo RESULT=STOP_WATCHER_TOPOLOGY_SLOT_INVALID; exit 64;; esac

mkdir -p "$STATE_DIR" "$(dirname "$LOCK_FILE")" "$(dirname "$FALLBACK_LOCK_FILE")" "$(dirname "$OUTBOX_LOCK_FILE")" || exit 70
chmod 700 "$STATE_DIR" 2>/dev/null || true
exec 9>"$LOCK_FILE"
flock -n 9 || { echo RESULT=NOOP_WATCHER_TOPOLOGY_LOCKED; exit 75; }
# Serialize with fallback writer and keep the delivery loop from observing a pre-verify state.
exec 7>"$FALLBACK_LOCK_FILE"
flock 7 || exit 75
exec 8>"$OUTBOX_LOCK_FILE"
flock 8 || exit 75

kv() { key="$1" file="$2"; [ -f "$file" ] || return 0; awk -F= -v k="$key" '$1==k{print substr($0,index($0,"=")+1)}' "$file" | tail -n1; }
csv_has() { list="$1" item="$2"; [ -n "$list" ] && printf '%s\n' "$list" | awk -F, -v x="$item" '{for(i=1;i<=NF;i++)if($i==x)f=1}END{exit f?0:1}'; }
slot_selector() { case "$1" in egress1) echo cs4;; egress2) echo cs5;; egress3) echo cs1;; egress4) echo cs2;; egress5) echo cs3;; *) return 1;; esac; }
selector_slot() { case "$1" in cs1) echo egress3;; cs2) echo egress4;; cs3) echo egress5;; cs4) echo egress1;; cs5) echo egress2;; *) return 1;; esac; }
slot_iface() { echo "vpn${1#egress}"; }
slot_table() { echo $((200 + ${1#egress})); }
slot_mark() { printf '0x20%s\n' "${1#egress}"; }
gen_next() { printf '%s' "$1" | grep -Eq '^[0-9]{12}$' || return 1; [ "$1" != 999999999999 ] || return 1; awk -v n="$1" 'BEGIN{printf "%012d\n", n+1}'; }
atomic_write() { src="$1" dst="$2" mode_bits="${3:-600}"; mkdir -p "$(dirname "$dst")" || return 1; cp "$src" "$dst.tmp.$$" && chmod "$mode_bits" "$dst.tmp.$$" && mv "$dst.tmp.$$" "$dst"; }

old_exhausted="$(kv exhausted_slots "$STATE_FILE")"
[ -n "$old_exhausted" ] || old_exhausted="$(kv exhausted_slots "$FALLBACK_STATE")"
new_exhausted=''
for s in egress1 egress2 egress3 egress4 egress5; do
    present=false
    csv_has "$old_exhausted" "$s" && present=true
    case "$mode" in
        --bridge-start|--bridge-confirm) [ "$s" = "$slot" ] && present=true ;;
        --bridge-clear) [ "$s" = "$slot" ] && present=false ;;
    esac
    if [ "$present" = true ]; then new_exhausted="${new_exhausted:+$new_exhausted,}$s"; fi
done

if [ "$new_exhausted" = "$old_exhausted" ]; then
    echo RESULT=NOOP_WATCHER_TOPOLOGY_STATE_UNCHANGED
    echo EXHAUSTED_SLOTS="$new_exhausted"
    exit 0
fi

healthy_slots=''
for s in egress1 egress2 egress3 egress4 egress5; do
    csv_has "$new_exhausted" "$s" || healthy_slots="${healthy_slots:+$healthy_slots,}$s"
done
[ -n "$healthy_slots" ] || { echo RESULT=STOP_WATCHER_TOPOLOGY_ZERO_HEALTHY_DIRECT_REQUIRED; exit 73; }
first_healthy="${healthy_slots%%,*}"
exhausted_selectors=''
healthy_selectors=''
for c in cs1 cs2 cs3 cs4 cs5; do
    canonical="$(selector_slot "$c")"
    if csv_has "$new_exhausted" "$canonical"; then
        exhausted_selectors="${exhausted_selectors:+$exhausted_selectors,}$c"
    else
        healthy_selectors="${healthy_selectors:+$healthy_selectors,}$c"
    fi
done
if [ -z "$new_exhausted" ]; then state_mode=NORMAL; else state_mode=SLOT_EXHAUSTED; fi
old_gen="$(kv accepted_generation "$FALLBACK_STATE")"; [ -n "$old_gen" ] || old_gen=000000000000
new_gen="$(gen_next "$old_gen")" || { echo RESULT=STOP_WATCHER_TOPOLOGY_GENERATION_INVALID; exit 70; }
source_gen="WATCHER_${mode#--}_${slot}_${NOW}"

TMP="$STATE_DIR/txn.$$"; rm -rf "$TMP"; mkdir -p "$TMP" || exit 70
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
old_state_present=false; old_ack_present=false
if [ -f "$FALLBACK_STATE" ]; then cp "$FALLBACK_STATE" "$TMP/state.before" || exit 70; old_state_present=true; fi
if [ -f "$FALLBACK_ACK" ]; then cp "$FALLBACK_ACK" "$TMP/ack.before" || exit 70; old_ack_present=true; fi

body="$TMP/state.body"; candidate="$TMP/state.candidate"
{
    echo schema=router-wgpay-fallback-state-v1
    echo accepted_generation="$new_gen"
    echo mode="$state_mode"
    echo source_vm101_generation="$source_gen"
    echo healthy_slots="$healthy_slots"
    echo exhausted_slots="$new_exhausted"
    echo healthy_selectors="$healthy_selectors"
    echo exhausted_selectors="$exhausted_selectors"
    echo first_healthy_slot="$first_healthy"
    echo created_epoch="$NOW"
    echo applied_epoch="$NOW"
    for c in cs4 cs5 cs1 cs2 cs3; do
        canonical="$(selector_slot "$c")"; effective="$canonical"
        csv_has "$new_exhausted" "$canonical" && effective="$first_healthy"
        echo "canonical.$c.slot=$canonical"
        echo "effective.$c.slot=$effective"
        echo "effective.$c.interface=$(slot_iface "$effective")"
        echo "effective.$c.table=$(slot_table "$effective")"
        echo "effective.$c.mark=$(slot_mark "$effective")"
    done
    echo fallback_selectors="$exhausted_selectors"
} > "$body" || exit 70
payload="$(sha256sum "$body" | awk '{print $1}')"
{
    sed -n '1p' "$body"
    echo payload_sha256="$payload"
    sed -n '2,$p' "$body"
} > "$candidate"

rollback() {
    if [ "$old_state_present" = true ]; then atomic_write "$TMP/state.before" "$FALLBACK_STATE" 600 || true; else rm -f "$FALLBACK_STATE"; fi
    if [ "$old_ack_present" = true ]; then atomic_write "$TMP/ack.before" "$FALLBACK_ACK" 600 || true; else rm -f "$FALLBACK_ACK"; fi
    "$MAPPER_APPLY" start >/dev/null 2>&1 || true
}

atomic_write "$candidate" "$FALLBACK_STATE" 600 || { echo RESULT=STOP_WATCHER_TOPOLOGY_STATE_WRITE; exit 70; }
set +e
"$MAPPER_APPLY" start > "$TMP/mapper.log" 2>&1
mapper_rc=$?
set -e
if [ "$mapper_rc" -ne 0 ]; then
    rollback; cat "$TMP/mapper.log"; echo RESULT=STOP_WATCHER_TOPOLOGY_MAPPER_APPLY; exit "$mapper_rc"
fi

"$NFT_BIN" list table inet "$NFT_TABLE" > "$TMP/nft.txt" 2>&1 || { rollback; cat "$TMP/nft.txt"; echo RESULT=STOP_WATCHER_TOPOLOGY_NFT_MISSING; exit 80; }
map_count="$(grep -c 'meta mark set' "$TMP/nft.txt" || true)"; clear_count="$(grep -c 'ip dscp set cs0' "$TMP/nft.txt" || true)"
[ "$map_count" -eq 5 ] && [ "$clear_count" -eq 5 ] || { rollback; cat "$TMP/nft.txt"; echo RESULT=STOP_WATCHER_TOPOLOGY_NFT_COUNT; exit 80; }
for c in cs1 cs2 cs3 cs4 cs5; do
    canonical="$(selector_slot "$c")"; effective="$canonical"; csv_has "$new_exhausted" "$canonical" && effective="$first_healthy"
    expected_dec=$((0x200 + ${effective#egress}))
    actual_token="$(awk -v cls="$c" '$0 ~ "ip dscp " cls && $0 ~ /meta mark set/ {for(i=1;i<=NF;i++)if($i=="set"){print $(i+1); exit}}' "$TMP/nft.txt")"
    [ -n "$actual_token" ] || { rollback; echo "RESULT=STOP_WATCHER_TOPOLOGY_NFT_CLASS_MISSING"; echo CLASS="$c"; exit 80; }
    actual_dec=$((actual_token))
    [ "$actual_dec" -eq "$expected_dec" ] || { rollback; echo RESULT=STOP_WATCHER_TOPOLOGY_NFT_MARK_MISMATCH; echo CLASS="$c"; exit 80; }
done

plan_sha="$(sha256sum "$candidate" | awk '{print $1}')"
ack="$TMP/ack"
{
    echo schema=router-wgpay-fallback-ack-v1
    echo result=PASS
    echo accepted_generation="$new_gen"
    echo payload_sha256="$payload"
    echo mode="$state_mode"
    echo first_healthy_slot="$first_healthy"
    echo fallback_selectors="$exhausted_selectors"
    echo plan_sha256="$plan_sha"
    echo mapper_applied=true
    echo state_persisted=true
    echo always_on=true
} > "$ack"
atomic_write "$ack" "$FALLBACK_ACK" 600 || { rollback; echo RESULT=STOP_WATCHER_TOPOLOGY_ACK_WRITE; exit 82; }

integration="$TMP/integration"
{
    echo schema="$WATCHER_TOPOLOGY_SCHEMA"
    echo updated_epoch="$NOW"
    echo last_action="${mode#--}"
    echo last_slot="$slot"
    echo last_reason="$reason"
    echo fallback_generation="$new_gen"
    echo mode="$state_mode"
    echo healthy_slots="$healthy_slots"
    echo exhausted_slots="$new_exhausted"
    echo healthy_selectors="$healthy_selectors"
    echo exhausted_selectors="$exhausted_selectors"
    echo first_healthy_slot="$first_healthy"
} > "$integration"
atomic_write "$integration" "$STATE_FILE" 600 || { rollback; echo RESULT=STOP_WATCHER_TOPOLOGY_INTEGRATION_STATE_WRITE; exit 82; }

# Local mapper/state/ack are committed. Release delivery lock, then create/supersede pending;
# the already-running retry service performs SSH delivery independently.
exec 8>&-
outbox_rc=0
if [ -x "$OUTBOX" ]; then "$OUTBOX" --sync > "$TMP/outbox.log" 2>&1 || outbox_rc=$?; fi
cat "$TMP/outbox.log" 2>/dev/null || true
echo RESULT=PASS_WATCHER_TOPOLOGY_SYNC
echo ACTION="${mode#--}"
echo SLOT="$slot"
echo FALLBACK_GENERATION="$new_gen"
echo FALLBACK_MODE="$state_mode"
echo EXHAUSTED_SLOTS="$new_exhausted"
echo FIRST_HEALTHY_SLOT="$first_healthy"
echo OUTBOX_RC="$outbox_rc"
exit 0
