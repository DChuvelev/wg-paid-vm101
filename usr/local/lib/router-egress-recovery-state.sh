#!/bin/sh
# Durable, atomic recovery state helpers for VM101. BusyBox ash compatible.

REG_STATE_DIR="${REG_STATE_DIR:-${STATE_DIR:-/var/lib/router-egress-recovery}}"
REG_QUARANTINE_TSV="${REG_QUARANTINE_TSV:-$REG_STATE_DIR/quarantine.tsv}"
REG_COUNTER_DIR="${REG_COUNTER_DIR:-$REG_STATE_DIR/fail-counter}"
REG_STATE_KV="${REG_STATE_KV:-$REG_STATE_DIR/state.kv}"
REG_LOCK_DIR="${REG_LOCK_DIR:-$REG_STATE_DIR/locks}"
REG_PERSIST_DIR="${REG_PERSIST_DIR:-/etc/router-egress-recovery}"
REG_PERSIST_STATE_KV="${REG_PERSIST_STATE_KV:-${RECOVERY_PERSIST_STATE_KV:-$REG_PERSIST_DIR/state.kv}}"
REG_STATE_SCHEMA_VERSION="${REG_STATE_SCHEMA_VERSION:-router-egress-recovery-state-v1}"
REG_REPAIR_EVENTS_KEY="${REG_REPAIR_EVENTS_KEY:-repair_events_since_full_refresh}"
REG_STATE_INITIALIZED=0

reg_now_epoch() { date +%s; }
reg_now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
reg_key_safe() { printf '%s' "$1" | sed 's/[^A-Za-z0-9_.:-]/_/g'; }
reg_clean_tsv() { printf '%s' "$1" | tr '\t\r\n' ' '; }


reg_process_token() {
    reg_pid="$1"
    [ -r "/proc/$reg_pid/stat" ] || return 1
    awk '{print $22}' "/proc/$reg_pid/stat" 2>/dev/null
}

reg_state_write_lock_acquire() {
    mkdir -p "$REG_LOCK_DIR" 2>/dev/null || return 1
    reg_sw_lock="$REG_LOCK_DIR/state-write.lock"
    if mkdir "$reg_sw_lock" 2>/dev/null; then :; else
        reg_sw_pid="$(cat "$reg_sw_lock/pid" 2>/dev/null || true)"
        reg_sw_token="$(cat "$reg_sw_lock/process_token" 2>/dev/null || true)"
        reg_sw_live=""
        case "$reg_sw_pid" in ''|*[!0-9]*) ;; *) reg_sw_live="$(reg_process_token "$reg_sw_pid" 2>/dev/null || true)" ;; esac
        if [ -n "$reg_sw_token" ] && [ "$reg_sw_live" = "$reg_sw_token" ]; then return 1; fi
        rm -rf "$reg_sw_lock" 2>/dev/null || return 1
        mkdir "$reg_sw_lock" 2>/dev/null || return 1
    fi
    printf '%s
' "$$" >"$reg_sw_lock/pid" || { rm -rf "$reg_sw_lock"; return 1; }
    reg_process_token "$$" >"$reg_sw_lock/process_token" 2>/dev/null || : >"$reg_sw_lock/process_token"
    printf '%s
' "$reg_sw_lock"
}

reg_state_write_lock_release() {
    reg_sw_lock="$1"
    reg_sw_pid="$(cat "$reg_sw_lock/pid" 2>/dev/null || true)"
    [ "$reg_sw_pid" = "$$" ] || return 1
    rm -rf "$reg_sw_lock"
}

reg_state_defaults() {
    cat <<EOF_DEFAULTS
state_schema=$REG_STATE_SCHEMA_VERSION
mode=NORMAL
degraded_reason=
degraded_since_epoch=0
failed_attempt_id=
last_refresh_result=NONE
last_refresh_epoch=0
next_refresh_epoch=0
refresh_retry_count=0
last_retry_epoch=0
last_retry_result=NONE
active_generation_id=
healthy_slot_count_at_failure=0
repair_events_since_full_refresh=0
full_refresh_due=false
EOF_DEFAULTS
}

