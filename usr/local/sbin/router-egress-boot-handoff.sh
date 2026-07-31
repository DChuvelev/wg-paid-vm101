#!/bin/sh
# R20Q-U-B1 production boot/handoff owner for VM101.
set -u
umask 077
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

CONF="${ROUTER_EGRESS_BOOT_HANDOFF_CONF:-/etc/router-egress-boot-handoff.conf}"
[ -r "$CONF" ] || { echo RESULT=STOP_R20QUB_BOOT_CONFIG_MISSING; exit 20; }
. "$CONF"

ENABLED="${BOOT_HANDOFF_ENABLED:-0}"
LOCK_DIR="${BOOT_HANDOFF_LOCK_DIR:-/var/run/router-egress-boot-handoff.lock}"
READY_FILE="${BOOT_HANDOFF_READY_FILE:-/var/run/router-egress-boot-handoff.ready}"
LOG="${BOOT_HANDOFF_LOG:-/var/log/router-egress-boot-handoff.log}"
WAIT_TIMEOUT="${BOOT_HANDOFF_WAIT_TIMEOUT_SEC:-120}"
WAIT_POLL="${BOOT_HANDOFF_WAIT_POLL_SEC:-2}"
NETWORK_CONFIG="${BOOT_HANDOFF_NETWORK_CONFIG:-/etc/config/network}"
STATE_HELPER="${BOOT_HANDOFF_RECOVERY_STATE_HELPER:-/usr/local/lib/router-egress-recovery-state.sh}"
GEN_CONF="${BOOT_HANDOFF_GENERATION_CONFIG:-/etc/router-egress-generation.conf}"
GEN_VALIDATOR="${BOOT_HANDOFF_GENERATION_VALIDATOR:-/usr/local/sbin/router-egress-generation-validate}"
SLOTS_APPLY="${BOOT_HANDOFF_SLOTS_APPLY:-/usr/local/sbin/router-egress-slots-apply.sh}"
SLOTS_STATUS="${BOOT_HANDOFF_SLOTS_STATUS:-/usr/local/sbin/router-egress-slots-status.sh}"
TOPOLOGY_OUTBOX="${BOOT_HANDOFF_TOPOLOGY_OUTBOX:-/usr/local/sbin/router-wgpay-topology-outbox.sh}"
PROVIDER_CONF="${BOOT_HANDOFF_PROVIDER_DIRECT_CONFIG:-/etc/router-egress-provider-direct.conf}"
BOOTSTRAP_CONF="${BOOT_HANDOFF_BOOTSTRAP_CONFIG:-/etc/router-egress-zero-healthy-bootstrap.conf}"
INITD_DIR="${BOOT_HANDOFF_INITD_DIR:-/etc/init.d}"
SERVICE_ORDER="${BOOT_HANDOFF_SERVICE_ORDER:-router-wgpay-topology-delivery router-egress-zero-healthy-bootstrap router-egress-health-repair router-egress-full-pool-refresh-retry}"
PROVIDER_SERVICE="${BOOT_HANDOFF_PROVIDER_DIRECT_SERVICE:-router-egress-provider-direct}"
VPN_INTERFACES="${BOOT_HANDOFF_VPN_INTERFACES:-vpn1 vpn2 vpn3 vpn4 vpn5}"

UCI_BIN="${ROUTER_EGRESS_UCI_BIN:-uci}"
IP_BIN="${ROUTER_EGRESS_IP_BIN:-ip}"
AWG_BIN="${ROUTER_EGRESS_AWG_BIN:-amneziawg}"
IFUP_BIN="${ROUTER_EGRESS_IFUP_BIN:-ifup}"
SHA256SUM_BIN="${ROUTER_EGRESS_SHA256SUM_BIN:-sha256sum}"
DATE_BIN="${ROUTER_EGRESS_DATE_BIN:-date}"
SLEEP_BIN="${ROUTER_EGRESS_SLEEP_BIN:-sleep}"
READLINK_BIN="${ROUTER_EGRESS_READLINK_BIN:-readlink}"

case "$WAIT_TIMEOUT" in ''|*[!0-9]*) echo RESULT=STOP_R20QUB_BOOT_WAIT_TIMEOUT_INVALID; exit 20;; esac
case "$WAIT_POLL" in ''|*[!0-9]*) echo RESULT=STOP_R20QUB_BOOT_WAIT_POLL_INVALID; exit 20;; esac
[ "$WAIT_TIMEOUT" -gt 0 ] && [ "$WAIT_POLL" -gt 0 ] || { echo RESULT=STOP_R20QUB_BOOT_WAIT_RANGE_INVALID; exit 20; }

