#!/bin/sh
# Canonical VM101 LOCAL_REPAIR watcher. BusyBox ash compatible.
# R20Q-K: no-candidate failures request one durable full-pool refresh.
set -u

VM101_CONF="${VM101_CONF:-/etc/router-egress-vm101.conf}"
[ -r "$VM101_CONF" ] && . "$VM101_CONF"

ENABLED="${LOCAL_REPAIR_ENABLED:-0}"
MODE="${LOCAL_REPAIR_MODE:---dry-run}"
INTERVAL_SEC="${HEALTH_CHECK_INTERVAL_SEC:-60}"
FAIL_THRESHOLD="${HEALTH_FAILURES_BEFORE_DOWN:-2}"
COOLDOWN_SEC="${LOCAL_REPAIR_COOLDOWN_SEC:-900}"
SLOTS_CONF="${SLOTS_CONF:-/etc/router-egress-slots.d/slots.conf}"
STATE_ROOT="${STATE_DIR:-/var/lib/router-egress-recovery}"
WATCH_STATE_DIR="$STATE_ROOT/health-watch"
LOG="${HEALTH_REPAIR_LOG:-/var/log/router-egress-health-repair.log}"
LOG_MAX_BYTES="${HEALTH_REPAIR_LOG_MAX_BYTES:-1048576}"
LOG_KEEP_LINES="${HEALTH_REPAIR_LOG_KEEP_LINES:-200}"
DISPATCHER="${RECOVERY_DISPATCHER:-/usr/local/sbin/router-egress-recovery-dispatcher.sh}"
FULL_REFRESH_ORCHESTRATOR="${FULL_POOL_REFRESH_ORCHESTRATOR:-/usr/local/sbin/router-egress-full-pool-refresh.sh}"
STATE_HELPER="${RECOVERY_STATE_HELPER:-/usr/local/lib/router-egress-recovery-state.sh}"
HTTPS_ORACLE="${HTTPS_HEALTH_ORACLE:-/usr/local/lib/router-egress-https-health.sh}"
IDENTITY_HELPER="${HMN_IDENTITY_HELPER:-/usr/local/lib/router-egress-hmn-identity.sh}"
UCI_BIN="${UCI_BIN:-uci}"
HEARTBEAT_SEC="${HEALTH_REPAIR_LOG_HEARTBEAT_SEC:-600}"
HEARTBEAT_FILE="$WATCH_STATE_DIR/event-heartbeat-epoch"
# A slot excluded during a failed repair must not remain permanently excluded
# after its own VPN path has become demonstrably healthy again.
TOPOLOGY_SYNC="${ROUTER_WGPAY_WATCHER_SYNC:-/usr/local/sbin/router-wgpay-watcher-topology-sync.sh}"
TOPOLOGY_SLOTS_STATUS="${ROUTER_WGPAY_SLOTS_STATUS:-/usr/local/sbin/router-egress-slots-status.sh}"
TOPOLOGY_FALLBACK="${ROUTER_WGPAY_FALLBACK_STATE:-/etc/router-wgpay-fallback/state.kv}"
TOPOLOGY_WATCHER="${ROUTER_WGPAY_TOPOLOGY_STATE:-/etc/router-wgpay-watcher-topology/state.kv}"
TOPOLOGY_DIRECT="${ROUTER_WGPAY_DIRECT_STATE:-/etc/router-wgpay-direct/state.kv}"
TOPOLOGY_DELIVERY="${ROUTER_WGPAY_DELIVERY_STATE:-/etc/router-wgpay-topology-delivery/state.kv}"
TOPOLOGY_STABLE_CYCLES="${TOPOLOGY_STABLE_CYCLES:-12}"
TOPOLOGY_STABLE_SECONDS="${TOPOLOGY_STABLE_SECONDS:-100}"
TOPOLOGY_MAX_GAP_SECONDS="${TOPOLOGY_MAX_GAP_SECONDS:-30}"

