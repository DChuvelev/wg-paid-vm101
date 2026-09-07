#!/bin/ash
# Daily HMN provider refresh / quality ranking / bounded best-5 optimizer.
# R21B: service-driven 04:20 UTC maintenance, distinct from repair/full refresh.
set -u
umask 077
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

CONF="${ROUTER_EGRESS_VM101_CONF:-/etc/router-egress-vm101.conf}"
STATE_HELPER="${ROUTER_EGRESS_RECOVERY_STATE_HELPER:-/usr/local/lib/router-egress-recovery-state.sh}"
HEALTH_INIT="${ROUTER_EGRESS_HEALTH_SERVICE:-/etc/init.d/router-egress-health-repair}"
HTTPS_ORACLE="${HTTPS_HEALTH_ORACLE:-/usr/local/lib/router-egress-https-health.sh}"
IDENTITY_BIN="${HMN_TUNNEL_IDENTITY:-/usr/local/lib/router-egress-hmn-identity.sh}"
SLOT_CORE="${ROUTER_EGRESS_HMN_SLOT_CORE:-/usr/local/lib/router-egress-hmn-slot-replace.sh}"
PLAN_HELPER="${ROUTER_EGRESS_DAILY_QUALITY_PLAN_HELPER:-/usr/local/lib/router-egress-daily-quality-plan.sh}"

[ -r "$CONF" ] || { echo RESULT=STOP_R21B_DAILY_CONFIG_MISSING; exit 20; }
. "$CONF"
[ -r "$STATE_HELPER" ] || { echo RESULT=STOP_R21B_DAILY_STATE_HELPER_MISSING; exit 20; }
. "$STATE_HELPER"

ENABLED="${DAILY_QUALITY_ENABLED:-0}"
OPTIMIZER_ENABLED="${DAILY_QUALITY_OPTIMIZER_ENABLED:-1}"
SCHEDULE="${DAILY_QUALITY_SCHEDULE_HHMM_UTC:-0420}"
TICK_SEC="${DAILY_QUALITY_TICK_SEC:-30}"
CATCHUP_MIN="${DAILY_QUALITY_CATCHUP_WINDOW_MIN:-180}"
RETRY_INTERVAL="${DAILY_QUALITY_RETRY_INTERVAL_SEC:-1800}"
MAX_RETRIES="${DAILY_QUALITY_MAX_RETRIES:-3}"
MIN_GAIN_PCT="${DAILY_QUALITY_MIN_GAIN_PCT:-25}"
MIN_GAIN_BPS="${DAILY_QUALITY_MIN_GAIN_BPS:-15000000}"
MAX_REPLACEMENTS="${DAILY_QUALITY_MAX_REPLACEMENTS:-5}"
MIN_ELIGIBLE="${DAILY_QUALITY_MIN_ELIGIBLE:-5}"
DQ_STATE_DIR="${DAILY_QUALITY_STATE_DIR:-/var/lib/router-egress-recovery/daily-quality}"
DQ_LOG="${DAILY_QUALITY_LOG:-/var/log/router-egress-daily-quality.log}"

DOWNLOAD="${PROVIDER_DOWNLOAD_CMD:-/root/hmn/hmn-download-all-awg.sh}"
TESTER="${PROVIDER_TEST_CMD:-/root/hmn/hmn-test-all-awg.sh}"
RANKER="${PROVIDER_RANK_CMD:-/root/hmn/hmn-rank-awg.sh}"
PROVIDER_ROOT="${PROVIDER_ROOT:-/root/hmn}"
QUALITY_POOL="$PROVIDER_ROOT/cache/ranked-awg1-quality-latest.tsv"
LAST_STATE="$DQ_STATE_DIR/last.kv"
RUNS_DIR="$DQ_STATE_DIR/runs"

RUN_MODE=loop
PLAN_ONLY=false
case "${1:---loop}" in
    --loop) RUN_MODE=loop ;;
    --run-now|--once) RUN_MODE=manual ;;
    --plan-only) RUN_MODE=manual; PLAN_ONLY=true ;;
    --status) RUN_MODE=status ;;
    *) echo 'Usage: router-egress-daily-quality.sh --loop|--run-now|--plan-only|--status' >&2; exit 64 ;;
esac

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
for value in "$TICK_SEC" "$CATCHUP_MIN" "$RETRY_INTERVAL" "$MAX_RETRIES" "$MIN_GAIN_PCT" "$MIN_GAIN_BPS" "$MAX_REPLACEMENTS" "$MIN_ELIGIBLE"; do
    is_uint "$value" || { echo RESULT=STOP_R21B_DAILY_NUMERIC_CONFIG; exit 20; }
