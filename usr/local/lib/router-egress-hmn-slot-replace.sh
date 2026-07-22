#!/bin/sh
set -u

CONF="${ROUTER_EGRESS_RECOVERY_HMN_CONF:-/etc/router-egress-recovery-hmn.conf}"
[ -f "$CONF" ] && . "$CONF"

MODE="${MODE:---dry-run}"
SLOT=""
CONFIRM=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --slot|--egress) [ "$#" -ge 2 ] || { echo 'ERROR=slot_value_missing' >&2; exit 2; }; SLOT="$2"; shift 2 ;;
        --dry-run|--dryrun) MODE='--dry-run'; shift ;;
        --commit|--apply) MODE='--commit'; shift ;;
        --confirm) [ "$#" -ge 2 ] || { echo 'ERROR=confirm_value_missing' >&2; exit 2; }; CONFIRM="$2"; shift 2 ;;
        *) echo "ERROR=unsupported_argument:$1" >&2; exit 2 ;;
    esac
done

SLOTS_CONF="${SLOTS_CONF:-/etc/router-egress-slots.d/slots.conf}"
HMN_CACHE_DIR="${HMN_CACHE_DIR:-/root/hmn/cache}"
HMN_CONFIG_ROOT="${HMN_CONFIG_ROOT:-/root/hmn/configs/awg1}"
MAX_POOL_AGE_SEC="${MAX_POOL_AGE_SEC:-129600}"
PREFERRED_POOL_FILES="${PREFERRED_POOL_FILES:-ok-awg1-strict-foreign-latest.tsv ok-awg1-strict-all-latest.tsv working-awg1-latest.tsv ranked-awg1-latest.tsv}"
STATE_DIR="${STATE_DIR:-/var/lib/router-egress-recovery}"
STATE_HELPER="${STATE_HELPER:-/usr/local/lib/router-egress-recovery-state.sh}"
LOG="${LOG:-/var/log/router-egress-recovery-hmn.log}"
REQUIRE_EXPLICIT_COMMIT="${REQUIRE_EXPLICIT_COMMIT:-1}"
POST_APPLY_SLEEP_SEC="${POST_APPLY_SLEEP_SEC:-12}"
LOCAL_REPAIR_CANDIDATE_RETRIES="${LOCAL_REPAIR_CANDIDATE_RETRIES:-3}"
SLOTS_APPLY="${SLOTS_APPLY:-/usr/local/sbin/router-egress-slots-apply.sh}"
NETWORK_CONFIG="${NETWORK_CONFIG:-/etc/config/network}"
UCI_BIN="${UCI_BIN:-uci}"
IP_BIN="${IP_BIN:-ip}"
PING_BIN="${PING_BIN:-ping}"
IFUP_BIN="${IFUP_BIN:-ifup}"
IFDOWN_BIN="${IFDOWN_BIN:-ifdown}"
SLEEP_BIN="${SLEEP_BIN:-sleep}"
AWG_BIN="${AWG_BIN:-/usr/bin/amneziawg}"
SHA256_BIN="${SHA256_BIN:-sha256sum}"