ONCE=false
FORCE_SLOT=""
RUN_MODE=loop
while [ "$#" -gt 0 ]; do
    case "$1" in
        --once) ONCE=true; RUN_MODE=once; shift ;;
        --dry-run) MODE=--dry-run; shift ;;
        --commit) MODE=--commit; shift ;;
        --force-slot)
            [ "$#" -ge 2 ] || { echo 'ERROR=force_slot_value_missing' >&2; exit 2; }
            FORCE_SLOT="$2"; shift 2 ;;
        *) echo "ERROR=unsupported_argument:$1" >&2; exit 2 ;;
    esac
done

case "$MODE" in --dry-run|--commit) ;; *) echo "ERROR=invalid_mode:$MODE" >&2; exit 2 ;; esac
case "$FAIL_THRESHOLD:$INTERVAL_SEC:$COOLDOWN_SEC:$LOG_MAX_BYTES:$LOG_KEEP_LINES:$HEARTBEAT_SEC" in *[!0-9:]*) echo 'ERROR=invalid_numeric_configuration' >&2; exit 2 ;; esac
[ "$LOG_MAX_BYTES" -ge 65536 ] || { echo 'ERROR=health_log_max_bytes_too_small' >&2; exit 2; }
[ "$LOG_KEEP_LINES" -ge 20 ] || { echo 'ERROR=health_log_keep_lines_too_small' >&2; exit 2; }
[ "$HEARTBEAT_SEC" -ge 60 ] || { echo 'ERROR=health_log_heartbeat_too_small' >&2; exit 2; }
[ -r "$SLOTS_CONF" ] || { echo "ERROR=slots_conf_missing:$SLOTS_CONF" >&2; exit 2; }
[ -x "$DISPATCHER" ] || { echo "ERROR=dispatcher_missing:$DISPATCHER" >&2; exit 2; }
[ -r "$STATE_HELPER" ] || { echo "ERROR=state_helper_missing:$STATE_HELPER" >&2; exit 2; }
[ -x "$HTTPS_ORACLE" ] || { echo "ERROR=https_oracle_missing:$HTTPS_ORACLE" >&2; exit 2; }
mkdir -p "$WATCH_STATE_DIR" "$(dirname "$LOG")" || exit 2

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
uint_or_zero() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

event_emit() {
    ev="$1"; shift
    printf '%s event=%s' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$ev" >>"$LOG"
    for kv in "$@"; do printf ' %s' "$kv" >>"$LOG"; done
    printf '
' >>"$LOG"
}

slot_metadata() {
    sm_iface="$1"
    sm_cfg=''; sm_endpoint=''; sm_identity=''
    if command -v "$UCI_BIN" >/dev/null 2>&1; then
        sm_cfg="$($UCI_BIN -q get "network.${sm_iface}.hmn_source_config" 2>/dev/null || true)"
        sm_endpoint="$($UCI_BIN -q get "network.${sm_iface}.hmn_endpoint" 2>/dev/null || true)"
    fi
    if [ -n "$sm_cfg" ] && [ -r "$sm_cfg" ] && [ -x "$IDENTITY_HELPER" ]; then
        sm_identity="$($IDENTITY_HELPER "$sm_cfg" 2>/dev/null || true)"
    fi
    [ -n "$sm_identity" ] || sm_identity=unknown
    [ -n "$sm_endpoint" ] || sm_endpoint=unknown
}

probe_metadata() {
    pm_file="$1"
    pm_google="$(sed -n 's/.* google=\([^ ]*\).*/\1/p' "$pm_file" 2>/dev/null | head -n1)"
    pm_cloudflare="$(sed -n 's/.* cloudflare=\([^ ]*\).*/\1/p' "$pm_file" 2>/dev/null | head -n1)"
    pm_mozilla="$(sed -n 's/.* mozilla=\([^ ]*\).*/\1/p' "$pm_file" 2>/dev/null | head -n1)"
    [ -n "$pm_google" ] || pm_google=missing
    [ -n "$pm_cloudflare" ] || pm_cloudflare=missing
    [ -n "$pm_mozilla" ] || pm_mozilla=missing
}

