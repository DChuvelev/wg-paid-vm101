#!/bin/sh
# STEP_050M07R15A_LEGACY_EXECUTION_FREEZE_AND_CLEAN_FOUNDATION
set -u

CONF="${ROUTER_EGRESS_RECOVERY_HMN_CONF:-/etc/router-egress-recovery-hmn.conf}"
[ -f "$CONF" ] && . "$CONF"

ADAPTER_CORE_DEFAULT="/usr/local/lib/router-egress-hmn-slot-replace.sh"
ADAPTER_CORE="${ROUTER_EGRESS_RECOVERY_CORE_OVERRIDE:-$ADAPTER_CORE_DEFAULT}"
HELPER="${ROUTER_EGRESS_RECOVERY_STATE_HELPER:-${STATE_HELPER:-/usr/local/lib/router-egress-recovery-state.sh}}"
LOG="${ROUTER_EGRESS_RECOVERY_STATE_LOG:-${LOG:-/var/log/router-egress-recovery-state.log}}"
FULL_REFRESH_AFTER_REPAIRS="${FULL_REFRESH_AFTER_REPAIRS:-5}"

egress=""
dry_run=false
apply_requested=false
prev=""

for arg in "$@"; do
    if [ "$prev" = "egress" ]; then
        egress="$arg"
        prev=""
        continue
    fi
    if [ "$prev" = "confirm" ]; then
        prev=""
        continue
    fi
    case "$arg" in
        --egress|--slot) prev="egress" ;;
        --confirm) apply_requested=true; prev="confirm" ;;
        --apply|--commit) apply_requested=true ;;
        --dry-run|--dryrun) dry_run=true ;;
        egress[1-5]) [ -n "$egress" ] || egress="$arg" ;;
    esac
done

[ "$dry_run" = "true" ] && apply_requested=false

case "$egress" in
    egress1) iface="vpn1" ;;
    egress2) iface="vpn2" ;;
    egress3) iface="vpn3" ;;
    egress4) iface="vpn4" ;;
    egress5) iface="vpn5" ;;
    *) iface="" ;;
esac

old_ep="${ROUTER_EGRESS_RECOVERY_OLD_ENDPOINT_OVERRIDE:-}"
if [ -z "$old_ep" ] && [ -n "$iface" ]; then
    old_ep="$(uci -q get "network.${iface}.hmn_endpoint" 2>/dev/null || true)"
fi

tmp_base="/tmp/router-egress-recovery-hmn-wrapper.$$"
out="${tmp_base}.out"
err="${tmp_base}.err"
coordinator_lock=""
coordinator_lock_owned=false
operation_lock=""
operation_lock_owned=false
trap 'rm -f "$out" "$err"; [ "$operation_lock_owned" = "true" ] && reg_lock_release "$operation_lock" >/dev/null 2>&1 || true; [ "$coordinator_lock_owned" = "true" ] && reg_lock_release "$coordinator_lock" >/dev/null 2>&1 || true' EXIT HUP INT TERM

if [ ! -x "$ADAPTER_CORE" ]; then
    echo "adapter_core_missing=$ADAPTER_CORE" >&2
    exit 23
fi
if [ ! -r "$HELPER" ]; then
    echo "state_helper_missing=$HELPER" >&2
    exit 24
fi
# shellcheck disable=SC1090
. "$HELPER"

if [ "$apply_requested" = "true" ] && [ "$dry_run" = "false" ]; then
    reg_init_state >/dev/null 2>&1 || {
        echo '{"schema":"router-egress-hmn-slot-replace-v4","decision":"refuse","reason":"local_repair_state_init_failed","apply_performed":false}'
        exit 32
    }
    coordinator_lock="$(reg_lock_acquire recovery-coordinator.lock local-repair 2>/dev/null || true)"
    if [ -z "$coordinator_lock" ]; then
        echo '{"schema":"router-egress-hmn-slot-replace-v4","decision":"refuse","reason":"recovery_coordinator_lock_busy","apply_performed":false}'
        exit 32
    fi
    coordinator_lock_owned=true
    operation_lock="$(reg_lock_acquire local-repair.lock local-repair 2>/dev/null || true)"
    if [ -z "$operation_lock" ]; then
        echo '{"schema":"router-egress-hmn-slot-replace-v4","decision":"refuse","reason":"local_repair_lock_busy","apply_performed":false}'
        exit 32
    fi
    operation_lock_owned=true