mkdir -p "$STATE_DIR" "$(dirname "$LOG")" 2>/dev/null || true

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
is_uint() { printf '%s\n' "$1" | grep -Eq '^[0-9]+$'; }
valid_endpoint() { printf '%s\n' "$1" | grep -Eq '^([A-Za-z0-9._-]+\.[A-Za-z]{2,}|[0-9]{1,3}(\.[0-9]{1,3}){3}):[0-9]{2,5}$'; }
trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
config_value() (
    cv_key="$1"; cv_file="$2"
    awk -v key="$cv_key" '$0 ~ "^[[:space:]]*" key "[[:space:]]*=" {sub(/^[^=]*=[[:space:]]*/,"",$0); sub(/[[:space:]]*$/, "", $0); print; exit}' "$cv_file"
)
extract_endpoints() (
    ee_file="$1"
    grep -Eho '([A-Za-z0-9._-]+\.[A-Za-z]{2,}|[0-9]{1,3}(\.[0-9]{1,3}){3}):[0-9]{2,5}' "$ee_file" 2>/dev/null \
      | sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//' \
      | grep -E '^([A-Za-z0-9._-]+\.[A-Za-z]{2,}|[0-9]{1,3}(\.[0-9]{1,3}){3}):[0-9]{2,5}$' \
      | awk '!seen[$0]++'
)
endpoint_count() { extract_endpoints "$1" | wc -l | tr -d ' '; }
peer_uci_endpoint_for_iface() (
    pu_iface="$1"
    pu_host="$("$UCI_BIN" -q get "network.@amneziawg_${pu_iface}[0].endpoint_host" 2>/dev/null || true)"
    pu_port="$("$UCI_BIN" -q get "network.@amneziawg_${pu_iface}[0].endpoint_port" 2>/dev/null || true)"
    [ -n "$pu_host" ] && [ -n "$pu_port" ] && printf '%s:%s\n' "$pu_host" "$pu_port"
)
current_endpoint_for_iface() (
    ce_iface="$1"
    ce_endpoint="$("$UCI_BIN" -q get "network.${ce_iface}.hmn_endpoint" 2>/dev/null || true)"
    [ -n "$ce_endpoint" ] || ce_endpoint="$(peer_uci_endpoint_for_iface "$ce_iface")"
    printf '%s\n' "$ce_endpoint"
)
live_endpoint_for_iface() (
    le_iface="$1"
    "$AWG_BIN" show "$le_iface" endpoints 2>/dev/null | awk 'NR==1{print $NF; exit}'
)
normalize_tokens() (
    printf '%s\n' "$1" | tr ', ' '\n\n' | sed '/^[[:space:]]*$/d;s/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u | awk 'NF{if(n++)printf ",";printf "%s",$0} END{printf "\n"}'
)
find_config_for_endpoint() (
    fc_endpoint="$1"; fc_hint_pool="${2:-}"
    for fc_pool in "$fc_hint_pool" \
      "$HMN_CACHE_DIR/ok-awg1-strict-foreign-latest.tsv" \
      "$HMN_CACHE_DIR/ok-awg1-strict-all-latest.tsv" \
      "$HMN_CACHE_DIR/working-awg1-latest.tsv" \
      "$HMN_CACHE_DIR/ranked-awg1-latest.tsv" \
      "$HMN_CACHE_DIR/candidate-pool-awg1-latest.tsv"
    do
        [ -n "$fc_pool" ] && [ -s "$fc_pool" ] || continue
        fc_path="$(awk -F '\t' -v ep="$fc_endpoint" '
          NR>1 {
            hit=0; path="";
            for(i=1;i<=NF;i++){if($i==ep)hit=1; if($i ~ /^\// && $i ~ /\.conf$/)path=$i}
            if(hit && path!=""){print path; exit}
          }' "$fc_pool" 2>/dev/null || true)"
        if [ -n "$fc_path" ] && [ -f "$fc_path" ] && [ "$(config_value Endpoint "$fc_path")" = "$fc_endpoint" ]; then
            printf '%s\n' "$fc_path"; exit 0
        fi
    done
    find "$HMN_CONFIG_ROOT" -type f -name '*.conf' 2>/dev/null | sort | while IFS= read -r fc_path; do
        [ "$(config_value Endpoint "$fc_path")" = "$fc_endpoint" ] || continue
        printf '%s\n' "$fc_path"; exit 0
    done
)
config_binding_valid() (
    cb_file="$1"; cb_expected="$2"
    [ -f "$cb_file" ] || exit 1
    [ "$(config_value Endpoint "$cb_file")" = "$cb_expected" ] || exit 1
    for cb_key in PrivateKey Address Jc Jmin Jmax S1 S2 H1 H2 H3 H4 PublicKey; do
        [ -n "$(config_value "$cb_key" "$cb_file")" ] || exit 1
    done
    valid_endpoint "$cb_expected"
)
remove_iface_peers() (
    rp_iface="$1"
    while :; do
        rp_sec="$("$UCI_BIN" -q show network | sed -n "s/^\(network\.@amneziawg_${rp_iface}\[[0-9][0-9]*\]\)=amneziawg_${rp_iface}$/\1/p" | head -n1)"
        [ -n "$rp_sec" ] || break
        "$UCI_BIN" -q delete "$rp_sec" || exit 1
    done
)
apply_full_config_to_iface() (
    af_iface="$1"; af_slot="$2"; af_cfg="$3"; af_expected="$4"
    config_binding_valid "$af_cfg" "$af_expected" || exit 1
    af_private="$(config_value PrivateKey "$af_cfg")"; af_address="$(config_value Address "$af_cfg")"; af_dns="$(config_value DNS "$af_cfg")"
    af_jc="$(config_value Jc "$af_cfg")"; af_jmin="$(config_value Jmin "$af_cfg")"; af_jmax="$(config_value Jmax "$af_cfg")"
    af_s1="$(config_value S1 "$af_cfg")"; af_s2="$(config_value S2 "$af_cfg")"
    af_h1="$(config_value H1 "$af_cfg")"; af_h2="$(config_value H2 "$af_cfg")"; af_h3="$(config_value H3 "$af_cfg")"; af_h4="$(config_value H4 "$af_cfg")"
    af_public="$(config_value PublicKey "$af_cfg")"; af_allowed="$(config_value AllowedIPs "$af_cfg")"; af_keepalive="$(config_value PersistentKeepalive "$af_cfg")"
    [ -n "$af_allowed" ] || af_allowed='0.0.0.0/0'; [ -n "$af_keepalive" ] || af_keepalive=25
    af_host="${af_expected%:*}"; af_port="${af_expected##*:}"
    af_auto="$("$UCI_BIN" -q get "network.${af_iface}.auto" 2>/dev/null || echo 1)"
    af_disabled="$("$UCI_BIN" -q get "network.${af_iface}.disabled" 2>/dev/null || echo 0)"
    af_generation="$("$UCI_BIN" -q get "network.${af_iface}.hmn_generation_id" 2>/dev/null || true)"
    af_role="$("$UCI_BIN" -q get "network.${af_iface}.hmn_role" 2>/dev/null || echo production_slot)"
    remove_iface_peers "$af_iface" || exit 1
    if ! "$UCI_BIN" -q get "network.${af_iface}" >/dev/null 2>&1; then "$UCI_BIN" set "network.${af_iface}=interface" || exit 1; fi
    "$UCI_BIN" -q delete "network.${af_iface}.addresses" 2>/dev/null || true
    "$UCI_BIN" -q delete "network.${af_iface}.dns" 2>/dev/null || true
    "$UCI_BIN" set "network.${af_iface}.proto=amneziawg" || exit 1
    "$UCI_BIN" set "network.${af_iface}.private_key=${af_private}" || exit 1
    "$UCI_BIN" set "network.${af_iface}.awg_jc=${af_jc}" || exit 1
    "$UCI_BIN" set "network.${af_iface}.awg_jmin=${af_jmin}" || exit 1
    "$UCI_BIN" set "network.${af_iface}.awg_jmax=${af_jmax}" || exit 1
    "$UCI_BIN" set "network.${af_iface}.awg_s1=${af_s1}" || exit 1
    "$UCI_BIN" set "network.${af_iface}.awg_s2=${af_s2}" || exit 1
    "$UCI_BIN" set "network.${af_iface}.awg_h1=${af_h1}" || exit 1
    "$UCI_BIN" set "network.${af_iface}.awg_h2=${af_h2}" || exit 1
    "$UCI_BIN" set "network.${af_iface}.awg_h3=${af_h3}" || exit 1
    "$UCI_BIN" set "network.${af_iface}.awg_h4=${af_h4}" || exit 1
    "$UCI_BIN" set "network.${af_iface}.auto=${af_auto}" || exit 1
    "$UCI_BIN" set "network.${af_iface}.disabled=${af_disabled}" || exit 1
    "$UCI_BIN" set "network.${af_iface}.delegate=0" || exit 1
    "$UCI_BIN" set "network.${af_iface}.peerdns=0" || exit 1
    "$UCI_BIN" set "network.${af_iface}.defaultroute=0" || exit 1
    af_oldifs="$IFS"; IFS=','
    for af_value in $af_address; do IFS="$af_oldifs"; af_value="$(trim "$af_value")"; [ -z "$af_value" ] || "$UCI_BIN" add_list "network.${af_iface}.addresses=${af_value}" || exit 1; IFS=','; done
    for af_value in $af_dns; do IFS="$af_oldifs"; af_value="$(trim "$af_value")"; [ -z "$af_value" ] || "$UCI_BIN" add_list "network.${af_iface}.dns=${af_value}" || exit 1; IFS=','; done
    IFS="$af_oldifs"
    af_peer="$("$UCI_BIN" add network "amneziawg_${af_iface}")" || exit 1
    "$UCI_BIN" set "network.${af_peer}.description=local-repair-${af_slot}" || exit 1
    "$UCI_BIN" set "network.${af_peer}.public_key=${af_public}" || exit 1
    af_oldifs="$IFS"; IFS=','
    for af_value in $af_allowed; do IFS="$af_oldifs"; af_value="$(trim "$af_value")"; [ -z "$af_value" ] || "$UCI_BIN" add_list "network.${af_peer}.allowed_ips=${af_value}" || exit 1; IFS=','; done
    IFS="$af_oldifs"
    "$UCI_BIN" set "network.${af_peer}.route_allowed_ips=0" || exit 1
    "$UCI_BIN" set "network.${af_peer}.persistent_keepalive=${af_keepalive}" || exit 1
    "$UCI_BIN" set "network.${af_peer}.endpoint_host=${af_host}" || exit 1
    "$UCI_BIN" set "network.${af_peer}.endpoint_port=${af_port}" || exit 1
    "$UCI_BIN" set "network.${af_iface}.hmn_role=${af_role}" || exit 1
    "$UCI_BIN" set "network.${af_iface}.hmn_source_config=${af_cfg}" || exit 1
    [ -z "$af_generation" ] || "$UCI_BIN" set "network.${af_iface}.hmn_generation_id=${af_generation}" || exit 1
    "$UCI_BIN" set "network.${af_iface}.hmn_loaded_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" || exit 1
    "$UCI_BIN" set "network.${af_iface}.hmn_endpoint=${af_expected}" || exit 1
    "$UCI_BIN" commit network || exit 1
)
binding_matches() (
    bm_iface="$1"; bm_cfg="$2"; bm_expected="$3"; bm_out="$4"; bm_ok=true
    : >"$bm_out"
    bm_check() { bm_name="$1"; bm_actual="$2"; bm_want="$3"; bm_match=false; [ "$bm_actual" = "$bm_want" ] && bm_match=true || bm_ok=false; printf '%s_match=%s\n' "$bm_name" "$bm_match" >>"$bm_out"; }
    bm_check private_key "$("$UCI_BIN" -q get "network.${bm_iface}.private_key" 2>/dev/null || true)" "$(config_value PrivateKey "$bm_cfg")"
    bm_check address "$(normalize_tokens "$("$UCI_BIN" -q get "network.${bm_iface}.addresses" 2>/dev/null || true)")" "$(normalize_tokens "$(config_value Address "$bm_cfg")")"
    for bm_key in jc jmin jmax s1 s2 h1 h2 h3 h4; do
        case "$bm_key" in jc) bm_conf=Jc;; jmin) bm_conf=Jmin;; jmax) bm_conf=Jmax;; s1) bm_conf=S1;; s2) bm_conf=S2;; h1) bm_conf=H1;; h2) bm_conf=H2;; h3) bm_conf=H3;; h4) bm_conf=H4;; esac
        bm_check "awg_${bm_key}" "$("$UCI_BIN" -q get "network.${bm_iface}.awg_${bm_key}" 2>/dev/null || true)" "$(config_value "$bm_conf" "$bm_cfg")"
    done
    bm_check public_key "$("$UCI_BIN" -q get "network.@amneziawg_${bm_iface}[0].public_key" 2>/dev/null || true)" "$(config_value PublicKey "$bm_cfg")"
    bm_check allowed_ips "$(normalize_tokens "$("$UCI_BIN" -q get "network.@amneziawg_${bm_iface}[0].allowed_ips" 2>/dev/null || true)")" "$(normalize_tokens "$(config_value AllowedIPs "$bm_cfg")")"
    bm_keepalive="$(config_value PersistentKeepalive "$bm_cfg")"; [ -n "$bm_keepalive" ] || bm_keepalive=25
    bm_check keepalive "$("$UCI_BIN" -q get "network.@amneziawg_${bm_iface}[0].persistent_keepalive" 2>/dev/null || true)" "$bm_keepalive"
    bm_check source_config "$("$UCI_BIN" -q get "network.${bm_iface}.hmn_source_config" 2>/dev/null || true)" "$bm_cfg"
    bm_check metadata_endpoint "$("$UCI_BIN" -q get "network.${bm_iface}.hmn_endpoint" 2>/dev/null || true)" "$bm_expected"
    bm_check peer_endpoint "$(peer_uci_endpoint_for_iface "$bm_iface")" "$bm_expected"
    printf 'binding_match=%s\n' "$bm_ok" >>"$bm_out"
    [ "$bm_ok" = true ]
)
strict_ping() (
    sp_iface="$1"; sp_targets="$2"; sp_count="$3"; sp_timeout="$4"; sp_oldifs="$IFS"; IFS=','
    for sp_target in $sp_targets; do
        IFS="$sp_oldifs"; [ -n "$sp_target" ] || continue
        sp_out="/tmp/router-egress-repair-ping.$$.out"; sp_err="/tmp/router-egress-repair-ping.$$.err"
        if ! "$PING_BIN" -I "$sp_iface" -c "$sp_count" -W "$sp_timeout" "$sp_target" >"$sp_out" 2>"$sp_err"; then rm -f "$sp_out" "$sp_err"; exit 1; fi
        sp_received="$(grep -Eo '[0-9]+ packets received' "$sp_out" 2>/dev/null | awk '{print $1}' | tail -1)"
        if [ -n "$sp_received" ] && [ "$sp_received" != "$sp_count" ]; then rm -f "$sp_out" "$sp_err"; exit 1; fi
        rm -f "$sp_out" "$sp_err"; IFS=','
    done
    IFS="$sp_oldifs"
)

