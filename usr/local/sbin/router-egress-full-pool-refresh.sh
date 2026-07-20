#!/bin/sh
# STEP_050M07R20C_DURABLE_DEGRADED_POOL_AND_CONTROLLED_RETRY
set -eu
umask 077

VM101_CONF="${ROUTER_EGRESS_VM101_CONF:-/etc/router-egress-vm101.conf}"
GENERATION_CONF="${GENERATION_CONF:-/etc/router-egress-generation.conf}"
STATE_HELPER="${ROUTER_EGRESS_RECOVERY_STATE_HELPER:-/usr/local/lib/router-egress-recovery-state.sh}"
BUILDER="${ROUTER_EGRESS_GENERATION_BUILDER:-/usr/local/sbin/router-egress-generation-build}"
VALIDATOR="${ROUTER_EGRESS_GENERATION_VALIDATOR:-/usr/local/sbin/router-egress-generation-validate}"
ACTIVATOR="${ROUTER_EGRESS_GENERATION_ACTIVATOR:-/usr/local/sbin/router-egress-generation-activate}"
RUN_MODE=--run-if-due
CONFIRM=""
NOW_EPOCH=""
SOURCE_STEP=STEP_050M07R20C_DURABLE_DEGRADED_POOL_AND_CONTROLLED_RETRY

usage() {
    echo "Usage: router-egress-full-pool-refresh.sh [--run-if-due | --retry | --force --confirm FULL_REFRESH_<ACTIVE_ID>] [--now-epoch EPOCH]"
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --run-if-due) RUN_MODE=--run-if-due ;;
        --retry) RUN_MODE=--retry ;;
        --force) RUN_MODE=--force ;;
        --confirm) shift; [ "$#" -gt 0 ] || { echo RESULT=STOP_R18_ARGUMENT_MISSING; exit 2; }; CONFIRM="$1" ;;
        --now-epoch) shift; [ "$#" -gt 0 ] || { echo RESULT=STOP_R18_ARGUMENT_MISSING; exit 2; }; NOW_EPOCH="$1" ;;
        --help|-h) usage; exit 0 ;;
        *) echo RESULT=STOP_R18_UNKNOWN_ARGUMENT; echo "ARGUMENT=$1"; exit 2 ;;
    esac
    shift
done

require_command() { command -v "$1" >/dev/null 2>&1 || { echo RESULT=STOP_R18_REQUIRED_COMMAND_MISSING; echo "MISSING_COMMAND=$1"; exit 20; }; }
for c in sh awk sed grep cut tr head tail wc sort find sha256sum cp mv rm mkdir rmdir chmod date readlink stat tar mkfifo tee kill sleep basename dirname env cat ln; do require_command "$c"; done
[ -r "$VM101_CONF" ] || { echo RESULT=STOP_R18_VM101_CONFIG_MISSING; exit 21; }
[ -r "$GENERATION_CONF" ] || { echo RESULT=STOP_R18_GENERATION_CONFIG_MISSING; exit 21; }
[ -r "$STATE_HELPER" ] || { echo RESULT=STOP_R18_STATE_HELPER_MISSING; exit 21; }
. "$VM101_CONF"
. "$GENERATION_CONF"
. "$STATE_HELPER"

DOWNLOAD="${PROVIDER_DOWNLOAD_CMD:-/root/hmn/hmn-download-all-awg.sh}"
TESTER="${PROVIDER_TEST_CMD:-/root/hmn/hmn-test-all-awg.sh}"
RANKER="${PROVIDER_RANK_CMD:-/root/hmn/hmn-rank-awg.sh}"
PROVIDER_ROOT="${PROVIDER_ROOT:-/root/hmn}"
FULL_REFRESH_AFTER_REPAIRS="${FULL_REFRESH_AFTER_REPAIRS:-5}"
FULL_POOL_REFRESH_ENABLED="${FULL_POOL_REFRESH_ENABLED:-false}"
HMN_REFRESH_RETRY_INTERVAL_SEC="${HMN_REFRESH_RETRY_INTERVAL_SEC:-1800}"
RUNTIME_HELPER="${ROUTER_EGRESS_VM101_RUNTIME_HELPER:-/usr/local/lib/router-egress-vm101-runtime.sh}"
[ -r "$RUNTIME_HELPER" ] || { echo RESULT=STOP_R20C_RUNTIME_HELPER_MISSING; exit 21; }
. "$RUNTIME_HELPER"

