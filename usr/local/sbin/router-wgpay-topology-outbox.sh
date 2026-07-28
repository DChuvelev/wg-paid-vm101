#!/bin/sh
set -u
umask 077
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

CONFIG="${ROUTER_TOPOLOGY_DELIVERY_CONFIG:-/etc/router-wgpay-topology-delivery.conf}"
LIB="${ROUTER_TOPOLOGY_DELIVERY_LIB:-/usr/local/lib/router-wgpay-topology-delivery-lib.sh}"
[ -r "$CONFIG" ] || { echo RESULT=STOP_TOPOLOGY_DELIVERY_CONFIG_MISSING; exit 70; }
[ -r "$LIB" ] || { echo RESULT=STOP_TOPOLOGY_DELIVERY_LIBRARY_MISSING; exit 70; }
. "$CONFIG"
. "$LIB"

FALLBACK_STATE="${ROUTER_TOPOLOGY_DELIVERY_FALLBACK_STATE:-${TOPOLOGY_DELIVERY_FALLBACK_STATE}}"
DIRECT_STATE="${ROUTER_TOPOLOGY_DELIVERY_DIRECT_STATE:-${TOPOLOGY_DELIVERY_DIRECT_STATE:-/etc/router-wgpay-direct/state.kv}}"
SOURCE_STATE="$FALLBACK_STATE"
STATE_DIR="${ROUTER_TOPOLOGY_DELIVERY_STATE_DIR:-${TOPOLOGY_DELIVERY_STATE_DIR}}"
LOCK_FILE="${ROUTER_TOPOLOGY_DELIVERY_LOCK:-${TOPOLOGY_DELIVERY_LOCK}}"
DELIVERY_COMMAND="${ROUTER_TOPOLOGY_DELIVERY_COMMAND:-${TOPOLOGY_DELIVERY_COMMAND}}"
DELIVERY_ENABLED="${ROUTER_TOPOLOGY_DELIVERY_ENABLED:-${TOPOLOGY_DELIVERY_ENABLED}}"
MAX_ACK_BYTES="${ROUTER_TOPOLOGY_DELIVERY_MAX_ACK_BYTES:-${TOPOLOGY_DELIVERY_MAX_ACK_BYTES}}"
NOW="${ROUTER_TOPOLOGY_DELIVERY_NOW_EPOCH:-$(date +%s)}"
STATE_FILE="$STATE_DIR/state.kv"
PENDING_FILE="$STATE_DIR/pending.kv"
LAST_ACK_FILE="$STATE_DIR/last-ack.kv"
LAST_DELIVERED_FILE="$STATE_DIR/last-delivered.kv"

COMMAND_MODE="${1:---run-once}"
case "$COMMAND_MODE" in --sync|--attempt|--run-once|--status) ;; *) echo "Usage: $0 --sync|--attempt|--run-once|--status" >&2; exit 64 ;; esac

mkdir -p "$STATE_DIR" "$(dirname "$LOCK_FILE")" || exit 70
chmod 700 "$STATE_DIR" 2>/dev/null || true
exec 9>"$LOCK_FILE"
flock -n 9 || { echo RESULT=NOOP_TOPOLOGY_DELIVERY_LOCKED; exit 75; }

state_init() {
    if [ -f "$STATE_FILE" ]; then return 0; fi
    tmp="$STATE_DIR/state.init.$$"
    {
        echo schema="$TOPOLOGY_DELIVERY_STATE_SCHEMA"
        echo next_generation=000000000001
        echo last_source_fingerprint=
        echo pending_generation=
        echo pending_payload_sha256=
        echo pending_source_fingerprint=
        echo pending_attempt_count=0
        echo last_attempt_epoch=0
        echo last_attempt_result=NEVER
        echo last_attempt_detail=
        echo last_acked_generation=
        echo last_acked_payload_sha256=
        echo last_ack_epoch=0
    } > "$tmp"
    router_topology_delivery_atomic_write "$tmp" "$STATE_FILE" 600
    rm -f "$tmp"
}