write_result() {
    wr_file="$1"
    {
        echo '{'
        echo '  "schema": "router-egress-hmn-slot-replace-v4",'
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
        echo "  \"preferred_pool_scan_count\": ${preferred_pool_scan_count},"
        echo "  \"nonempty_pool_count\": ${nonempty_pool_count},"
        echo "  \"stale_pool_count\": ${stale_pool_count},"
        echo "  \"fresh_pool_count\": ${fresh_pool_count},"
        echo "  \"fresh_pool_without_candidate_count\": ${fresh_pool_without_candidate_count},"
        echo "  \"candidate_config_missing_count\": ${candidate_config_missing_count},"
        echo "  \"first_nonempty_pool\": \"$(json_escape "$first_nonempty_pool")\","
        echo "  \"first_nonempty_pool_age_sec\": ${first_nonempty_pool_age_sec},"
        echo "  \"pool_is_fresh\": ${pool_is_fresh},"
        echo "  \"available_candidate_count\": ${candidate_count},"
        echo "  \"candidate_endpoint\": \"$(json_escape "$candidate")\","
        echo "  \"candidate_config_path\": \"$(json_escape "$candidate_config")\","
        echo "  \"candidate_config_sha256\": \"$(json_escape "$candidate_config_sha256")\","
        echo "  \"candidate_attempts\": ${candidate_attempts},"
        echo "  \"decision\": \"$(json_escape "$decision")\","
        echo "  \"reason\": \"$(json_escape "$reason")\","
        echo "  \"apply_performed\": ${apply_performed},"
        echo "  \"apply_rc\": ${apply_rc},"
        echo "  \"post_strict_ok\": ${post_strict_ok},"
        echo "  \"binding_consistency_ok\": ${binding_consistency_ok},"
        echo "  \"metadata_endpoint_after_apply\": \"$(json_escape "$metadata_endpoint_after_apply")\","
        echo "  \"peer_uci_endpoint_after_apply\": \"$(json_escape "$peer_uci_endpoint_after_apply")\","
        echo "  \"live_endpoint_after_apply\": \"$(json_escape "$live_endpoint_after_apply")\","
        echo "  \"endpoint_consistency_ok\": ${endpoint_consistency_ok},"
        echo "  \"rollback_performed\": ${rollback_performed},"
        echo "  \"rollback_ok\": ${rollback_ok},"
        echo "  \"rollback_file\": \"$(json_escape "$rollback_file")\","
        echo '  "safety": {'
        echo "    \"requires_explicit_commit\": $([ "$REQUIRE_EXPLICIT_COMMIT" = 1 ] && echo true || echo false),"
        echo '    "slot_is_required": true,'
        echo '    "quarantine_is_enforced": true,'
        echo '    "failed_candidates_are_quarantined": true,'
        echo '    "full_candidate_config_binding_required": true,'
        echo '    "binding_failure_is_not_quarantined": true,'
        echo '    "all_candidates_failed_restores_original_network": true,'
        echo '    "no_vm100_change": true'
        echo '  }'
        echo '}'
    } >"$wr_file"
}