for x in "$DOWNLOAD" "$TESTER" "$RANKER" "$BUILDER" "$VALIDATOR" "$ACTIVATOR"; do [ -x "$x" ] || { echo RESULT=STOP_R18_EXECUTABLE_MISSING; echo "PATH=$x"; exit 21; }; done
[ "${GENERATION_ACTIVATION_ALLOWED:-false}" = false ] || { echo RESULT=STOP_R18_AUTOMATIC_ACTIVATION_POLICY_CHANGED; exit 22; }
case "$FULL_REFRESH_AFTER_REPAIRS" in ''|*[!0-9]*) echo RESULT=STOP_R18_THRESHOLD_INVALID; exit 22 ;; esac
[ "$FULL_REFRESH_AFTER_REPAIRS" -gt 0 ] || { echo RESULT=STOP_R18_THRESHOLD_INVALID; exit 22; }
case "$HMN_REFRESH_RETRY_INTERVAL_SEC" in ''|*[!0-9]*) echo RESULT=STOP_R20C_RETRY_INTERVAL_INVALID; exit 22 ;; esac
[ "$HMN_REFRESH_RETRY_INTERVAL_SEC" -gt 0 ] || { echo RESULT=STOP_R20C_RETRY_INTERVAL_INVALID; exit 22; }
[ "${DIRECT_FAILOPEN_ENABLED:-false}" = false ] || { echo RESULT=STOP_R20C_DIRECT_FAILOPEN_POLICY_CHANGED; exit 22; }
case "$FULL_POOL_REFRESH_ENABLED" in true|1) ;; *) echo RESULT=NOOP_R18_FULL_POOL_REFRESH_DISABLED; exit 0 ;; esac
[ -z "$NOW_EPOCH" ] && NOW_EPOCH="$(date +%s)"
case "$NOW_EPOCH" in ''|*[!0-9]*) echo RESULT=STOP_R18_NOW_EPOCH_INVALID; exit 22 ;; esac

reg_init_state || { echo RESULT=STOP_R18_STATE_INIT_FAILED; exit 23; }
ACTIVE_REAL="$(readlink -f "$GENERATION_ACTIVE_LINK" 2>/dev/null || true)"
[ -n "$ACTIVE_REAL" ] && [ -d "$ACTIVE_REAL" ] || { echo RESULT=STOP_R18_ACTIVE_GENERATION_MISSING; exit 23; }
ACTIVE_ID="$(basename "$ACTIVE_REAL")"
COUNTER="$(reg_repair_events_get)"
case "$COUNTER" in ''|*[!0-9]*) echo RESULT=STOP_R18_COUNTER_INVALID; exit 23 ;; esac
MODE="$(reg_get_state mode NORMAL 2>/dev/null || echo NORMAL)"
DUE="$(reg_get_state full_refresh_due false 2>/dev/null || echo false)"
ENTRY_MODE="$MODE"
ENTRY_DEGRADED_SINCE="$(reg_get_state degraded_since_epoch 0 2>/dev/null || echo 0)"

# The activator contract uses ROUTER_EGRESS_ACTIVATION_AUTH_DIR. Keep the
# generation.conf legacy name as a compatibility fallback for fixtures only.
GENERATION_ACTIVATION_AUTH_DIR="${ROUTER_EGRESS_ACTIVATION_AUTH_DIR:-${GENERATION_ACTIVATION_AUTH_DIR:-/var/lib/router-egress-recovery/activation-authorizations}}"

COORDINATOR_LOCK="$REG_LOCK_DIR/recovery-coordinator.lock"
FULL_LOCK="$REG_LOCK_DIR/full-pool-refresh.lock"
COORDINATOR_LOCK_OWNED=false
FULL_LOCK_OWNED=false
ATTEMPT_ID=""
RUN_DIR=""
PROVIDER_RESTORE_NEEDED=false
COMPLETED=false
FAILURE_CLASS=unknown_failure
FAIL_RESULT=STOP_R20C_UNKNOWN_FAILURE
FAIL_REASON=unknown_failure
DEGRADED_STATE_RECORD_OK=not_attempted
DEGRADED_RECORD_ALLOWED=true
LATEST_LINK="$PROVIDER_ROOT/configs/awg1/latest"