state_update() {
    updates="$STATE_DIR/state.updates.$$"
    candidate="$STATE_DIR/state.candidate.$$"
    : > "$updates" || return 1
    for pair in "$@"; do
        printf '%s\n' "$pair" >> "$updates" || return 1
    done
    awk -F= '
        NR==FNR { key=$1; u[key]=substr($0,index($0,"=")+1); order[++n]=key; next }
        {
            if($1 in u) { print $1 "=" u[$1]; seen[$1]=1 }
            else print
        }
        END { for(i=1;i<=n;i++) if(!seen[order[i]]) print order[i] "=" u[order[i]] }
    ' "$updates" "$STATE_FILE" > "$candidate" || { rm -f "$updates" "$candidate"; return 1; }
    router_topology_delivery_atomic_write "$candidate" "$STATE_FILE" 600 || { rm -f "$updates" "$candidate"; return 1; }
    rm -f "$updates" "$candidate"
}

source_snapshot_select() {
    SOURCE_STATE="$FALLBACK_STATE"
    if [ -f "$DIRECT_STATE" ] && [ "$(router_topology_delivery_kv_get direct_required "$DIRECT_STATE")" = true ]; then SOURCE_STATE="$DIRECT_STATE"; fi
}

fallback_snapshot_validate() {
    source_snapshot_select
    [ -f "$SOURCE_STATE" ] || return 10
    fb_schema="$(router_topology_delivery_kv_get schema "$SOURCE_STATE")"
    fb_mode="$(router_topology_delivery_kv_get mode "$SOURCE_STATE")"
    fb_source="$(router_topology_delivery_kv_get source_vm101_generation "$SOURCE_STATE")"
    fb_healthy_slots="$(router_topology_delivery_kv_get healthy_slots "$SOURCE_STATE")"
    fb_exhausted_slots="$(router_topology_delivery_kv_get exhausted_slots "$SOURCE_STATE")"
    fb_healthy_selectors="$(router_topology_delivery_kv_get healthy_selectors "$SOURCE_STATE")"
    fb_exhausted_selectors="$(router_topology_delivery_kv_get exhausted_selectors "$SOURCE_STATE")"
    [ "$fb_schema" = router-wgpay-fallback-state-v1 ] || return 11
    case "$fb_mode" in NORMAL|SLOT_EXHAUSTED) ;; *) return 12 ;; esac
    printf '%s' "$fb_source" | grep -Eq '^[A-Za-z0-9_.:-]{1,128}$' || return 13
    router_topology_delivery_csv_validate_subsequence "$fb_healthy_slots" 'egress1,egress2,egress3,egress4,egress5' true || return 14
    router_topology_delivery_csv_validate_subsequence "$fb_exhausted_slots" 'egress1,egress2,egress3,egress4,egress5' true || return 15
    router_topology_delivery_csv_validate_subsequence "$fb_healthy_selectors" 'cs1,cs2,cs3,cs4,cs5' true || return 16
    router_topology_delivery_csv_validate_subsequence "$fb_exhausted_selectors" 'cs1,cs2,cs3,cs4,cs5' true || return 17
    router_topology_delivery_sets_complete_disjoint "$fb_healthy_slots" "$fb_exhausted_slots" 'egress1,egress2,egress3,egress4,egress5' || return 18
    router_topology_delivery_sets_complete_disjoint "$fb_healthy_selectors" "$fb_exhausted_selectors" 'cs1,cs2,cs3,cs4,cs5' || return 19
    router_topology_delivery_validate_alignment "$fb_healthy_slots" "$fb_exhausted_slots" "$fb_healthy_selectors" "$fb_exhausted_selectors" || return 23
    if [ "$fb_mode" = NORMAL ]; then
        [ "$fb_healthy_slots" = 'egress1,egress2,egress3,egress4,egress5' ] || return 20
        [ -z "$fb_exhausted_slots" ] && [ "$fb_healthy_selectors" = 'cs1,cs2,cs3,cs4,cs5' ] && [ -z "$fb_exhausted_selectors" ] || return 21
    else
        [ -n "$fb_exhausted_slots" ] && [ -n "$fb_exhausted_selectors" ] || return 22
    fi
    return 0
}

source_fingerprint() {
    {
        printf 'mode=%s\n' "$fb_mode"
        printf 'source_vm101_generation=%s\n' "$fb_source"
        printf 'healthy_slots=%s\n' "$fb_healthy_slots"
        printf 'exhausted_slots=%s\n' "$fb_exhausted_slots"
        printf 'healthy_selectors=%s\n' "$fb_healthy_selectors"
        printf 'exhausted_selectors=%s\n' "$fb_exhausted_selectors"
    } | sha256sum | awk '{print $1}'
}