refuse_json() { printf '{"schema":"router-egress-hmn-slot-replace-v4","decision":"refuse","reason":"%s","apply_performed":false}\n' "$1"; exit 2; }
[ -n "$SLOT" ] || refuse_json slot_required
[ -r "$SLOTS_CONF" ] || refuse_json slots_conf_missing
[ -r "$STATE_HELPER" ] || refuse_json state_helper_missing
[ -r "$NETWORK_CONFIG" ] || refuse_json network_config_missing
. "$STATE_HELPER"
reg_init_state >/dev/null 2>&1 || refuse_json state_init_failed
operation_lock=''; operation_lock_owned=false
slot_line="$(grep -Ev '^[[:space:]]*(#|$)' "$SLOTS_CONF" | awk -v slot="$SLOT" '$1==slot {print; exit}')"
[ -n "$slot_line" ] || refuse_json slot_not_found
set -- $slot_line
slot_id="$1"; iface="$2"; table="$3"; mark="$4"; dscp="$5"; provider="$6"; adapter="$7"; health_targets="$8"; strict_count="$9"; shift 9; strict_timeout="$1"; enabled="$2"
[ "$provider" = hidemyname ] && [ "$adapter" = hmn_pool_replace ] || refuse_json wrong_provider_or_adapter
[ "$enabled" = 1 ] || refuse_json slot_disabled
is_uint "$table" || refuse_json invalid_table
is_uint "$strict_count" || strict_count=3; is_uint "$strict_timeout" || strict_timeout=2
is_uint "$LOCAL_REPAIR_CANDIDATE_RETRIES" || LOCAL_REPAIR_CANDIDATE_RETRIES=3; [ "$LOCAL_REPAIR_CANDIDATE_RETRIES" -gt 0 ] || LOCAL_REPAIR_CANDIDATE_RETRIES=1
now="$(date +%s)"; iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"; current_ep="$(current_endpoint_for_iface "$iface")"
used_file="/tmp/router-egress-hmn-used.$$"; pool_file="/tmp/router-egress-hmn-pool.$$"; candidate_file="/tmp/router-egress-hmn-candidates.$$"; result_file="${STATE_DIR}/hmn-pool-replace-last.json"
trap 'rm -f "$used_file" "$pool_file" "$candidate_file"; [ "$operation_lock_owned" = true ] && rmdir "$operation_lock" 2>/dev/null || true' EXIT HUP INT TERM
if [ "$MODE" = '--commit' ] && [ "${ROUTER_EGRESS_LOCAL_REPAIR_LOCK_HELD:-0}" != 1 ]; then
    operation_lock="${REG_LOCK_DIR}/local-repair.lock"; mkdir "$operation_lock" 2>/dev/null || refuse_json local_repair_lock_busy; operation_lock_owned=true
