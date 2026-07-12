#!/bin/sh
# STEP_050D_RECORD_QUARANTINE_COUNTER_WRAPPER
set -u

ADAPTER_CORE_DEFAULT="/usr/local/sbin/router-egress-recovery-hmn-pool-replace.sh.core-step050d-20260711-104437"
ADAPTER_CORE="${ROUTER_EGRESS_RECOVERY_CORE_OVERRIDE:-$ADAPTER_CORE_DEFAULT}"
HELPER="${ROUTER_EGRESS_RECOVERY_STATE_HELPER:-/usr/local/lib/router-egress-recovery-state.sh}"
LOG="${ROUTER_EGRESS_RECOVERY_STATE_LOG:-/var/log/router-egress-recovery-state.log}"

egress=""
dry_run=false
apply_requested=false
confirm_seen=false
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
    --egress|--slot)
      prev="egress"
      ;;
    --confirm)
      confirm_seen=true
      apply_requested=true
      prev="confirm"
      ;;
    --apply|--commit)
      apply_requested=true
      ;;
    --dry-run|--dryrun)
      dry_run=true
      ;;
    egress[1-5])
      if [ -z "$egress" ]; then
        egress="$arg"
      fi
      ;;
  esac
done

if [ "$dry_run" = "true" ]; then
  apply_requested=false
fi

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
  old_ep="$(uci -q get network.${iface}.hmn_endpoint 2>/dev/null || true)"
fi

tmp_base="/tmp/router-egress-recovery-hmn-wrapper.$$"
out="${tmp_base}.out"
err="${tmp_base}.err"

if [ ! -x "$ADAPTER_CORE" ]; then
  echo "adapter_core_missing=$ADAPTER_CORE" >&2
  rm -f "$out" "$err" 2>/dev/null || true
  exit 23
fi

"$ADAPTER_CORE" "$@" > "$out" 2> "$err"
rc=$?

cat "$out" 2>/dev/null || true
cat "$err" >&2 2>/dev/null || true

new_ep="${ROUTER_EGRESS_RECOVERY_NEW_ENDPOINT_OVERRIDE:-}"
if [ -z "$new_ep" ] && [ -n "$iface" ]; then
  new_ep="$(uci -q get network.${iface}.hmn_endpoint 2>/dev/null || true)"
fi

pool_path="$(sed -n 's/.*\"pool\"[ ]*:[ ]*\"\([^\"]*\)\".*/\1/p' "$out" 2>/dev/null | tail -1)"
[ -n "$pool_path" ] || pool_path="$(sed -n 's/.*\"pool_path\"[ ]*:[ ]*\"\([^\"]*\)\".*/\1/p' "$out" 2>/dev/null | tail -1)"
[ -n "$pool_path" ] || pool_path="/root/hmn/cache/ok-awg1-strict-foreign-latest.tsv"

record_ok=false

if [ "$rc" = "0" ] && [ "$apply_requested" = "true" ] && [ "$dry_run" = "false" ] && [ -n "$egress" ] && [ -n "$iface" ] && [ -n "$old_ep" ] && [ -n "$new_ep" ] && [ "$old_ep" != "$new_ep" ]; then
  if [ -r "$HELPER" ]; then
    . "$HELPER"
    if reg_init_state >/dev/null 2>&1; then
      reg_quarantine_endpoint "$old_ep" "$egress" "$iface" "$new_ep" "repair_replaced_endpoint" "$pool_path" "STEP_050D_REPAIR_WRAPPER" >/dev/null 2>&1 && record_ok=true
      daily_count="$(reg_daily_repair_inc 2>/dev/null || echo 0)"
      now="$(reg_now_epoch 2>/dev/null || date +%s)"
      reg_set_state last_repair_epoch "$now" >/dev/null 2>&1 || true
      reg_set_state last_repair_egress "$egress" >/dev/null 2>&1 || true
      reg_set_state last_repair_iface "$iface" >/dev/null 2>&1 || true
      reg_set_state last_repair_old_endpoint "$old_ep" >/dev/null 2>&1 || true
      reg_set_state last_repair_new_endpoint "$new_ep" >/dev/null 2>&1 || true
      reg_set_state daily_repair_count "$daily_count" >/dev/null 2>&1 || true
      mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
      printf '%s action=record_quarantine egress=%s iface=%s old=%s new=%s pool=%s daily_count=%s record_ok=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" "$egress" "$iface" "$old_ep" "$new_ep" "$pool_path" "$daily_count" "$record_ok" >> "$LOG" 2>/dev/null || true
    fi
  fi
fi

rm -f "$out" "$err" 2>/dev/null || true
exit "$rc"
