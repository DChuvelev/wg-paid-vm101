#!/bin/sh

REG_STATE_DIR="${REG_STATE_DIR:-/var/lib/router-egress-recovery}"
REG_QUARANTINE_TSV="${REG_QUARANTINE_TSV:-$REG_STATE_DIR/quarantine.tsv}"
REG_COUNTER_DIR="${REG_COUNTER_DIR:-$REG_STATE_DIR/fail-counter}"
REG_STATE_KV="${REG_STATE_KV:-$REG_STATE_DIR/state.kv}"
REG_LOCK_DIR="${REG_LOCK_DIR:-$REG_STATE_DIR/locks}"
REG_REPAIR_EVENTS_KEY="${REG_REPAIR_EVENTS_KEY:-repair_events_since_full_refresh}"

reg_now_epoch() { date +%s; }
reg_now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
reg_today_utc() { date -u '+%Y%m%d'; }

reg_key_safe() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9_.:-]/_/g'
}

reg_clean_tsv() {
    printf '%s' "$1" | tr '\t\r\n' ' '
}

reg_init_state() {
    mkdir -p "$REG_STATE_DIR" "$REG_COUNTER_DIR" "$REG_LOCK_DIR" 2>/dev/null || return 1
    if [ ! -e "$REG_QUARANTINE_TSV" ]; then
        printf 'ts_epoch\tts_utc\tegress\tiface\tendpoint\treplacement\treason\tpool_path\tpool_mtime_epoch\tsource_step\n' >"$REG_QUARANTINE_TSV" || return 1
    fi
    touch "$REG_STATE_KV" 2>/dev/null || return 1
    return 0
}

reg_pool_mtime_epoch() {
    path="$1"
    [ -n "$path" ] && [ -e "$path" ] || {
        echo 0
        return 0
    }

    value="$(stat -c %Y "$path" 2>/dev/null | head -n 1)"
    if printf '%s\n' "$value" | grep -Eq '^[0-9]+$'; then
        echo "$value"
        return 0
    fi

    value="$(date -r "$path" +%s 2>/dev/null | head -n 1)"
    if printf '%s\n' "$value" | grep -Eq '^[0-9]+$'; then
        echo "$value"
        return 0
    fi

    value="$(find "$path" -maxdepth 0 -printf '%T@\n' 2>/dev/null | sed 's/\..*$//' | head -n 1)"
    if printf '%s\n' "$value" | grep -Eq '^[0-9]+$'; then
        echo "$value"
        return 0
    fi

    echo 0
}

reg_set_state() {
    key="$(reg_key_safe "$1")"
    value="$2"
    reg_init_state || return 1
    temp="${REG_STATE_KV}.$$"
    grep -v "^${key}=" "$REG_STATE_KV" 2>/dev/null >"$temp" || true
    printf '%s=%s\n' "$key" "$value" >>"$temp"
    mv "$temp" "$REG_STATE_KV"
}

reg_get_state() {
    key="$(reg_key_safe "$1")"
    default="${2:-}"
    reg_init_state >/dev/null 2>&1 || {
        printf '%s\n' "$default"
        return 1
    }
    value="$(grep "^${key}=" "$REG_STATE_KV" 2>/dev/null | tail -n 1 | sed 's/^[^=]*=//')"
    if [ -n "$value" ]; then
        printf '%s\n' "$value"
    else
        printf '%s\n' "$default"
    fi
}

reg_quarantine_endpoint() {
    endpoint="$1"
    egress="${2:-}"
    iface="${3:-}"
    replacement="${4:-}"
    reason="${5:-unspecified}"
    pool_path="${6:-}"
    source_step="${7:-manual}"

    reg_init_state || return 1
    ts="$(reg_now_epoch)"
    utc="$(reg_now_utc)"
    pool_mtime="$(reg_pool_mtime_epoch "$pool_path")"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(reg_clean_tsv "$ts")" \
        "$(reg_clean_tsv "$utc")" \
        "$(reg_clean_tsv "$egress")" \
        "$(reg_clean_tsv "$iface")" \
        "$(reg_clean_tsv "$endpoint")" \
        "$(reg_clean_tsv "$replacement")" \
        "$(reg_clean_tsv "$reason")" \
        "$(reg_clean_tsv "$pool_path")" \
        "$(reg_clean_tsv "$pool_mtime")" \
        "$(reg_clean_tsv "$source_step")" >>"$REG_QUARANTINE_TSV"
}

reg_latest_quarantine_ts() {
    endpoint="$1"
    reg_init_state >/dev/null 2>&1 || return 1
    awk -F '\t' -v ep="$endpoint" 'NR > 1 && $5 == ep { ts = $1 } END { if (ts != "") print ts }' "$REG_QUARANTINE_TSV" 2>/dev/null
}