fi
: >"$used_file"
for active_iface in vpn1 vpn2 vpn3 vpn4 vpn5; do active_endpoint="$(current_endpoint_for_iface "$active_iface")"; [ -z "$active_endpoint" ] || printf '%s\n' "$active_endpoint" >>"$used_file"; done
sort -u "$used_file" -o "$used_file"
selected_pool=''; selected_pool_age_sec=999999999; selected_pool_endpoint_count=0; preferred_pool_scan_count=0; nonempty_pool_count=0; stale_pool_count=0; fresh_pool_count=0; fresh_pool_without_candidate_count=0; candidate_config_missing_count=0; first_nonempty_pool=''; first_nonempty_pool_age_sec=999999999; pool_is_fresh=false; candidate_count=0; candidate=''; candidate_config=''; candidate_config_sha256=''
for name in $PREFERRED_POOL_FILES; do
    preferred_pool_scan_count=$((preferred_pool_scan_count+1)); file="${HMN_CACHE_DIR}/${name}"; [ -s "$file" ] || continue
    count="$(endpoint_count "$file")"; [ "$count" -gt 0 ] || continue; nonempty_pool_count=$((nonempty_pool_count+1))
    mtime="$(reg_pool_mtime_epoch "$file")"; [ -n "$mtime" ] || mtime=0; age=$((now-mtime))
    if [ -z "$first_nonempty_pool" ]; then first_nonempty_pool="$file"; first_nonempty_pool_age_sec="$age"; fi
    if [ "$age" -lt 0 ] || [ "$age" -gt "$MAX_POOL_AGE_SEC" ]; then stale_pool_count=$((stale_pool_count+1)); continue; fi
    fresh_pool_count=$((fresh_pool_count+1)); extract_endpoints "$file" >"$pool_file"; : >"$candidate_file"
    while IFS= read -r endpoint; do
        [ -n "$endpoint" ] || continue; grep -Fx "$endpoint" "$used_file" >/dev/null 2>&1 && continue; reg_endpoint_quarantined_for_pool "$endpoint" "$file" && continue
        cfg="$(find_config_for_endpoint "$endpoint" "$file" 2>/dev/null || true)"
        if [ -z "$cfg" ] || ! config_binding_valid "$cfg" "$endpoint"; then candidate_config_missing_count=$((candidate_config_missing_count+1)); continue; fi
        printf '%s\t%s\n' "$endpoint" "$cfg" >>"$candidate_file"
    done <"$pool_file"
    candidate_count="$(wc -l <"$candidate_file" | tr -d ' ')"; candidate="$(awk -F '\t' 'NR==1{print $1}' "$candidate_file")"; candidate_config="$(awk -F '\t' 'NR==1{print $2}' "$candidate_file")"
    if [ "$candidate_count" -gt 0 ] && [ -n "$candidate" ] && [ -n "$candidate_config" ]; then selected_pool="$file"; selected_pool_age_sec="$age"; selected_pool_endpoint_count="$count"; pool_is_fresh=true; candidate_config_sha256="$("$SHA256_BIN" "$candidate_config" | awk '{print $1}')"; break; fi
    fresh_pool_without_candidate_count=$((fresh_pool_without_candidate_count+1)); candidate_count=0; candidate=''; candidate_config=''
