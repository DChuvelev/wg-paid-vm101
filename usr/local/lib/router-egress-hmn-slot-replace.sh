#!/bin/sh
set -u

CONF="${ROUTER_EGRESS_RECOVERY_HMN_CONF:-/etc/router-egress-recovery-hmn.conf}"
[ -f "$CONF" ] && . "$CONF"

MODE="${MODE:---dry-run}"
SLOT=""
CONFIRM=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --slot|--egress)
            [ "$#" -ge 2 ] || { echo "ERROR=slot_value_missing" >&2; exit 2; }
            SLOT="$2"
            shift 2
            ;;
        --dry-run|--dryrun)
            MODE="--dry-run"
            shift
            ;;
        --commit|--apply)
            MODE="--commit"
            shift
            ;;
        --confirm)
            [ "$#" -ge 2 ] || { echo "ERROR=confirm_value_missing" >&2; exit 2; }
            CONFIRM="$2"
            shift 2
            ;;
        *)
            echo "ERROR=unsupported_argument:$1" >&2
            exit 2
            ;;
    esac
done

SLOTS_CONF="${SLOTS_CONF:-/etc/router-egress-slots.d/slots.conf}"
HMN_CACHE_DIR="${HMN_CACHE_DIR:-/root/hmn/cache}"
MAX_POOL_AGE_SEC="${MAX_POOL_AGE_SEC:-129600}"
PREFERRED_POOL_FILES="${PREFERRED_POOL_FILES:-ok-awg1-strict-foreign-latest.tsv ok-awg1-strict-all-latest.tsv working-awg1-latest.tsv ranked-awg1-latest.tsv}"
STATE_DIR="${STATE_DIR:-/var/lib/router-egress-recovery}"
STATE_HELPER="${STATE_HELPER:-/usr/local/lib/router-egress-recovery-state.sh}"
LOG="${LOG:-/var/log/router-egress-recovery-hmn.log}"
REQUIRE_EXPLICIT_COMMIT="${REQUIRE_EXPLICIT_COMMIT:-1}"
POST_APPLY_SLEEP_SEC="${POST_APPLY_SLEEP_SEC:-12}"
LOCAL_REPAIR_CANDIDATE_RETRIES="${LOCAL_REPAIR_CANDIDATE_RETRIES:-3}"
SLOTS_APPLY="${SLOTS_APPLY:-/usr/local/sbin/router-egress-slots-apply.sh}"

UCI_BIN="${UCI_BIN:-uci}"
IP_BIN="${IP_BIN:-ip}"
PING_BIN="${PING_BIN:-ping}"
IFUP_BIN="${IFUP_BIN:-ifup}"
IFDOWN_BIN="${IFDOWN_BIN:-ifdown}"
SLEEP_BIN="${SLEEP_BIN:-sleep}"

mkdir -p "$STATE_DIR" "$(dirname "$LOG")" 2>/dev/null || true

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

is_uint() {
    printf '%s\n' "$1" | grep -Eq '^[0-9]+$'
}

valid_endpoint() {
    printf '%s\n' "$1" | grep -Eq '^([A-Za-z0-9._-]+\.[A-Za-z]{2,}|[0-9]{1,3}(\.[0-9]{1,3}){3}):[0-9]{2,5}$'
}

extract_endpoints() {
    file="$1"
    grep -Eho '([A-Za-z0-9._-]+\.[A-Za-z]{2,}|[0-9]{1,3}(\.[0-9]{1,3}){3}):[0-9]{2,5}' "$file" 2>/dev/null \
        | sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//' \
        | grep -E '^([A-Za-z0-9._-]+\.[A-Za-z]{2,}|[0-9]{1,3}(\.[0-9]{1,3}){3}):[0-9]{2,5}$' \
        | awk '!seen[$0]++'
}

endpoint_count() {
    extract_endpoints "$1" | wc -l | tr -d ' '
}

