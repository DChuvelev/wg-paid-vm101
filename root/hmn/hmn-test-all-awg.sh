#!/bin/ash
# HMN provider quality tester: HTTPS eligibility + RTT + download throughput.
# R21B adds per-candidate coordination and optional active-five inclusion.
set -u
umask 077

CONFIG_DIR="${1:-/root/hmn/configs/awg1/latest}"
BASE="${HMN_BASE:-/root/hmn}"
LOADER="${HMN_LOADER:-$BASE/hmn-load-vpn-test.sh}"
AWGSHOW="${AWGSHOW:-/usr/bin/amneziawg}"
HTTPS_ORACLE="${HTTPS_HEALTH_ORACLE:-/usr/local/lib/router-egress-https-health.sh}"
IDENTITY_BIN="${HMN_TUNNEL_IDENTITY:-/usr/local/lib/router-egress-hmn-identity.sh}"
STATE_HELPER="${STATE_HELPER:-/usr/local/lib/router-egress-recovery-state.sh}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
TEST_IFACE="${PROVIDER_TEST_INTERFACE:-vpn_test}"
WAIT_SECONDS="${WAIT_SECONDS:-8}"
LEAVE_UP="${LEAVE_UP:-0}"
RTT_COUNT="${PROVIDER_RTT_COUNT:-3}"
RTT_TIMEOUT="${PROVIDER_RTT_TIMEOUT_SEC:-2}"
THROUGHPUT_BYTES="${PROVIDER_THROUGHPUT_BYTES:-5000000}"
THROUGHPUT_MAX_TIME="${PROVIDER_THROUGHPUT_MAX_TIME_SEC:-20}"
THROUGHPUT_URL_BASE="${PROVIDER_THROUGHPUT_URL_BASE:-https://speed.cloudflare.com/__down}"
INCLUDE_ACTIVE="${HMN_TEST_INCLUDE_ACTIVE:-0}"
LOCK_WAIT_SEC="${PROVIDER_TEST_LOCK_WAIT_SEC:-60}"

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN_DIR="$BASE/test-runs/$RUN_ID"
RESULTS="$RUN_DIR/results.tsv"
RAW_LIST="$RUN_DIR/candidate-paths.raw"
CANDIDATES="$RUN_DIR/candidates.tsv"
SEEN_IDS="$RUN_DIR/seen-identities.txt"
mkdir -p "$RUN_DIR"

case "$RTT_COUNT:$RTT_TIMEOUT:$THROUGHPUT_BYTES:$THROUGHPUT_MAX_TIME:$LOCK_WAIT_SEC" in
    *[!0-9:]*) echo 'ERROR=invalid_quality_test_config' >&2; exit 2 ;;
esac
case "$INCLUDE_ACTIVE" in 0|1) ;; *) echo 'ERROR=invalid_include_active' >&2; exit 2 ;; esac
[ "$LEAVE_UP" = 0 ] || { echo 'ERROR=leave_up_forbidden_by_singleton_contract' >&2; exit 2; }
[ -d "$CONFIG_DIR" ] || { echo "ERROR=config_dir_missing:$CONFIG_DIR" >&2; exit 2; }
[ -x "$LOADER" ] || { echo "ERROR=loader_missing:$LOADER" >&2; exit 2; }
[ -x "$HTTPS_ORACLE" ] || { echo "ERROR=https_oracle_missing:$HTTPS_ORACLE" >&2; exit 2; }
[ -x "$IDENTITY_BIN" ] || { echo "ERROR=identity_helper_missing:$IDENTITY_BIN" >&2; exit 2; }
[ -x "$CURL_BIN" ] || { echo "ERROR=curl_missing:$CURL_BIN" >&2; exit 2; }
[ -r "$STATE_HELPER" ] || { echo "ERROR=state_helper_missing:$STATE_HELPER" >&2; exit 2; }

. "$STATE_HELPER"
reg_init_state >/dev/null 2>&1 || { echo 'ERROR=state_init_failed' >&2; exit 2; }