reg_endpoint_quarantined_for_pool() {
    endpoint="$1"
    pool_path="${2:-}"
    quarantine_ts="$(reg_latest_quarantine_ts "$endpoint" 2>/dev/null || true)"
    [ -n "$quarantine_ts" ] || return 1

    pool_mtime="$(reg_pool_mtime_epoch "$pool_path")"
    [ -n "$pool_mtime" ] || pool_mtime=0

    if [ "$pool_mtime" -gt "$quarantine_ts" ] 2>/dev/null; then
        return 1
    fi
    return 0
}

reg_counter_file() {
    key="$(reg_key_safe "$1")"
    printf '%s/%s.count\n' "$REG_COUNTER_DIR" "$key"
}

reg_counter_get() {
    key="$1"
    reg_init_state >/dev/null 2>&1 || {
        echo 0
        return 1
    }
    file="$(reg_counter_file "$key")"
    if [ -e "$file" ]; then
        value="$(tail -n 1 "$file" 2>/dev/null | sed 's/[^0-9].*$//')"
        printf '%s\n' "$value" | grep -Eq '^[0-9]+$' && printf '%s\n' "$value" || echo 0
    else
        echo 0
    fi
}

reg_counter_set() {
    key="$1"
    value="$2"
    printf '%s\n' "$value" | grep -Eq '^[0-9]+$' || return 1
    reg_init_state || return 1
    file="$(reg_counter_file "$key")"
    printf '%s\n' "$value" >"$file"
}

reg_counter_inc() {
    key="$1"
    current="$(reg_counter_get "$key")"
    [ -n "$current" ] || current=0
    next=$((current + 1))
    reg_counter_set "$key" "$next" || return 1
    printf '%s\n' "$next"
}

reg_daily_repair_key() {
    printf 'repairs_%s\n' "$(reg_today_utc)"
}

reg_daily_repair_get() {
    reg_counter_get "$(reg_daily_repair_key)"
}

reg_daily_repair_inc() {
    reg_counter_inc "$(reg_daily_repair_key)"
}

reg_repair_events_get() {
    reg_counter_get "$REG_REPAIR_EVENTS_KEY"
}

reg_repair_events_inc() {
    reg_counter_inc "$REG_REPAIR_EVENTS_KEY"
}

reg_repair_events_reset() {
    reg_counter_set "$REG_REPAIR_EVENTS_KEY" 0
    reg_set_state repair_events_since_full_refresh 0 >/dev/null 2>&1 || true
}

reg_selftest() {
    old_state_dir="$REG_STATE_DIR"
    old_quarantine="$REG_QUARANTINE_TSV"
    old_counter="$REG_COUNTER_DIR"
    old_state_kv="$REG_STATE_KV"
    old_lock="$REG_LOCK_DIR"

    test_root="/tmp/router-egress-recovery-state-selftest-$$"
    REG_STATE_DIR="$test_root/state"
    REG_QUARANTINE_TSV="$REG_STATE_DIR/quarantine.tsv"
    REG_COUNTER_DIR="$REG_STATE_DIR/fail-counter"
    REG_STATE_KV="$REG_STATE_DIR/state.kv"
    REG_LOCK_DIR="$REG_STATE_DIR/locks"

    endpoint="203.0.113.77:1111"
    replacement="198.51.100.88:2222"
    pool="$test_root/pool.tsv"

    mkdir -p "$test_root" || return 1
    printf 'rank\tfile\tendpoint\tavg_ms\tping_loss\tconfig_path\n1\tx\t%s\t50\t0\tx\n' "$endpoint" >"$pool"

    reg_init_state || return 1
    sleep 1
    reg_quarantine_endpoint "$endpoint" egressX vpnX "$replacement" selftest "$pool" STEP_R14B_SELFTEST || return 1

    if reg_endpoint_quarantined_for_pool "$endpoint" "$pool"; then
        echo "selftest.quarantine_active_old_pool=true"
    else
        echo "selftest.quarantine_active_old_pool=false"
        return 1
    fi

    sleep 1
    printf '\n# refreshed-after-quarantine %s\n' "$(reg_now_utc)" >>"$pool"
    touch "$pool" 2>/dev/null || true

    if reg_endpoint_quarantined_for_pool "$endpoint" "$pool"; then
        echo "selftest.quarantine_released_new_pool=false"
        return 1
    else
        echo "selftest.quarantine_released_new_pool=true"
    fi

    reg_set_state mode NORMAL || return 1
    [ "$(reg_get_state mode UNKNOWN)" = "NORMAL" ] || return 1

    [ "$(reg_repair_events_get)" = "0" ] || return 1
    [ "$(reg_repair_events_inc)" = "1" ] || return 1
    [ "$(reg_repair_events_inc)" = "2" ] || return 1
    reg_repair_events_reset || return 1
    [ "$(reg_repair_events_get)" = "0" ] || return 1

    rm -rf "$test_root"
    REG_STATE_DIR="$old_state_dir"
    REG_QUARANTINE_TSV="$old_quarantine"
    REG_COUNTER_DIR="$old_counter"
    REG_STATE_KV="$old_state_kv"
    REG_LOCK_DIR="$old_lock"

    echo "selftest.ok=true"
    return 0
}