current_endpoint_for_iface() {
    iface="$1"
    endpoint="$("$UCI_BIN" -q get "network.${iface}.hmn_endpoint" 2>/dev/null || true)"
    if [ -z "$endpoint" ]; then
        host="$("$UCI_BIN" -q get "network.awg_${iface}.endpoint_host" 2>/dev/null || "$UCI_BIN" -q get "network.amneziawg_${iface}.endpoint_host" 2>/dev/null || true)"
        port="$("$UCI_BIN" -q get "network.awg_${iface}.endpoint_port" 2>/dev/null || "$UCI_BIN" -q get "network.amneziawg_${iface}.endpoint_port" 2>/dev/null || true)"
        [ -n "$host" ] && [ -n "$port" ] && endpoint="${host}:${port}"
    fi
    printf '%s\n' "$endpoint"
}

set_endpoint_for_iface() {
    iface="$1"
    endpoint="$2"
    if [ -n "$endpoint" ]; then
        "$UCI_BIN" set "network.${iface}.hmn_endpoint=${endpoint}" || return 1
    else
        "$UCI_BIN" -q delete "network.${iface}.hmn_endpoint" 2>/dev/null || true
    fi
    "$UCI_BIN" commit network
}

strict_ping() {
    iface="$1"
    targets_csv="$2"
    count="$3"
    timeout="$4"
    old_ifs="$IFS"
    IFS=','
    for target in $targets_csv; do
        IFS="$old_ifs"
        [ -n "$target" ] || continue
        out="/tmp/router-egress-repair-ping.$$.out"
        err="/tmp/router-egress-repair-ping.$$.err"
        if ! "$PING_BIN" -I "$iface" -c "$count" -W "$timeout" "$target" >"$out" 2>"$err"; then
            rm -f "$out" "$err"
            return 1
        fi
        received="$(grep -Eo '[0-9]+ packets received' "$out" 2>/dev/null | awk '{print $1}' | tail -1)"
        if [ -n "$received" ] && [ "$received" != "$count" ]; then
            rm -f "$out" "$err"
            return 1
        fi
        rm -f "$out" "$err"
        IFS=','
    done
    IFS="$old_ifs"
    return 0
}

write_result() {
    result_file="$1"
    {
        echo '{'
        echo '  "schema": "router-egress-hmn-slot-replace-v3",'
        echo "  \"mode\": \"$(json_escape "$MODE")\","
        echo "  \"epoch\": ${now},"
        echo "  \"iso\": \"$(json_escape "$iso")\","
        echo "  \"slot\": \"$(json_escape "$SLOT")\","
        echo "  \"interface\": \"$(json_escape "$iface")\","
        echo "  \"table\": \"$(json_escape "$table")\","
        echo "  \"mark\": \"$(json_escape "$mark")\","
        echo "  \"dscp\": \"$(json_escape "$dscp")\","
        echo "  \"provider\": \"$(json_escape "$provider")\","
        echo "  \"adapter\": \"$(json_escape "$adapter")\","
        echo "  \"current_endpoint\": \"$(json_escape "$current_ep")\","
        echo "  \"selected_pool\": \"$(json_escape "$selected_pool")\","
        echo "  \"pool_path\": \"$(json_escape "$selected_pool")\","
        echo "  \"selected_pool_age_sec\": ${selected_pool_age_sec},"
        echo "  \"max_pool_age_sec\": ${MAX_POOL_AGE_SEC},"
        echo "  \"selected_pool_endpoint_count\": ${selected_pool_endpoint_count},"
        echo "  \"pool_is_fresh\": ${pool_is_fresh},"
        echo "  \"available_candidate_count\": ${candidate_count},"
        echo "  \"candidate_endpoint\": \"$(json_escape "$candidate")\","
        echo "  \"candidate_attempts\": ${candidate_attempts},"
        echo "  \"decision\": \"$(json_escape "$decision")\","
        echo "  \"reason\": \"$(json_escape "$reason")\","
        echo "  \"apply_performed\": ${apply_performed},"
        echo "  \"apply_rc\": ${apply_rc},"
        echo "  \"post_strict_ok\": ${post_strict_ok},"
        echo "  \"rollback_performed\": ${rollback_performed},"
        echo "  \"rollback_ok\": ${rollback_ok},"
        echo "  \"rollback_file\": \"$(json_escape "$rollback_file")\","
        echo '  "safety": {'
        echo "    \"requires_explicit_commit\": $([ "$REQUIRE_EXPLICIT_COMMIT" = "1" ] && echo true || echo false),"
        echo '    "slot_is_required": true,'
        echo '    "quarantine_is_enforced": true,'
        echo '    "failed_candidates_are_quarantined": true,'
        echo '    "all_candidates_failed_restores_original_endpoint": true,'
        echo '    "no_vm100_change": true'
        echo '  }'
        echo '}'
    } >"$result_file"
}