get_conf_endpoint() { awk -F'= *' '/^[[:space:]]*Endpoint[[:space:]]*=/{print $2; exit}' "$1"; }
active_source_config() { uci -q get "network.${1}.hmn_source_config" 2>/dev/null || true; }
active_identity() {
    cfg="$(active_source_config "$1")"
    [ -r "$cfg" ] || return 1
    "$IDENTITY_BIN" "$cfg" 2>/dev/null
}
find_active_iface_by_identity() {
    want="$1"
    for ifx in vpn1 vpn2 vpn3 vpn4 vpn5; do
        got="$(active_identity "$ifx" 2>/dev/null || true)"
        [ -n "$got" ] && [ "$got" = "$want" ] && { echo "$ifx"; return 0; }
    done
    return 1
}
active_identities_readable() {
    for ifx in vpn1 vpn2 vpn3 vpn4 vpn5; do
        got="$(active_identity "$ifx" 2>/dev/null || true)"
        [ -n "$got" ] || return 1
    done
}

COORD_LOCK=""
TEST_LOCK=""
TEST_IFACE_OWNED=false
acquire_one_lock() {
    lock_name="$1"; lock_owner="$2"; deadline=$(( $(date +%s) + LOCK_WAIT_SEC ))
    while :; do
        got="$(reg_lock_acquire "$lock_name" "$lock_owner" 2>/dev/null || true)"
        [ -n "$got" ] && { printf '%s\n' "$got"; return 0; }
        now="$(date +%s)"
        [ "$now" -lt "$deadline" ] || return 1
        sleep 1
    done
}
candidate_locks_acquire() {
    COORD_LOCK=""
    TEST_LOCK=""
    if [ "${ROUTER_EGRESS_COORDINATOR_LOCK_HELD:-0}" = 1 ]; then
        [ -d "$REG_LOCK_DIR/recovery-coordinator.lock" ] || return 1
        COORD_LOCK="caller"
    else
        COORD_LOCK="$(acquire_one_lock recovery-coordinator.lock provider-quality-test 2>/dev/null || true)"
        [ -n "$COORD_LOCK" ] || return 1
    fi
    TEST_LOCK="$(acquire_one_lock provider-quality-test.lock provider-quality-test 2>/dev/null || true)"
    if [ -z "$TEST_LOCK" ]; then
        [ "$COORD_LOCK" = caller ] || reg_lock_release "$COORD_LOCK" >/dev/null 2>&1 || true
        COORD_LOCK=""
        return 1
    fi
    return 0
}
candidate_locks_release() {
    [ -z "$TEST_LOCK" ] || reg_lock_release "$TEST_LOCK" >/dev/null 2>&1 || true
    [ -z "$COORD_LOCK" ] || [ "$COORD_LOCK" = caller ] || reg_lock_release "$COORD_LOCK" >/dev/null 2>&1 || true
    TEST_LOCK=""
    COORD_LOCK=""
}

cleanup_test_route() { ip route del default dev "$TEST_IFACE" metric 32760 2>/dev/null || true; }
cleanup_test_iface() {
    [ "$TEST_IFACE_OWNED" = true ] || return 0
    cleanup_test_route
    [ "$LEAVE_UP" = 1 ] || ifdown "$TEST_IFACE" 2>/dev/null || true
    TEST_IFACE_OWNED=false
}
cleanup_all() {
    cleanup_test_iface
    candidate_locks_release
}
trap 'cleanup_all' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Build a deterministic candidate universe. Daily quality runs may add all active
# source configs so the current five are measured in the same cycle. Exact
# identities are deduplicated before any temporary interface can be loaded.
# Active configs go first. If the provider publishes the same cryptographic
# tunnel with a rotated endpoint, identity dedupe keeps the active config as the
# measured row and never loads the fresh variant alongside it.
: >"$RAW_LIST"
if [ "$INCLUDE_ACTIVE" = 1 ]; then
    for ifx in vpn1 vpn2 vpn3 vpn4 vpn5; do
        cfg="$(active_source_config "$ifx")"
        [ -r "$cfg" ] && printf '%s\n' "$cfg" >>"$RAW_LIST"
    done
