#!/bin/sh
set -u
umask 077
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

SLOTS_FILE="${ROUTER_FALLBACK_SLOTS_FILE:-/etc/router-egress-slots.d/slots.conf}"
LIB="${ROUTER_FALLBACK_LIB:-/usr/local/lib/router-wgpay-fallback-map.sh}"
MAPPER="${ROUTER_FALLBACK_MAPPER:-/usr/local/sbin/router-wgpay-canary-apply.sh}"
STATE_DIR="${ROUTER_FALLBACK_STATE_DIR:-/etc/router-wgpay-fallback}"
STATE_FILE="${ROUTER_FALLBACK_STATE_FILE:-${STATE_DIR}/state.kv}"
ACK_FILE="${ROUTER_FALLBACK_ACK_FILE:-${STATE_DIR}/ack.kv}"
RUNTIME_DIR="${ROUTER_FALLBACK_RUNTIME_DIR:-/var/lib/router-wgpay-fallback}"
RUNTIME_STATE="${ROUTER_FALLBACK_RUNTIME_STATE:-${RUNTIME_DIR}/state.kv}"
PLAN_FILE="${ROUTER_FALLBACK_PLAN_FILE:-${RUNTIME_DIR}/plan.kv}"
LOCK_FILE="${ROUTER_FALLBACK_LOCK_FILE:-/var/run/router-wgpay-fallback.lock}"
INPUT_MAX_BYTES="${ROUTER_FALLBACK_INPUT_MAX_BYTES:-4096}"
NOW_EPOCH="${ROUTER_FALLBACK_NOW_EPOCH:-$(date +%s)}"
SCHEMA='router-wgpay-slot-topology-v1'
ACK_SCHEMA='router-wgpay-fallback-ack-v1'
CANONICAL_SLOTS='egress1,egress2,egress3,egress4,egress5'
CANONICAL_SELECTORS='cs1,cs2,cs3,cs4,cs5'

[ -r "$LIB" ] || { echo 'RESULT=STOP_FALLBACK_LIBRARY_MISSING'; exit 70; }
# shellcheck disable=SC1090
. "$LIB"

fallback_reject() {
    fallback_reject_reason="$1"
    fallback_reject_detail="$(rwf_sanitize "${2:-}")"
    fallback_reject_rc="${3:-64}"
    printf '%s\n' "schema=${ACK_SCHEMA}" 'result=REJECTED' "reason=${fallback_reject_reason}" "detail=${fallback_reject_detail}"
    return "$fallback_reject_rc"
}

