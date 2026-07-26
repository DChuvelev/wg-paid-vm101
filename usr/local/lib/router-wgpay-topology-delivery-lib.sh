#!/bin/sh
# shellcheck shell=sh

router_topology_delivery_kv_get() {
    rtd_kv_key="$1"
    rtd_kv_file="$2"
    [ -f "$rtd_kv_file" ] || return 0
    awk -F= -v key="$rtd_kv_key" '$1==key {print substr($0,index($0,"=")+1)}' "$rtd_kv_file" | tail -n 1
}

router_topology_delivery_atomic_write() {
    rtd_aw_src="$1"
    rtd_aw_dst="$2"
    rtd_aw_mode="${3:-600}"
    rtd_aw_dir="$(dirname "$rtd_aw_dst")"
    mkdir -p "$rtd_aw_dir" || return 1
    chmod 700 "$rtd_aw_dir" 2>/dev/null || true
    rtd_aw_tmp="${rtd_aw_dst}.tmp.$$"
    cp "$rtd_aw_src" "$rtd_aw_tmp" || return 1
    chmod "$rtd_aw_mode" "$rtd_aw_tmp" || { rm -f "$rtd_aw_tmp"; return 1; }
    mv "$rtd_aw_tmp" "$rtd_aw_dst"
}

router_topology_delivery_csv_validate_subsequence() {
    rtd_csv_value="$1"
    rtd_csv_canonical="$2"
    rtd_csv_allow_empty="$3"
    [ -n "$rtd_csv_value" ] || [ "$rtd_csv_allow_empty" = true ] || return 1
    [ -n "$rtd_csv_value" ] || return 0
    printf '%s\n' "$rtd_csv_value" | awk -F, -v canonical="$rtd_csv_canonical" '
        BEGIN { n=split(canonical,c,","); for(i=1;i<=n;i++) idx[c[i]]=i }
        {
            last=0
            for(i=1;i<=NF;i++) {
                if($i=="" || !($i in idx) || seen[$i] || idx[$i] <= last) exit 1
                seen[$i]=1; last=idx[$i]
            }
        }
    '
}

router_topology_delivery_sets_complete_disjoint() {
    rtd_set_a="$1"
    rtd_set_b="$2"
    rtd_set_canonical="$3"
    printf '%s\n' "$rtd_set_canonical" | awk -F, -v a="$rtd_set_a" -v b="$rtd_set_b" '
        function has(csv,item, x,n,i) {
            if(csv=="") return 0
            n=split(csv,x,",")
            for(i=1;i<=n;i++) if(x[i]==item) return 1
            return 0
        }
        {
            for(i=1;i<=NF;i++) if(has(a,$i)+has(b,$i)!=1) exit 1
        }
    '
}

router_topology_delivery_validate_alignment() {
    rtd_align_hs="$1"
    rtd_align_es="$2"
    rtd_align_hc="$3"
    rtd_align_ec="$4"
    printf '%s\n' 'egress1=cs4' 'egress2=cs5' 'egress3=cs1' 'egress4=cs2' 'egress5=cs3' | awk -F= -v hs="$rtd_align_hs" -v es="$rtd_align_es" -v hc="$rtd_align_hc" -v ec="$rtd_align_ec" '
        function has(csv,item, x,n,i) {
            if(csv=="") return 0
            n=split(csv,x,",")
            for(i=1;i<=n;i++) if(x[i]==item) return 1
            return 0
        }
        {
            if(has(hs,$1) != has(hc,$2)) exit 1
            if(has(es,$1) != has(ec,$2)) exit 1
        }
    '
}

router_topology_delivery_generation_next() {
    rtd_gen_current="$1"
    printf '%s' "$rtd_gen_current" | grep -Eq '^[0-9]{12}$' || return 1
    [ "$rtd_gen_current" != 999999999999 ] || return 1
    awk -v n="$rtd_gen_current" 'BEGIN { printf "%012.0f\n", n + 1 }'
}

router_topology_delivery_sanitize_detail() {
    printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9_.:,/@+-' | cut -c1-160
}

router_topology_delivery_validate_ack() {
    rtd_ack_file="$1"
    rtd_ack_pending_file="$2"
    rtd_ack_expected_schema="$3"
    [ -f "$rtd_ack_file" ] && [ -f "$rtd_ack_pending_file" ] || return 1
    rtd_ack_schema="$(router_topology_delivery_kv_get schema "$rtd_ack_file")"
    rtd_ack_result="$(router_topology_delivery_kv_get result "$rtd_ack_file")"
    rtd_ack_generation="$(router_topology_delivery_kv_get accepted_generation "$rtd_ack_file")"
    rtd_ack_applied="$(router_topology_delivery_kv_get applied_generation "$rtd_ack_file")"
    rtd_ack_payload="$(router_topology_delivery_kv_get payload_sha256 "$rtd_ack_file")"
    rtd_ack_expected_generation="$(router_topology_delivery_kv_get generation "$rtd_ack_pending_file")"
    rtd_ack_expected_payload="$(router_topology_delivery_kv_get confirm_sha256 "$rtd_ack_pending_file")"
    [ "$rtd_ack_schema" = "$rtd_ack_expected_schema" ] || return 2
    case "$rtd_ack_result" in PASS|DIRECT_REQUIRED) ;; *) return 3 ;; esac
    [ "$rtd_ack_generation" = "$rtd_ack_expected_generation" ] || return 4
    [ -z "$rtd_ack_applied" ] || [ "$rtd_ack_applied" = "$rtd_ack_expected_generation" ] || return 5
    [ "$rtd_ack_payload" = "$rtd_ack_expected_payload" ] || return 6
    return 0
}