build_pending() {
    generation="$1"
    output="$2"
    body="$STATE_DIR/pending.body.$$"
    {
        printf 'schema=%s\n' "$TOPOLOGY_DELIVERY_INPUT_SCHEMA"
        printf 'generation=%s\n' "$generation"
        printf 'mode=%s\n' "$fb_mode"
        printf 'source_vm101_generation=%s\n' "$fb_source"
        printf 'healthy_slots=%s\n' "$fb_healthy_slots"
        printf 'exhausted_slots=%s\n' "$fb_exhausted_slots"
        printf 'healthy_selectors=%s\n' "$fb_healthy_selectors"
        printf 'exhausted_selectors=%s\n' "$fb_exhausted_selectors"
        printf 'created_epoch=%s\n' "$NOW"
    } > "$body"
    confirm="$(sha256sum "$body" | awk '{print $1}')"
    cat "$body" > "$output"
    printf 'confirm_sha256=%s\n' "$confirm" >> "$output"
    rm -f "$body"
}

sync_pending() {
    fallback_snapshot_validate
    rc=$?
    [ "$rc" -eq 0 ] || { echo RESULT=STOP_TOPOLOGY_SOURCE_STATE_INVALID; echo DETAIL="$rc"; return 70; }
    fingerprint="$(source_fingerprint)"
    pending_fp="$(router_topology_delivery_kv_get pending_source_fingerprint "$STATE_FILE")"
    if [ -f "$PENDING_FILE" ] && [ "$pending_fp" = "$fingerprint" ]; then
        echo RESULT=NOOP_TOPOLOGY_PENDING_REPLAY
        echo PENDING_GENERATION="$(router_topology_delivery_kv_get generation "$PENDING_FILE")"
        return 0
    fi
    last_fp="$(router_topology_delivery_kv_get last_source_fingerprint "$STATE_FILE")"
    if [ ! -f "$PENDING_FILE" ] && [ "$last_fp" = "$fingerprint" ]; then
        echo RESULT=NOOP_TOPOLOGY_SOURCE_ALREADY_ACKED
        return 0
    fi
    generation="$(router_topology_delivery_kv_get next_generation "$STATE_FILE")"
    printf '%s' "$generation" | grep -Eq '^[0-9]{12}$' || { echo RESULT=STOP_TOPOLOGY_GENERATION_STATE_INVALID; return 70; }
    next_generation="$(router_topology_delivery_generation_next "$generation")" || { echo RESULT=STOP_TOPOLOGY_GENERATION_EXHAUSTED; return 70; }
    candidate="$STATE_DIR/pending.candidate.$$"
    build_pending "$generation" "$candidate" || return 70
    payload="$(router_topology_delivery_kv_get confirm_sha256 "$candidate")"
    router_topology_delivery_atomic_write "$candidate" "$PENDING_FILE" 600 || return 70
    rm -f "$candidate"
    state_update \
        "next_generation=$next_generation" \
        "pending_generation=$generation" \
        "pending_payload_sha256=$payload" \
        "pending_source_fingerprint=$fingerprint" \
        "pending_attempt_count=0" || return 70
    echo RESULT=PASS_TOPOLOGY_GENERATION_CREATED
    echo PENDING_GENERATION="$generation"
    echo PENDING_PAYLOAD_SHA256="$payload"
    return 0
}