done
[ "$TICK_SEC" -gt 0 ] && [ "$MAX_REPLACEMENTS" -le 5 ] && [ "$MIN_ELIGIBLE" -ge 5 ] || { echo RESULT=STOP_R21B_DAILY_CONFIG_RANGE; exit 20; }
printf '%s\n' "$SCHEDULE" | grep -Eq '^[0-2][0-9][0-5][0-9]$' || { echo RESULT=STOP_R21B_DAILY_SCHEDULE_FORMAT; exit 20; }
HH="${SCHEDULE%??}"; MM="${SCHEDULE#??}"
[ "$HH" -le 23 ] || { echo RESULT=STOP_R21B_DAILY_SCHEDULE_HOUR; exit 20; }
SCHEDULE_MIN="$(awk -v h="$HH" -v m="$MM" 'BEGIN{print (h+0)*60+(m+0)}')"

for req in "$DOWNLOAD" "$TESTER" "$RANKER" "$HTTPS_ORACLE" "$IDENTITY_BIN" "$SLOT_CORE" "$PLAN_HELPER" "$HEALTH_INIT"; do
    [ -e "$req" ] || { echo RESULT=STOP_R21B_DAILY_REQUIRED_PATH; echo "PATH=$req"; exit 20; }
done

mkdir -p "$DQ_STATE_DIR" "$RUNS_DIR" "$(dirname "$DQ_LOG")" || exit 20
chmod 700 "$DQ_STATE_DIR" "$RUNS_DIR" 2>/dev/null || true

log_line() {
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" "$*" >>"$DQ_LOG" 2>/dev/null || true
}
state_get() {
    key="$1"; def="${2:-}"
    val="$(sed -n "s/^${key}=//p" "$LAST_STATE" 2>/dev/null | tail -n1)"
    [ -n "$val" ] && printf '%s\n' "$val" || printf '%s\n' "$def"
}
write_state() {
    result="$1"; reason="$2"; trigger="$3"; run_id="$4"; run_dir="$5"; results="$6"; pool="$7"; plan="$8"; replacements="$9"; retries="${10}"; next_retry="${11}"
    now="$(date +%s)"; today="$(date -u +%Y%m%d)"
    previous_success="$(state_get last_success_epoch 0)"
    case "$result" in PASS*) previous_success="$now" ;; esac
    tmp="${LAST_STATE}.new.$$"
    cat >"$tmp" <<EOF
schema=router-egress-daily-quality-state-v1
last_attempt_epoch=$now
last_attempt_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
last_schedule_date=$today
last_result=$result
last_reason=$reason
last_trigger=$trigger
last_run_id=$run_id
last_run_dir=$run_dir
last_results=$results
last_quality_pool=$pool
last_plan=$plan
last_replacements=$replacements
retry_count=$retries
next_retry_epoch=$next_retry
last_success_epoch=$previous_success
schedule_hhmm_utc=$SCHEDULE
optimizer_enabled=$OPTIMIZER_ENABLED
min_gain_pct=$MIN_GAIN_PCT
min_gain_bps=$MIN_GAIN_BPS
max_replacements=$MAX_REPLACEMENTS
EOF
    chmod 600 "$tmp"
    mv "$tmp" "$LAST_STATE"
}
prune_runs() {
    keep=14
    n=0
    for d in $(find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r); do
        n=$((n+1))
        [ "$n" -le "$keep" ] || rm -rf "$d"
    done
}
active_source() { uci -q get "network.${1}.hmn_source_config" 2>/dev/null || true; }
active_identity() {
    cfg="$(active_source "$1")"
    [ -r "$cfg" ] || return 1
    "$IDENTITY_BIN" "$cfg" 2>/dev/null
}
active_endpoint() { uci -q get "network.${1}.hmn_endpoint" 2>/dev/null || true; }
all_unique_active() {
    out="$1"; : >"$out"
    for ifx in vpn1 vpn2 vpn3 vpn4 vpn5; do
        ident="$(active_identity "$ifx" 2>/dev/null || true)"
        [ -n "$ident" ] || return 1
        printf '%s\t%s\n' "$ifx" "$ident" >>"$out"
    done
    [ "$(cut -f2 "$out" | sort -u | wc -l | tr -d ' ')" -eq 5 ]
}
find_provider_iface() {
    for ifx in vpn1 vpn2 vpn3 vpn4 vpn5; do
        "$HTTPS_ORACLE" --iface "$ifx" >/dev/null 2>&1 && { echo "$ifx"; return 0; }
    done
    return 1
}
lock_wait() {
    name="$1"; owner="$2"; wait_sec="${3:-60}"; deadline=$(( $(date +%s) + wait_sec ))
    while :; do
        got="$(reg_lock_acquire "$name" "$owner" 2>/dev/null || true)"
        [ -n "$got" ] && { printf '%s\n' "$got"; return 0; }
        now="$(date +%s)"
        [ "$now" -lt "$deadline" ] || return 1
        sleep 1
    done
}