fi
find -L "$CONFIG_DIR" -type f -name '*.conf' | sort >>"$RAW_LIST"
: >"$CANDIDATES"
: >"$SEEN_IDS"
while IFS= read -r conf; do
    [ -f "$conf" ] || continue
    ident="$("$IDENTITY_BIN" "$conf" 2>/dev/null || true)"
    if [ -n "$ident" ]; then
        grep -Fqx "$ident" "$SEEN_IDS" 2>/dev/null && continue
        printf '%s\n' "$ident" >>"$SEEN_IDS"
    fi
    printf '%s\t%s\n' "${ident:--}" "$conf" >>"$CANDIDATES"
done <"$RAW_LIST"
TOTAL="$(wc -l <"$CANDIDATES" | tr -d ' ')"

rtt_one() {
    dev="$1"; target="$2"; out="$3"
    ping -4 -I "$dev" -c "$RTT_COUNT" -W "$RTT_TIMEOUT" "$target" >"$out" 2>&1 || true
}
measure_rtt() {
    dev="$1"; prefix="$2"
    p1="$prefix.ping1"; p2="$prefix.ping2"
    rtt_one "$dev" 1.1.1.1 "$p1" &
    rtt_one "$dev" 8.8.8.8 "$p2" &
    wait || true
    loss1="$(sed -n 's/.* \([0-9][0-9]*%\) packet loss.*/\1/p' "$p1" | tail -n1)"; [ -n "$loss1" ] || loss1=100%
    loss2="$(sed -n 's/.* \([0-9][0-9]*%\) packet loss.*/\1/p' "$p2" | tail -n1)"; [ -n "$loss2" ] || loss2=100%
    avg1="$(sed -n 's/^round-trip min\/avg\/max = [^\/]*\/\([^\/]*\)\/.*/\1/p' "$p1" | tail -n1)"
    avg2="$(sed -n 's/^round-trip min\/avg\/max = [^\/]*\/\([^\/]*\)\/.*/\1/p' "$p2" | tail -n1)"
    avg="$(awk -v a="$avg1" -v b="$avg2" 'BEGIN{n=0;s=0;if(a~/^[0-9.]+$/){s+=a;n++}if(b~/^[0-9.]+$/){s+=b;n++}if(n)printf "%.3f",s/n;else printf "-"}')"
    printf '1.1.1.1:%s,8.8.8.8:%s|%s\n' "$loss1" "$loss2" "$avg"
}
measure_throughput() {
    dev="$1"; out="$2"; rc=0
    url="${THROUGHPUT_URL_BASE}?bytes=${THROUGHPUT_BYTES}"
    line="$("$CURL_BIN" -4 --http1.1 --interface "$dev" --connect-timeout 3 --max-time "$THROUGHPUT_MAX_TIME" --silent --show-error --output /dev/null --write-out '%{http_code},%{speed_download},%{size_download},%{time_total},%{remote_ip}' "$url" 2>/dev/null)" || rc=$?
    [ -n "$line" ] || line='000,0,0,0,-'
    printf '%s,%s\n' "$rc" "$line" >"$out"
    http="${line%%,*}"; rest="${line#*,}"; speed="${rest%%,*}"; rest="${rest#*,}"; size="${rest%%,*}"
    min_size=$((THROUGHPUT_BYTES * 9 / 10))
    case "$speed:$size" in *[!0-9.:]*) return 1 ;; esac
    [ "$rc" -eq 0 ] && [ "$http" = 200 ] && awk -v s="$speed" -v n="$size" -v min="$min_size" 'BEGIN{exit !(s>0 && n>=min)}'
}