if [ -z "$SLOT" ]; then
    echo '{"schema":"router-egress-hmn-slot-replace-v3","decision":"refuse","reason":"slot_required","apply_performed":false}'
    exit 2
fi

if [ ! -r "$SLOTS_CONF" ]; then
    echo '{"schema":"router-egress-hmn-slot-replace-v3","decision":"refuse","reason":"slots_conf_missing","apply_performed":false}'
    exit 2
fi

if [ ! -r "$STATE_HELPER" ]; then
    echo '{"schema":"router-egress-hmn-slot-replace-v3","decision":"refuse","reason":"state_helper_missing","apply_performed":false}'
    exit 2
fi

# shellcheck disable=SC1090
. "$STATE_HELPER"
reg_init_state >/dev/null 2>&1 || {
    echo '{"schema":"router-egress-hmn-slot-replace-v3","decision":"refuse","reason":"state_init_failed","apply_performed":false}'
    exit 2
}

operation_lock=""
operation_lock_owned=false

slot_line="$(grep -Ev '^[[:space:]]*(#|$)' "$SLOTS_CONF" | awk -v slot="$SLOT" '$1==slot {print; exit}')"
if [ -z "$slot_line" ]; then
    echo '{"schema":"router-egress-hmn-slot-replace-v3","decision":"refuse","reason":"slot_not_found","apply_performed":false}'
    exit 2
fi

set -- $slot_line
slot_id="$1"
iface="$2"
table="$3"
mark="$4"
dscp="$5"
provider="$6"
adapter="$7"
health_targets="$8"
strict_count="$9"
shift 9
strict_timeout="$1"
enabled="$2"

if [ "$provider" != "hidemyname" ] || [ "$adapter" != "hmn_pool_replace" ]; then
    echo '{"schema":"router-egress-hmn-slot-replace-v3","decision":"refuse","reason":"wrong_provider_or_adapter","apply_performed":false}'
    exit 2
fi
if [ "$enabled" != "1" ]; then
    echo '{"schema":"router-egress-hmn-slot-replace-v3","decision":"refuse","reason":"slot_disabled","apply_performed":false}'
    exit 2
fi
is_uint "$table" || { echo '{"schema":"router-egress-hmn-slot-replace-v3","decision":"refuse","reason":"invalid_table","apply_performed":false}'; exit 2; }
is_uint "$strict_count" || strict_count=3
is_uint "$strict_timeout" || strict_timeout=2
is_uint "$LOCAL_REPAIR_CANDIDATE_RETRIES" || LOCAL_REPAIR_CANDIDATE_RETRIES=3
[ "$LOCAL_REPAIR_CANDIDATE_RETRIES" -gt 0 ] || LOCAL_REPAIR_CANDIDATE_RETRIES=1

now="$(date +%s)"
iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
current_ep="$(current_endpoint_for_iface "$iface")"

used_file="/tmp/router-egress-hmn-used.$$"
pool_file="/tmp/router-egress-hmn-pool.$$"
candidate_file="/tmp/router-egress-hmn-candidates.$$"
result_file="${STATE_DIR}/hmn-pool-replace-last.json"
trap 'rm -f "$used_file" "$pool_file" "$candidate_file"; [ "$operation_lock_owned" = "true" ] && rmdir "$operation_lock" 2>/dev/null || true' EXIT HUP INT TERM

