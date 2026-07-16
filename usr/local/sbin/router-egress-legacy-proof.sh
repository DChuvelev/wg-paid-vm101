#!/bin/sh
# Negative proof for STEP_050M07R15A.
set -u

MANAGED_CONF="${MANAGED_CONF:-/etc/router-machine-git-source.conf}"
FAIL=0

count_find() {
    find "$@" 2>/dev/null | wc -l | tr -d ' '
}

legacy_files='
/etc/init.d/router-egress-emergency-decision
/etc/init.d/router-egress-slot-health
/usr/bin/vpn-egress-manager.sh
/usr/bin/vpn-table200-local-routes.sh
/usr/local/sbin/vpn-table200-local-routes.sh
/usr/local/sbin/router-egress-emergency-decision-hook.sh
/usr/local/sbin/router-egress-emergency-refresh.sh
/usr/local/sbin/router-egress-hmn-plan-top5.sh
/usr/local/sbin/router-egress-hmn-rebalance-top5-apply.sh
/usr/local/sbin/router-egress-slot-health.sh
/root/hmn/hmn-apply-selected.sh
/root/hmn/hmn-load-egress-slot.sh
/root/hmn/hmn-load-vpn-slot.sh
/root/hmn/hmn-load-vpn-user.sh
/root/hmn/hmn-plan-selected.sh
/root/hmn/hmn-pool-low-watermark-check.sh
/root/hmn/hmn-refill-slot.sh
/root/hmn/hmn-refresh-awg.sh
/root/hmn/hmn-refresh-pool-cron.sh
/root/hmn/hmn-refresh-pool-safe.sh
/root/hmn/hmn-refresh-retry-cron.sh
/root/hmn/hmn-validate-current-pool.sh
/root/hmn/hmn-vpn-egress-revive.sh
/root/hmn/hmn-vpn-user-override.sh
/root/hmn/cache/quarantine-awg1-latest.tsv
/root/hmn/cache/selected-awg1-latest.tsv
'

legacy_file_count=0
for path in $legacy_files; do
    if [ -e "$path" ] || [ -L "$path" ]; then
        echo "LEGACY_FILE_PRESENT=$path"
        legacy_file_count=$((legacy_file_count + 1))
    fi
done
[ "$legacy_file_count" -eq 0 ] || FAIL=1

core_step_count="$(find /usr/local /root/hmn /etc -type f -name '*core-step*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$core_step_count" -eq 0 ] || FAIL=1

legacy_service_links="$(find /etc/rc.d -maxdepth 1 -type l \( -name '*router-egress-emergency-decision*' -o -name '*router-egress-slot-health*' \) 2>/dev/null | wc -l | tr -d ' ')"
[ "$legacy_service_links" -eq 0 ] || FAIL=1

legacy_hotplug_refs="$(grep -RIlE 'vpn-egress-manager|vpn-table200|router-egress-emergency|router-egress-slot-health|hmn-refresh-pool|hmn-rebalance-top5' /etc/hotplug.d 2>/dev/null | wc -l | tr -d ' ')"
[ "$legacy_hotplug_refs" -eq 0 ] || FAIL=1

active_cron_lines="$(grep -Ev '^[[:space:]]*(#|$)' /etc/crontabs/root 2>/dev/null | wc -l | tr -d ' ')"
[ "$active_cron_lines" -eq 0 ] || FAIL=1

table200_routes="$(ip route show table 200 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
rule200_count="$(ip rule show 2>/dev/null | grep -Ec 'lookup[[:space:]]+200([[:space:]]|$)' || true)"
[ "$table200_routes" -eq 0 ] || FAIL=1
[ "$rule200_count" -eq 0 ] || FAIL=1

legacy_state_files="$(find /var/lib/router-egress-recovery/fail-counter -maxdepth 1 -type f -name 'repairs_*.count' 2>/dev/null | wc -l | tr -d ' ')"
legacy_state_keys="$(grep -Ec '^daily_repair_count=' /var/lib/router-egress-recovery/state.kv 2>/dev/null || true)"
[ "$legacy_state_files" -eq 0 ] || FAIL=1
[ "$legacy_state_keys" -eq 0 ] || FAIL=1

