#!/bin/sh
set -u
umask 077
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

SCHEMA='router-wgpay-exit-catalog-v1'
ACK_SCHEMA='router-wgpay-exit-catalog-ack-v1'
STATE_SCHEMA='router-wgpay-exit-catalog-publisher-state-v1'
SLOTS_FILE="${ROUTER_EXIT_CATALOG_SLOTS_FILE:-/etc/router-egress-slots.d/slots.conf}"
POOL_FILE="${ROUTER_EXIT_CATALOG_POOL_FILE:-/root/hmn/cache/working-awg1-latest.tsv}"
GEN_CONFIG="${ROUTER_EXIT_CATALOG_GENERATION_CONFIG:-/etc/router-egress-generation.conf}"
TRANSPORT="${ROUTER_EXIT_CATALOG_TRANSPORT:-/usr/local/sbin/router-wgpay-exit-catalog-transport.sh}"
UCI_BIN="${ROUTER_EXIT_CATALOG_UCI_BIN:-uci}"
STATE_DIR="${ROUTER_EXIT_CATALOG_PUBLISH_STATE_DIR:-/var/lib/router-wgpay-exit-catalog-publisher}"
STATE_FILE="${ROUTER_EXIT_CATALOG_PUBLISH_STATE_FILE:-${STATE_DIR}/state.kv}"
LOCK_FILE="${ROUTER_EXIT_CATALOG_PUBLISH_LOCK_FILE:-/var/run/router-wgpay-exit-catalog-publisher.lock}"
REPUBLISH_SEC="${ROUTER_EXIT_CATALOG_REPUBLISH_SEC:-300}"
MAX_ACK_BYTES="${ROUTER_EXIT_CATALOG_MAX_ACK_BYTES:-2048}"
NOW="${ROUTER_EXIT_CATALOG_NOW_EPOCH:-$(date +%s)}"
MODE="${1:---run-once}"

kv_get() {
    key="$1"; file="$2"
    [ -f "$file" ] || return 0
    awk -F= -v key="$key" '$1==key {print substr($0,index($0,"=")+1)}' "$file" | tail -n 1
}
fail() {
    reason="$1"; rc="${2:-70}"
    echo "RESULT=STOP_EXIT_CATALOG_PUBLISH"
    echo "REASON=$reason"
    exit "$rc"
}
case "$MODE" in --build|--run-once|--publish-now|--status) ;; *) echo "Usage: $0 --build|--run-once|--publish-now|--status" >&2; exit 64;; esac
case "$NOW:$REPUBLISH_SEC:$MAX_ACK_BYTES" in *[!0-9:]*|:*|*:) fail numeric_config_invalid 64;; esac
[ "$REPUBLISH_SEC" -ge 30 ] && [ "$REPUBLISH_SEC" -le 3600 ] || fail republish_range_invalid 64
[ "$MAX_ACK_BYTES" -ge 256 ] && [ "$MAX_ACK_BYTES" -le 8192 ] || fail ack_limit_range_invalid 64
if [ "$MODE" = --status ]; then
    if [ -r "$STATE_FILE" ]; then cat "$STATE_FILE"; else printf '%s\n' "schema=$STATE_SCHEMA" 'result=EMPTY' 'reason=no_publish_state'; fi
    exit 0
fi
for f in "$SLOTS_FILE" "$POOL_FILE" "$GEN_CONFIG"; do [ -r "$f" ] || fail required_input_missing 70; done
[ -x "$TRANSPORT" ] || [ "$MODE" = --build ] || fail transport_missing 70
command -v "$UCI_BIN" >/dev/null 2>&1 || fail uci_missing 70

TMP="${TMPDIR:-/tmp}/router-wgpay-exit-catalog-publish.$$"
rm -rf "$TMP"; mkdir -p "$TMP" || fail tmp_create_failed 70
cleanup() { rc="$?"; trap - EXIT HUP INT TERM; rm -rf "$TMP"; exit "$rc"; }
trap cleanup EXIT HUP INT TERM
SLOTS="$TMP/slots.tsv"; RAW="$TMP/raw.tsv"; LABELS="$TMP/labels.kv"; BODY="$TMP/body.kv"; PAYLOAD="$TMP/payload.kv"; ACK="$TMP/ack.kv"; ERR="$TMP/transport.err"

