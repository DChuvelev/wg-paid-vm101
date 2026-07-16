#!/bin/sh
# STEP_050M07R14B_LOCAL_REPAIR_NORMALIZATION
set -u

ADAPTER="${ADAPTER:-/usr/local/sbin/router-egress-recovery-hmn-pool-replace.sh}"
MODE="--dry-run"
SLOT=""
REASON="health_fail"
CONFIRM=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --slot)
            [ "$#" -ge 2 ] || { echo 'ERROR=slot_value_missing' >&2; exit 2; }
            SLOT="$2"
            shift 2
            ;;
        --reason)
            [ "$#" -ge 2 ] || { echo 'ERROR=reason_value_missing' >&2; exit 2; }
            REASON="$2"
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
            [ "$#" -ge 2 ] || { echo 'ERROR=confirm_value_missing' >&2; exit 2; }
            CONFIRM="$2"
            shift 2
            ;;
        *)
            echo "ERROR=unsupported_argument:$1" >&2
            exit 2
            ;;
    esac
done

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

emit_json() {
    echo '{'
    echo '  "schema": "router-egress-recovery-dispatcher-v2",'
    echo "  \"mode\": \"$(json_escape "$MODE")\","
    echo "  \"slot\": \"$(json_escape "$SLOT")\","
    echo "  \"reason_input\": \"$(json_escape "$REASON")\","
    echo "  \"iface\": \"$(json_escape "$iface")\","
    echo "  \"candidate_endpoint\": \"$(json_escape "$candidate")\","
    echo "  \"adapter_dryrun_rc\": ${dry_rc},"
    echo "  \"adapter_dryrun_decision\": \"$(json_escape "$dry_decision")\","
    echo "  \"adapter_commit_rc\": ${commit_rc},"
    echo "  \"adapter_commit_decision\": \"$(json_escape "$commit_decision")\","
    echo "  \"decision\": \"$(json_escape "$decision")\","
    echo "  \"reason\": \"$(json_escape "$reason_out")\","
    echo "  \"apply_performed\": ${apply_performed},"
    echo "  \"required_dispatch_confirm\": \"$(json_escape "$required_confirm")\","
    echo '  "safety": {'
    echo '    "slot_is_required": true,'
    echo '    "dry_run_no_uci_set": true,'
    echo '    "dry_run_no_ifup_ifdown": true,'
    echo '    "commit_requires_dispatch_confirm": true,'
    echo '    "adapter_nonzero_rc_cannot_be_commit_ok": true'
    echo '  }'
    echo '}'
}

iface=""
candidate=""
dry_rc=2
dry_decision=""
commit_rc=0
commit_decision=""
decision="refuse"
reason_out="unknown"
apply_performed=false
required_confirm=""

if [ -z "$SLOT" ]; then
    reason_out="slot_required"
    emit_json
    exit 2
fi

if [ ! -x "$ADAPTER" ]; then
    reason_out="adapter_missing"
    emit_json
    exit 2
fi

dry_json="$($ADAPTER --dry-run --slot "$SLOT" 2>/dev/null)"
dry_rc=$?
candidate="$(printf '%s\n' "$dry_json" | sed -n 's/.*"candidate_endpoint": "\([^"]*\)".*/\1/p' | head -n 1)"
iface="$(printf '%s\n' "$dry_json" | sed -n 's/.*"interface": "\([^"]*\)".*/\1/p' | head -n 1)"
dry_decision="$(printf '%s\n' "$dry_json" | sed -n 's/.*"decision": "\([^"]*\)".*/\1/p' | head -n 1)"
required_confirm="DISPATCH_${SLOT}_${candidate}"

if [ "$dry_rc" -ne 0 ] || [ "$dry_decision" != "dry_run_ok" ] || [ -z "$candidate" ] || [ -z "$iface" ]; then
    decision="refuse"
    reason_out="adapter_dryrun_not_ready"
elif [ "$MODE" = "--dry-run" ]; then
    decision="dry_run_ok"
    reason_out="dispatcher_ready"
elif [ "$MODE" = "--commit" ]; then
    if [ "$CONFIRM" != "$required_confirm" ]; then
        decision="refuse"
        reason_out="missing_or_wrong_dispatch_confirm"
    else
        adapter_confirm="APPLY_${SLOT}_${iface}_${candidate}"
        commit_json="$($ADAPTER --commit --slot "$SLOT" --confirm "$adapter_confirm" 2>/dev/null)"
        commit_rc=$?
        commit_decision="$(printf '%s\n' "$commit_json" | sed -n 's/.*"decision": "\([^"]*\)".*/\1/p' | head -n 1)"
        apply_performed=true
        if [ "$commit_rc" -eq 0 ] && [ "$commit_decision" = "commit_ok" ]; then
            decision="commit_ok"
            reason_out="adapter_commit_ok"
        else
            decision="commit_failed"
            reason_out="adapter_commit_failed_or_state_record_failed"
        fi
    fi
else
    decision="refuse"
    reason_out="unsupported_mode"
fi

emit_json

case "$decision" in
    dry_run_ok|commit_ok) exit 0 ;;
    commit_failed) exit 3 ;;
    *) exit 2 ;;
esac