printf 'status\tfile\tendpoint\ttunnel_id\tactive_iface\thttps_quorum\thttps_google\thttps_cloudflare\thttps_mozilla\tping_loss\tping_rtt_avg\tthroughput_bps\tconfig_path\tshow_file\tdetail_file\n' >"$RESULTS"
TAB="$(printf '\t')"
N=0; OK=0; FAIL=0; LOCK_BUSY=0; INCOMPLETE=0; ACTIVE_REUSED=0; TEMP_TESTED=0
while IFS="$TAB" read -r PRE_ID CONF; do
    [ -n "$CONF" ] || continue
    N=$((N+1)); FILE="$(basename "$CONF")"; ENDPOINT="$(get_conf_endpoint "$CONF")"; ID="$PRE_ID"
    [ "$ID" != '-' ] || ID=""
    [ -n "$ID" ] || ID="$("$IDENTITY_BIN" "$CONF" 2>/dev/null || true)"
    DETAIL="$RUN_DIR/${N}-${FILE}.quality.txt"; SHOW="$RUN_DIR/${N}-${FILE}.show.txt"; LOAD_LOG="$RUN_DIR/${N}-${FILE}.load.txt"
    echo "[$N/$TOTAL] $FILE endpoint=$ENDPOINT"
    if [ -z "$ID" ]; then
        printf 'FAIL_IDENTITY\t%s\t%s\t-\t-\t0/3\t-\t-\t-\t-\t-\t0\t%s\t%s\t%s\n' "$FILE" "$ENDPOINT" "$CONF" "$SHOW" "$DETAIL" >>"$RESULTS"
        FAIL=$((FAIL+1)); continue
    fi

    if ! candidate_locks_acquire; then
        printf 'FAIL_LOCK_BUSY\t%s\t%s\t%s\t-\t0/3\t-\t-\t-\t-\t-\t0\t%s\t%s\t%s\n' "$FILE" "$ENDPOINT" "$ID" "$CONF" "$SHOW" "$DETAIL" >>"$RESULTS"
        LOCK_BUSY=$((LOCK_BUSY+1))
        FAIL=$((FAIL+1)); continue
    fi

    # Identity is resolved again under the coordinator lock. This closes the
    # repair/provider-test race required by the singleton invariant.
    if ! active_identities_readable || [ "$("$IDENTITY_BIN" "$CONF" 2>/dev/null || true)" != "$ID" ]; then
        printf 'FAIL_IDENTITY_SNAPSHOT\t%s\t%s\t%s\t-\t0/3\t-\t-\t-\t-\t-\t0\t%s\t%s\t%s\n' "$FILE" "$ENDPOINT" "$ID" "$CONF" "$SHOW" "$DETAIL" >>"$RESULTS"
        FAIL=$((FAIL+1)); INCOMPLETE=$((INCOMPLETE+1)); candidate_locks_release; continue
    fi
    DEV="$(find_active_iface_by_identity "$ID" 2>/dev/null || true)"
    ACTIVE_IFACE="$DEV"
    if [ -n "$DEV" ]; then
        ACTIVE_REUSED=$((ACTIVE_REUSED+1))
        echo "  exact tunnel already active on $DEV; reuse existing interface"
    else
        DEV="$TEST_IFACE"; ACTIVE_IFACE='-'
        TEMP_TESTED=$((TEMP_TESTED+1))
        TEST_IFACE_OWNED=true
        ifdown "$TEST_IFACE" 2>/dev/null || true; cleanup_test_route
        if ! "$LOADER" "$CONF" >"$LOAD_LOG" 2>&1; then
            printf 'FAIL_LOAD\t%s\t%s\t%s\t-\t0/3\t-\t-\t-\t-\t-\t0\t%s\t%s\t%s\n' "$FILE" "$ENDPOINT" "$ID" "$CONF" "$SHOW" "$DETAIL" >>"$RESULTS"
            FAIL=$((FAIL+1)); cleanup_test_iface; candidate_locks_release; continue
        fi
        ifup "$TEST_IFACE" >"$RUN_DIR/${N}-${FILE}.ifup.log" 2>&1 || true
        sleep "$WAIT_SECONDS"
        ip route replace default dev "$TEST_IFACE" metric 32760 2>/dev/null || true
    fi

    HTTPS_LINE="$("$HTTPS_ORACLE" --iface "$DEV" 2>/dev/null || true)"
    HTTPS_Q="$(printf '%s\n' "$HTTPS_LINE" | sed -n 's/.* quorum=\([0-9]\)\/3.*/\1/p')"; [ -n "$HTTPS_Q" ] || HTTPS_Q=0
    G="$(printf '%s\n' "$HTTPS_LINE" | sed -n 's/.* google=\([^ ]*\).*/\1/p')"; [ -n "$G" ] || G='-'
    C="$(printf '%s\n' "$HTTPS_LINE" | sed -n 's/.* cloudflare=\([^ ]*\).*/\1/p')"; [ -n "$C" ] || C='-'
    M="$(printf '%s\n' "$HTTPS_LINE" | sed -n 's/.* mozilla=\([^ ]*\).*/\1/p')"; [ -n "$M" ] || M='-'
    RTT="$(measure_rtt "$DEV" "$RUN_DIR/${N}-${FILE}")"; LOSS="${RTT%%|*}"; AVG="${RTT#*|}"
    THR_FILE="$RUN_DIR/${N}-${FILE}.throughput.txt"; THR_OK=false
    if [ "$HTTPS_Q" -ge 2 ] && measure_throughput "$DEV" "$THR_FILE"; then THR_OK=true; fi
    THR_LINE="$(cat "$THR_FILE" 2>/dev/null || echo '1,000,0,0,0,-')"; THR_REST="${THR_LINE#*,}"; THR_REST="${THR_REST#*,}"; THR_SPEED="${THR_REST%%,*}"
    case "$THR_SPEED" in ''|*[!0-9.]*) THR_SPEED=0 ;; esac
    THR_SPEED="$(awk -v s="$THR_SPEED" 'BEGIN{if(s+0>0) printf "%.0f",(s+0)*8; else printf "0"}')"
    "$AWGSHOW" show "$DEV" >"$SHOW" 2>&1 || true
    {
        echo "https=$HTTPS_LINE"; echo "rtt=$RTT"; echo "throughput=$THR_LINE"; echo "device=$DEV"; echo "active_iface=$ACTIVE_IFACE"; echo "tunnel_id=$ID"
    } >"$DETAIL"
    if [ "$HTTPS_Q" -lt 2 ]; then STATUS=FAIL_HTTPS
    elif [ "$THR_OK" != true ]; then STATUS=FAIL_THROUGHPUT
    else STATUS=OK; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s/3\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$STATUS" "$FILE" "$ENDPOINT" "$ID" "$ACTIVE_IFACE" "$HTTPS_Q" "$G" "$C" "$M" "$LOSS" "$AVG" "$THR_SPEED" "$CONF" "$SHOW" "$DETAIL" >>"$RESULTS"
    [ "$STATUS" = OK ] && OK=$((OK+1)) || FAIL=$((FAIL+1))

    [ "$DEV" != "$TEST_IFACE" ] || cleanup_test_iface
    candidate_locks_release
    sleep 1
done <"$CANDIDATES"
cleanup_all

if [ "$LOCK_BUSY" -gt 0 ] || [ "$INCOMPLETE" -gt 0 ]; then echo "RESULT=STOP_HMN_PROVIDER_QUALITY_INCOMPLETE"
else echo "RESULT=PASS_HMN_PROVIDER_QUALITY_TEST"; fi
echo "RESULTS=$RESULTS"
echo "TOTAL=$TOTAL"
echo "OK=$OK"
echo "FAIL=$FAIL"
echo "ACTIVE_REUSED=$ACTIVE_REUSED"
echo "TEMP_TESTED=$TEMP_TESTED"
echo "INCLUDE_ACTIVE=$INCLUDE_ACTIVE"
[ "$LOCK_BUSY" -eq 0 ] && [ "$INCOMPLETE" -eq 0 ]