awk '
BEGIN { n=0 }
/^[[:space:]]*($|#)/ { next }
NF != 11 { exit 41 }
{
    if ($11 != "1") exit 42
    if ($5 !~ /^cs[1-5]$/) exit 43
    s=substr($5,3)+0
    if (seen[s]++) exit 44
    printf "%s\t%s\t%d\n", $1, $2, s
    n++
}
END { if (n != 5) exit 45; for (i=1;i<=5;i++) if (!seen[i]) exit 46 }
' "$SLOTS_FILE" > "$SLOTS" || fail slots_contract_invalid 65

awk -F '\t' 'NR==1 { ok=(NF==9 && $1=="id" && $2=="country" && $3=="name" && $4=="wg_ip" && $5=="wg_port" && $6=="endpoint" && $7=="endpoint_match" && $8=="address" && $9=="config_file"); exit ok?0:1 }' "$POOL_FILE" || fail provider_pool_header_invalid 65

. "$GEN_CONFIG"
ACTIVE="$(readlink -f "$GENERATION_ACTIVE_LINK" 2>/dev/null || true)"
[ -n "$ACTIVE" ] && [ -d "$ACTIVE" ] || fail active_generation_missing 65
SOURCE_GENERATION="$(basename "$ACTIVE")"
printf '%s' "$SOURCE_GENERATION" | grep -Eq '^[A-Za-z0-9_.:-]{1,128}$' || fail active_generation_invalid 65

: > "$RAW"
for selector in 1 2 3 4 5; do
    iface="$(awk -F '\t' -v s="$selector" '$3==s {print $2}' "$SLOTS")"
    [ -n "$iface" ] || fail selector_interface_missing 65
    endpoint="$($UCI_BIN -q get "network.${iface}.hmn_endpoint" 2>/dev/null || true)"
    [ -n "$endpoint" ] || fail live_endpoint_missing 75
    case "$endpoint" in *[!A-Za-z0-9.:_-]*) fail live_endpoint_invalid 65;; esac
    provider_name="$(awk -F '\t' -v ep="$endpoint" 'NR>1 && $6==ep {n++; value=$3} END {if(n==1) print value; else exit (n==0?44:45)}' "$POOL_FILE")" || fail provider_endpoint_match_not_unique 75
    display="$(printf '%s\n' "$provider_name" | sed 's/[[:space:]][A-Z][0-9][0-9]*$//')"
    [ -n "$display" ] || fail display_name_empty 65
    [ "${#display}" -le 92 ] || fail display_name_too_long 65
    printf '%s\n' "$display" | grep -Eq "^[A-Za-z0-9][A-Za-z0-9 .,'&()/_-]*$" || fail display_name_invalid 65
    case "$display" in *,\ *) ;; *) fail display_name_country_city_invalid 65;; esac
    printf '%s\t%s\n' "$selector" "$display" >> "$RAW"
done

awk -F '\t' '
NR==FNR { count[$2]++; next }
{
    seen[$2]++
    label=$2
    if (count[$2] > 1) label=label " " seen[$2]
    if (length(label) > 96) exit 51
    printf "selector%d=%s\n", $1, label
}
' "$RAW" "$RAW" > "$LABELS" || fail duplicate_label_numbering_failed 65
[ "$(wc -l < "$LABELS" | tr -d ' ')" -eq 5 ] || fail label_count_invalid 65
for selector in 1 2 3 4 5; do grep -q "^selector${selector}=" "$LABELS" || fail selector_label_missing 65; done
if grep -Eq '[[:space:]][A-Z][0-9]+([[:space:]][0-9]+)?$' "$LABELS"; then fail technical_server_token_leaked 65; fi