done

decision=refuse; reason=unknown; apply_performed=false; apply_rc=0; post_strict_ok=false; binding_consistency_ok=false; metadata_endpoint_after_apply=''; peer_uci_endpoint_after_apply=''; live_endpoint_after_apply=''; endpoint_consistency_ok=false; apply_mechanism_failed=false; rollback_performed=false; rollback_ok=false; rollback_file=''; candidate_attempts=0
if [ -z "$selected_pool" ] && [ "$nonempty_pool_count" -eq 0 ]; then reason=no_pool_file
elif [ -z "$selected_pool" ] && [ "$fresh_pool_count" -eq 0 ]; then reason=stale_pool
elif [ -z "$selected_pool" ]; then reason=no_eligible_candidate_with_config
elif [ "$pool_is_fresh" != true ]; then reason=stale_pool
elif [ "$candidate_count" -eq 0 ] || [ -z "$candidate" ] || [ -z "$candidate_config" ]; then reason=no_eligible_candidate_with_config
elif [ "$MODE" = '--dry-run' ]; then decision=dry_run_ok; reason=dry_run_candidate_full_config_selected
elif [ "$MODE" = '--commit' ]; then
    valid_endpoint "$current_ep" || { reason=current_endpoint_missing_or_invalid; write_result "$result_file"; cat "$result_file"; exit 2; }
    expected="APPLY_${SLOT}_${iface}_${candidate}"
    if [ "$REQUIRE_EXPLICIT_COMMIT" = 1 ] && [ "$CONFIRM" != "$expected" ]; then reason=missing_or_wrong_confirm_token
    else
        backup_dir="${STATE_DIR}/backup-${SLOT}-$(date -u +%Y%m%d-%H%M%S)"; mkdir -p "$backup_dir" || { reason=backup_dir_create_failed; write_result "$result_file"; cat "$result_file"; exit 2; }
        cp -p "$NETWORK_CONFIG" "${backup_dir}/network.before" || { reason=network_backup_failed; write_result "$result_file"; cat "$result_file"; exit 2; }
        chmod 600 "${backup_dir}/network.before"; "$UCI_BIN" show network >"${backup_dir}/network.uci.before" 2>/dev/null || true; "$IP_BIN" route show table "$table" >"${backup_dir}/table.before" 2>/dev/null || true
        rollback_file="${backup_dir}/rollback-${SLOT}.sh"
        cat >"$rollback_file" <<EOF_ROLLBACK