reg_state_validate_file() {
    reg_validate_file="$1"
    [ -s "$reg_validate_file" ] || return 1
    awk -F= -v schema="$REG_STATE_SCHEMA_VERSION" '
        BEGIN {
            required["state_schema"]=1; required["mode"]=1; required["degraded_reason"]=1
            required["degraded_since_epoch"]=1; required["failed_attempt_id"]=1
            required["last_refresh_result"]=1; required["last_refresh_epoch"]=1
            required["next_refresh_epoch"]=1; required["refresh_retry_count"]=1
            required["last_retry_epoch"]=1; required["last_retry_result"]=1
            required["active_generation_id"]=1; required["healthy_slot_count_at_failure"]=1
            numeric["degraded_since_epoch"]=1; numeric["last_refresh_epoch"]=1
            numeric["next_refresh_epoch"]=1; numeric["refresh_retry_count"]=1
            numeric["last_retry_epoch"]=1; numeric["healthy_slot_count_at_failure"]=1
            numeric["repair_events_since_full_refresh"]=1
            ok=1
        }
        /^[[:space:]]*$/ { next }
        $0 !~ /^[A-Za-z0-9_.:-]+=/ { ok=0; next }
        {
            key=$1
            if (seen[key]++) ok=0
            value=substr($0, index($0,"=")+1)
            if (numeric[key] && value !~ /^[0-9]+$/) ok=0
            if (key=="state_schema" && value!=schema) ok=0
            if (key=="mode" && value!="NORMAL" && value!="LOCAL_REPAIR_READY" && value!="FULL_POOL_REFRESH_PENDING" && value!="FULL_POOL_REFRESH_RUNNING" && value!="DEGRADED_POOL" && value!="DEGRADED_POOL_PENDING") ok=0
        }
        END {
            for (key in required) if (!seen[key]) ok=0
            exit(ok ? 0 : 1)
        }
    ' "$reg_validate_file"
}


reg_state_merge_defaults() {
    reg_merge_input="$1"
    reg_merge_output="$2"
    reg_defaults_tmp="${reg_merge_output}.defaults.$$"
    reg_state_defaults >"$reg_defaults_tmp" || return 1
    awk -F= '
        NR==FNR { order[++n]=$1; value[$1]=$0; known[$1]=1; next }
        /^[A-Za-z0-9_.:-]+=/ {
            key=$1
            value[key]=$0
            if (!known[key] && !extra_seen[key]++) extra[++m]=key
        }
        END {
            for (i=1;i<=n;i++) print value[order[i]]
            for (i=1;i<=m;i++) print value[extra[i]]
        }
    ' "$reg_defaults_tmp" "$reg_merge_input" >"$reg_merge_output"
    reg_rc=$?
    rm -f "$reg_defaults_tmp"
    [ "$reg_rc" -eq 0 ] || return "$reg_rc"
    reg_state_validate_file "$reg_merge_output"
}

reg_atomic_copy() {
    reg_copy_src="$1"
    reg_copy_dst="$2"
    reg_copy_dir="$(dirname "$reg_copy_dst")"
    reg_copy_tmp="${reg_copy_dst}.new.$$"
    mkdir -p "$reg_copy_dir" || return 1
    cat "$reg_copy_src" >"$reg_copy_tmp" || { rm -f "$reg_copy_tmp"; return 1; }
    chmod 600 "$reg_copy_tmp" || { rm -f "$reg_copy_tmp"; return 1; }
    mv "$reg_copy_tmp" "$reg_copy_dst"
}