FINGERPRINT="$( { printf 'source_generation=%s\n' "$SOURCE_GENERATION"; cat "$LABELS"; } | sha256sum | awk '{print $1}')"
{
    echo "schema=$SCHEMA"
    echo "source_generation=$SOURCE_GENERATION"
    echo "generated_epoch=$NOW"
    cat "$LABELS"
} > "$BODY"
CONFIRM="$(sha256sum "$BODY" | awk '{print $1}')"
cat "$BODY" > "$PAYLOAD"; echo "confirm_sha256=$CONFIRM" >> "$PAYLOAD"

if [ "$MODE" = --build ]; then cat "$PAYLOAD"; exit 0; fi
mkdir -p "$STATE_DIR" "$(dirname "$LOCK_FILE")" || fail state_dir_create_failed 70
chmod 700 "$STATE_DIR" 2>/dev/null || true
exec 9>"$LOCK_FILE"
flock -n 9 || { echo RESULT=NOOP_EXIT_CATALOG_PUBLISH_LOCKED; exit 75; }
LAST_FP="$(kv_get last_fingerprint "$STATE_FILE")"
LAST_ACK_EPOCH="$(kv_get last_ack_epoch "$STATE_FILE")"
case "$LAST_ACK_EPOCH" in ''|*[!0-9]*) LAST_ACK_EPOCH=0;; esac
AGE=$((NOW - LAST_ACK_EPOCH)); [ "$AGE" -ge 0 ] || AGE="$REPUBLISH_SEC"
if [ "$MODE" = --run-once ] && [ "$LAST_FP" = "$FINGERPRINT" ] && [ "$AGE" -lt "$REPUBLISH_SEC" ]; then
    echo RESULT=NOOP_EXIT_CATALOG_CURRENT
    echo SOURCE_GENERATION="$SOURCE_GENERATION"
    echo AGE_SEC="$AGE"
    exit 0
fi

set +e
"$TRANSPORT" < "$PAYLOAD" > "$ACK" 2> "$ERR"
RC=$?
set -e
[ "$RC" -eq 0 ] || { detail="$(tr -cd 'A-Za-z0-9_.:,/@+ -' < "$ERR" | head -c 160)"; echo RESULT=STOP_EXIT_CATALOG_TRANSPORT; echo TRANSPORT_RC="$RC"; echo "DETAIL=${detail:-none}"; exit 75; }
bytes="$(wc -c < "$ACK" | tr -d ' ')"; [ "$bytes" -gt 0 ] && [ "$bytes" -le "$MAX_ACK_BYTES" ] || fail ack_size_invalid 75
[ "$(wc -l < "$ACK" | tr -d ' ')" -eq 5 ] || fail ack_line_count_invalid 75
grep -Fqx "schema=$ACK_SCHEMA" "$ACK" || fail ack_schema_invalid 75
grep -Fqx 'result=PASS' "$ACK" || fail ack_result_invalid 75
grep -Fqx "source_generation=$SOURCE_GENERATION" "$ACK" || fail ack_generation_invalid 75
grep -Fqx "generated_epoch=$NOW" "$ACK" || fail ack_epoch_invalid 75
grep -Fqx "payload_sha256=$CONFIRM" "$ACK" || fail ack_payload_invalid 75

NEW="$TMP/state.kv"
{
    echo "schema=$STATE_SCHEMA"
    echo "last_fingerprint=$FINGERPRINT"
    echo "last_ack_epoch=$NOW"
    echo "last_payload_sha256=$CONFIRM"
    echo "source_generation=$SOURCE_GENERATION"
} > "$NEW"
TMP_STATE="${STATE_FILE}.tmp.$$"; cp "$NEW" "$TMP_STATE" || fail state_copy_failed 70; chmod 600 "$TMP_STATE" || { rm -f "$TMP_STATE"; fail state_chmod_failed 70; }; mv "$TMP_STATE" "$STATE_FILE" || { rm -f "$TMP_STATE"; fail state_commit_failed 70; }
echo RESULT=PASS_EXIT_CATALOG_PUBLISHED
echo SOURCE_GENERATION="$SOURCE_GENERATION"
echo PAYLOAD_SHA256="$CONFIRM"