health_log_bound() {
    [ -f "$LOG" ] || return 0
    size="$(wc -c < "$LOG" 2>/dev/null || echo 0)"
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    [ "$size" -gt "$LOG_MAX_BYTES" ] || return 0
    trim="${LOG}.trim.$$"
    {
        echo "__ROUTER_EGRESS_HEALTH_REPAIR_LOG_TRUNCATED__ original_bytes=$size max_bytes=$LOG_MAX_BYTES keep_lines=$LOG_KEEP_LINES"
        tail -n "$LOG_KEEP_LINES" "$LOG" 2>/dev/null || true
    } > "$trim" || { rm -f "$trim"; return 1; }
    trim_size="$(wc -c < "$trim" 2>/dev/null || echo 0)"
    case "$trim_size" in ''|*[!0-9]*) trim_size=0 ;; esac
    if [ "$trim_size" -gt "$LOG_MAX_BYTES" ]; then
        keep_bytes=$((LOG_MAX_BYTES / 2))
        byte_trim="${LOG}.bytes.$$"
        {
            echo "__ROUTER_EGRESS_HEALTH_REPAIR_LOG_TRUNCATED_BYTES__ original_bytes=$size max_bytes=$LOG_MAX_BYTES keep_bytes=$keep_bytes"
            tail -c "$keep_bytes" "$LOG" 2>/dev/null || true
        } > "$byte_trim" || { rm -f "$trim" "$byte_trim"; return 1; }
        mv -f "$byte_trim" "$trim" || { rm -f "$trim" "$byte_trim"; return 1; }
    fi
    chmod 0644 "$trim" 2>/dev/null || true
    mv -f "$trim" "$LOG"
}

https_quorum_from_file() {
    hq_file="$1"
    hq="$(sed -n 's/.* quorum=\([0-9]\)\/3.*/\1/p' "$hq_file" 2>/dev/null | head -n1)"
    case "$hq" in ''|*[!0-9]*) echo 0 ;; *) echo "$hq" ;; esac
}