fallback_run_stdin() {
    fallback_tmp="${TMPDIR:-/tmp}/router-wgpay-fallback-state.$$"
    fallback_raw="$fallback_tmp/input.kv"
    fallback_body="$fallback_tmp/body.kv"
    fallback_expected="$fallback_tmp/expected.kv"
    fallback_rows="$fallback_tmp/slots.tsv"
    fallback_candidate="$fallback_tmp/state.kv"
    fallback_plan="$fallback_tmp/plan.kv"
    fallback_ack="$fallback_tmp/ack.kv"
    fallback_old_state="$fallback_tmp/old-state.kv"
    fallback_old_ack="$fallback_tmp/old-ack.kv"
    fallback_old_runtime="$fallback_tmp/old-runtime-state.kv"
    fallback_old_plan="$fallback_tmp/old-plan.kv"
    fallback_old_state_existed=false
    fallback_old_ack_existed=false
    fallback_old_runtime_existed=false
    fallback_old_plan_existed=false
    trap 'rm -rf "$fallback_tmp"' EXIT HUP INT TERM
    mkdir -p "$fallback_tmp" "$STATE_DIR" "$RUNTIME_DIR" "$(dirname "$LOCK_FILE")" || return 70
    chmod 700 "$STATE_DIR" "$RUNTIME_DIR" 2>/dev/null || true

    dd bs=$((INPUT_MAX_BYTES + 1)) count=1 of="$fallback_raw" 2>/dev/null
    fallback_bytes="$(wc -c < "$fallback_raw" | tr -d ' ')"
    [ "$fallback_bytes" -le "$INPUT_MAX_BYTES" ] || { fallback_reject input_too_large "$fallback_bytes" 65; return $?; }
    [ "$fallback_bytes" -gt 0 ] || { fallback_reject empty_input none 65; return $?; }
    if LC_ALL=C grep -n '[[:space:]]' "$fallback_raw" >/dev/null 2>&1; then fallback_reject whitespace_forbidden input 65; return $?; fi

    fallback_msg_schema=''; fallback_msg_generation=''; fallback_msg_mode=''; fallback_msg_source=''
    fallback_msg_healthy_slots=''; fallback_msg_exhausted_slots=''; fallback_msg_healthy_selectors=''; fallback_msg_exhausted_selectors=''
    fallback_msg_created=''; fallback_msg_confirm=''; fallback_seen='|'; fallback_parse_error=''
    while IFS='=' read -r fallback_key fallback_value; do
        [ -n "$fallback_key" ] || { fallback_parse_error=blank_key; break; }
        case "$fallback_seen" in *"|${fallback_key}|"*) fallback_parse_error="duplicate_${fallback_key}"; break;; esac
        fallback_seen="${fallback_seen}${fallback_key}|"
        case "$fallback_key" in
            schema) fallback_msg_schema="$fallback_value" ;;
            generation) fallback_msg_generation="$fallback_value" ;;
            mode) fallback_msg_mode="$fallback_value" ;;
            source_vm101_generation) fallback_msg_source="$fallback_value" ;;
            healthy_slots) fallback_msg_healthy_slots="$fallback_value" ;;
            exhausted_slots) fallback_msg_exhausted_slots="$fallback_value" ;;
            healthy_selectors) fallback_msg_healthy_selectors="$fallback_value" ;;
            exhausted_selectors) fallback_msg_exhausted_selectors="$fallback_value" ;;
            created_epoch) fallback_msg_created="$fallback_value" ;;
            confirm_sha256) fallback_msg_confirm="$fallback_value" ;;
            *) fallback_parse_error="unknown_${fallback_key}"; break ;;
        esac
    done < "$fallback_raw"
    [ -z "$fallback_parse_error" ] || { fallback_reject parse_error "$fallback_parse_error" 66; return $?; }

    [ "$fallback_msg_schema" = "$SCHEMA" ] || { fallback_reject schema_unsupported "$fallback_msg_schema" 66; return $?; }
    printf '%s' "$fallback_msg_generation" | grep -Eq '^[0-9]{12}$' || { fallback_reject generation_invalid "$fallback_msg_generation" 66; return $?; }
    case "$fallback_msg_mode" in NORMAL|SLOT_EXHAUSTED) ;; *) fallback_reject mode_invalid "$fallback_msg_mode" 66; return $?;; esac
    printf '%s' "$fallback_msg_source" | grep -Eq '^[A-Za-z0-9_.:-]{1,128}$' || { fallback_reject source_generation_invalid "$fallback_msg_source" 66; return $?; }
    printf '%s' "$fallback_msg_created" | grep -Eq '^[0-9]{1,12}$' || { fallback_reject created_epoch_invalid "$fallback_msg_created" 66; return $?; }
    printf '%s' "$fallback_msg_confirm" | grep -Eq '^[0-9a-f]{64}$' || { fallback_reject confirm_sha256_invalid "$fallback_msg_confirm" 66; return $?; }

    rwf_csv_validate_subsequence "$fallback_msg_healthy_slots" "$CANONICAL_SLOTS" true || { fallback_reject healthy_slots_invalid "$fallback_msg_healthy_slots" 66; return $?; }
    rwf_csv_validate_subsequence "$fallback_msg_exhausted_slots" "$CANONICAL_SLOTS" true || { fallback_reject exhausted_slots_invalid "$fallback_msg_exhausted_slots" 66; return $?; }
    rwf_csv_validate_subsequence "$fallback_msg_healthy_selectors" "$CANONICAL_SELECTORS" true || { fallback_reject healthy_selectors_invalid "$fallback_msg_healthy_selectors" 66; return $?; }
    rwf_csv_validate_subsequence "$fallback_msg_exhausted_selectors" "$CANONICAL_SELECTORS" true || { fallback_reject exhausted_selectors_invalid "$fallback_msg_exhausted_selectors" 66; return $?; }
    rwf_sets_complete_disjoint "$fallback_msg_healthy_slots" "$fallback_msg_exhausted_slots" "$CANONICAL_SLOTS" || { fallback_reject slot_sets_not_complete_disjoint sets 66; return $?; }
    rwf_sets_complete_disjoint "$fallback_msg_healthy_selectors" "$fallback_msg_exhausted_selectors" "$CANONICAL_SELECTORS" || { fallback_reject selector_sets_not_complete_disjoint sets 66; return $?; }
    rwf_slots_to_tsv "$SLOTS_FILE" "$fallback_rows" || { fallback_reject slots_config_invalid slots 66; return $?; }
    rwf_validate_slot_selector_alignment "$fallback_rows" "$fallback_msg_healthy_slots" "$fallback_msg_exhausted_slots" "$fallback_msg_healthy_selectors" "$fallback_msg_exhausted_selectors" || { fallback_reject slot_selector_mapping_invalid sets 66; return $?; }
    if [ "$fallback_msg_mode" = NORMAL ]; then
        [ "$fallback_msg_healthy_slots" = "$CANONICAL_SLOTS" ] && [ -z "$fallback_msg_exhausted_slots" ] && [ "$fallback_msg_healthy_selectors" = "$CANONICAL_SELECTORS" ] && [ -z "$fallback_msg_exhausted_selectors" ] || { fallback_reject normal_sets_invalid sets 66; return $?; }
    else
        [ -n "$fallback_msg_exhausted_slots" ] && [ -n "$fallback_msg_exhausted_selectors" ] || { fallback_reject exhausted_sets_empty sets 66; return $?; }
    fi

    {
        printf 'schema=%s\n' "$fallback_msg_schema"
        printf 'generation=%s\n' "$fallback_msg_generation"
        printf 'mode=%s\n' "$fallback_msg_mode"
        printf 'source_vm101_generation=%s\n' "$fallback_msg_source"
        printf 'healthy_slots=%s\n' "$fallback_msg_healthy_slots"
        printf 'exhausted_slots=%s\n' "$fallback_msg_exhausted_slots"
        printf 'healthy_selectors=%s\n' "$fallback_msg_healthy_selectors"
        printf 'exhausted_selectors=%s\n' "$fallback_msg_exhausted_selectors"
        printf 'created_epoch=%s\n' "$fallback_msg_created"
    } > "$fallback_body"
    fallback_payload_sha="$(sha256sum "$fallback_body" | awk '{print $1}')"
    [ "$fallback_payload_sha" = "$fallback_msg_confirm" ] || { fallback_reject confirm_sha256_mismatch "$fallback_payload_sha" 67; return $?; }
    cat "$fallback_body" > "$fallback_expected"; printf 'confirm_sha256=%s\n' "$fallback_msg_confirm" >> "$fallback_expected"
    cmp -s "$fallback_raw" "$fallback_expected" || { fallback_reject noncanonical_document input 67; return $?; }

    exec 9>"$LOCK_FILE"
    flock -n 9 || { fallback_reject operation_locked lock 75; return $?; }

    fallback_prev_generation="$(rwf_kv_get accepted_generation "$STATE_FILE")"
    fallback_prev_payload="$(rwf_kv_get payload_sha256 "$STATE_FILE")"
    if [ -n "$fallback_prev_generation" ]; then
        fallback_cmp="$(rwf_generation_compare "$fallback_msg_generation" "$fallback_prev_generation")"
        if [ "$fallback_cmp" = '-1' ]; then fallback_reject older_generation "${fallback_msg_generation}_lt_${fallback_prev_generation}" 68; return $?; fi
        if [ "$fallback_cmp" = '0' ]; then
            [ "$fallback_prev_payload" = "$fallback_payload_sha" ] || { fallback_reject generation_payload_conflict "$fallback_msg_generation" 69; return $?; }
            [ -f "$ACK_FILE" ] || { fallback_reject replay_ack_missing "$fallback_msg_generation" 70; return $?; }
            cat "$ACK_FILE"
            return 0
        fi
    fi

    if [ -z "$fallback_msg_healthy_slots" ]; then
        printf '%s\n' "schema=${ACK_SCHEMA}" 'result=DIRECT_REQUIRED' "generation=${fallback_msg_generation}" "payload_sha256=${fallback_payload_sha}" 'mapper_applied=false' 'state_persisted=false' 'reason=no_healthy_slot'
        return 0
    fi

    fallback_first_healthy=''
    while IFS="$(printf '\t')" read -r fallback_ord fallback_slot fallback_iface fallback_table fallback_mark fallback_selector; do
        if rwf_csv_contains "$fallback_msg_healthy_slots" "$fallback_slot"; then fallback_first_healthy="$fallback_slot"; break; fi
    done < "$fallback_rows"
    [ -n "$fallback_first_healthy" ] || { fallback_reject planner_no_healthy_slot planner 72; return $?; }

    fallback_fallback_selectors=''
    {
        printf 'schema=router-wgpay-fallback-state-v1\n'
        printf 'accepted_generation=%s\n' "$fallback_msg_generation"
        printf 'payload_sha256=%s\n' "$fallback_payload_sha"
        printf 'mode=%s\n' "$fallback_msg_mode"
        printf 'source_vm101_generation=%s\n' "$fallback_msg_source"
        printf 'healthy_slots=%s\n' "$fallback_msg_healthy_slots"
        printf 'exhausted_slots=%s\n' "$fallback_msg_exhausted_slots"
        printf 'healthy_selectors=%s\n' "$fallback_msg_healthy_selectors"
        printf 'exhausted_selectors=%s\n' "$fallback_msg_exhausted_selectors"
        printf 'first_healthy_slot=%s\n' "$fallback_first_healthy"
        printf 'created_epoch=%s\n' "$fallback_msg_created"
        printf 'applied_epoch=%s\n' "$NOW_EPOCH"
        while IFS="$(printf '\t')" read -r fallback_ord fallback_slot fallback_iface fallback_table fallback_mark fallback_selector; do
            if rwf_csv_contains "$fallback_msg_healthy_slots" "$fallback_slot"; then fallback_target_slot="$fallback_slot"; else fallback_target_slot="$fallback_first_healthy"; fi
            fallback_target_iface="$(rwf_slot_field "$fallback_rows" "$fallback_target_slot" 3)"
            fallback_target_table="$(rwf_slot_field "$fallback_rows" "$fallback_target_slot" 4)"
            fallback_target_mark="$(rwf_slot_field "$fallback_rows" "$fallback_target_slot" 5)"
            if [ "$fallback_target_slot" != "$fallback_slot" ]; then
                if [ -n "$fallback_fallback_selectors" ]; then fallback_fallback_selectors="${fallback_fallback_selectors},${fallback_selector}"; else fallback_fallback_selectors="$fallback_selector"; fi
            fi
            printf 'canonical.%s.slot=%s\n' "$fallback_selector" "$fallback_slot"
            printf 'effective.%s.slot=%s\n' "$fallback_selector" "$fallback_target_slot"
            printf 'effective.%s.interface=%s\n' "$fallback_selector" "$fallback_target_iface"
            printf 'effective.%s.table=%s\n' "$fallback_selector" "$fallback_target_table"
            printf 'effective.%s.mark=%s\n' "$fallback_selector" "$fallback_target_mark"
        done < "$fallback_rows"
        printf 'fallback_selectors=%s\n' "$fallback_fallback_selectors"
    } > "$fallback_candidate"

    {
        printf 'schema=router-wgpay-fallback-plan-v1\n'
        printf 'generation=%s\n' "$fallback_msg_generation"
        printf 'payload_sha256=%s\n' "$fallback_payload_sha"
        printf 'mode=%s\n' "$fallback_msg_mode"
        printf 'first_healthy_slot=%s\n' "$fallback_first_healthy"
        printf 'fallback_selectors=%s\n' "$fallback_fallback_selectors"
        for fallback_selector in cs1 cs2 cs3 cs4 cs5; do
            printf 'mapping.%s=%s\n' "$fallback_selector" "$(rwf_kv_get "effective.${fallback_selector}.slot" "$fallback_candidate")"
        done
    } > "$fallback_plan"
    fallback_plan_sha="$(sha256sum "$fallback_plan" | awk '{print $1}')"

    if [ -f "$STATE_FILE" ]; then cp "$STATE_FILE" "$fallback_old_state"; fallback_old_state_existed=true; fi
    if [ -f "$ACK_FILE" ]; then cp "$ACK_FILE" "$fallback_old_ack"; fallback_old_ack_existed=true; fi
    if [ -f "$RUNTIME_STATE" ]; then cp "$RUNTIME_STATE" "$fallback_old_runtime"; fallback_old_runtime_existed=true; fi
    if [ -f "$PLAN_FILE" ]; then cp "$PLAN_FILE" "$fallback_old_plan"; fallback_old_plan_existed=true; fi

    ROUTER_WGPAY_FALLBACK_LOCK_BYPASS=1 ROUTER_WGPAY_FALLBACK_STATE_FILE="$fallback_candidate" "$MAPPER" start > "$fallback_tmp/mapper.log" 2>&1 || {
        fallback_map_rc=$?
        fallback_map_result="$(awk -F= '$1=="RESULT"{v=$2} END{print v}' "$fallback_tmp/mapper.log" 2>/dev/null)"
        fallback_map_result="$(rwf_sanitize "${fallback_map_result:-unknown}")"
        printf '%s\n' "schema=${ACK_SCHEMA}" 'result=FAILED' 'reason=mapper_apply_failed' "detail=${fallback_map_rc}" "mapper_result=${fallback_map_result}" "generation=${fallback_msg_generation}" "payload_sha256=${fallback_payload_sha}" 'state_persisted=false'
        return "$fallback_map_rc"
    }

    {
        printf 'schema=%s\n' "$ACK_SCHEMA"
        printf 'result=PASS\n'
        printf 'accepted_generation=%s\n' "$fallback_msg_generation"
        printf 'payload_sha256=%s\n' "$fallback_payload_sha"
        printf 'mode=%s\n' "$fallback_msg_mode"
        printf 'first_healthy_slot=%s\n' "$fallback_first_healthy"
        printf 'fallback_selectors=%s\n' "$fallback_fallback_selectors"
        printf 'plan_sha256=%s\n' "$fallback_plan_sha"
        printf 'mapper_applied=true\n'
        printf 'state_persisted=true\n'
        printf 'always_on=true\n'
    } > "$fallback_ack"

    fallback_persist_rc=0
    if [ "${ROUTER_FALLBACK_TEST_FAULT:-}" = persist ]; then
        fallback_persist_rc=91
    else
        # The persistent state is the commit marker and is written last.
        rwf_atomic_write "$fallback_candidate" "$RUNTIME_STATE" 600 || fallback_persist_rc=1
        [ "$fallback_persist_rc" -ne 0 ] || rwf_atomic_write "$fallback_plan" "$PLAN_FILE" 600 || fallback_persist_rc=1
        [ "$fallback_persist_rc" -ne 0 ] || rwf_atomic_write "$fallback_ack" "$ACK_FILE" 600 || fallback_persist_rc=1
        [ "$fallback_persist_rc" -ne 0 ] || rwf_atomic_write "$fallback_candidate" "$STATE_FILE" 600 || fallback_persist_rc=1
    fi
    if [ "$fallback_persist_rc" -ne 0 ]; then
        if [ "$fallback_old_state_existed" = true ]; then
            rwf_atomic_write "$fallback_old_state" "$STATE_FILE" 600 || true
            ROUTER_WGPAY_FALLBACK_LOCK_BYPASS=1 ROUTER_WGPAY_FALLBACK_STATE_FILE="$fallback_old_state" "$MAPPER" start >/dev/null 2>&1 || true
        else
            rm -f "$STATE_FILE"
            ROUTER_WGPAY_FALLBACK_LOCK_BYPASS=1 ROUTER_WGPAY_FALLBACK_STATE_FILE="$fallback_tmp/nonexistent" "$MAPPER" start >/dev/null 2>&1 || true
        fi
        if [ "$fallback_old_ack_existed" = true ]; then rwf_atomic_write "$fallback_old_ack" "$ACK_FILE" 600 || true; else rm -f "$ACK_FILE"; fi
        if [ "$fallback_old_runtime_existed" = true ]; then rwf_atomic_write "$fallback_old_runtime" "$RUNTIME_STATE" 600 || true; else rm -f "$RUNTIME_STATE"; fi
        if [ "$fallback_old_plan_existed" = true ]; then rwf_atomic_write "$fallback_old_plan" "$PLAN_FILE" 600 || true; else rm -f "$PLAN_FILE"; fi
        printf '%s\n' "schema=${ACK_SCHEMA}" 'result=FAILED' 'reason=state_persist_failed' "detail=${fallback_persist_rc}" "generation=${fallback_msg_generation}" 'mapper_rollback_attempted=true' 'state_persisted=false'
        return 82
    fi

    cat "$ACK_FILE"
    return 0
}