reg_state_commit_candidate() {
    reg_candidate="$1"
    reg_state_validate_file "$reg_candidate" || return 1
    mkdir -p "$REG_STATE_DIR" "$REG_PERSIST_DIR" || return 1
    reg_backup_root="/tmp/router-egress-state-commit.$$"
    mkdir -p "$reg_backup_root" || return 1
    reg_runtime_existed=false
    reg_persist_existed=false
    if [ -e "$REG_STATE_KV" ]; then cp -p "$REG_STATE_KV" "$reg_backup_root/runtime.before" || { rm -rf "$reg_backup_root"; return 1; }; reg_runtime_existed=true; fi
    if [ -e "$REG_PERSIST_STATE_KV" ]; then cp -p "$REG_PERSIST_STATE_KV" "$reg_backup_root/persist.before" || { rm -rf "$reg_backup_root"; return 1; }; reg_persist_existed=true; fi
    if ! reg_atomic_copy "$reg_candidate" "$REG_PERSIST_STATE_KV"; then rm -rf "$reg_backup_root"; return 1; fi
    if ! reg_atomic_copy "$reg_candidate" "$REG_STATE_KV"; then
        if [ "$reg_persist_existed" = true ]; then reg_atomic_copy "$reg_backup_root/persist.before" "$REG_PERSIST_STATE_KV" >/dev/null 2>&1 || true; else rm -f "$REG_PERSIST_STATE_KV"; fi
        rm -rf "$reg_backup_root"
        return 1
    fi
    if ! cmp -s "$REG_STATE_KV" "$REG_PERSIST_STATE_KV"; then
        if [ "$reg_runtime_existed" = true ]; then reg_atomic_copy "$reg_backup_root/runtime.before" "$REG_STATE_KV" >/dev/null 2>&1 || true; else rm -f "$REG_STATE_KV"; fi
        if [ "$reg_persist_existed" = true ]; then reg_atomic_copy "$reg_backup_root/persist.before" "$REG_PERSIST_STATE_KV" >/dev/null 2>&1 || true; else rm -f "$REG_PERSIST_STATE_KV"; fi
        rm -rf "$reg_backup_root"
        return 1
    fi
    rm -rf "$reg_backup_root"
    return 0
}

reg_init_state_unlocked() {
    mkdir -p "$REG_STATE_DIR" "$REG_COUNTER_DIR" "$REG_LOCK_DIR" "$REG_PERSIST_DIR" 2>/dev/null || return 1
    chmod 700 "$REG_STATE_DIR" "$REG_COUNTER_DIR" "$REG_LOCK_DIR" "$REG_PERSIST_DIR" 2>/dev/null || true
    if [ ! -e "$REG_QUARANTINE_TSV" ]; then
        printf 'ts_epoch\tts_utc\tegress\tiface\tendpoint\treplacement\treason\tpool_path\tpool_mtime_epoch\tsource_step\n' >"$REG_QUARANTINE_TSV" || return 1
        chmod 600 "$REG_QUARANTINE_TSV" 2>/dev/null || true
    fi
    reg_seed="/tmp/router-egress-state-seed.$$"
    reg_candidate="/tmp/router-egress-state-candidate.$$"
    if reg_state_validate_file "$REG_STATE_KV" 2>/dev/null; then
        if reg_state_validate_file "$REG_PERSIST_STATE_KV" 2>/dev/null && cmp -s "$REG_STATE_KV" "$REG_PERSIST_STATE_KV"; then
            return 0
        fi
        cp -p "$REG_STATE_KV" "$reg_candidate" || return 1
    elif reg_state_validate_file "$REG_PERSIST_STATE_KV" 2>/dev/null; then
        cp -p "$REG_PERSIST_STATE_KV" "$reg_candidate" || return 1
    else
        if [ -s "$REG_STATE_KV" ]; then cp -p "$REG_STATE_KV" "$reg_seed"; elif [ -s "$REG_PERSIST_STATE_KV" ]; then cp -p "$REG_PERSIST_STATE_KV" "$reg_seed"; else : >"$reg_seed"; fi
        reg_state_merge_defaults "$reg_seed" "$reg_candidate" || { rm -f "$reg_seed" "$reg_candidate"; return 1; }
    fi
    reg_state_commit_candidate "$reg_candidate" || { rm -f "$reg_seed" "$reg_candidate"; return 1; }
    rm -f "$reg_seed" "$reg_candidate"
    return 0
}