kv_get() {
    key="$1" file="$2"
    sed -n "s/^${key}=//p" "$file" 2>/dev/null | tail -n1
}

valid_id() {
    value="$1"
    [ -n "$value" ] || return 1
    [ "${#value}" -le 64 ] || return 1
    printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

log_event() {
    mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
    printf '%s %s\n' "$($DATE_BIN -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || $DATE_BIN)" "$*" >> "$LOG" 2>/dev/null || true
}

lock_token() {
    pid="$1"
    [ -r "/proc/$pid/stat" ] || return 1
    awk '{print $22}' "/proc/$pid/stat" 2>/dev/null
}

lock_acquire() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        token="$(lock_token $$ 2>/dev/null || echo unknown)"
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        printf '%s\n' "$token" > "$LOCK_DIR/token"
        return 0
    fi
    old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    old_token="$(cat "$LOCK_DIR/token" 2>/dev/null || true)"
    live_token=""
    case "$old_pid" in ''|*[!0-9]*) ;; *) live_token="$(lock_token "$old_pid" 2>/dev/null || true)";; esac
    if [ -z "$live_token" ] || [ -z "$old_token" ] || [ "$live_token" != "$old_token" ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || return 1
        mkdir "$LOCK_DIR" 2>/dev/null || return 1
        token="$(lock_token $$ 2>/dev/null || echo unknown)"
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        printf '%s\n' "$token" > "$LOCK_DIR/token"
        echo STALE_LOCK_RECOVERED=true
        return 0
    fi
    return 1
}

lock_release() {
    [ -d "$LOCK_DIR" ] || return 0
    owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    [ "$owner" = "$$" ] || return 0
    rm -rf "$LOCK_DIR" 2>/dev/null || true
}

uci_get() {
    "$UCI_BIN" -q get "$1" 2>/dev/null
}

csv_from_uci_list() {
    printf '%s\n' "$1" | awk '{$1=$1; gsub(/[[:space:]]+/,","); print}'
}

peer_section() {
    iface="$1"
    "$UCI_BIN" -q show network 2>/dev/null |
        sed -n "s/^\(network\.@amneziawg_${iface}\[[0-9][0-9]*\]\)=amneziawg_${iface}$/\1/p" |
        head -n1
}

current_endpoint() {
    iface="$1"
    configured="$(uci_get "network.${iface}.hmn_endpoint" 2>/dev/null || true)"
    peer="$(peer_section "$iface")"
    [ -n "$peer" ] || return 1
    host="$(uci_get "${peer}.endpoint_host" 2>/dev/null || true)"
    port="$(uci_get "${peer}.endpoint_port" 2>/dev/null || true)"
    [ -n "$host" ] && [ -n "$port" ] || return 1
    endpoint="${host}:${port}"
    [ -z "$configured" ] || [ "$configured" = "$endpoint" ] || return 1
    printf '%s\n' "$endpoint"
}