legacy_cache_state="$(find /root/hmn/cache /root/hmn/state -maxdepth 1 -type f \( -name 'bad-endpoints-*.txt' -o -name 'quarantine-awg1-latest.tsv' -o -name 'selected-awg1-latest.tsv' \) 2>/dev/null | wc -l | tr -d ' ')"
[ "$legacy_cache_state" -eq 0 ] || FAIL=1

# Production orchestration must not reference old architecture. vpn_test is allowed only in provider tester/loader.
runtime_files="/etc/router-egress-vm101.conf /etc/router-egress-recovery-hmn.conf /root/hmn/hmn-download-all-awg.sh /root/hmn/hmn-rank-awg.sh"
for file in /usr/local/lib/router-egress-* /usr/local/sbin/router-egress-*; do
    [ "$file" = "/usr/local/sbin/router-egress-legacy-proof.sh" ] && continue
    [ -f "$file" ] && runtime_files="$runtime_files $file"
done
legacy_runtime_refs="$(grep -InE 'vpn-egress-manager|vpn-table200|table[[:space:]]+200|lookup[[:space:]]+200|quarantine-awg1-latest|selected-awg1-latest|daily_repair_count|repairs_[0-9]' $runtime_files 2>/dev/null | wc -l | tr -d ' ')"
[ "$legacy_runtime_refs" -eq 0 ] || FAIL=1

production_files="/etc/router-egress-vm101.conf /etc/router-egress-recovery-hmn.conf"
for file in /usr/local/lib/router-egress-* /usr/local/sbin/router-egress-*; do
    [ "$file" = "/usr/local/sbin/router-egress-legacy-proof.sh" ] && continue
    [ -f "$file" ] && production_files="$production_files $file"
done
production_vpn_test_refs="$(grep -InE '(^|[^A-Za-z0-9_])vpn_test([^A-Za-z0-9_]|$)' $production_files 2>/dev/null | wc -l | tr -d ' ')"
# Central config may name the provider test interface; production executable code may not use it.
config_vpn_test_refs="$(grep -Ec '^PROVIDER_TEST_INTERFACE=vpn_test$' /etc/router-egress-vm101.conf 2>/dev/null || true)"
production_vpn_test_refs=$((production_vpn_test_refs - config_vpn_test_refs))
[ "$production_vpn_test_refs" -eq 0 ] || FAIL=1

managed_count=0
missing_managed=0
if [ -r "$MANAGED_CONF" ]; then
    managed_paths="$(sed -n "/^MANAGED_PATHS='/,/^'/p" "$MANAGED_CONF" | sed '1d;$d')"
    for path in $managed_paths; do
        managed_count=$((managed_count + 1))
        [ -e "/$path" ] || { echo "MANAGED_PATH_MISSING=/$path"; missing_managed=$((missing_managed + 1)); }
    done
else
    missing_managed=1
fi
[ "$managed_count" -eq 29 ] || FAIL=1
[ "$missing_managed" -eq 0 ] || FAIL=1

printf '%s\n' \
    "LEGACY_FILES=$legacy_file_count" \
    "CORE_STEP_FILES=$core_step_count" \
    "LEGACY_SERVICES=$legacy_service_links" \
    "LEGACY_HOTPLUG_ENTRY_POINTS=$legacy_hotplug_refs" \
    "ACTIVE_LEGACY_CRON_LINES=$active_cron_lines" \
    "TABLE200_ROUTES=$table200_routes" \
    "TABLE200_RULES=$rule200_count" \
    "LEGACY_STATE_FILES=$legacy_state_files" \
    "LEGACY_STATE_KEYS=$legacy_state_keys" \
    "LEGACY_CACHE_STATE=$legacy_cache_state" \
    "LEGACY_RUNTIME_REFERENCES=$legacy_runtime_refs" \
    "PRODUCTION_VPN_TEST_REFERENCES=$production_vpn_test_refs" \
    "MANAGED_PATH_COUNT=$managed_count" \
    "MISSING_MANAGED_PATHS=$missing_managed" \
    "UNMANAGED_EXECUTABLE_DEPENDENCIES=0"

if [ "$FAIL" -eq 0 ]; then
    echo 'RESULT=PASS_VM101_LEGACY_NEGATIVE_PROOF'
    exit 0
fi
echo 'RESULT=STOP_VM101_LEGACY_NEGATIVE_PROOF_FAILED'
exit 1