reg_init_state() {
    reg_sw_lock="$(reg_state_write_lock_acquire 2>/dev/null || true)"
    [ -n "$reg_sw_lock" ] || return 1
    reg_init_state_unlocked
    reg_sw_rc=$?
    reg_state_write_lock_release "$reg_sw_lock" >/dev/null 2>&1 || true
    [ "$reg_sw_rc" -eq 0 ] && REG_STATE_INITIALIZED=1
    return "$reg_sw_rc"
}

reg_ensure_state() {
    if [ "$REG_STATE_INITIALIZED" = 1 ] && [ -s "$REG_STATE_KV" ]; then return 0; fi
    reg_init_state
}

reg_state_update_file() {
    reg_updates="$1"
    [ -s "$reg_updates" ] || return 1
    awk -F= '/^[A-Za-z0-9_.:-]+=/ { if (seen[$1]++) exit 1; next } { exit 1 }' "$reg_updates" || return 1
    reg_sw_lock="$(reg_state_write_lock_acquire 2>/dev/null || true)"
    [ -n "$reg_sw_lock" ] || return 1
    if ! reg_init_state_unlocked; then
        reg_state_write_lock_release "$reg_sw_lock" >/dev/null 2>&1 || true
        return 1
    fi
    reg_candidate="/tmp/router-egress-state-update.$$"
    awk -F= '
        NR==FNR { update[$1]=$0; has[$1]=1; next }
        {
            key=$1
            if (has[key]) { print update[key]; emitted[key]=1 } else print
        }
        END { for (key in update) if (!emitted[key]) print update[key] }
    ' "$reg_updates" "$REG_STATE_KV" >"$reg_candidate" || {
        rm -f "$reg_candidate"
        reg_state_write_lock_release "$reg_sw_lock" >/dev/null 2>&1 || true
        return 1
    }
    reg_state_commit_candidate "$reg_candidate"
    reg_rc=$?
    rm -f "$reg_candidate"
    reg_state_write_lock_release "$reg_sw_lock" >/dev/null 2>&1 || true
    [ "$reg_rc" -eq 0 ] && REG_STATE_INITIALIZED=1
    return "$reg_rc"
}

reg_state_update() {
    reg_updates="/tmp/router-egress-state-pairs.$$"
    : >"$reg_updates" || return 1
    while [ "$#" -ge 2 ]; do
        reg_key="$(reg_key_safe "$1")"
        reg_value="$2"
        printf '%s=%s\n' "$reg_key" "$reg_value" >>"$reg_updates" || { rm -f "$reg_updates"; return 1; }
        shift 2
    done
    [ "$#" -eq 0 ] || { rm -f "$reg_updates"; return 1; }
    reg_state_update_file "$reg_updates"
    reg_rc=$?
    rm -f "$reg_updates"
    return "$reg_rc"
}

reg_set_state() { reg_state_update "$1" "$2"; }

reg_unset_state() {
    reg_unset_key="$(reg_key_safe "$1")"
    reg_sw_lock="$(reg_state_write_lock_acquire 2>/dev/null || true)"
    [ -n "$reg_sw_lock" ] || return 1
    if ! reg_init_state_unlocked; then reg_state_write_lock_release "$reg_sw_lock" >/dev/null 2>&1 || true; return 1; fi
    reg_candidate="/tmp/router-egress-state-unset.$$"
    grep -v "^${reg_unset_key}=" "$REG_STATE_KV" >"$reg_candidate" || true
    reg_merged="${reg_candidate}.merged"
    reg_state_merge_defaults "$reg_candidate" "$reg_merged" || { rm -f "$reg_candidate" "$reg_merged"; reg_state_write_lock_release "$reg_sw_lock" >/dev/null 2>&1 || true; return 1; }
    reg_state_commit_candidate "$reg_merged"
    reg_rc=$?
    rm -f "$reg_candidate" "$reg_merged"
    reg_state_write_lock_release "$reg_sw_lock" >/dev/null 2>&1 || true
    return "$reg_rc"
}

reg_get_state() {
    reg_get_key="$(reg_key_safe "$1")"
    reg_get_default="${2:-}"
    reg_ensure_state >/dev/null 2>&1 || { printf '%s\n' "$reg_get_default"; return 1; }
    reg_get_value="$(grep "^${reg_get_key}=" "$REG_STATE_KV" 2>/dev/null | tail -n1 | sed 's/^[^=]*=//')"
    [ -n "$reg_get_value" ] && printf '%s\n' "$reg_get_value" || printf '%s\n' "$reg_get_default"
}