DAILY_LOCK=""
COORD_LOCK=""
LOCAL_LOCK=""
HEALTH_STOPPED=false
PENDING_ROLLBACK=""
restart_health() {
    [ "$HEALTH_STOPPED" = true ] || return 0
    "$HEALTH_INIT" start >/dev/null 2>&1 || return 1
    dq_health_tries=0
    while [ "$dq_health_tries" -lt 5 ]; do
        if "$HEALTH_INIT" running >/dev/null 2>&1; then HEALTH_STOPPED=false; return 0; fi
        dq_health_tries=$((dq_health_tries + 1))
        sleep 1
    done
    return 1
}
rollback_pending() {
    [ -n "$PENDING_ROLLBACK" ] || return 0
    if [ -x "$PENDING_ROLLBACK" ] && "$PENDING_ROLLBACK" >>"$run_dir/rollback.log" 2>&1; then
        PENDING_ROLLBACK=""
        return 0
    fi
    log_line "event=rollback_failed run_id=$run_id"
    return 1
}
cleanup_locks() {
    rollback_pending || true
    restart_health || log_line event=health_restart_failed
    [ -z "$LOCAL_LOCK" ] || reg_lock_release "$LOCAL_LOCK" >/dev/null 2>&1 || true
    [ -z "$COORD_LOCK" ] || reg_lock_release "$COORD_LOCK" >/dev/null 2>&1 || true
    [ -z "$DAILY_LOCK" ] || reg_lock_release "$DAILY_LOCK" >/dev/null 2>&1 || true
    LOCAL_LOCK=""; COORD_LOCK=""; DAILY_LOCK=""
}
trap 'cleanup_locks' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

record_failure() {
    trigger="$1"; run_id="$2"; run_dir="$3"; reason="$4"; results="${5:-}"; pool="${6:-}"; plan="${7:-}"; replacements="${8:-0}"
    old_retries="$(state_get retry_count 0)"; is_uint "$old_retries" || old_retries=0
    if [ "$trigger" = retry ]; then retries=$((old_retries + 1)); else retries=1; fi
    next=0
    [ "$retries" -ge "$MAX_RETRIES" ] || next=$(( $(date +%s) + RETRY_INTERVAL ))
    write_state FAILED "$reason" "$trigger" "$run_id" "$run_dir" "$results" "$pool" "$plan" "$replacements" "$retries" "$next"
    log_line "result=FAILED reason=$reason trigger=$trigger run_id=$run_id retries=$retries next_retry_epoch=$next"
}