#!/bin/sh
set -u
cp -p '${backup_dir}/network.before' '${NETWORK_CONFIG}'
'${IFDOWN_BIN}' '${iface}' >/dev/null 2>&1 || true
'${IFUP_BIN}' '${iface}' >/dev/null 2>&1 || true
'${SLEEP_BIN}' '${POST_APPLY_SLEEP_SEC}'
if [ -x '${SLOTS_APPLY}' ]; then '${SLOTS_APPLY}' start '${SLOT}' >/dev/null 2>&1 || true; fi
echo 'rollback_done=true'
EOF_ROLLBACK
        chmod 700 "$rollback_file"
        attempt_limit="$LOCAL_REPAIR_CANDIDATE_RETRIES"; [ "$candidate_count" -lt "$attempt_limit" ] && attempt_limit="$candidate_count"
        while IFS="$(printf '\t')" read -r attempt_candidate attempt_config; do
            [ "$candidate_attempts" -lt "$attempt_limit" ] || break; [ -n "$attempt_candidate" ] && [ -n "$attempt_config" ] || continue
            candidate_attempts=$((candidate_attempts+1)); candidate="$attempt_candidate"; candidate_config="$attempt_config"; candidate_config_sha256="$("$SHA256_BIN" "$candidate_config" | awk '{print $1}')"; apply_performed=true
            binding_evidence="${backup_dir}/binding-attempt-${candidate_attempts}.kv"
            apply_full_config_to_iface "$iface" "$SLOT" "$candidate_config" "$candidate"; apply_rc=$?
            if [ "$apply_rc" -eq 0 ]; then "$IFDOWN_BIN" "$iface" >/dev/null 2>&1 || true; "$IFUP_BIN" "$iface" >/dev/null 2>&1; apply_rc=$?; fi
            "$SLEEP_BIN" "$POST_APPLY_SLEEP_SEC"
            if [ "$apply_rc" -eq 0 ] && [ -x "$SLOTS_APPLY" ]; then "$SLOTS_APPLY" start "$SLOT" >/dev/null 2>&1; apply_rc=$?; fi
            binding_consistency_ok=false; binding_matches "$iface" "$candidate_config" "$candidate" "$binding_evidence" && binding_consistency_ok=true || true
            metadata_endpoint_after_apply="$("$UCI_BIN" -q get "network.${iface}.hmn_endpoint" 2>/dev/null || true)"; peer_uci_endpoint_after_apply="$(peer_uci_endpoint_for_iface "$iface")"; live_endpoint_after_apply="$(live_endpoint_for_iface "$iface")"; endpoint_consistency_ok=false
            if [ "$binding_consistency_ok" = true ] && [ "$metadata_endpoint_after_apply" = "$candidate" ] && [ "$peer_uci_endpoint_after_apply" = "$candidate" ] && [ "$live_endpoint_after_apply" = "$candidate" ]; then endpoint_consistency_ok=true; fi
            if [ "$apply_rc" -ne 0 ] || [ "$binding_consistency_ok" != true ] || [ "$endpoint_consistency_ok" != true ]; then apply_mechanism_failed=true; reason=candidate_full_config_not_applied; break; fi
            if "$IP_BIN" link show "$iface" >/dev/null 2>&1 && "$IP_BIN" route show table "$table" 2>/dev/null | grep -Eq "default[[:space:]].*dev[[:space:]]+${iface}([[:space:]]|$)" && strict_ping "$iface" "$health_targets" "$strict_count" "$strict_timeout"; then decision=commit_ok; reason=candidate_full_config_applied_live_verified_and_strict_ok; post_strict_ok=true; break; fi
            reg_quarantine_endpoint "$candidate" "$SLOT" "$iface" '' repair_candidate_failed "$selected_pool" STEP_050M07R20L_FULL_CANDIDATE_CONFIG_BINDING >/dev/null 2>&1 || true
        done <"$candidate_file"
        if [ "$decision" != commit_ok ]; then
            rollback_performed=true
            if "$rollback_file" >/dev/null 2>&1; then
                restored="$(current_endpoint_for_iface "$iface")"; restored_peer="$(peer_uci_endpoint_for_iface "$iface")"; restored_live="$(live_endpoint_for_iface "$iface")"
                [ "$restored" = "$current_ep" ] && [ "$restored_peer" = "$current_ep" ] && [ "$restored_live" = "$current_ep" ] && cmp -s "$NETWORK_CONFIG" "${backup_dir}/network.before" && rollback_ok=true
            fi
            decision=commit_failed; post_strict_ok=false; binding_consistency_ok=false; endpoint_consistency_ok=false
            if [ "$apply_mechanism_failed" = true ]; then [ "$rollback_ok" = true ] && reason=candidate_full_config_not_applied_original_network_restored || reason=candidate_full_config_not_applied_original_network_restore_failed
            elif [ "$rollback_ok" = true ]; then reason=all_candidates_failed_original_network_restored
            else reason=all_candidates_failed_original_network_restore_failed; fi
        fi
    fi
else reason=unsupported_mode
fi
write_result "$result_file"; cat "$result_file"
printf '%s action=hmn_slot_replace slot=%s iface=%s mode=%s decision=%s reason=%s candidate=%s config_sha=%s attempts=%s rollback=%s\n' "$iso" "$SLOT" "$iface" "$MODE" "$decision" "$reason" "$candidate" "$candidate_config_sha256" "$candidate_attempts" "$rollback_performed" >>"$LOG" 2>/dev/null || true
case "$decision" in dry_run_ok|commit_ok) exit 0;; commit_failed) exit 3;; *) exit 2;; esac
