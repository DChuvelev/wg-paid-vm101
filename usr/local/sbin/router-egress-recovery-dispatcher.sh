#!/bin/sh
set -u

ADAPTER="${ADAPTER:-/usr/local/sbin/router-egress-recovery-hmn-pool-replace.sh}"
MODE="--dry-run"
SLOT=""
REASON="health_fail"
CONFIRM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --slot) SLOT="${2:-}"; shift 2 ;;
    --reason) REASON="${2:-}"; shift 2 ;;
    --dry-run) MODE="--dry-run"; shift ;;
    --commit) MODE="--commit"; shift ;;
    --confirm) CONFIRM="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$SLOT" ] || SLOT="egress2"

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

if [ ! -x "$ADAPTER" ]; then
  echo '{"schema":"router-egress-recovery-dispatcher-v1","decision":"refuse","reason":"adapter_missing","apply_performed":false}'
  exit 0
fi

dry_json="$("$ADAPTER" --dry-run --slot "$SLOT" 2>/dev/null || true)"
candidate="$(printf '%s\n' "$dry_json" | sed -n 's/.*"candidate_endpoint": "\([^"]*\)".*/\1/p' | head -1)"
iface="$(printf '%s\n' "$dry_json" | sed -n 's/.*"interface": "\([^"]*\)".*/\1/p' | head -1)"
dry_decision="$(printf '%s\n' "$dry_json" | sed -n 's/.*"decision": "\([^"]*\)".*/\1/p' | head -1)"

decision="dry_run_ok"
apply_performed=false
adapter_commit_json=""

if [ "$dry_decision" != "dry_run_ok" ] || [ -z "$candidate" ] || [ -z "$iface" ]; then
  decision="refuse"
  reason_out="adapter_dryrun_not_ready"
elif [ "$MODE" = "--dry-run" ]; then
  decision="dry_run_ok"
  reason_out="dispatcher_ready"
elif [ "$MODE" = "--commit" ]; then
  expected="DISPATCH_${SLOT}_${candidate}"
  if [ "$CONFIRM" != "$expected" ]; then
    decision="refuse"
    reason_out="missing_or_wrong_dispatch_confirm"
  else
    adapter_confirm="APPLY_${SLOT}_${iface}_${candidate}"
    adapter_commit_json="$("$ADAPTER" --commit --slot "$SLOT" --confirm "$adapter_confirm" 2>/dev/null || true)"
    adapter_commit_decision="$(printf '%s\n' "$adapter_commit_json" | sed -n 's/.*"decision": "\([^"]*\)".*/\1/p' | head -1)"
    apply_performed=true
    if [ "$adapter_commit_decision" = "commit_ok" ]; then
      decision="commit_ok"
      reason_out="adapter_commit_ok"
    else
      decision="commit_failed"
      reason_out="adapter_commit_failed"
    fi
  fi
else
  decision="refuse"
  reason_out="unsupported_mode"
fi

echo "{"
echo '  "schema": "router-egress-recovery-dispatcher-v1",'
echo "  \"mode\": \"$(json_escape "$MODE")\","
echo "  \"slot\": \"$(json_escape "$SLOT")\","
echo "  \"reason_input\": \"$(json_escape "$REASON")\","
echo "  \"iface\": \"$(json_escape "$iface")\","
echo "  \"candidate_endpoint\": \"$(json_escape "$candidate")\","
echo "  \"adapter_dryrun_decision\": \"$(json_escape "$dry_decision")\","
echo "  \"decision\": \"$(json_escape "$decision")\","
echo "  \"reason\": \"$(json_escape "$reason_out")\","
echo "  \"apply_performed\": $apply_performed,"
echo "  \"required_dispatch_confirm\": \"$(json_escape "DISPATCH_${SLOT}_${candidate}")\","
echo '  "safety": {'
echo '    "dry_run_no_uci_set": true,'
echo '    "dry_run_no_ifup_ifdown": true,'
echo '    "commit_requires_dispatch_confirm": true'
echo '  }'
echo "}"