run_once() {
    trigger="$1"; plan_only="$2"
    [ "$ENABLED" = 1 ] || { echo RESULT=NOOP_R21B_DAILY_DISABLED; return 0; }

    run_id="dq-$(date -u +%Y%m%d-%H%M%S)-$$"
    run_dir="$RUNS_DIR/$run_id"
    mkdir -p "$run_dir" || { echo RESULT=STOP_R21B_DAILY_RUN_DIR; return 1; }
    chmod 700 "$run_dir"
    results=""; plan="$run_dir/plan.tsv"; replacements=0

    DAILY_LOCK="$(lock_wait daily-quality.lock daily-quality 2 2>/dev/null || true)"
    if [ -z "$DAILY_LOCK" ]; then
        echo RESULT=NOOP_R21B_DAILY_ALREADY_RUNNING
        rm -rf "$run_dir"
        return 0
    fi

    # Another scheduler may have finished after this loop observed last.kv.
    # Recheck under the singleton so each due attempt is consumed only once.
    dq_today="$(date -u +%Y%m%d)"
    dq_last_date="$(state_get last_schedule_date '')"
    dq_next_retry="$(state_get next_retry_epoch 0)"
    is_uint "$dq_next_retry" || dq_next_retry=0
    if { [ "$trigger" = scheduled ] && [ "$dq_last_date" = "$dq_today" ]; } ||
       { [ "$trigger" = retry ] && { [ "$dq_last_date" != "$dq_today" ] || [ "$dq_next_retry" -eq 0 ] || [ "$(date +%s)" -lt "$dq_next_retry" ]; }; }; then
        cleanup_locks
        rm -rf "$run_dir"
        echo RESULT=NOOP_R21B_DAILY_ATTEMPT_ALREADY_CONSUMED
        return 0
    fi

    mode="$(reg_get_state mode NORMAL 2>/dev/null || echo NORMAL)"
    if [ "$mode" != NORMAL ] || [ -d "$REG_LOCK_DIR/full-pool-refresh.lock" ]; then
        record_failure "$trigger" "$run_id" "$run_dir" recovery_mode_busy
        cleanup_locks
        echo RESULT=DEFER_R21B_DAILY_RECOVERY_BUSY
        return 1
    fi

    provider_iface="$(find_provider_iface 2>/dev/null || true)"
    if [ -z "$provider_iface" ]; then
        record_failure "$trigger" "$run_id" "$run_dir" no_https_healthy_provider_iface
        cleanup_locks
        echo RESULT=STOP_R21B_DAILY_NO_PROVIDER_IFACE
        return 1
    fi

    log_line "event=start trigger=$trigger run_id=$run_id provider_iface=$provider_iface plan_only=$plan_only"

    if ! HMN_REQUEST_IFACE="$provider_iface" "$DOWNLOAD" >"$run_dir/provider-download.log" 2>&1; then
        record_failure "$trigger" "$run_id" "$run_dir" provider_download_failed
        cleanup_locks
        cat "$run_dir/provider-download.log"
        echo RESULT=STOP_R21B_DAILY_PROVIDER_DOWNLOAD
        return 1
    fi
    config_dir="$(readlink -f "$PROVIDER_ROOT/configs/awg1/latest" 2>/dev/null || true)"
    if [ -z "$config_dir" ] || [ ! -d "$config_dir" ]; then
        record_failure "$trigger" "$run_id" "$run_dir" provider_config_dir_invalid
        cleanup_locks
        echo RESULT=STOP_R21B_DAILY_CONFIG_DIR
        return 1
    fi

    if ! HMN_TEST_INCLUDE_ACTIVE=1 "$TESTER" "$config_dir" >"$run_dir/provider-test.log" 2>&1; then
        record_failure "$trigger" "$run_id" "$run_dir" provider_test_failed
        cleanup_locks
        cat "$run_dir/provider-test.log"
        echo RESULT=STOP_R21B_DAILY_PROVIDER_TEST
        return 1
    fi
    results="$(sed -n 's/^RESULTS=//p' "$run_dir/provider-test.log" | tail -n1)"
    expected_header='status	file	endpoint	tunnel_id	active_iface	https_quorum	https_google	https_cloudflare	https_mozilla	ping_loss	ping_rtt_avg	throughput_bps	config_path	show_file	detail_file'
    if [ -z "$results" ] || [ ! -s "$results" ] || [ "$(head -n1 "$results")" != "$expected_header" ]; then
        record_failure "$trigger" "$run_id" "$run_dir" provider_results_schema_invalid "$results"
        cleanup_locks
        echo RESULT=STOP_R21B_DAILY_RESULTS_SCHEMA
        return 1
    fi

    ok_count="$(awk -F '\t' 'NR>1 && $1=="OK" && $6 ~ /^[23]\/3$/ && $12 ~ /^[0-9]+$/ && $12+0>0 {n++} END{print n+0}' "$results")"
    if [ "$ok_count" -lt "$MIN_ELIGIBLE" ]; then
        record_failure "$trigger" "$run_id" "$run_dir" insufficient_quality_candidates "$results"
        cleanup_locks
        echo RESULT=STOP_R21B_DAILY_INSUFFICIENT_QUALITY
        echo "OK_COUNT=$ok_count"
        return 1
    fi

    if ! CONFIG_DIR="$config_dir" HMN_RANK_MIN_CANDIDATES="$MIN_ELIGIBLE" "$RANKER" "$results" >"$run_dir/provider-rank.log" 2>&1; then
        record_failure "$trigger" "$run_id" "$run_dir" provider_rank_failed "$results"
        cleanup_locks
        cat "$run_dir/provider-rank.log"
        echo RESULT=STOP_R21B_DAILY_PROVIDER_RANK
        return 1
    fi
    [ -s "$QUALITY_POOL" ] || {
        record_failure "$trigger" "$run_id" "$run_dir" quality_pool_missing "$results"
        cleanup_locks
        echo RESULT=STOP_R21B_DAILY_QUALITY_POOL
        return 1
    }
    quality_pool="$run_dir/ranked-quality.tsv"
    if ! cp "$QUALITY_POOL" "$quality_pool"; then
        record_failure "$trigger" "$run_id" "$run_dir" quality_pool_snapshot_failed "$results"
        cleanup_locks
        echo RESULT=STOP_R21B_DAILY_QUALITY_POOL_SNAPSHOT
        return 1
    fi

    # A daily cycle compares against the same active identities that were
    # measured. If any active slot lacked a usable quality row, publish the
    # fresh pool but leave the active five untouched.
    active_ok="$(awk -F '\t' 'NR>1 && $1=="OK" && $5 ~ /^vpn[1-5]$/ {seen[$5]=1} END{for(k in seen)n++; print n+0}' "$results")"
    if [ "$active_ok" -ne 5 ]; then
        write_state PASS_REFRESH_OPTIMIZER_SKIPPED active_quality_incomplete "$trigger" "$run_id" "$run_dir" "$results" "$quality_pool" "$plan" 0 0 0
        reg_event_append daily_quality PASS "$run_id" "" "" "" "" "" active_quality_incomplete "" "" "quality_pool=$quality_pool" >/dev/null 2>&1 || true
        cleanup_locks
        prune_runs
        echo RESULT=PASS_R21B_DAILY_REFRESH_OPTIMIZER_SKIPPED
        echo REASON=active_quality_incomplete
        echo "RESULTS=$results"
        echo "QUALITY_POOL=$quality_pool"
        return 0
    fi

    # Acquire mutation ownership only after the expensive provider work is
    # finished. The daily-quality lock keeps full refresh from starting; the
    # coordinator/local locks serialize with repair for the short plan/apply phase.
    COORD_LOCK="$(lock_wait recovery-coordinator.lock daily-quality-optimize 60 2>/dev/null || true)"
    if [ -z "$COORD_LOCK" ]; then
        write_state PASS_REFRESH_OPTIMIZER_SKIPPED coordinator_busy "$trigger" "$run_id" "$run_dir" "$results" "$quality_pool" "$plan" 0 0 0
        cleanup_locks
        prune_runs
        echo RESULT=PASS_R21B_DAILY_REFRESH_OPTIMIZER_SKIPPED
        echo REASON=coordinator_busy
        return 0
    fi
    LOCAL_LOCK="$(lock_wait local-repair.lock daily-quality-optimize 60 2>/dev/null || true)"
    if [ -z "$LOCAL_LOCK" ]; then
        write_state PASS_REFRESH_OPTIMIZER_SKIPPED local_repair_busy "$trigger" "$run_id" "$run_dir" "$results" "$quality_pool" "$plan" 0 0 0
        cleanup_locks
        prune_runs
        echo RESULT=PASS_R21B_DAILY_REFRESH_OPTIMIZER_SKIPPED
        echo REASON=local_repair_busy
        return 0
    fi

    mode="$(reg_get_state mode NORMAL 2>/dev/null || echo NORMAL)"
    [ "$mode" = NORMAL ] || {
        write_state PASS_REFRESH_OPTIMIZER_SKIPPED recovery_mode_changed "$trigger" "$run_id" "$run_dir" "$results" "$quality_pool" "$plan" 0 0 0
        cleanup_locks
        prune_runs
        echo RESULT=PASS_R21B_DAILY_REFRESH_OPTIMIZER_SKIPPED
        echo REASON=recovery_mode_changed
        return 0
    }

    expected_ids="$run_dir/expected-active.tsv"
    current_ids="$run_dir/current-active.tsv"
    : >"$expected_ids"
    for ifx in vpn1 vpn2 vpn3 vpn4 vpn5; do
        eid="$(awk -F '\t' -v x="$ifx" 'NR>1 && $1=="OK" && $5==x {print $4; exit}' "$results")"
        [ -n "$eid" ] || {
            write_state PASS_REFRESH_OPTIMIZER_SKIPPED active_identity_not_measured "$trigger" "$run_id" "$run_dir" "$results" "$quality_pool" "$plan" 0 0 0
            cleanup_locks
            prune_runs
            echo RESULT=PASS_R21B_DAILY_REFRESH_OPTIMIZER_SKIPPED
            echo REASON=active_identity_not_measured
            return 0
        }
        printf '%s\t%s\n' "$ifx" "$eid" >>"$expected_ids"
    done
    if ! all_unique_active "$current_ids" || ! cmp -s "$expected_ids" "$current_ids"; then
        write_state PASS_REFRESH_OPTIMIZER_SKIPPED active_identity_changed_during_test "$trigger" "$run_id" "$run_dir" "$results" "$quality_pool" "$plan" 0 0 0
        cleanup_locks
        prune_runs
        echo RESULT=PASS_R21B_DAILY_REFRESH_OPTIMIZER_SKIPPED
        echo REASON=active_identity_changed_during_test
        return 0
    fi

    # Derive the measured target best-5 and a hysteresis-limited minimal plan.
    head -n 6 "$quality_pool" >"$run_dir/target-best5.tsv"
    active_work="$run_dir/active-work.tsv"
    : >"$active_work"
    for ifx in vpn1 vpn2 vpn3 vpn4 vpn5; do
        eid="$(awk -F '\t' -v x="$ifx" '$1==x{print $2}' "$expected_ids")"
        qrow="$(awk -F '\t' -v id="$eid" 'NR>1 && $6==id {print; exit}' "$quality_pool")"
        [ -n "$qrow" ] || {
            write_state PASS_REFRESH_OPTIMIZER_SKIPPED active_missing_from_quality_pool "$trigger" "$run_id" "$run_dir" "$results" "$quality_pool" "$plan" 0 0 0
            cleanup_locks
            prune_runs
            echo RESULT=PASS_R21B_DAILY_REFRESH_OPTIMIZER_SKIPPED
            echo REASON=active_missing_from_quality_pool
            return 0
        }
        thr="$(printf '%s\n' "$qrow" | cut -f2)"
        rtt="$(printf '%s\n' "$qrow" | cut -f3)"
        endpoint="$(printf '%s\n' "$qrow" | cut -f5)"
        cfg="$(printf '%s\n' "$qrow" | cut -f8)"
        slot="egress${ifx#vpn}"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ifx" "$slot" "$thr" "$rtt" "$eid" "$endpoint" "$cfg" >>"$active_work"
    done
    # The pure helper derives the hysteresis-limited minimal replacement plan.
    if ! "$PLAN_HELPER" "$active_work" "$quality_pool" "$plan" "$MIN_GAIN_PCT" "$MIN_GAIN_BPS" "$MAX_REPLACEMENTS" >"$run_dir/planner.log" 2>&1; then
        record_failure "$trigger" "$run_id" "$run_dir" planner_failed "$results" "$quality_pool" "$plan" 0
        cleanup_locks
        cat "$run_dir/planner.log"
        echo RESULT=STOP_R21B_DAILY_PLANNER
        return 1
    fi
    plan_count="$(sed -n 's/^PLAN_COUNT=//p' "$run_dir/planner.log" | tail -n1)"
    is_uint "$plan_count" || plan_count=0

    if [ "$plan_count" -eq 0 ] || [ "$plan_only" = true ] || [ "$OPTIMIZER_ENABLED" != 1 ]; then
        reason=already_good_or_below_hysteresis
        [ "$plan_count" -gt 0 ] && [ "$plan_only" = true ] && reason=plan_only
        [ "$plan_count" -gt 0 ] && [ "$OPTIMIZER_ENABLED" != 1 ] && reason=optimizer_disabled
        write_state PASS "$reason" "$trigger" "$run_id" "$run_dir" "$results" "$quality_pool" "$plan" 0 0 0
        reg_event_append daily_quality PASS "$run_id" "" "" "" "" "" "$reason" "" "" "plan_count=$plan_count quality_pool=$quality_pool" >/dev/null 2>&1 || true
        cleanup_locks
        prune_runs
        echo RESULT=PASS_R21B_DAILY_QUALITY
        echo "REASON=$reason"
        echo "RESULTS=$results"
        echo "QUALITY_POOL=$quality_pool"
        echo "TARGET_BEST5=$run_dir/target-best5.tsv"
        echo "PLAN=$plan"
        echo "PLAN_COUNT=$plan_count"
        echo REPLACEMENTS=0
        return 0
    fi

    "$HEALTH_INIT" running >/dev/null 2>&1 || {
        write_state PASS_REFRESH_OPTIMIZER_SKIPPED health_service_not_running "$trigger" "$run_id" "$run_dir" "$results" "$quality_pool" "$plan" 0 0 0
        cleanup_locks
        prune_runs
        echo RESULT=PASS_R21B_DAILY_REFRESH_OPTIMIZER_SKIPPED
        echo REASON=health_service_not_running
        return 0
    }
    HEALTH_STOPPED=true
    "$HEALTH_INIT" stop >/dev/null 2>&1 || {
        record_failure "$trigger" "$run_id" "$run_dir" health_service_stop_failed "$results" "$quality_pool" "$plan" 0
        cleanup_locks
        echo RESULT=STOP_R21B_DAILY_HEALTH_STOP
        return 1
    }
    sleep 1

    counter_before="$(reg_repair_events_get 2>/dev/null || echo 0)"
    quarantine_before="$(sha256sum "$REG_QUARANTINE_TSV" 2>/dev/null | awk '{print $1}')"

    apply_failed=false
    apply_rc=0
    TAB="$(printf '\t')"
    exec 3<"$plan"
    IFS= read -r plan_header <&3
    while IFS="$TAB" read -r pseq slot ifx old_id old_thr old_rtt new_id new_thr new_rtt new_ep new_cfg gain gain_pct <&3; do
        current_id="$(active_identity "$ifx" 2>/dev/null || true)"
        [ "$current_id" = "$old_id" ] || { echo "APPLY_STOP=slot_identity_changed slot=$slot iface=$ifx" >>"$run_dir/apply.log"; apply_rc=91; break; }

        for aif in vpn1 vpn2 vpn3 vpn4 vpn5; do
            aid="$(active_identity "$aif" 2>/dev/null || true)"
            [ "$aid" != "$new_id" ] || { echo "APPLY_STOP=candidate_identity_already_active candidate=$new_id iface=$aif" >>"$run_dir/apply.log"; apply_rc=92; break; }
        done
        [ "$apply_rc" -eq 0 ] || break

        pool="candidate-${pseq}.tsv"
        {
            printf 'rank\tavg_ms\tfile\tendpoint\tloss\tconfig_path\n'
            printf '1\t%010.3f\t%s\t%s\t0%%\t%s\n' "$new_rtt" "$(basename "$new_cfg")" "$new_ep" "$new_cfg"
        } >"$run_dir/$pool"
        chmod 600 "$run_dir/$pool"
        confirm="APPLY_${slot}_${ifx}_${new_ep}"

        if ROUTER_EGRESS_HMN_CACHE_DIR_OVERRIDE="$run_dir" \
           ROUTER_EGRESS_HMN_PREFERRED_POOL_FILES_OVERRIDE="$pool" \
           ROUTER_EGRESS_COORDINATOR_LOCK_HELD=1 \
           ROUTER_EGRESS_LOCAL_REPAIR_LOCK_HELD=1 \
           HMN_SLOT_REPLACE_QUARANTINE_FAILED_CANDIDATE=0 \
           LOCAL_REPAIR_CANDIDATE_RETRIES=1 \
           "$SLOT_CORE" --commit --slot "$slot" --confirm "$confirm" >"$run_dir/apply-${pseq}.json" 2>"$run_dir/apply-${pseq}.err"; then
            arc=0
        else
            arc=$?
        fi
        decision="$(sed -n 's/.*"decision": "\([^"]*\)".*/\1/p' "$run_dir/apply-${pseq}.json" | tail -n1)"
        if [ "$arc" -ne 0 ] || [ "$decision" != commit_ok ]; then
            echo "APPLY_STOP=candidate_apply_failed seq=$pseq slot=$slot rc=$arc decision=$decision" >>"$run_dir/apply.log"
            apply_rc=93; break
        fi
        PENDING_ROLLBACK="$(sed -n 's/.*"rollback_file": "\([^"]*\)".*/\1/p' "$run_dir/apply-${pseq}.json" | tail -n1)"
        after_id="$(active_identity "$ifx" 2>/dev/null || true)"
        [ "$after_id" = "$new_id" ] || { echo "APPLY_STOP=post_identity_mismatch seq=$pseq slot=$slot" >>"$run_dir/apply.log"; apply_rc=94; break; }
        "$HTTPS_ORACLE" --iface "$ifx" >"$run_dir/post-https-${pseq}.log" 2>&1 || { echo "APPLY_STOP=post_https_failed seq=$pseq slot=$slot" >>"$run_dir/apply.log"; apply_rc=95; break; }
        PENDING_ROLLBACK=""
        echo 0 >"$REG_STATE_DIR/health-watch/fail-$slot" 2>/dev/null || true
        echo "APPLY_PASS=seq=$pseq slot=$slot iface=$ifx old_id=$old_id new_id=$new_id gain_bps=$gain gain_pct=$gain_pct" >>"$run_dir/apply.log"
    done
    exec 3<&-
    if [ "$apply_rc" -ne 0 ]; then apply_failed=true; fi
    rollback_pending || apply_failed=true

    if ! restart_health; then
        record_failure "$trigger" "$run_id" "$run_dir" health_service_restart_failed "$results" "$quality_pool" "$plan" 0
        cleanup_locks
        echo RESULT=STOP_R21B_DAILY_HEALTH_RESTART
        return 1
    fi

    replacements="$(grep -c '^APPLY_PASS=' "$run_dir/apply.log" 2>/dev/null || true)"
    counter_after="$(reg_repair_events_get 2>/dev/null || echo 0)"
    quarantine_after="$(sha256sum "$REG_QUARANTINE_TSV" 2>/dev/null | awk '{print $1}')"
    if [ "$counter_before" != "$counter_after" ] || [ "$quarantine_before" != "$quarantine_after" ]; then
        record_failure "$trigger" "$run_id" "$run_dir" repair_accounting_changed "$results" "$quality_pool" "$plan" "$replacements"
        cleanup_locks
        echo RESULT=STOP_R21B_DAILY_REPAIR_ACCOUNTING_CHANGED
        echo "COUNTER_BEFORE=$counter_before"
        echo "COUNTER_AFTER=$counter_after"
        return 1
    fi

    final_ids="$run_dir/final-active.tsv"
    if ! all_unique_active "$final_ids"; then
        record_failure "$trigger" "$run_id" "$run_dir" duplicate_active_identity "$results" "$quality_pool" "$plan" "$replacements"
        cleanup_locks
        echo RESULT=STOP_R21B_DAILY_DUPLICATE_IDENTITY
        return 1
    fi

    if [ "$apply_failed" = true ]; then
        record_failure "$trigger" "$run_id" "$run_dir" optimization_apply_failed "$results" "$quality_pool" "$plan" "$replacements"
        reg_event_append daily_quality FAILED "$run_id" "" "" "" "" "" optimization_apply_failed "" "" "replacements=$replacements" >/dev/null 2>&1 || true
        cleanup_locks
        echo RESULT=STOP_R21B_DAILY_OPTIMIZATION_APPLY
        echo "REPLACEMENTS=$replacements"
        cat "$run_dir/apply.log" 2>/dev/null || true
        return 1
    fi

    write_state PASS optimized "$trigger" "$run_id" "$run_dir" "$results" "$quality_pool" "$plan" "$replacements" 0 0
    reg_event_append daily_quality PASS "$run_id" "" "" "" "" "" optimized "" "" "replacements=$replacements quality_pool=$quality_pool" >/dev/null 2>&1 || true
    cleanup_locks
    prune_runs
    echo RESULT=PASS_R21B_DAILY_QUALITY
    echo REASON=optimized
    echo "RESULTS=$results"
    echo "QUALITY_POOL=$quality_pool"
    echo "TARGET_BEST5=$run_dir/target-best5.tsv"
    echo "PLAN=$plan"
    echo "PLAN_COUNT=$plan_count"
    echo "REPLACEMENTS=$replacements"
    echo "REPAIR_COUNTER_BEFORE=$counter_before"
    echo "REPAIR_COUNTER_AFTER=$counter_after"
    echo "QUARANTINE_UNCHANGED=true"
    return 0
}

if [ "$RUN_MODE" = status ]; then
    [ -s "$LAST_STATE" ] && cat "$LAST_STATE" || {
        echo schema=router-egress-daily-quality-state-v1
        echo last_result=NONE
        echo schedule_hhmm_utc="$SCHEDULE"
        echo optimizer_enabled="$OPTIMIZER_ENABLED"
    }
    exit 0
fi

if [ "$RUN_MODE" = manual ]; then
    if run_once manual "$PLAN_ONLY"; then exit 0; else exit $?; fi
fi

while :; do
    now="$(date +%s)"
    today="$(date -u +%Y%m%d)"
    hh="$(date -u +%H)"; mm="$(date -u +%M)"
    current_min="$(awk -v h="$hh" -v m="$mm" 'BEGIN{print (h+0)*60+(m+0)}')"
    last_date="$(state_get last_schedule_date '')"
    next_retry="$(state_get next_retry_epoch 0)"; is_uint "$next_retry" || next_retry=0
    retries="$(state_get retry_count 0)"; is_uint "$retries" || retries=0

    if [ "$next_retry" -gt 0 ] && [ "$now" -ge "$next_retry" ] && [ "$last_date" = "$today" ] && [ "$retries" -lt "$MAX_RETRIES" ]; then
        run_once retry false || true
    elif [ "$last_date" != "$today" ] && [ "$current_min" -ge "$SCHEDULE_MIN" ] && [ "$current_min" -lt $((SCHEDULE_MIN + CATCHUP_MIN)) ]; then
        run_once scheduled false || true
    fi
    sleep "$TICK_SEC"
done