restore_provider() {
    [ -n "$RUN_DIR" ] && [ -d "$RUN_DIR/provider-before" ] || return 0
    rm -rf "$PROVIDER_ROOT/cache"
    if [ -f "$RUN_DIR/provider-before/cache.tar.gz" ]; then
        tar -xzf "$RUN_DIR/provider-before/cache.tar.gz" -C "$PROVIDER_ROOT"
    else
        mkdir -p "$PROVIDER_ROOT/cache"
        chmod 700 "$PROVIDER_ROOT/cache"
    fi
    kind="$(cat "$RUN_DIR/provider-before/latest.kind")"
    rm -rf "$LATEST_LINK"
    case "$kind" in
        symlink) ln -s "$(cat "$RUN_DIR/provider-before/latest.link")" "$LATEST_LINK" ;;
        directory) tar -xzf "$RUN_DIR/provider-before/latest-dir.tar.gz" -C "$(dirname "$LATEST_LINK")" ;;
        absent) : ;;
    esac
}

cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ "$rc" -ne 0 ] && [ "$COMPLETED" != true ]; then
        if [ "$PROVIDER_RESTORE_NEEDED" = true ]; then restore_provider >/dev/null 2>&1 || true; fi
        if [ -n "$ATTEMPT_ID" ] && [ "$DEGRADED_RECORD_ALLOWED" = true ]; then
            failure_active_real="$(readlink -f "$GENERATION_ACTIVE_LINK" 2>/dev/null || true)"
            failure_active_id="$(basename "$failure_active_real" 2>/dev/null || echo "$ACTIVE_ID")"
            failure_healthy="$(vm101_count_healthy_slots 2>/dev/null || echo 0)"
            case "$failure_healthy" in ''|*[!0-9]*) failure_healthy=0 ;; esac
            failure_degraded_since="$NOW_EPOCH"
            if [ "$ENTRY_MODE" = DEGRADED_POOL ]; then
                case "$ENTRY_DEGRADED_SINCE" in ''|*[!0-9]*) ;; *) [ "$ENTRY_DEGRADED_SINCE" -gt 0 ] && failure_degraded_since="$ENTRY_DEGRADED_SINCE" ;; esac
            fi
            failure_next=$((NOW_EPOCH + HMN_REFRESH_RETRY_INTERVAL_SEC))
            if reg_state_update mode DEGRADED_POOL degraded_reason "$FAILURE_CLASS" degraded_since_epoch "$failure_degraded_since" failed_attempt_id "$ATTEMPT_ID" last_refresh_result FAILED last_refresh_epoch "$NOW_EPOCH" next_refresh_epoch "$failure_next" active_generation_id "$failure_active_id" healthy_slot_count_at_failure "$failure_healthy" full_refresh_due true last_full_refresh_result FAILED last_full_refresh_failure_epoch "$NOW_EPOCH" last_full_refresh_attempt_id "$ATTEMPT_ID" >/dev/null 2>&1; then
                DEGRADED_STATE_RECORD_OK=true
            else
                DEGRADED_STATE_RECORD_OK=false
                rc=30
            fi
            cat >"$RUN_DIR/result.kv" <<EOF_FAILURE
result=$FAIL_RESULT
attempt_id=$ATTEMPT_ID
failure_class=$FAILURE_CLASS
stop_reason=$FAIL_REASON
previous_generation_id=$ACTIVE_ID
active_generation_id=$failure_active_id
healthy_slot_count=$failure_healthy
next_refresh_epoch=$failure_next
degraded_state_record_ok=$DEGRADED_STATE_RECORD_OK
direct_failopen_used=false
EOF_FAILURE
            reg_event_append full_pool_refresh FAILED "$ATTEMPT_ID" '' '' '' "$ACTIVE_ID" "$failure_active_id" "$FAILURE_CLASS" "$COUNTER" "$COUNTER" "degraded_state_record_ok=$DEGRADED_STATE_RECORD_OK" >/dev/null 2>&1 || true
            echo "DEGRADED_STATE_RECORD_OK=$DEGRADED_STATE_RECORD_OK"
            [ "$DEGRADED_STATE_RECORD_OK" = true ] || echo RESULT=STOP_R20D_DEGRADED_STATE_RECORD_FAILED
            if [ "$failure_healthy" -eq 0 ]; then
                echo RESULT=STOP_R20C_ZERO_HEALTHY_SLOTS_OUT_OF_SCOPE
                echo DIRECT_FAILOPEN_USED=false
            fi
        fi
    fi
    [ "$FULL_LOCK_OWNED" = true ] && reg_lock_release "$FULL_LOCK" >/dev/null 2>&1 || true
    [ "$COORDINATOR_LOCK_OWNED" = true ] && reg_lock_release "$COORDINATOR_LOCK" >/dev/null 2>&1 || true
    if [ "$rc" -ne 0 ]; then
        [ -z "$RUN_DIR" ] || echo "ATTEMPT_DIR=$RUN_DIR"
        echo ACTIVE_GENERATION_PRESERVED=true
        echo REPAIR_COUNTER_PRESERVED=true
        echo DIRECT_FAILOPEN_USED=false
    fi
    exit "$rc"
}
trap cleanup EXIT HUP INT TERM