fallback_initialize_normal() {
    if [ -f "$STATE_FILE" ]; then
        ROUTER_WGPAY_FALLBACK_STATE_FILE="$STATE_FILE" "$MAPPER" start
        return $?
    fi
    fallback_init_tmp="${TMPDIR:-/tmp}/router-wgpay-fallback-init.$$"
    trap 'rm -f "$fallback_init_tmp" "${fallback_init_tmp}.body"' EXIT HUP INT TERM
    {
        printf 'schema=%s\n' "$SCHEMA"
        printf 'generation=000000000000\n'
        printf 'mode=NORMAL\n'
        printf 'source_vm101_generation=R20QD_INSTALL\n'
        printf 'healthy_slots=%s\n' "$CANONICAL_SLOTS"
        printf 'exhausted_slots=\n'
        printf 'healthy_selectors=%s\n' "$CANONICAL_SELECTORS"
        printf 'exhausted_selectors=\n'
        printf 'created_epoch=%s\n' "$NOW_EPOCH"
    } > "${fallback_init_tmp}.body"
    cp "${fallback_init_tmp}.body" "$fallback_init_tmp"
    printf 'confirm_sha256=%s\n' "$(sha256sum "${fallback_init_tmp}.body" | awk '{print $1}')" >> "$fallback_init_tmp"
    "$0" --stdin < "$fallback_init_tmp"
}

case "${1:---status}" in
    --stdin) fallback_run_stdin ;;
    --initialize-normal) fallback_initialize_normal ;;
    --reapply)
        [ -f "$STATE_FILE" ] || { echo 'RESULT=STOP_FALLBACK_STATE_MISSING'; exit 70; }
        ROUTER_WGPAY_FALLBACK_STATE_FILE="$STATE_FILE" "$MAPPER" start
        ;;
    --status)
        if [ -f "$STATE_FILE" ]; then cat "$STATE_FILE"; else printf '%s\n' 'schema=router-wgpay-fallback-state-v1' 'result=EMPTY'; fi
        ;;
    *) echo "usage: $0 {--stdin|--initialize-normal|--reapply|--status}"; exit 64 ;;
esac