write_config_from_uci() {
    iface="$1" output="$2"
    peer="$(peer_section "$iface")"
    [ -n "$peer" ] || return 1
    private_key="$(uci_get "network.${iface}.private_key")" || return 1
    addresses="$(uci_get "network.${iface}.addresses")" || return 1
    dns="$(uci_get "network.${iface}.dns" 2>/dev/null || true)"
    jc="$(uci_get "network.${iface}.awg_jc" 2>/dev/null || true)"
    jmin="$(uci_get "network.${iface}.awg_jmin" 2>/dev/null || true)"
    jmax="$(uci_get "network.${iface}.awg_jmax" 2>/dev/null || true)"
    s1="$(uci_get "network.${iface}.awg_s1" 2>/dev/null || true)"
    s2="$(uci_get "network.${iface}.awg_s2" 2>/dev/null || true)"
    h1="$(uci_get "network.${iface}.awg_h1" 2>/dev/null || true)"
    h2="$(uci_get "network.${iface}.awg_h2" 2>/dev/null || true)"
    h3="$(uci_get "network.${iface}.awg_h3" 2>/dev/null || true)"
    h4="$(uci_get "network.${iface}.awg_h4" 2>/dev/null || true)"
    public_key="$(uci_get "${peer}.public_key")" || return 1
    allowed_ips="$(uci_get "${peer}.allowed_ips" 2>/dev/null || echo '0.0.0.0/0')"
    keepalive="$(uci_get "${peer}.persistent_keepalive" 2>/dev/null || echo 25)"
    endpoint="$(current_endpoint "$iface")" || return 1
    [ -n "$private_key" ] && [ -n "$addresses" ] && [ -n "$public_key" ] || return 1
    addresses="$(csv_from_uci_list "$addresses")"
    dns="$(csv_from_uci_list "$dns")"
    allowed_ips="$(csv_from_uci_list "$allowed_ips")"
    cat > "$output" <<CFG
[Interface]
PrivateKey = $private_key
Address = $addresses
DNS = $dns
Jc = $jc
Jmin = $jmin
Jmax = $jmax
S1 = $s1
S2 = $s2
H1 = $h1
H2 = $h2
H3 = $h3
H4 = $h4

[Peer]
PublicKey = $public_key
AllowedIPs = $allowed_ips
Endpoint = $endpoint
PersistentKeepalive = $keepalive
CFG
    chmod 600 "$output" 2>/dev/null || true
}

network_generation_matches() {
    generation_id="$1"
    n=1
    while [ "$n" -le 5 ]; do
        iface="vpn$n"
        [ "$(uci_get "network.${iface}.hmn_generation_id" 2>/dev/null || true)" = "$generation_id" ] || return 1
        current_endpoint "$iface" >/dev/null || return 1
        n=$((n + 1))
    done
}

anchor_matches_current() {
    dir="$1" generation_id="$2"
    [ -d "$dir" ] || return 1
    [ "$(kv_get generation_id "$dir/metadata.kv")" = "$generation_id" ] || return 1
    "$GEN_VALIDATOR" --generation-dir "$dir" --now-epoch "$($DATE_BIN +%s)" >/dev/null 2>&1 || return 1
    n=1
    while [ "$n" -le 5 ]; do
        slot="egress$n" iface="vpn$n"
        want="$(current_endpoint "$iface")" || return 1
        got="$(sed -n 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*//p' "$dir/configs/${slot}.conf" | head -n1 | tr -d '\r')"
        [ "$got" = "$want" ] || return 1
        n=$((n + 1))
    done
}

