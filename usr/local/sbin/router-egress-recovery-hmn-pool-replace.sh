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
operation_lock=""
operation_lock_owned=false
trap 'rm -f "$out" "$err"; [ "$operation_lock_owned" = "true" ] && rmdir "$operation_lock" 2>/dev/null || true' EXIT HUP INT TERM

if [ ! -x "$ADAPTER_CORE" ]; then
    echo "adapter_core_missing=$ADAPTER_CORE" >&2
    exit 23
fi
if [ ! -r "$HELPER" ]; then
    echo "state_helper_missing=$HELPER" >&2
    exit 24
fi

if [ "$apply_requested" = "true" ] && [ "$dry_run" = "false" ]; then
    recovery_state_dir="${STATE_DIR:-/var/lib/router-egress-recovery}"
    mkdir -p "$recovery_state_dir/locks" 2>/dev/null || {
        echo '{"schema":"router-egress-hmn-slot-replace-v4","decision":"refuse","reason":"local_repair_lock_dir_failed","apply_performed":false}'
        exit 32
    }
    operation_lock="$recovery_state_dir/locks/local-repair.lock"
    if ! mkdir "$operation_lock" 2>/dev/null; then
        echo '{"schema":"router-egress-hmn-slot-replace-v4","decision":"refuse","reason":"local_repair_lock_busy","apply_performed":false}'
        exit 32
    fi
    operation_lock_owned=true
fi

ROUTER_EGRESS_LOCAL_REPAIR_LOCK_HELD=1 "$ADAPTER_CORE" "$@" >"$out" 2>"$err"
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
state_restore_ok=false
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

    # shellcheck disable=SC1090
    . "$HELPER"
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

            if reg_quarantine_endpoint "$old_ep" "$egress" "$iface" "$new_ep" "repair_replaced_endpoint" "$pool_path" "STEP_050M07R15A_LEGACY_EXECUTION_FREEZE_AND_CLEAN_FOUNDATION" >/dev/null 2>&1; then
                global_count="$(reg_repair_events_inc 2>/dev/null || true)"
                case "$global_count:$FULL_REFRESH_AFTER_REPAIRS" in
                    *[!0-9:]*) full_refresh_due=false ;;
                    *) [ "$global_count" -ge "$FULL_REFRESH_AFTER_REPAIRS" ] && full_refresh_due=true || full_refresh_due=false ;;
                esac

                if [ -n "$global_count" ]; then
                    now="$(reg_now_epoch 2>/dev/null || date +%s)"
                    if reg_set_state mode LOCAL_REPAIR_READY >/dev/null 2>&1 \
                        && reg_set_state last_repair_epoch "$now" >/dev/null 2>&1 \
                        && reg_set_state last_repair_egress "$egress" >/dev/null 2>&1 \
                        && reg_set_state last_repair_iface "$iface" >/dev/null 2>&1 \
                        && reg_set_state last_repair_old_endpoint "$old_ep" >/dev/null 2>&1 \
                        && reg_set_state last_repair_new_endpoint "$new_ep" >/dev/null 2>&1 \
                        && reg_set_state repair_events_since_full_refresh "$global_count" >/dev/null 2>&1 \
                        && reg_set_state full_refresh_due "$full_refresh_due" >/dev/null 2>&1; then
                        record_ok=true
                    fi
                fi
            fi

            if [ "$record_ok" != "true" ]; then
                restore_failed=false
                head -n "$quarantine_lines" "$REG_QUARANTINE_TSV" >"${REG_QUARANTINE_TSV}.restore.$$" 2>/dev/null \
                    && mv "${REG_QUARANTINE_TSV}.restore.$$" "$REG_QUARANTINE_TSV" \
                    || restore_failed=true
                cp -p "$state_txn_dir/state.kv.before" "$REG_STATE_KV" 2>/dev/null || restore_failed=true

                if [ "$(cat "$state_txn_dir/global.existed")" = "1" ]; then
                    cp -p "$state_txn_dir/global.before" "$global_file" 2>/dev/null || restore_failed=true
                else
                    rm -f "$global_file" 2>/dev/null || restore_failed=true
                fi
                [ "$restore_failed" = "false" ] && state_restore_ok=true
            fi

            rm -rf "$state_txn_dir" 2>/dev/null || true
            rmdir "$state_lock" 2>/dev/null || true
        fi
        [ -n "$state_txn_dir" ] && rm -rf "$state_txn_dir" 2>/dev/null || true
        [ -n "$state_lock" ] && rmdir "$state_lock" 2>/dev/null || true
    fi

    mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
    printf '%s action=record_successful_repair egress=%s iface=%s old=%s new=%s pool=%s repair_events=%s full_refresh_due=%s record_ok=%s state_restore_ok=%s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" \
        "$egress" "$iface" "$old_ep" "$new_ep" "$pool_path" "$global_count" "$full_refresh_due" "$record_ok" "$state_restore_ok" >>"$LOG" 2>/dev/null || true

    if [ "$record_ok" != "true" ]; then
        state_failure=true
        if [ -n "$rollback_file" ] && [ -x "$rollback_file" ] && "$rollback_file" >/dev/null 2>&1; then
            restored="$(uci -q get "network.${iface}.hmn_endpoint" 2>/dev/null || true)"
            [ "$restored" = "$old_ep" ] && network_rollback_ok=true
        fi
    fi
fi

if [ "$state_failure" = "true" ]; then
    cat "$err" >&2 2>/dev/null || true
    printf '{"schema":"router-egress-hmn-slot-replace-v4","slot":"%s","interface":"%s","current_endpoint":"%s","candidate_endpoint":"%s","pool_path":"%s","decision":"commit_failed","reason":"state_record_failed_after_network_success","apply_performed":true,"rollback_performed":true,"network_rollback_ok":%s,"state_restore_ok":%s}\n' \
        "$egress" "$iface" "$old_ep" "$new_ep" "$pool_path" "$network_rollback_ok" "$state_restore_ok"
    echo "state_record_failed_after_success=true network_rollback_ok=$network_rollback_ok state_restore_ok=$state_restore_ok" >&2
    exit 31
fi
cat "$out" 2>/dev/null || true
cat "$err" >&2 2>/dev/null || true
exit "$rc"