if [ "$MODE" = "--commit" ] && [ "${ROUTER_EGRESS_LOCAL_REPAIR_LOCK_HELD:-0}" != "1" ]; then
    operation_lock="${REG_LOCK_DIR}/local-repair.lock"
    if ! mkdir "$operation_lock" 2>/dev/null; then
        echo '{"schema":"router-egress-hmn-slot-replace-v3","decision":"refuse","reason":"local_repair_lock_busy","apply_performed":false}'
        exit 2
    fi
    operation_lock_owned=true
fi

: >"$used_file"
for active_iface in vpn1 vpn2 vpn3 vpn4 vpn5; do
    endpoint="$(current_endpoint_for_iface "$active_iface")"
    [ -n "$endpoint" ] && printf '%s\n' "$endpoint" >>"$used_file"
done
sort -u "$used_file" -o "$used_file"

selected_pool=""
selected_pool_age_sec=999999999
selected_pool_endpoint_count=0
for name in $PREFERRED_POOL_FILES; do
    file="${HMN_CACHE_DIR}/${name}"
    [ -s "$file" ] || continue
    count="$(endpoint_count "$file")"
    [ "$count" -gt 0 ] || continue
    selected_pool="$file"
    mtime="$(reg_pool_mtime_epoch "$file")"
    [ -n "$mtime" ] || mtime=0
    selected_pool_age_sec=$((now - mtime))
    selected_pool_endpoint_count="$count"
    break
done

pool_is_fresh=false
candidate_count=0
candidate=""
if [ -n "$selected_pool" ]; then
    [ "$selected_pool_age_sec" -le "$MAX_POOL_AGE_SEC" ] && pool_is_fresh=true
    extract_endpoints "$selected_pool" >"$pool_file"
    : >"$candidate_file"
    while IFS= read -r endpoint; do
        [ -n "$endpoint" ] || continue
        grep -Fx "$endpoint" "$used_file" >/dev/null 2>&1 && continue
        reg_endpoint_quarantined_for_pool "$endpoint" "$selected_pool" && continue
        printf '%s\n' "$endpoint" >>"$candidate_file"
    done <"$pool_file"
    candidate_count="$(wc -l <"$candidate_file" | tr -d ' ')"
    candidate="$(head -n 1 "$candidate_file" 2>/dev/null || true)"
fi

decision="refuse"
reason="unknown"
apply_performed=false
apply_rc=0
post_strict_ok=false
rollback_performed=false
rollback_ok=false
rollback_file=""
candidate_attempts=0

if [ -z "$selected_pool" ]; then
    reason="no_pool_file"
elif [ "$pool_is_fresh" != "true" ]; then
    reason="stale_pool"
elif [ "$candidate_count" -eq 0 ] || [ -z "$candidate" ]; then
    reason="no_eligible_candidate"
elif [ "$MODE" = "--dry-run" ]; then
    decision="dry_run_ok"
    reason="dry_run_candidate_selected"
elif [ "$MODE" = "--commit" ]; then
    valid_endpoint "$current_ep" || {
        decision="refuse"
        reason="current_endpoint_missing_or_invalid"
        write_result "$result_file"
        cat "$result_file"
        exit 2
    }
    expected="APPLY_${SLOT}_${iface}_${candidate}"
    if [ "$REQUIRE_EXPLICIT_COMMIT" = "1" ] && [ "$CONFIRM" != "$expected" ]; then
        decision="refuse"
        reason="missing_or_wrong_confirm_token"
    else
        backup_dir="${STATE_DIR}/backup-${SLOT}-$(date -u +%Y%m%d-%H%M%S)"
        mkdir -p "$backup_dir" || {
            decision="refuse"
            reason="backup_dir_create_failed"
            write_result "$result_file"
            cat "$result_file"
            exit 2
        }
        "$UCI_BIN" show network >"${backup_dir}/network.uci.before" 2>/dev/null || true
        "$IP_BIN" route show table "$table" >"${backup_dir}/table.before" 2>/dev/null || true

        rollback_file="${backup_dir}/rollback-${SLOT}.sh"
        cat >"$rollback_file" <<EOF