# A killed previous attempt is converted to durable DEGRADED_POOL; retry remains controller-owned.
if [ "$MODE" = FULL_POOL_REFRESH_RUNNING ] && [ ! -d "$COORDINATOR_LOCK" ] && [ ! -d "$FULL_LOCK" ]; then
    interrupted_next=$((NOW_EPOCH + HMN_REFRESH_RETRY_INTERVAL_SEC))
    reg_state_update mode DEGRADED_POOL degraded_reason interrupted_refresh degraded_since_epoch "$NOW_EPOCH" failed_attempt_id "$(reg_get_state last_full_refresh_attempt_id interrupted 2>/dev/null || echo interrupted)" last_refresh_result INTERRUPTED last_refresh_epoch "$NOW_EPOCH" next_refresh_epoch "$interrupted_next" full_refresh_due true last_full_refresh_result INTERRUPTED
    MODE=DEGRADED_POOL
    DUE=true
fi

if [ "$RUN_MODE" = --force ]; then
    [ "$CONFIRM" = "FULL_REFRESH_${ACTIVE_ID}" ] || { echo RESULT=STOP_R18_FORCE_CONFIRMATION_MISMATCH; echo "EXPECTED_CONFIRM=FULL_REFRESH_${ACTIVE_ID}"; exit 24; }
elif [ "$RUN_MODE" = --retry ]; then
    [ "${ROUTER_EGRESS_RETRY_CONTROLLER:-0}" = 1 ] || { echo RESULT=STOP_R20C_RETRY_CONTROLLER_REQUIRED; exit 24; }
    RETRY_DUE="$(reg_get_state next_refresh_epoch 0 2>/dev/null || echo 0)"
    case "$RETRY_DUE" in ''|*[!0-9]*) echo RESULT=STOP_R20C_RETRY_DUE_INVALID; exit 24 ;; esac
    if [ "$MODE" != DEGRADED_POOL ] || [ "$NOW_EPOCH" -lt "$RETRY_DUE" ]; then
        echo RESULT=NOOP_R20C_RETRY_NOT_DUE
        echo "MODE=$MODE"
        echo "NEXT_REFRESH_EPOCH=$RETRY_DUE"
        exit 0
    fi
else
    if [ "$MODE" != FULL_POOL_REFRESH_PENDING ] || [ "$DUE" != true ] || [ "$COUNTER" -lt "$FULL_REFRESH_AFTER_REPAIRS" ]; then
        echo RESULT=NOOP_R18_FULL_POOL_REFRESH_NOT_DUE
        echo "MODE=$MODE"
        echo "COUNTER=$COUNTER"
        echo "THRESHOLD=$FULL_REFRESH_AFTER_REPAIRS"
        echo "FULL_REFRESH_DUE=$DUE"
        exit 0
    fi
fi

if [ "${ROUTER_EGRESS_COORDINATOR_LOCK_HELD:-0}" = 1 ]; then
    [ -d "$COORDINATOR_LOCK" ] || { echo RESULT=STOP_R20C_CALLER_COORDINATOR_LOCK_MISSING; exit 24; }
else
    acquired_coord="$(reg_lock_acquire recovery-coordinator.lock r20c-full-pool-refresh 2>/dev/null || true)"
    [ -n "$acquired_coord" ] || { echo RESULT=NOOP_R20C_RECOVERY_COORDINATOR_BUSY; exit 0; }
    COORDINATOR_LOCK_OWNED=true
fi
acquired_full="$(reg_lock_acquire full-pool-refresh.lock r20c-full-pool-refresh 2>/dev/null || true)"
[ -n "$acquired_full" ] || { echo RESULT=NOOP_R20C_FULL_POOL_REFRESH_LOCK_BUSY; exit 0; }
FULL_LOCK_OWNED=true