attempt_pending() {
    [ -f "$PENDING_FILE" ] || { echo RESULT=NOOP_TOPOLOGY_NOT_PENDING; return 0; }
    generation="$(router_topology_delivery_kv_get generation "$PENDING_FILE")"
    payload="$(router_topology_delivery_kv_get confirm_sha256 "$PENDING_FILE")"
    if [ "$DELIVERY_ENABLED" != 1 ]; then
        echo RESULT=NOOP_TOPOLOGY_DELIVERY_DISABLED
        echo PENDING_GENERATION="$generation"
        return 0
    fi
    [ -x "$DELIVERY_COMMAND" ] || {
        state_update \
            "last_attempt_epoch=$NOW" \
            "last_attempt_result=TRANSPORT_MISSING" \
            "last_attempt_detail=$(router_topology_delivery_sanitize_detail "$DELIVERY_COMMAND")" || true
        echo RESULT=RETRY_TOPOLOGY_TRANSPORT_MISSING
        return 69
    }
    attempt_count="$(router_topology_delivery_kv_get pending_attempt_count "$STATE_FILE")"
    [ -n "$attempt_count" ] || attempt_count=0
    attempt_count=$((attempt_count + 1))
    ack="$STATE_DIR/ack.attempt.$$"
    err="$STATE_DIR/transport.err.$$"
    if "$DELIVERY_COMMAND" < "$PENDING_FILE" > "$ack" 2> "$err"; then
        transport_rc=0
    else
        transport_rc=$?
    fi
    bytes="$(wc -c < "$ack" | tr -d ' ')"
    state_update "pending_attempt_count=$attempt_count" "last_attempt_epoch=$NOW" || true
    if [ "$transport_rc" -ne 0 ]; then
        detail="$(head -c 160 "$err" 2>/dev/null | tr '\n' '_' )"
        state_update \
            "last_attempt_result=TRANSPORT_FAILED" \
            "last_attempt_detail=$(router_topology_delivery_sanitize_detail "rc${transport_rc}_${detail}")" || true
        rm -f "$ack" "$err"
        echo RESULT=RETRY_TOPOLOGY_TRANSPORT_FAILED
        echo TRANSPORT_RC="$transport_rc"
        return 69
    fi
    if [ "$bytes" -gt "$MAX_ACK_BYTES" ]; then
        state_update "last_attempt_result=ACK_TOO_LARGE" "last_attempt_detail=$bytes" || true
        rm -f "$ack" "$err"
        echo RESULT=RETRY_TOPOLOGY_ACK_TOO_LARGE
        return 69
    fi
    router_topology_delivery_validate_ack "$ack" "$PENDING_FILE" "$TOPOLOGY_DELIVERY_ACK_SCHEMA"
    ack_rc=$?
    if [ "$ack_rc" -ne 0 ]; then
        state_update "last_attempt_result=ACK_INVALID" "last_attempt_detail=$ack_rc" || true
        rm -f "$ack" "$err"
        echo RESULT=RETRY_TOPOLOGY_ACK_INVALID
        echo ACK_VALIDATE_RC="$ack_rc"
        return 69
    fi
    delivered="$STATE_DIR/delivered.$$"
    cp "$PENDING_FILE" "$delivered" || return 70
    router_topology_delivery_atomic_write "$ack" "$LAST_ACK_FILE" 600 || return 70
    router_topology_delivery_atomic_write "$delivered" "$LAST_DELIVERED_FILE" 600 || return 70
    fingerprint="$(router_topology_delivery_kv_get pending_source_fingerprint "$STATE_FILE")"
    state_update \
        "last_source_fingerprint=$fingerprint" \
        "last_acked_generation=$generation" \
        "last_acked_payload_sha256=$payload" \
        "last_ack_epoch=$NOW" \
        "pending_generation=" \
        "pending_payload_sha256=" \
        "pending_source_fingerprint=" \
        "pending_attempt_count=0" \
        "last_attempt_result=ACK_ACCEPTED" \
        "last_attempt_detail=" || return 70
    rm -f "$PENDING_FILE" "$ack" "$err" "$delivered"
    echo RESULT=PASS_TOPOLOGY_ACK_ACCEPTED
    echo ACKED_GENERATION="$generation"
    echo ACKED_PAYLOAD_SHA256="$payload"
    return 0
}

status_emit() {
    echo schema="$TOPOLOGY_DELIVERY_STATE_SCHEMA"
    echo delivery_enabled="$DELIVERY_ENABLED"
    echo state_dir="$STATE_DIR"
    echo transport_command="$DELIVERY_COMMAND"
    source_snapshot_select
    echo source_state="$SOURCE_STATE"
    echo direct_state_present="$([ -f "$DIRECT_STATE" ] && echo true || echo false)"
    if [ -f "$STATE_FILE" ]; then cat "$STATE_FILE"; else echo state_initialized=false; fi
    if [ -f "$PENDING_FILE" ]; then
        echo pending_present=true
        echo pending_generation="$(router_topology_delivery_kv_get generation "$PENDING_FILE")"
        echo pending_payload_sha256="$(router_topology_delivery_kv_get confirm_sha256 "$PENDING_FILE")"
    else
        echo pending_present=false
    fi
}

state_init || exit 70
case "$COMMAND_MODE" in
    --status) status_emit ;;
    --sync) sync_pending ;;
    --attempt) attempt_pending ;;
    --run-once)
        sync_pending
        sync_rc=$?
        [ "$sync_rc" -eq 0 ] || exit "$sync_rc"
        attempt_pending
        ;;
esac