fi

ROUTER_EGRESS_COORDINATOR_LOCK_HELD=1 ROUTER_EGRESS_LOCAL_REPAIR_LOCK_HELD=1 "$ADAPTER_CORE" "$@" >"$out" 2>"$err"
rc=$?

decision="$(sed -n 's/.*"decision": "\([^"]*\)".*/\1/p' "$out" 2>/dev/null | tail -n 1)"
new_ep="${ROUTER_EGRESS_RECOVERY_NEW_ENDPOINT_OVERRIDE:-}"
if [ -z "$new_ep" ] && [ -n "$iface" ]; then
    new_ep="$(uci -q get "network.${iface}.hmn_endpoint" 2>/dev/null || true)"
fi

pool_path="$(sed -n 's/.*"pool_path": "\([^"]*\)".*/\1/p' "$out" 2>/dev/null | tail -n 1)"
[ -n "$pool_path" ] || pool_path="$(sed -n 's/.*"selected_pool": "\([^"]*\)".*/\1/p' "$out" 2>/dev/null | tail -n 1)"
rollback_file="$(sed -n 's/.*"rollback_file": "\([^"]*\)".*/\1/p' "$out" 2>/dev/null | tail -n 1)"

record_ok=false
global_count=""
full_refresh_due=false
state_failure=false
state_restore_needed=false
state_restore_ok=not_required
state_restore_ok_json=true
network_rollback_ok=false
state_lock=""
state_txn_dir=""

if [ "$rc" -eq 0 ] \
    && [ "$decision" = "commit_ok" ] \
    && [ "$apply_requested" = "true" ] \
    && [ "$dry_run" = "false" ] \
    && [ -n "$egress" ] \
    && [ -n "$iface" ] \
    && [ -n "$old_ep" ] \
    && [ -n "$new_ep" ] \
    && [ "$old_ep" != "$new_ep" ]; then

    if reg_init_state >/dev/null 2>&1; then
        state_lock="${REG_LOCK_DIR}/local-repair-state.lock"
        state_txn_dir="/tmp/router-egress-repair-state-txn.$$"
        if mkdir "$state_lock" 2>/dev/null && mkdir -p "$state_txn_dir"; then
            quarantine_lines="$(wc -l <"$REG_QUARANTINE_TSV" 2>/dev/null | tr -d ' ')"
            [ -n "$quarantine_lines" ] || quarantine_lines=0
            cp -p "$REG_STATE_KV" "$state_txn_dir/state.kv.before" 2>/dev/null || : >"$state_txn_dir/state.kv.before"

            global_file="$(reg_counter_file "$REG_REPAIR_EVENTS_KEY")"
            if [ -e "$global_file" ]; then
                cp -p "$global_file" "$state_txn_dir/global.before"
                echo 1 >"$state_txn_dir/global.existed"
            else
                echo 0 >"$state_txn_dir/global.existed"
            fi

            if reg_quarantine_endpoint "$old_ep" "$egress" "$iface" "$new_ep" "repair_replaced_endpoint" "$pool_path" "router-egress-local-repair" >/dev/null 2>&1; then
                global_count="$(reg_repair_events_inc 2>/dev/null || true)"
                case "$global_count:$FULL_REFRESH_AFTER_REPAIRS" in
                    *[!0-9:]*) full_refresh_due=false ;;
                    *) [ "$global_count" -ge "$FULL_REFRESH_AFTER_REPAIRS" ] && full_refresh_due=true || full_refresh_due=false ;;
                esac

                if [ -n "$global_count" ]; then
                    now="$(reg_now_epoch 2>/dev/null || date +%s)"
                    current_mode="$(reg_get_state mode NORMAL 2>/dev/null || echo NORMAL)"
                    case "$current_mode" in
                        DEGRADED_POOL|DEGRADED_POOL_PENDING)
                            next_mode=DEGRADED_POOL
                            full_refresh_due=true
                            ;;
                        *)
                            if [ "$full_refresh_due" = true ]; then next_mode=FULL_POOL_REFRESH_PENDING; else next_mode=NORMAL; fi
                            ;;
                    esac
                    if reg_state_update mode "$next_mode" last_repair_epoch "$now" last_repair_egress "$egress" last_repair_iface "$iface" last_repair_old_endpoint "$old_ep" last_repair_new_endpoint "$new_ep" repair_events_since_full_refresh "$global_count" full_refresh_due "$full_refresh_due" >/dev/null 2>&1; then
                        record_ok=true
                    fi
                fi
            fi

            if [ "$record_ok" != "true" ]; then
                state_restore_needed=true
                state_restore_ok=failed
                state_restore_ok_json=false
                restore_failed=false
                head -n "$quarantine_lines" "$REG_QUARANTINE_TSV" >"${REG_QUARANTINE_TSV}.restore.$$" 2>/dev/null \
                    && mv "${REG_QUARANTINE_TSV}.restore.$$" "$REG_QUARANTINE_TSV" \
                    || restore_failed=true
                if [ -s "$state_txn_dir/state.kv.before" ]; then
                    reg_state_commit_candidate "$state_txn_dir/state.kv.before" >/dev/null 2>&1 || restore_failed=true
                else
                    restore_failed=true
                fi

                if [ "$(cat "$state_txn_dir/global.existed")" = "1" ]; then
                    cp -p "$state_txn_dir/global.before" "$global_file" 2>/dev/null || restore_failed=true
                else
                    rm -f "$global_file" 2>/dev/null || restore_failed=true
                fi
                [ "$restore_failed" = "false" ] && { state_restore_ok=succeeded; state_restore_ok_json=true; }
            fi

            rm -rf "$state_txn_dir" 2>/dev/null || true
            rmdir "$state_lock" 2>/dev/null || true
        fi
        [ -n "$state_txn_dir" ] && rm -rf "$state_txn_dir" 2>/dev/null || true
        [ -n "$state_lock" ] && rmdir "$state_lock" 2>/dev/null || true
    fi

    mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
    printf '%s action=record_successful_repair egress=%s iface=%s old=%s new=%s pool=%s repair_events=%s full_refresh_due=%s record_ok=%s state_restore_needed=%s state_restore_ok=%s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" \
        "$egress" "$iface" "$old_ep" "$new_ep" "$pool_path" "$global_count" "$full_refresh_due" "$record_ok" "$state_restore_needed" "$state_restore_ok" >>"$LOG" 2>/dev/null || true

    if [ "$record_ok" = "true" ]; then
        reg_event_append local_repair PASS "" "$iface" "$old_ep" "$new_ep" "" "" repair_replaced_endpoint "$((global_count - 1))" "$global_count" "egress=$egress pool=$pool_path" >/dev/null 2>&1 || true
    fi

    if [ "$record_ok" != "true" ]; then
        reg_event_append local_repair FAILED "" "$iface" "$old_ep" "$new_ep" "" "" state_record_failed "" "$global_count" "egress=$egress rollback_pending=true" >/dev/null 2>&1 || true
        state_failure=true
        if [ -n "$rollback_file" ] && [ -x "$rollback_file" ] && "$rollback_file" >/dev/null 2>&1; then
            restored="$(uci -q get "network.${iface}.hmn_endpoint" 2>/dev/null || true)"
            [ "$restored" = "$old_ep" ] && network_rollback_ok=true
        fi
    fi
fi

if [ "$state_failure" = "true" ]; then
    cat "$err" >&2 2>/dev/null || true
    printf '{"schema":"router-egress-hmn-slot-replace-v4","slot":"%s","interface":"%s","current_endpoint":"%s","candidate_endpoint":"%s","pool_path":"%s","decision":"commit_failed","reason":"state_record_failed_after_network_success","apply_performed":true,"rollback_performed":true,"network_rollback_ok":%s,"state_restore_needed":%s,"state_restore_ok":%s,"state_restore_status":"%s"}\n' \
        "$egress" "$iface" "$old_ep" "$new_ep" "$pool_path" "$network_rollback_ok" "$state_restore_needed" "$state_restore_ok_json" "$state_restore_ok"
    echo "state_record_failed_after_success=true network_rollback_ok=$network_rollback_ok state_restore_ok=$state_restore_ok" >&2
    exit 31
fi
cat "$out" 2>/dev/null || true
cat "$err" >&2 2>/dev/null || true
exit "$rc"