# Recheck the trigger under the coordinator/full-refresh locks.
MODE="$(reg_get_state mode NORMAL 2>/dev/null || echo NORMAL)"
DUE="$(reg_get_state full_refresh_due false 2>/dev/null || echo false)"
ENTRY_MODE="$MODE"
ENTRY_DEGRADED_SINCE="$(reg_get_state degraded_since_epoch 0 2>/dev/null || echo 0)"
COUNTER="$(reg_repair_events_get)"
if [ "$RUN_MODE" = --run-if-due ]; then
    if [ "$MODE" != FULL_POOL_REFRESH_PENDING ] || [ "$DUE" != true ] || [ "$COUNTER" -lt "$FULL_REFRESH_AFTER_REPAIRS" ]; then
        echo RESULT=NOOP_R20C_FULL_POOL_REFRESH_RECHECK_NOT_DUE
        exit 0
    fi
elif [ "$RUN_MODE" = --retry ]; then
    RETRY_DUE="$(reg_get_state next_refresh_epoch 0 2>/dev/null || echo 0)"
    case "$RETRY_DUE" in ''|*[!0-9]*) echo RESULT=STOP_R20C_RETRY_DUE_INVALID; exit 24 ;; esac
    if [ "$MODE" != DEGRADED_POOL ] || [ "$NOW_EPOCH" -lt "$RETRY_DUE" ]; then
        echo RESULT=NOOP_R20C_RETRY_RECHECK_NOT_DUE
        exit 0
    fi
fi

ATTEMPT_ID="r20c-$(date -u +%Y%m%d-%H%M%S)-$$"
RUN_DIR="$REG_STATE_DIR/full-refresh-attempts/$ATTEMPT_ID"
mkdir -p "$RUN_DIR/provider-before" "$RUN_DIR/logs" "$GENERATION_ACTIVATION_AUTH_DIR"
chmod 700 "$RUN_DIR" "$RUN_DIR/provider-before" "$RUN_DIR/logs" "$GENERATION_ACTIVATION_AUTH_DIR"

if [ -L "$LATEST_LINK" ]; then
    readlink "$LATEST_LINK" >"$RUN_DIR/provider-before/latest.link"
    echo symlink >"$RUN_DIR/provider-before/latest.kind"
elif [ -d "$LATEST_LINK" ]; then
    echo directory >"$RUN_DIR/provider-before/latest.kind"
    tar -czf "$RUN_DIR/provider-before/latest-dir.tar.gz" -C "$(dirname "$LATEST_LINK")" "$(basename "$LATEST_LINK")"
else
    echo absent >"$RUN_DIR/provider-before/latest.kind"
fi
if [ -d "$PROVIDER_ROOT/cache" ]; then
    tar -czf "$RUN_DIR/provider-before/cache.tar.gz" -C "$PROVIDER_ROOT" cache
fi
cp -p "$REG_STATE_KV" "$RUN_DIR/state.before.kv" 2>/dev/null || : >"$RUN_DIR/state.before.kv"
COUNTER_FILE="$(reg_counter_file "$REG_REPAIR_EVENTS_KEY")"
if [ -e "$COUNTER_FILE" ]; then
    cp -p "$COUNTER_FILE" "$RUN_DIR/counter.before"
    echo true >"$RUN_DIR/counter.existed"
else
    : >"$RUN_DIR/counter.before"
    echo false >"$RUN_DIR/counter.existed"
fi
cp -p "$REG_QUARANTINE_TSV" "$RUN_DIR/quarantine.before.tsv"
echo "$ACTIVE_REAL" >"$RUN_DIR/previous-active-real.txt"
echo "$COUNTER" >"$RUN_DIR/trigger-counter.txt"
PROVIDER_RESTORE_NEEDED=true
stream_command() {
    label="$1"; shift
    fifo="$RUN_DIR/${label}.fifo"
    log="$RUN_DIR/logs/${label}.log"
    mkfifo "$fifo"
    tee -a "$log" <"$fifo" & tee_pid=$!
    set +e
    "$@" >"$fifo" 2>&1
    rc=$?
    set -e
    wait "$tee_pid" || true
    rm -f "$fifo"
    return "$rc"
}

fail() { result="$1"; reason="$2"; FAILURE_CLASS="${3:-$reason}"; FAIL_RESULT="$result"; FAIL_REASON="$reason"; echo "RESULT=$result"; echo "STOP_REASON=$reason"; exit 1; }

reg_state_update mode FULL_POOL_REFRESH_RUNNING full_refresh_due true last_full_refresh_attempt_id "$ATTEMPT_ID" last_full_refresh_started_epoch "$NOW_EPOCH" last_full_refresh_previous_generation "$ACTIVE_ID" last_full_refresh_trigger_counter "$COUNTER" || fail STOP_R20C_STATE_UPDATE_FAILED state_running state_update_failure

