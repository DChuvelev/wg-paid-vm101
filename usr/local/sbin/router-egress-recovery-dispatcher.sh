#!/bin/sh
set -u
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
CORE="${ROUTER_EGRESS_RECOVERY_DISPATCHER_CORE:-/usr/local/lib/router-egress-recovery-dispatcher-core.sh}"
SYNC="${ROUTER_WGPAY_WATCHER_SYNC:-/usr/local/sbin/router-wgpay-watcher-topology-sync.sh}"
LOG="${ROUTER_WGPAY_WATCHER_LOG:-/var/log/router-wgpay-health-topology.log}"

[ -x "$CORE" ] || { echo RESULT=STOP_WATCHER_DISPATCHER_CORE_MISSING; exit 70; }

find_slot() {
    for value in \
        "${ROUTER_EGRESS_FAILED_SLOT:-}" \
        "${ROUTER_EGRESS_TARGET_SLOT:-}" \
        "${FAILED_SLOT:-}" "${TARGET_SLOT:-}" "${SLOT:-}" \
        "$@"
    do
        case "$value" in
            egress[1-5]) printf '%s\n' "$value"; return 0 ;;
            vpn[1-5]) printf 'egress%s\n' "${value#vpn}"; return 0 ;;
            *=egress[1-5]) printf '%s\n' "${value##*=}"; return 0 ;;
            *=vpn[1-5]) printf 'egress%s\n' "${value##*vpn}"; return 0 ;;
            *egress[1-5]*)
                printf '%s\n' "$value" | sed -n 's/.*\(egress[1-5]\).*/\1/p' | head -n1
                return 0
                ;;
        esac
    done
    state="${ROUTER_EGRESS_RECOVERY_STATE_FILE:-/var/lib/router-egress-recovery/state.kv}"
    if [ -f "$state" ]; then
        for key in failed_slot target_slot slot egress_slot; do
            value="$(awk -F= -v k="$key" '$1==k{print substr($0,index($0,"=")+1)}' "$state" | tail -n1)"
            case "$value" in egress[1-5]) printf '%s\n' "$value"; return 0;; esac
        done
    fi
    return 1
}

log_line() {
    mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
    printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || true
}

slot="$(find_slot "$@" 2>/dev/null || true)"
if [ -n "$slot" ] && [ -x "$SYNC" ]; then
    "$SYNC" --bridge-start "$slot" watcher_dispatch_start >> "$LOG" 2>&1 || log_line "bridge_start_failed slot=$slot rc=$?"
fi

"$CORE" "$@"
rc=$?

if [ -n "$slot" ] && [ -x "$SYNC" ]; then
    if [ "$rc" -eq 0 ]; then
        "$SYNC" --bridge-clear "$slot" watcher_dispatch_success >> "$LOG" 2>&1 || log_line "bridge_clear_failed slot=$slot rc=$?"
    else
        "$SYNC" --bridge-confirm "$slot" watcher_dispatch_failed >> "$LOG" 2>&1 || log_line "bridge_confirm_failed slot=$slot rc=$?"
    fi
fi
exit "$rc"