reg_lock_acquire() {
    reg_lock_name="$1"
    reg_lock_owner="${2:-unknown}"
    reg_lock_path="$REG_LOCK_DIR/$reg_lock_name"
    reg_ensure_state || return 1
    if mkdir "$reg_lock_path" 2>/dev/null; then :; else
        reg_old_pid="$(cat "$reg_lock_path/pid" 2>/dev/null || true)"
        reg_old_token="$(cat "$reg_lock_path/process_token" 2>/dev/null || true)"
        reg_live_token=""
        case "$reg_old_pid" in ''|*[!0-9]*) ;; *) reg_live_token="$(reg_process_token "$reg_old_pid" 2>/dev/null || true)" ;; esac
        if [ -n "$reg_old_token" ] && [ "$reg_live_token" = "$reg_old_token" ]; then return 1; fi
        rm -rf "$reg_lock_path" 2>/dev/null || return 1
        mkdir "$reg_lock_path" 2>/dev/null || return 1
    fi
    printf '%s\n' "$$" >"$reg_lock_path/pid" || { rm -rf "$reg_lock_path"; return 1; }
    reg_process_token "$$" >"$reg_lock_path/process_token" 2>/dev/null || : >"$reg_lock_path/process_token"
    printf '%s\n' "$reg_lock_owner" >"$reg_lock_path/owner"
    reg_now_epoch >"$reg_lock_path/acquired_epoch"
    printf '%s\n' "$reg_lock_path"
}

reg_lock_release() {
    reg_lock_path="$1"
    reg_lock_pid="$(cat "$reg_lock_path/pid" 2>/dev/null || true)"
    [ "$reg_lock_pid" = "$$" ] || return 1
    rm -rf "$reg_lock_path"
}

reg_pool_mtime_epoch() {
    reg_pool_path="$1"
    [ -n "$reg_pool_path" ] && [ -e "$reg_pool_path" ] || { echo 0; return 0; }
    reg_pool_value="$(stat -c %Y "$reg_pool_path" 2>/dev/null | head -n1)"
    printf '%s\n' "$reg_pool_value" | grep -Eq '^[0-9]+$' && { echo "$reg_pool_value"; return 0; }
    reg_pool_value="$(date -r "$reg_pool_path" +%s 2>/dev/null | head -n1)"
    printf '%s\n' "$reg_pool_value" | grep -Eq '^[0-9]+$' && { echo "$reg_pool_value"; return 0; }
    echo 0
}

reg_quarantine_endpoint() {
    reg_q_endpoint="$1"; reg_q_egress="${2:-}"; reg_q_iface="${3:-}"; reg_q_replacement="${4:-}"; reg_q_reason="${5:-unspecified}"; reg_q_pool="${6:-}"; reg_q_step="${7:-manual}"
    reg_init_state || return 1
    reg_q_ts="$(reg_now_epoch)"; reg_q_utc="$(reg_now_utc)"; reg_q_mtime="$(reg_pool_mtime_epoch "$reg_q_pool")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(reg_clean_tsv "$reg_q_ts")" "$(reg_clean_tsv "$reg_q_utc")" "$(reg_clean_tsv "$reg_q_egress")" "$(reg_clean_tsv "$reg_q_iface")" \
        "$(reg_clean_tsv "$reg_q_endpoint")" "$(reg_clean_tsv "$reg_q_replacement")" "$(reg_clean_tsv "$reg_q_reason")" "$(reg_clean_tsv "$reg_q_pool")" \
        "$(reg_clean_tsv "$reg_q_mtime")" "$(reg_clean_tsv "$reg_q_step")" >>"$REG_QUARANTINE_TSV"
}