echo ">>> [R20C] provider download"
stream_command provider-download "$DOWNLOAD" || fail STOP_R20C_PROVIDER_DOWNLOAD_FAILED provider_download provider_download_failure
CONFIG_DIR="$(readlink -f "$LATEST_LINK" 2>/dev/null || true)"
[ -n "$CONFIG_DIR" ] && [ -d "$CONFIG_DIR" ] || fail STOP_R20C_PROVIDER_CONFIG_DIR_INVALID config_dir provider_schema_adapter_failure

echo ">>> [R20C] provider candidate testing"
stream_command provider-test "$TESTER" "$CONFIG_DIR" || fail STOP_R20C_PROVIDER_TEST_FAILED provider_test provider_test_failure
RESULTS=""
RESULTS_MTIME=0
for candidate in "$PROVIDER_ROOT"/test-runs/*/results.tsv; do
    [ -f "$candidate" ] || continue
    candidate_mtime="$(stat -c %Y "$candidate")"
    case "$candidate_mtime" in ''|*[!0-9]*) continue ;; esac
    if [ "$candidate_mtime" -ge "$RESULTS_MTIME" ]; then
        RESULTS="$candidate"
        RESULTS_MTIME="$candidate_mtime"
    fi
done
[ -n "$RESULTS" ] && [ -s "$RESULTS" ] || fail STOP_R20C_PROVIDER_RESULTS_MISSING provider_results provider_test_failure

echo ">>> [R20C] adapt tester results to provider ranker v1 schema"
EXPECTED_RESULTS_HEADER='status	file	endpoint	latest_handshake	transfer	ping_loss	ping_rtt_avg	show_file	ping_file'
[ "$(head -n1 "$RESULTS")" = "$EXPECTED_RESULTS_HEADER" ] || fail STOP_R20C_PROVIDER_RESULTS_SCHEMA_HEADER provider_results_header provider_schema_adapter_failure
RANK_RESULTS="$RUN_DIR/provider-results-ranker-v1.tsv"
if ! awk -F '\t' 'BEGIN { OFS="\t" }
    NR == 1 { print; next }
    NF < 7 { bad=1; next }
    $1 == "OK" {
        loss=$6
        all_zero=(loss == "0%")
        if (!all_zero) {
            n=split(loss, parts, ",")
            all_zero=(n > 0)
            for (i=1; i<=n; i++) {
                if (parts[i] !~ /^[^,:[:space:]]+:0%$/) all_zero=0
            }
        }
        if (!all_zero) { bad=1; next }
        $6="0%"
    }
    { print }
    END { if (bad) exit 1 }
' "$RESULTS" >"$RANK_RESULTS"; then
    fail STOP_R20C_PROVIDER_RESULTS_SCHEMA_ADAPTER provider_results_adapter provider_schema_adapter_failure
fi
chmod 600 "$RANK_RESULTS"
ORIGINAL_OK_COUNT="$(awk -F '\t' 'NR>1 && $1=="OK" {n++} END {print n+0}' "$RESULTS")"
ADAPTED_OK_COUNT="$(awk -F '\t' 'NR>1 && $1=="OK" && $6=="0%" {n++} END {print n+0}' "$RANK_RESULTS")"
[ "$ORIGINAL_OK_COUNT" = "$ADAPTED_OK_COUNT" ] || fail STOP_R20C_PROVIDER_RESULTS_SCHEMA_COUNT provider_results_count provider_schema_adapter_failure
[ "$ADAPTED_OK_COUNT" -ge 5 ] || fail STOP_R20C_PROVIDER_RESULTS_INSUFFICIENT_OK provider_results_ok_count insufficient_healthy_candidates
cat >"$RUN_DIR/logs/provider-results-adapter.log" <<EOF
RESULT=PASS_R18_PROVIDER_RESULTS_SCHEMA_ADAPTED
ORIGINAL_RESULTS=$RESULTS
ADAPTED_RESULTS=$RANK_RESULTS
ORIGINAL_OK_COUNT=$ORIGINAL_OK_COUNT
ADAPTED_OK_COUNT=$ADAPTED_OK_COUNT
SOURCE_SCHEMA=hmn-test-results-v9-composite-loss
TARGET_SCHEMA=hmn-ranker-v1-single-loss
EOF

echo ">>> [R20C] provider ranking"
stream_command provider-rank env CONFIG_DIR="$CONFIG_DIR" HMN_RANK_MIN_CANDIDATES=5 "$RANKER" "$RANK_RESULTS" || fail STOP_R20C_PROVIDER_RANK_FAILED provider_rank ranking_failure
SOURCE_POOL="$PROVIDER_ROOT/cache/candidate-pool-awg1-latest.tsv"
[ -s "$SOURCE_POOL" ] || fail STOP_R20C_SOURCE_POOL_MISSING source_pool fewer_than_five_eligible_candidates

# A full provider retest allows endpoints quarantined before this fresh test run.
RESULTS_MTIME="$(stat -c %Y "$RESULTS")"
FILTERED_QUARANTINE="$RUN_DIR/quarantine-for-generation.tsv"
awk -F '	' -v m="$RESULTS_MTIME" 'NR==1 || ($1 ~ /^[0-9]+$/ && $1 >= m)' "$REG_QUARANTINE_TSV" >"$FILTERED_QUARANTINE"
[ "$(head -n1 "$FILTERED_QUARANTINE")" = 'ts_epoch	ts_utc	egress	iface	endpoint	replacement	reason	pool_path	pool_mtime_epoch	source_step' ] || fail STOP_R20C_FILTERED_QUARANTINE_HEADER quarantine_header provider_schema_adapter_failure
chmod 600 "$FILTERED_QUARANTINE"

GEN_ID="$ATTEMPT_ID"
echo ">>> [R20C] generation build and validation"
BUILD_LOG="$RUN_DIR/logs/generation-build.log"
stream_command generation-build env ROUTER_EGRESS_QUARANTINE_SNAPSHOT_OVERRIDE="$FILTERED_QUARANTINE" "$BUILDER" --source-pool "$SOURCE_POOL" --generation-id "$GEN_ID" --now-epoch "$NOW_EPOCH" || fail STOP_R20C_GENERATION_BUILD_FAILED generation_build generation_build_failure
GEN_DIR="$(sed -n 's/^GENERATION_DIR=//p' "$BUILD_LOG" | tail -n1)"
[ -n "$GEN_DIR" ] && [ -d "$GEN_DIR" ] || fail STOP_R20C_GENERATION_DIR_MISSING generation_dir generation_build_failure
"$VALIDATOR" --generation-dir "$GEN_DIR" --now-epoch "$NOW_EPOCH" >"$RUN_DIR/logs/generation-validate.log" 2>&1 || { cat "$RUN_DIR/logs/generation-validate.log"; fail STOP_R20C_GENERATION_VALIDATE_FAILED generation_validate generation_validation_failure; }
grep -qx RESULT=PASS_STAGED_GENERATION_VALID "$RUN_DIR/logs/generation-validate.log" || fail STOP_R20C_GENERATION_VALIDATE_MARKER validation_marker generation_validation_failure

AUTH_ID="r20c-${GEN_ID}-${NOW_EPOCH}"
AUTH_FILE="$GENERATION_ACTIVATION_AUTH_DIR/${AUTH_ID}.kv"
cat >"$AUTH_FILE" <<EOF
schema=router-egress-activation-authorization-v2
authorization_id=$AUTH_ID
operation=replace_active_generation
generation_id=$GEN_ID
generation_dir=$GEN_DIR
generation_manifest_sha256=$(sha256sum "$GEN_DIR/manifest.sha256" | awk '{print $1}')
previous_generation_id=$ACTIVE_ID
previous_generation_dir=$ACTIVE_REAL
trigger_counter=$COUNTER
issued_at_epoch=$NOW_EPOCH
expires_at_epoch=$((NOW_EPOCH + 1800))
single_use=true
source_step=$SOURCE_STEP
EOF
chmod 600 "$AUTH_FILE"

echo ">>> [R20C] transactional active-generation replacement"
ACTIVATE_LOG="$RUN_DIR/logs/generation-activate.log"
if ! stream_command generation-activate env ROUTER_EGRESS_COORDINATOR_LOCK_HELD=1 ROUTER_EGRESS_FULL_POOL_REFRESH_LOCK_HELD=1 ROUTER_EGRESS_HEALTH_SERVICE_MANAGED_BY_CALLER="${ROUTER_EGRESS_HEALTH_SERVICE_MANAGED_BY_CALLER:-0}" "$ACTIVATOR" --generation-dir "$GEN_DIR" --authorization-file "$AUTH_FILE" --confirm "ACTIVATE_${GEN_ID}" --now-epoch "$NOW_EPOCH"; then
    if ! grep -qx ROLLBACK_OK=true "$ACTIVATE_LOG" 2>/dev/null; then
        DEGRADED_RECORD_ALLOWED=false
        fail STOP_R20C_ACTIVATION_ROLLBACK_NOT_PROVEN activation_rollback_not_proven activation_rollback_failure
    fi
    fail STOP_R20C_GENERATION_ACTIVATE_FAILED generation_activate transactional_activation_failure
fi
grep -qx RESULT=PASS_R18_GENERATION_REPLACED "$ACTIVATE_LOG" || fail STOP_R20C_ACTIVATION_MARKER_MISSING activation_marker transactional_activation_failure
ACTIVATION_TRANSACTION_DIR="$(sed -n 's/^TRANSACTION_DIR=//p' "$ACTIVATE_LOG" | tail -n1)"
ACTIVATION_ROLLBACK_FILE="$(sed -n 's/^ROLLBACK_FILE=//p' "$ACTIVATE_LOG" | tail -n1)"
[ -n "$ACTIVATION_TRANSACTION_DIR" ] && [ -d "$ACTIVATION_TRANSACTION_DIR" ] || fail STOP_R20C_ACTIVATION_TRANSACTION_MISSING activation_transaction transactional_activation_failure
[ -n "$ACTIVATION_ROLLBACK_FILE" ] && [ -x "$ACTIVATION_ROLLBACK_FILE" ] || fail STOP_R20C_ACTIVATION_ROLLBACK_MISSING activation_rollback transactional_activation_failure
[ "$(readlink -f "$GENERATION_ACTIVE_LINK")" = "$(readlink -f "$GEN_DIR")" ] || fail STOP_R20C_ACTIVE_LINK_POSTCHECK active_link transactional_activation_failure
[ "$(reg_repair_events_get)" = 0 ] || fail STOP_R20C_COUNTER_POSTCHECK counter transactional_activation_failure
[ "$(reg_get_state mode UNKNOWN)" = NORMAL ] || fail STOP_R20C_MODE_POSTCHECK mode transactional_activation_failure
[ "$(reg_get_state full_refresh_due true)" = false ] || fail STOP_R20C_DUE_POSTCHECK due transactional_activation_failure

PROVIDER_RESTORE_NEEDED=false
reg_state_update mode NORMAL degraded_reason "" degraded_since_epoch 0 failed_attempt_id "" last_refresh_result PASS last_refresh_epoch "$NOW_EPOCH" next_refresh_epoch 0 active_generation_id "$GEN_ID" healthy_slot_count_at_failure 5 full_refresh_due false last_full_refresh_result PASS last_full_refresh_attempt_id "$ATTEMPT_ID" last_full_refresh_previous_generation "$ACTIVE_ID" last_full_refresh_new_generation "$GEN_ID" || fail STOP_R20C_SUCCESS_STATE_FINALIZATION_FAILED success_state state_update_failure
COMPLETED=true
reg_event_append full_pool_refresh PASS "$ATTEMPT_ID" "" "" "" "$ACTIVE_ID" "$GEN_ID" success "$COUNTER" 0 "active_generation_replaced=true" >/dev/null 2>&1 || true
cat >"$RUN_DIR/result.kv" <<EOF
result=PASS_R20C_FULL_POOL_REFRESH
attempt_id=$ATTEMPT_ID
previous_generation_id=$ACTIVE_ID
new_generation_id=$GEN_ID
trigger_counter=$COUNTER
repair_events_since_full_refresh=0
active_generation_dir=$GEN_DIR
provider_results=$RESULTS
provider_rank_results=$RANK_RESULTS
provider_ok_count=$ADAPTED_OK_COUNT
source_pool=$SOURCE_POOL
runtime_impact=true
EOF

echo RESULT=PASS_R20C_FULL_POOL_REFRESH
echo "ATTEMPT_ID=$ATTEMPT_ID"
echo "PREVIOUS_GENERATION_ID=$ACTIVE_ID"
echo "NEW_GENERATION_ID=$GEN_ID"
echo "NEW_GENERATION_DIR=$GEN_DIR"
echo "ACTIVATION_TRANSACTION_DIR=$ACTIVATION_TRANSACTION_DIR"
echo "ACTIVATION_ROLLBACK_FILE=$ACTIVATION_ROLLBACK_FILE"
echo "TRIGGER_COUNTER=$COUNTER"
echo REPAIR_COUNTER_RESET=true
echo ACTIVE_GENERATION_REPLACED=true
echo ACTIVE_SLOT_COUNT=5
echo DIRECT_FAILOPEN_USED=false
echo RUNTIME_IMPACT=true