# An isolated subshell prevents the global ash variables in the state/lock
# helpers from overwriting run_once's current slot and oracle results.
# This is called only in the production watcher (--commit), never in dry-run.
topology_stable_health_step() (
    ts_slot="$1"; ts_healthy="$2"; ts_quorum="$3"; ts_now="$4"
    case "$ts_slot" in egress[1-5]) ;; *) return 0 ;; esac
    [ "$MODE" = --commit ] || return 0
    ts_streak="$WATCH_STATE_DIR/topology-stable-$ts_slot"
    ts_reset() { printf '0 0 0\n' > "$ts_streak"; }
    ts_has_slot() { case ",$1," in *",$2,"*) return 0;; esac; return 1; }
    ts_get() { sed -n "s/^$1=//p" "$2" 2>/dev/null | tail -n1; }

    if [ "$ts_healthy" != true ] || [ "$ts_quorum" -lt "${HTTPS_HEALTH_SUCCESS_QUORUM:-2}" ]; then
        ts_reset
        return 0
    fi
    ts_exhausted="$(ts_get exhausted_slots "$TOPOLOGY_FALLBACK")"
    if ! ts_has_slot "$ts_exhausted" "$ts_slot"; then
        ts_reset
        return 0
    fi
    ts_count=0; ts_since=0; ts_last=0
    if [ -f "$ts_streak" ]; then read -r ts_count ts_since ts_last < "$ts_streak" || true; fi
    ts_count="$(uint_or_zero "$ts_count")"
    ts_since="$(uint_or_zero "$ts_since")"
    ts_last="$(uint_or_zero "$ts_last")"
    if [ "$ts_since" -eq 0 ] || [ "$ts_now" -lt "$ts_last" ] || \
       [ $((ts_now - ts_last)) -gt "$TOPOLOGY_MAX_GAP_SECONDS" ]; then
        ts_since="$ts_now"
        ts_count=0
    fi
    [ "$ts_count" -ge "$TOPOLOGY_STABLE_CYCLES" ] || ts_count=$((ts_count + 1))
    printf '%s %s %s\n' "$ts_count" "$ts_since" "$ts_now" > "$ts_streak"
    [ "$ts_count" -ge "$TOPOLOGY_STABLE_CYCLES" ] || return 0
    [ $((ts_now - ts_since)) -ge "$TOPOLOGY_STABLE_SECONDS" ] || return 0

    # Do not un-exhaust a slot while an outage, direct fallback, delivery
    # backlog or competing recovery is in progress.  The next health tick
    # will retry if the exclusion is still present.
    [ ! -e "$TOPOLOGY_DIRECT" ] || return 0
    [ "$(ts_get mode "$TOPOLOGY_FALLBACK")" = SLOT_EXHAUSTED ] || return 0
    [ "$(ts_get exhausted_slots "$TOPOLOGY_WATCHER")" = "$ts_exhausted" ] || return 0
    [ -z "$(ts_get pending_generation "$TOPOLOGY_DELIVERY")" ] || return 0
    [ "$(ts_get last_attempt_result "$TOPOLOGY_DELIVERY")" = ACK_ACCEPTED ] || return 0
    [ -x "$TOPOLOGY_SYNC" ] && [ -x "$TOPOLOGY_SLOTS_STATUS" ] || return 0
    . "$STATE_HELPER"
    ts_lock="$(reg_lock_acquire recovery-coordinator.lock watcher-stable-topology 2>/dev/null || true)"
    [ -n "$ts_lock" ] || return 0
    trap 'reg_lock_release "$ts_lock" >/dev/null 2>&1 || true' EXIT
    [ "$(reg_get_state mode UNKNOWN 2>/dev/null || echo UNKNOWN)" = NORMAL ] || return 0
    # Re-check under the coordinator lock, then corroborate the watcher HTTPS
    # series with an independent fresh per-slot strict routing/ICMP oracle.
    ts_exhausted="$(ts_get exhausted_slots "$TOPOLOGY_FALLBACK")"
    ts_has_slot "$ts_exhausted" "$ts_slot" || return 0
    ts_status="$($TOPOLOGY_SLOTS_STATUS 2>&1)" || true
    printf '%s\n' "$ts_status" | grep -F '"slot":"'"$ts_slot"'"' | \
      grep -q '"iface_exists":true,"route_ok":true,"rule_ok":true,"strict_ok":true,"status":"healthy"' || return 0
    ts_out="$("$TOPOLOGY_SYNC" --bridge-clear "$ts_slot" watcher_stable_health 2>&1)" || {
        event_emit topology_stable_clear_failed "slot=$ts_slot" "reason=sync_failed"
        return 0
    }
    if printf '%s\n' "$ts_out" | grep -qx 'RESULT=PASS_WATCHER_TOPOLOGY_SYNC' && \
       printf '%s\n' "$ts_out" | grep -qx "SLOT=$ts_slot" && \
       printf '%s\n' "$ts_out" | grep -qx 'OUTBOX_RC=0'; then
        event_emit topology_stable_clear "slot=$ts_slot" "stable_cycles=$ts_count" "stable_seconds=$((ts_now-ts_since))" "delivery=queued"
        ts_reset
    else
        event_emit topology_stable_clear_uncertain "slot=$ts_slot" "reason=unexpected_sync_result"
    fi
    return 0
)