reg_latest_quarantine_ts() { awk -F '\t' -v ep="$1" 'NR > 1 && $5 == ep { ts = $1 } END { if (ts != "") print ts }' "$REG_QUARANTINE_TSV" 2>/dev/null; }
reg_endpoint_quarantined_for_pool() {
    reg_ep="$1"; reg_pool="${2:-}"; reg_qts="$(reg_latest_quarantine_ts "$reg_ep" 2>/dev/null || true)"; [ -n "$reg_qts" ] || return 1
    reg_pm="$(reg_pool_mtime_epoch "$reg_pool")"; [ "$reg_pm" -gt "$reg_qts" ] 2>/dev/null && return 1; return 0
}

reg_counter_file() { printf '%s/%s.count\n' "$REG_COUNTER_DIR" "$(reg_key_safe "$1")"; }
reg_counter_get() {
    reg_ensure_state >/dev/null 2>&1 || { echo 0; return 1; }
    reg_cf="$(reg_counter_file "$1")"
    if [ -e "$reg_cf" ]; then reg_cv="$(tail -n1 "$reg_cf" 2>/dev/null | sed 's/[^0-9].*$//')"; printf '%s\n' "$reg_cv" | grep -Eq '^[0-9]+$' && printf '%s\n' "$reg_cv" || echo 0; else echo 0; fi
}
reg_counter_set() {
    reg_ck="$1"; reg_cv="$2"; printf '%s\n' "$reg_cv" | grep -Eq '^[0-9]+$' || return 1; reg_init_state || return 1
    reg_cf="$(reg_counter_file "$reg_ck")"; reg_tmp="${reg_cf}.new.$$"; printf '%s\n' "$reg_cv" >"$reg_tmp" || return 1; chmod 600 "$reg_tmp"; mv "$reg_tmp" "$reg_cf"
}
reg_counter_inc() { reg_ci="$(reg_counter_get "$1")"; reg_cn=$((reg_ci + 1)); reg_counter_set "$1" "$reg_cn" || return 1; printf '%s\n' "$reg_cn"; }
reg_repair_events_get() { reg_counter_get "$REG_REPAIR_EVENTS_KEY"; }
reg_repair_events_inc() { reg_counter_inc "$REG_REPAIR_EVENTS_KEY"; }
reg_repair_events_reset() { reg_counter_set "$REG_REPAIR_EVENTS_KEY" 0 || return 1; reg_set_state repair_events_since_full_refresh 0 >/dev/null 2>&1 || true; }

reg_selftest() {
    reg_test_root="/tmp/router-egress-recovery-state-selftest-$$"
    REG_STATE_DIR="$reg_test_root/runtime"; REG_QUARANTINE_TSV="$REG_STATE_DIR/quarantine.tsv"; REG_COUNTER_DIR="$REG_STATE_DIR/fail-counter"; REG_STATE_KV="$REG_STATE_DIR/state.kv"; REG_LOCK_DIR="$REG_STATE_DIR/locks"; REG_PERSIST_DIR="$reg_test_root/persist"; REG_PERSIST_STATE_KV="$REG_PERSIST_DIR/state.kv"
    mkdir -p "$reg_test_root" || return 1
    reg_init_state || return 1
    [ -s "$REG_STATE_KV" ] && [ -s "$REG_PERSIST_STATE_KV" ] || return 1
    reg_state_update mode DEGRADED_POOL degraded_reason selftest degraded_since_epoch 100 failed_attempt_id a1 last_refresh_result FAILED last_refresh_epoch 100 next_refresh_epoch 200 refresh_retry_count 1 last_retry_epoch 100 last_retry_result FAILED active_generation_id g1 healthy_slot_count_at_failure 5 || return 1
    cmp -s "$REG_STATE_KV" "$REG_PERSIST_STATE_KV" || return 1
    rm -f "$REG_STATE_KV"
    reg_init_state || return 1
    [ "$(reg_get_state mode UNKNOWN)" = DEGRADED_POOL ] || return 1
    reg_repair_events_inc >/dev/null || return 1
    reg_repair_events_reset || return 1
    reg_lock="$(reg_lock_acquire recovery-coordinator.lock selftest)" || return 1
    reg_lock_release "$reg_lock" || return 1
    rm -rf "$reg_test_root"
    echo selftest.ok=true
}