reconstruct_anchor() {
    generation_id="$1"
    . "$GEN_CONF"
    final="$GENERATION_STAGING_DIR/$generation_id"
    now="$($DATE_BIN +%s)"
    mkdir -p "$GENERATION_STAGING_DIR" "$GENERATION_REJECTED_DIR" || return 1
    if anchor_matches_current "$final" "$generation_id"; then
        ln -sfn "$final" "${GENERATION_ACTIVE_LINK}.tmp.$$" || return 1
        mv -f "${GENERATION_ACTIVE_LINK}.tmp.$$" "$GENERATION_ACTIVE_LINK" || return 1
        echo RUNTIME_ANCHOR_REUSED=true
        echo RUNTIME_ANCHOR_DIR="$final"
        return 0
    fi
    tmp_parent="${GENERATION_STAGING_DIR}/.boot-reconstruct.$$"
    tmp="$tmp_parent/$generation_id"
    rm -rf "$tmp_parent"
    mkdir -p "$tmp/configs" || return 1
    chmod 700 "$tmp_parent" "$tmp" "$tmp/configs" 2>/dev/null || true
    printf 'rank\tavg_ms\tfile\tendpoint\tloss\tconfig_path\n' > "$tmp/source-pool.tsv"
    printf 'iface\tendpoint\n' > "$tmp/active-endpoints.tsv"
    printf 'ts_epoch\tts_utc\tegress\tiface\tendpoint\treplacement\treason\tpool_path\tpool_mtime_epoch\tsource_step\n' > "$tmp/quarantine-snapshot.tsv"
    printf 'slot\tiface\ttable\tendpoint\tconfig_path\tconfig_sha256\ttested_at_epoch\ttest_result\tsource_rank\n' > "$tmp/candidates.tsv"
    n=1
    while [ "$n" -le 5 ]; do
        slot="egress$n" iface="vpn$n" table=$((200 + n)) cfg="configs/${slot}.conf"
        write_config_from_uci "$iface" "$tmp/$cfg" || { rm -rf "$tmp_parent"; return 1; }
        endpoint="$(current_endpoint "$iface")" || { rm -rf "$tmp_parent"; return 1; }
        cfg_sha="$($SHA256SUM_BIN "$tmp/$cfg" | awk '{print $1}')"
        printf '%s\t0\tboot-current-%s\t%s\t0\t%s\n' "$n" "$iface" "$endpoint" "$cfg" >> "$tmp/source-pool.tsv"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tPASS\t%s\n' "$slot" "$iface" "$table" "$endpoint" "$cfg" "$cfg_sha" "$now" "$n" >> "$tmp/candidates.tsv"
        n=$((n + 1))
    done
    source_sha="$($SHA256SUM_BIN "$tmp/source-pool.tsv" | awk '{print $1}')"
    cat > "$tmp/metadata.kv" <<META
schema=$GENERATION_SCHEMA
generation_id=$generation_id
status=STAGED
mode=SHADOW
slot_count=5
created_at_epoch=$now
source_pool_sha256=$source_sha
activation_allowed=false
boot_reconstructed=true
boot_source=current_uci_network
META
    (
        cd "$tmp" || exit 1
        $SHA256SUM_BIN metadata.kv candidates.tsv source-pool.tsv active-endpoints.tsv quarantine-snapshot.tsv \
            configs/egress1.conf configs/egress2.conf configs/egress3.conf configs/egress4.conf configs/egress5.conf > manifest.sha256
    ) || { rm -rf "$tmp_parent"; return 1; }
    chmod 600 "$tmp"/*.tsv "$tmp"/*.kv "$tmp"/*.sha256 "$tmp"/configs/*.conf 2>/dev/null || true
    "$GEN_VALIDATOR" --generation-dir "$tmp" --now-epoch "$now" >/tmp/router-egress-boot-anchor-validator.$$.log 2>&1 || {
        cat /tmp/router-egress-boot-anchor-validator.$$.log >&2
        rm -f /tmp/router-egress-boot-anchor-validator.$$.log
        rm -rf "$tmp_parent"
        return 1
    }
    rm -f /tmp/router-egress-boot-anchor-validator.$$.log
    if [ -e "$final" ] || [ -L "$final" ]; then
        rejected="$GENERATION_REJECTED_DIR/${generation_id}.boot-replaced.${now}"
        rm -rf "$rejected"
        mv "$final" "$rejected" || { rm -rf "$tmp_parent"; return 1; }
    fi
    mv "$tmp" "$final" || { rm -rf "$tmp_parent"; return 1; }
    rmdir "$tmp_parent" 2>/dev/null || true
    ln -sfn "$final" "${GENERATION_ACTIVE_LINK}.tmp.$$" || return 1
    mv -f "${GENERATION_ACTIVE_LINK}.tmp.$$" "$GENERATION_ACTIVE_LINK" || return 1
    echo RUNTIME_ANCHOR_CREATED=true
    echo RUNTIME_ANCHOR_DIR="$final"
}

link_ready() {
    iface="$1"
    "$IP_BIN" link show dev "$iface" >/dev/null 2>&1 || return 1
    endpoint="$($AWG_BIN show "$iface" endpoints 2>/dev/null | awk 'NF>=2 {print $NF; exit}')"
    [ -n "$endpoint" ] && [ "$endpoint" != '(none)' ]
}

all_links_ready() {
    for iface in $VPN_INTERFACES; do link_ready "$iface" || return 1; done
}

slot_rules_ready() {
    n=1
    while [ "$n" -le 5 ]; do
        iface="vpn$n" table=$((200 + n))
        case "$n" in 1) mark=0x201;; 2) mark=0x202;; 3) mark=0x203;; 4) mark=0x204;; 5) mark=0x205;; esac
        "$IP_BIN" route show table "$table" 2>/dev/null | grep -Eq "default[[:space:]].*dev[[:space:]]+$iface" || return 1
        "$IP_BIN" rule show 2>/dev/null | grep -E "fwmark $mark.*lookup $table|fwmark $mark/0xffffffff.*lookup $table" >/dev/null || return 1
        n=$((n + 1))
    done
}

provider_disabled_contract() {
    [ -r "$PROVIDER_CONF" ] && [ "$(kv_get PROVIDER_DIRECT_ENABLED "$PROVIDER_CONF")" = 0 ] || return 1
    [ -r "$BOOTSTRAP_CONF" ] && [ "$(kv_get BOOTSTRAP_CONTROLLER_PROVIDER_DIRECT_ENABLED "$BOOTSTRAP_CONF")" = 0 ] || return 1
}

ready_marker_valid() {
    generation_id="$1"
    [ -s "$READY_FILE" ] || return 1
    [ "$(kv_get generation_id "$READY_FILE")" = "$generation_id" ] || return 1
    network_sha="$($SHA256SUM_BIN "$NETWORK_CONFIG" | awk '{print $1}')"
    [ "$(kv_get network_sha256 "$READY_FILE")" = "$network_sha" ] || return 1
    . "$GEN_CONF"
    active_real="$($READLINK_BIN -f "$GENERATION_ACTIVE_LINK" 2>/dev/null || true)"
    [ -n "$active_real" ] && [ "$(basename "$active_real")" = "$generation_id" ] || return 1
    anchor_matches_current "$active_real" "$generation_id" || return 1
    all_links_ready || return 1
    slot_rules_ready || return 1
    provider_disabled_contract || return 1
}

start_services() {
    for service in $SERVICE_ORDER; do
        [ -x "$INITD_DIR/$service" ] || return 1
        "$INITD_DIR/$service" start || return 1
        echo SERVICE_STARTED="$service"
    done
}

write_ready() {
    generation_id="$1"
    tmp="${READY_FILE}.tmp.$$"
    network_sha="$($SHA256SUM_BIN "$NETWORK_CONFIG" | awk '{print $1}')"
    mkdir -p "$(dirname "$READY_FILE")" || return 1
    {
        echo schema=router-egress-boot-handoff-ready-v1
        echo generation_id="$generation_id"
        echo network_sha256="$network_sha"
        echo completed_at_epoch="$($DATE_BIN +%s)"
        echo provider_direct_policy=disabled_until_proven
        echo service_order="$SERVICE_ORDER"
    } > "$tmp" || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$READY_FILE"
}

status_emit() {
    echo schema=router-egress-boot-handoff-status-v1
    echo enabled="$ENABLED"
    echo lock_present="$([ -d "$LOCK_DIR" ] && echo true || echo false)"
    echo ready_present="$([ -s "$READY_FILE" ] && echo true || echo false)"
    [ -s "$READY_FILE" ] && cat "$READY_FILE"
    if [ -r "$STATE_HELPER" ]; then
        . "$STATE_HELPER"
        reg_init_state >/dev/null 2>&1 || true
        echo recovery_mode="$(reg_get_state mode UNKNOWN 2>/dev/null || echo UNKNOWN)"
        echo active_generation_id="$(reg_get_state active_generation_id '' 2>/dev/null || true)"
    fi
}

mode="${1:---boot}"
case "$mode" in
    --status) status_emit; exit 0;;
    --stop)
        rm -f "$READY_FILE"
        for service in $SERVICE_ORDER; do [ -x "$INITD_DIR/$service" ] && "$INITD_DIR/$service" stop >/dev/null 2>&1 || true; done
        [ -x "$SLOTS_APPLY" ] && "$SLOTS_APPLY" stop >/dev/null 2>&1 || true
        echo RESULT=PASS_R20QUB_BOOT_HANDOFF_STOPPED
        exit 0
        ;;
    --boot|--run-once) ;;
    *) echo 'Usage: router-egress-boot-handoff.sh --boot|--run-once|--status|--stop' >&2; exit 64;;
esac

[ "$ENABLED" = 1 ] || { echo RESULT=NOOP_R20QUB_BOOT_HANDOFF_DISABLED; exit 0; }
for required in "$NETWORK_CONFIG" "$STATE_HELPER" "$GEN_CONF" "$GEN_VALIDATOR" "$SLOTS_APPLY" "$TOPOLOGY_OUTBOX" "$PROVIDER_CONF" "$BOOTSTRAP_CONF"; do
    [ -e "$required" ] || { echo RESULT=STOP_R20QUB_BOOT_REQUIRED_PATH_MISSING; echo REQUIRED_PATH="$required"; exit 20; }
done
provider_disabled_contract || { echo RESULT=STOP_R20QUB_PROVIDER_DIRECT_POLICY_NOT_DISABLED; exit 20; }
lock_acquire || { echo RESULT=NOOP_R20QUB_BOOT_HANDOFF_LOCKED; exit 0; }
trap 'lock_release >/dev/null 2>&1 || true' EXIT HUP INT TERM

. "$STATE_HELPER"
reg_init_state || { echo RESULT=STOP_R20QUB_BOOT_STATE_INIT_FAILED; exit 21; }
active_id="$(reg_get_state active_generation_id '' 2>/dev/null || true)"
valid_id "$active_id" || { echo RESULT=STOP_R20QUB_BOOT_ACTIVE_GENERATION_ID_INVALID; echo ACTIVE_GENERATION_ID="$active_id"; exit 21; }
network_generation_matches "$active_id" || { echo RESULT=STOP_R20QUB_BOOT_NETWORK_GENERATION_MISMATCH; echo ACTIVE_GENERATION_ID="$active_id"; exit 21; }

if ready_marker_valid "$active_id"; then
    echo RESULT=NOOP_R20QUB_BOOT_HANDOFF_ALREADY_READY
    echo ACTIVE_GENERATION_ID="$active_id"
    echo PROVIDER_DIRECT_POLICY=disabled_until_proven
    exit 0
fi
rm -f "$READY_FILE"

reconstruct_anchor "$active_id" || { echo RESULT=STOP_R20QUB_BOOT_ANCHOR_RECONSTRUCTION_FAILED; exit 22; }

for iface in $VPN_INTERFACES; do
    "$IFUP_BIN" "$iface" || { echo RESULT=STOP_R20QUB_BOOT_IFUP_FAILED; echo INTERFACE="$iface"; exit 23; }
    echo IFUP_COMPLETED="$iface"
done

start_epoch="$($DATE_BIN +%s)"
while ! all_links_ready; do
    now="$($DATE_BIN +%s)"
    [ $((now - start_epoch)) -lt "$WAIT_TIMEOUT" ] || {
        echo RESULT=STOP_R20QUB_BOOT_LINK_WAIT_TIMEOUT
        for iface in $VPN_INTERFACES; do echo "LINK_READY_${iface}=$(link_ready "$iface" && echo true || echo false)"; done
        exit 24
    }
    "$SLEEP_BIN" "$WAIT_POLL"
done
echo ALL_REQUIRED_LINKS_READY=true

"$SLOTS_APPLY" start || { echo RESULT=STOP_R20QUB_BOOT_ROUTE_APPLY_FAILED; exit 25; }
slot_rules_ready || { echo RESULT=STOP_R20QUB_BOOT_ROUTE_RULE_VERIFY_FAILED; exit 25; }
echo ROUTES_APPLIED_AFTER_LINKS=true

if "$TOPOLOGY_OUTBOX" --run-once; then outbox_rc=0; else outbox_rc=$?; fi
case "$outbox_rc" in 0|69|75) ;; *) echo RESULT=STOP_R20QUB_BOOT_TOPOLOGY_REPLAY_FAILED; echo TOPOLOGY_OUTBOX_RC="$outbox_rc"; exit 26;; esac
echo TOPOLOGY_REPLAY_ATTEMPTED=true
echo TOPOLOGY_OUTBOX_RC="$outbox_rc"

[ -x "$INITD_DIR/$PROVIDER_SERVICE" ] && "$INITD_DIR/$PROVIDER_SERVICE" stop >/dev/null 2>&1 || true
start_services || { echo RESULT=STOP_R20QUB_BOOT_SERVICE_START_FAILED; exit 27; }
write_ready "$active_id" || { echo RESULT=STOP_R20QUB_BOOT_READY_WRITE_FAILED; exit 28; }
log_event "result=PASS active_generation_id=$active_id provider_direct=disabled service_order=$(printf '%s' "$SERVICE_ORDER" | tr ' ' ',')"

echo RESULT=PASS_R20QUB_BOOT_HANDOFF
 echo ACTIVE_GENERATION_ID="$active_id"
echo RUNTIME_ANCHOR_READY=true
echo FIVE_VPN_LINKS_READY=true
echo ROUTE_TABLES_READY=true
echo TOPOLOGY_REPLAY_ATTEMPTED=true
echo PROVIDER_DIRECT_POLICY=disabled_until_proven
echo RECOVERY_SERVICE_ORDER="$SERVICE_ORDER"