run_once() {
    health_log_bound || true
    now="$(date +%s)"
    rows="/tmp/router-egress-health-rows.$$"
    json="/tmp/router-egress-health-json.$$"
    probes="/tmp/router-egress-health-probes.$$"
    mkdir -p "$probes" || return 1
    trap 'rm -f "$rows" "$json"; rm -rf "$probes"' EXIT HUP INT TERM
    grep -Ev '^[[:space:]]*(#|$)' "$SLOTS_CONF" >"$rows"
    : >"$json"
    first=true
    any_action=false
    cycle_total=0
    cycle_healthy=0

    # One bounded health cycle: all five HTTPS oracles run concurrently.
    while read -r p_slot p_iface p_table p_mark p_dscp p_provider p_adapter p_targets p_count p_timeout p_enabled p_rest; do
        [ -n "${p_slot:-}" ] || continue
        [ -z "$FORCE_SLOT" ] || [ "$p_slot" = "$FORCE_SLOT" ] || continue
        [ "$p_enabled" = 1 ] || continue
        "$HTTPS_ORACLE" --iface "$p_iface" >"$probes/$p_slot.out" 2>"$probes/$p_slot.err" &
    done <"$rows"
    wait || true

    while read -r slot iface table mark dscp provider adapter targets strict_count strict_timeout enabled rest; do
        [ -n "${slot:-}" ] || continue
        [ -z "$FORCE_SLOT" ] || [ "$slot" = "$FORCE_SLOT" ] || continue
        [ "$enabled" = "1" ] || continue

        strict_count="$(uint_or_zero "$strict_count")"; [ "$strict_count" -gt 0 ] || strict_count=3
        strict_timeout="$(uint_or_zero "$strict_timeout")"; [ "$strict_timeout" -gt 0 ] || strict_timeout=2
        fail_file="$WATCH_STATE_DIR/fail-$slot"
        cooldown_file="$WATCH_STATE_DIR/cooldown-$slot"
        fail_count="$(uint_or_zero "$(cat "$fail_file" 2>/dev/null || true)")"
        previous_fail_count="$fail_count"
        cooldown_until="$(uint_or_zero "$(cat "$cooldown_file" 2>/dev/null || true)")"
        health_ok=false
        decision=none
        action=none
        dispatcher_rc=0
        required_confirm=""
        adapter_reason=""
        adapter_selected_pool=""
        adapter_selected_pool_age_sec=0
        adapter_available_candidate_count=0
        candidate_endpoint=""
        refresh_request_reason=""
        refresh_request_result=not_requested

        https_quorum="$(https_quorum_from_file "$probes/$slot.out")"
        https_detail="$(cat "$probes/$slot.out" 2>/dev/null || true)"
        slot_metadata "$iface"
        probe_metadata "$probes/$slot.out"
        cycle_total=$((cycle_total + 1))
        if [ "$https_quorum" -ge "${HTTPS_HEALTH_SUCCESS_QUORUM:-2}" ]; then
            health_ok=true
            cycle_healthy=$((cycle_healthy + 1))
            fail_count=0
            echo 0 >"$fail_file"
            decision=healthy
            topology_stable_health_step "$slot" true "$https_quorum" "$now" || true
            if [ "$previous_fail_count" -gt 0 ]; then
                event_emit health_recovered "slot=$slot" "iface=$iface" "identity=$sm_identity" "endpoint=$sm_endpoint"                     "previous_fail_count=$previous_fail_count" "https_quorum=$https_quorum/3"                     "google=$pm_google" "cloudflare=$pm_cloudflare" "mozilla=$pm_mozilla"
            fi
        else
            topology_stable_health_step "$slot" false "$https_quorum" "$now" || true
            fail_count=$((fail_count + 1))
            echo "$fail_count" >"$fail_file"
            if [ "$fail_count" -eq 1 ]; then
                event_emit health_fail_first "slot=$slot" "iface=$iface" "identity=$sm_identity" "endpoint=$sm_endpoint"                     "https_quorum=$https_quorum/3" "fail_count=$fail_count"                     "google=$pm_google" "cloudflare=$pm_cloudflare" "mozilla=$pm_mozilla"
            fi
            if [ "$fail_count" -eq "$FAIL_THRESHOLD" ]; then
                event_emit health_fail_threshold "slot=$slot" "iface=$iface" "identity=$sm_identity" "endpoint=$sm_endpoint"                     "https_quorum=$https_quorum/3" "fail_count=$fail_count"
            fi
            if [ "$fail_count" -lt "$FAIL_THRESHOLD" ]; then
                decision=fail_observed_below_threshold
            elif [ "$now" -lt "$cooldown_until" ]; then
                decision=cooldown
                if [ "$fail_count" -eq "$FAIL_THRESHOLD" ]; then
                    event_emit repair_suppressed_cooldown "slot=$slot" "iface=$iface" "identity=$sm_identity"                         "endpoint=$sm_endpoint" "cooldown_until=$cooldown_until"
                fi
            else
                dry_out="/tmp/router-egress-health-dry-${slot}.$$"
                dry_err="/tmp/router-egress-health-dry-${slot}.$$.err"
                dry_rc=0
                "$DISPATCHER" --dry-run --slot "$slot" --reason health_watch >"$dry_out" 2>"$dry_err" || dry_rc=$?
                required_confirm="$(sed -n 's/.*"required_dispatch_confirm": "\([^"]*\)".*/\1/p' "$dry_out" | head -n1)"
                dry_decision="$(sed -n 's/.*"decision": "\([^"]*\)".*/\1/p' "$dry_out" | head -n1)"
                adapter_reason="$(sed -n 's/.*"adapter_dryrun_reason": "\([^"]*\)".*/\1/p' "$dry_out" | head -n1)"
                adapter_selected_pool="$(sed -n 's/.*"adapter_selected_pool": "\([^"]*\)".*/\1/p' "$dry_out" | head -n1)"
                adapter_selected_pool_age_sec="$(sed -n 's/.*"adapter_selected_pool_age_sec": \([0-9][0-9]*\).*/\1/p' "$dry_out" | head -n1)"
                adapter_available_candidate_count="$(sed -n 's/.*"adapter_available_candidate_count": \([0-9][0-9]*\).*/\1/p' "$dry_out" | head -n1)"
                candidate_endpoint="$(sed -n 's/.*"candidate_endpoint": "\([^"]*\)".*/\1/p' "$dry_out" | head -n1)"
                case "$adapter_selected_pool_age_sec" in ''|*[!0-9]*) adapter_selected_pool_age_sec=0 ;; esac
                case "$adapter_available_candidate_count" in ''|*[!0-9]*) adapter_available_candidate_count=0 ;; esac

                if [ "$dry_rc" -eq 0 ] && [ "$dry_decision" = dry_run_ok ] && [ "$MODE" = --commit ] && [ -n "$required_confirm" ]; then
                    commit_out="/tmp/router-egress-health-commit-${slot}.$$"
                    commit_err="/tmp/router-egress-health-commit-${slot}.$$.err"
                    dispatcher_rc=0
                    "$DISPATCHER" --commit --slot "$slot" --reason health_watch --confirm "$required_confirm" >"$commit_out" 2>"$commit_err" || dispatcher_rc=$?
                    decision="$(sed -n 's/.*"decision": "\([^"]*\)".*/\1/p' "$commit_out" | head -n1)"
                    adapter_reason="$(sed -n 's/.*"adapter_commit_reason": "\([^"]*\)".*/\1/p' "$commit_out" | head -n1)"
                    [ -n "$adapter_reason" ] || adapter_reason="$(sed -n 's/.*"adapter_dryrun_reason": "\([^"]*\)".*/\1/p' "$commit_out" | head -n1)"
                    adapter_selected_pool="$(sed -n 's/.*"adapter_selected_pool": "\([^"]*\)".*/\1/p' "$commit_out" | head -n1)"
                    adapter_selected_pool_age_sec="$(sed -n 's/.*"adapter_selected_pool_age_sec": \([0-9][0-9]*\).*/\1/p' "$commit_out" | head -n1)"
                    adapter_available_candidate_count="$(sed -n 's/.*"adapter_available_candidate_count": \([0-9][0-9]*\).*/\1/p' "$commit_out" | head -n1)"
                    candidate_endpoint="$(sed -n 's/.*"candidate_endpoint": "\([^"]*\)".*/\1/p' "$commit_out" | head -n1)"
                    case "$adapter_selected_pool_age_sec" in ''|*[!0-9]*) adapter_selected_pool_age_sec=0 ;; esac
                    case "$adapter_available_candidate_count" in ''|*[!0-9]*) adapter_available_candidate_count=0 ;; esac
                    [ -n "$decision" ] || decision=commit_failed_no_decision
                    action=commit_dispatch
                    any_action=true
                    case "$adapter_reason" in
                        recovery_coordinator_lock_busy|local_repair_lock_busy)
                            action=commit_deferred_lock_busy
                            decision=deferred_lock_busy
                            ;;
                        *)
                            echo $((now + COOLDOWN_SEC)) >"$cooldown_file"
                            ;;
                    esac
                    if [ "$dispatcher_rc" -eq 0 ] && [ "$decision" = commit_ok ]; then
                        echo 0 >"$fail_file"
                        fail_count=0
                    fi
                    if [ "$action" = commit_deferred_lock_busy ]; then
                        event_emit repair_deferred_lock_busy "slot=$slot" "iface=$iface" "identity=$sm_identity"                             "endpoint=$sm_endpoint" "candidate=$candidate_endpoint" "dispatcher_rc=$dispatcher_rc"
                    elif [ "$dispatcher_rc" -eq 0 ] && [ "$decision" = commit_ok ]; then
                        event_emit repair_success "slot=$slot" "iface=$iface" "old_identity=$sm_identity"                             "old_endpoint=$sm_endpoint" "candidate=$candidate_endpoint" "https_quorum=$https_quorum/3"
                    else
                        event_emit repair_failed "slot=$slot" "iface=$iface" "identity=$sm_identity"                             "endpoint=$sm_endpoint" "candidate=$candidate_endpoint" "dispatcher_rc=$dispatcher_rc"                             "decision=$decision" "adapter_reason=${adapter_reason:-none}"
                    fi
                    rm -f "$commit_out" "$commit_err"
                else
                    dispatcher_rc="$dry_rc"
                    decision="$dry_decision"
                    [ -n "$decision" ] || decision=dry_run_failed_no_decision
                    action=dry_run_dispatch
                    if [ "$MODE" = --commit ]; then
                        case "$adapter_reason" in
                            no_pool_file|stale_pool|no_eligible_candidate_with_config)
                                refresh_request_reason="$adapter_reason"
                                # shellcheck disable=SC1090
                                . "$STATE_HELPER"
                                refresh_request_result="$(reg_request_full_refresh "$adapter_reason" "$slot" 2>/dev/null)"
                                refresh_request_rc=$?
                                if [ "$refresh_request_rc" -eq 0 ]; then
                                    action=request_full_refresh
                                    any_action=true
                                    event_emit full_refresh_requested "slot=$slot" "iface=$iface" "identity=$sm_identity"                                         "endpoint=$sm_endpoint" "reason=$adapter_reason" "result=$refresh_request_result"
                                else
                                    [ -n "$refresh_request_result" ] || refresh_request_result=ERROR_UNKNOWN
                                    action=request_full_refresh_failed
                                    event_emit full_refresh_request_failed "slot=$slot" "iface=$iface" "identity=$sm_identity"                                         "endpoint=$sm_endpoint" "reason=$adapter_reason" "result=$refresh_request_result"
                                fi
                                ;;
                        esac
                    fi
                fi
                rm -f "$dry_out"
            fi
        fi

        $first || printf ',\n' >>"$json"
        first=false
        printf '    {"slot":"%s","iface":"%s","health_ok":%s,"https_quorum":%s,"fail_count":%s,"decision":"%s","action":"%s","dispatcher_rc":%s,"required_confirm":"%s","adapter_reason":"%s","adapter_selected_pool":"%s","adapter_selected_pool_age_sec":%s,"adapter_available_candidate_count":%s,"candidate_endpoint":"%s","refresh_request_reason":"%s","refresh_request_result":"%s"}' \
            "$(json_escape "$slot")" "$(json_escape "$iface")" "$health_ok" "$https_quorum" "$fail_count" \
            "$(json_escape "$decision")" "$(json_escape "$action")" "$dispatcher_rc" \
            "$(json_escape "$required_confirm")" "$(json_escape "$adapter_reason")" \
            "$(json_escape "$adapter_selected_pool")" "$adapter_selected_pool_age_sec" \
            "$adapter_available_candidate_count" "$(json_escape "$candidate_endpoint")" \
            "$(json_escape "$refresh_request_reason")" "$(json_escape "$refresh_request_result")" >>"$json"
    done <"$rows"

    if [ "$cycle_total" -gt 0 ] && [ "$cycle_healthy" -eq "$cycle_total" ]; then
        last_heartbeat="$(uint_or_zero "$(cat "$HEARTBEAT_FILE" 2>/dev/null || true)")"
        if [ $((now - last_heartbeat)) -ge "$HEARTBEAT_SEC" ]; then
            event_emit heartbeat "all_healthy=true" "healthy_slots=$cycle_healthy/$cycle_total" "mode=$MODE"
            printf '%s\n' "$now" >"$HEARTBEAT_FILE"
        fi
    fi

    printf '{\n  "schema":"router-egress-health-repair-watch-v6",\n  "mode":"%s",\n  "run_mode":"%s",\n  "any_action":%s,\n  "slots":[\n' \
        "$(json_escape "$MODE")" "$RUN_MODE" "$any_action"
    cat "$json"
    printf '\n  ]\n}\n'
    health_log_bound || true
}

if [ "$ENABLED" != "1" ] && [ "$ONCE" != true ]; then
    echo "health_repair disabled by $VM101_CONF"
    exit 0
fi

run_initial_full_refresh_if_due() {
    [ -x "$FULL_REFRESH_ORCHESTRATOR" ] || return 0
    [ -r "$STATE_HELPER" ] || return 0
    # Health watcher may trigger the initial threshold refresh only. Durable
    # DEGRADED_POOL scheduling belongs exclusively to the retry controller.
    # shellcheck disable=SC1090
    . "$STATE_HELPER"
    watcher_mode="$(reg_get_state mode NORMAL 2>/dev/null || echo NORMAL)"
    [ "$watcher_mode" = FULL_POOL_REFRESH_PENDING ] || return 0
    ROUTER_EGRESS_HEALTH_SERVICE_MANAGED_BY_CALLER=1 "$FULL_REFRESH_ORCHESTRATOR" --run-if-due >"$WATCH_STATE_DIR/full-refresh-last.log.tmp" 2>&1
    rc=$?
    mv "$WATCH_STATE_DIR/full-refresh-last.log.tmp" "$WATCH_STATE_DIR/full-refresh-last.log" 2>/dev/null || true
    return "$rc"
}

if [ "$ONCE" = true ]; then
    run_once
    exit 0
fi

while true; do
    run_once >"$WATCH_STATE_DIR/last.json.tmp" 2>"$WATCH_STATE_DIR/last.err.tmp" || true
    mv "$WATCH_STATE_DIR/last.json.tmp" "$WATCH_STATE_DIR/last.json" 2>/dev/null || true
    mv "$WATCH_STATE_DIR/last.err.tmp" "$WATCH_STATE_DIR/last.err" 2>/dev/null || true
    run_initial_full_refresh_if_due || true
    sleep "$INTERVAL_SEC"
done