#!/bin/sh
set -u
uci set network.${iface}.hmn_endpoint='${current_ep}'
uci commit network
ifdown '${iface}' >/dev/null 2>&1 || true
ifup '${iface}' >/dev/null 2>&1 || true
sleep '${POST_APPLY_SLEEP_SEC}'
if [ -x '${SLOTS_APPLY}' ]; then
    '${SLOTS_APPLY}' start '${SLOT}' >/dev/null 2>&1 || true
fi
echo 'rollback_done=true'
EOF
        chmod 700 "$rollback_file"

        attempt_limit="$LOCAL_REPAIR_CANDIDATE_RETRIES"
        [ "$candidate_count" -lt "$attempt_limit" ] && attempt_limit="$candidate_count"

        while IFS= read -r attempt_candidate; do
            [ "$candidate_attempts" -lt "$attempt_limit" ] || break
            [ -n "$attempt_candidate" ] || continue
            candidate_attempts=$((candidate_attempts + 1))
            candidate="$attempt_candidate"
            apply_performed=true

            set_endpoint_for_iface "$iface" "$candidate"
            apply_rc=$?
            if [ "$apply_rc" -eq 0 ]; then
                "$IFDOWN_BIN" "$iface" >/dev/null 2>&1 || true
                "$IFUP_BIN" "$iface" >/dev/null 2>&1
                apply_rc=$?
            fi
            "$SLEEP_BIN" "$POST_APPLY_SLEEP_SEC"

            if [ "$apply_rc" -eq 0 ] && [ -x "$SLOTS_APPLY" ]; then
                "$SLOTS_APPLY" start "$SLOT" >/dev/null 2>&1
                apply_rc=$?
            fi

            if [ "$apply_rc" -eq 0 ] \
                && "$IP_BIN" link show "$iface" >/dev/null 2>&1 \
                && "$IP_BIN" route show table "$table" 2>/dev/null | grep -Eq "default[[:space:]].*dev[[:space:]]+${iface}([[:space:]]|$)" \
                && strict_ping "$iface" "$health_targets" "$strict_count" "$strict_timeout"; then
                decision="commit_ok"
                reason="candidate_applied_and_strict_ok"
                post_strict_ok=true
                break
            fi

            reg_quarantine_endpoint "$candidate" "$SLOT" "$iface" "" "repair_candidate_failed" "$selected_pool" "STEP_050M07R15A_LEGACY_EXECUTION_FREEZE_AND_CLEAN_FOUNDATION" >/dev/null 2>&1 || true
        done <"$candidate_file"

        if [ "$decision" != "commit_ok" ]; then
            rollback_performed=true
            if set_endpoint_for_iface "$iface" "$current_ep"; then
                "$IFDOWN_BIN" "$iface" >/dev/null 2>&1 || true
                "$IFUP_BIN" "$iface" >/dev/null 2>&1 || true
                "$SLEEP_BIN" "$POST_APPLY_SLEEP_SEC"
                if [ -x "$SLOTS_APPLY" ]; then
                    "$SLOTS_APPLY" start "$SLOT" >/dev/null 2>&1 || true
                fi
                restored="$(current_endpoint_for_iface "$iface")"
                if [ "$restored" = "$current_ep" ]; then
                    rollback_ok=true
                fi
            fi
            decision="commit_failed"
            if [ "$rollback_ok" = "true" ]; then
                reason="all_candidates_failed_original_restored"
            else
                reason="all_candidates_failed_original_restore_failed"
            fi
            post_strict_ok=false
        fi
    fi
else
    reason="unsupported_mode"
fi

write_result "$result_file"
cat "$result_file"
printf '%s action=hmn_slot_replace slot=%s iface=%s mode=%s decision=%s reason=%s candidate=%s attempts=%s rollback=%s\n' \
    "$iso" "$SLOT" "$iface" "$MODE" "$decision" "$reason" "$candidate" "$candidate_attempts" "$rollback_performed" >>"$LOG" 2>/dev/null || true

case "$decision" in
    dry_run_ok|commit_ok) exit 0 ;;
    commit_failed) exit 3 ;;
    *) exit 2 ;;
esac
