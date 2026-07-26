#!/bin/sh
# shellcheck shell=sh

rwf_kv_get() {
    rwf_kv_key="$1"
    rwf_kv_file="$2"
    [ -f "$rwf_kv_file" ] || return 0
    awk -F= -v key="$rwf_kv_key" '$1==key {print substr($0,index($0,"=")+1)}' "$rwf_kv_file" | tail -n 1
}

rwf_sanitize() {
    printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9_.:,/@+-' | cut -c1-160
}

rwf_csv_contains() {
    rwf_csv_list="$1"
    rwf_csv_item="$2"
    [ -n "$rwf_csv_list" ] || return 1
    printf '%s\n' "$rwf_csv_list" | awk -F, -v item="$rwf_csv_item" '{for(i=1;i<=NF;i++) if($i==item) found=1} END{exit found?0:1}'
}

rwf_csv_validate_subsequence() {
    rwf_csv_value="$1"
    rwf_csv_canonical="$2"
    rwf_csv_allow_empty="$3"
    [ -n "$rwf_csv_value" ] || [ "$rwf_csv_allow_empty" = true ] || return 1
    [ -n "$rwf_csv_value" ] || return 0
    printf '%s\n' "$rwf_csv_value" | awk -F, -v canonical="$rwf_csv_canonical" '
        BEGIN {n=split(canonical,c,","); for(i=1;i<=n;i++) idx[c[i]]=i}
        {
            last=0
            for(i=1;i<=NF;i++) {
                if($i=="" || !($i in idx) || seen[$i] || idx[$i] <= last) exit 1
                seen[$i]=1; last=idx[$i]
            }
        }
    '
}

rwf_sets_complete_disjoint() {
    rwf_set_a="$1"
    rwf_set_b="$2"
    rwf_set_canonical="$3"
    rwf_set_old_ifs="$IFS"
    IFS=,
    for rwf_set_item in $rwf_set_canonical; do
        rwf_set_hits=0
        rwf_csv_contains "$rwf_set_a" "$rwf_set_item" && rwf_set_hits=$((rwf_set_hits + 1))
        rwf_csv_contains "$rwf_set_b" "$rwf_set_item" && rwf_set_hits=$((rwf_set_hits + 1))
        if [ "$rwf_set_hits" -ne 1 ]; then
            IFS="$rwf_set_old_ifs"
            return 1
        fi
    done
    IFS="$rwf_set_old_ifs"
    return 0
}

rwf_generation_compare() {
    rwf_gen_a="$1"
    rwf_gen_b="$2"
    if [ "$rwf_gen_a" = "$rwf_gen_b" ]; then
        printf '0\n'
    elif [ "$(printf '%s\n%s\n' "$rwf_gen_a" "$rwf_gen_b" | LC_ALL=C sort | head -n 1)" = "$rwf_gen_a" ]; then
        printf '%s\n' '-1'
    else
        printf '1\n'
    fi
}

rwf_atomic_write() {
    rwf_aw_src="$1"
    rwf_aw_dst="$2"
    rwf_aw_mode="${3:-600}"
    rwf_aw_dir="$(dirname "$rwf_aw_dst")"
    mkdir -p "$rwf_aw_dir" || return 1
    chmod 700 "$rwf_aw_dir" 2>/dev/null || true
    cp "$rwf_aw_src" "${rwf_aw_dst}.tmp.$$" || return 1
    chmod "$rwf_aw_mode" "${rwf_aw_dst}.tmp.$$" || return 1
    mv "${rwf_aw_dst}.tmp.$$" "$rwf_aw_dst"
}

rwf_slots_to_tsv() {
    rwf_slots_src="$1"
    rwf_slots_out="$2"
    awk '
        BEGIN {
            expected[1]="egress1"; expected[2]="egress2"; expected[3]="egress3"; expected[4]="egress4"; expected[5]="egress5"
        }
        /^[[:space:]]*($|#)/ {next}
        NF != 11 {exit 41}
        {
            n++
            slot=$1; iface=$2; table=$3; mark=$4; dscp=$5; enabled=$11
            if(n>5 || slot!=expected[n]) exit 42
            if(iface !~ /^vpn[1-5]$/ || table !~ /^20[1-5]$/ || mark !~ /^0x20[1-5]$/ || dscp !~ /^cs[1-5]$/ || enabled != 1) exit 43
            if(seen_slot[slot]++ || seen_iface[iface]++ || seen_table[table]++ || seen_mark[mark]++ || seen_dscp[dscp]++) exit 44
            printf "%d\t%s\t%s\t%s\t%s\t%s\n",n,slot,iface,table,mark,dscp
        }
        END {if(n!=5) exit 45}
    ' "$rwf_slots_src" > "$rwf_slots_out"
}

rwf_slot_field() {
    rwf_sf_rows="$1"
    rwf_sf_slot="$2"
    rwf_sf_col="$3"
    awk -F '\t' -v slot="$rwf_sf_slot" -v col="$rwf_sf_col" '$2==slot {print $col; found=1} END{exit found?0:1}' "$rwf_sf_rows"
}

rwf_selector_slot() {
    rwf_ss_rows="$1"
    rwf_ss_selector="$2"
    awk -F '\t' -v selector="$rwf_ss_selector" '$6==selector {print $2; found=1} END{exit found?0:1}' "$rwf_ss_rows"
}

rwf_validate_slot_selector_alignment() {
    rwf_va_rows="$1"
    rwf_va_healthy_slots="$2"
    rwf_va_exhausted_slots="$3"
    rwf_va_healthy_selectors="$4"
    rwf_va_exhausted_selectors="$5"
    while IFS="$(printf '\t')" read -r rwf_va_ord rwf_va_slot rwf_va_iface rwf_va_table rwf_va_mark rwf_va_selector; do
        if rwf_csv_contains "$rwf_va_healthy_slots" "$rwf_va_slot"; then
            rwf_csv_contains "$rwf_va_healthy_selectors" "$rwf_va_selector" || return 1
        else
            rwf_csv_contains "$rwf_va_exhausted_slots" "$rwf_va_slot" || return 1
            rwf_csv_contains "$rwf_va_exhausted_selectors" "$rwf_va_selector" || return 1
        fi
    done < "$rwf_va_rows"
    return 0
}

rwf_state_validate() {
    rwf_sv_state="$1"
    rwf_sv_rows="$2"
    [ -r "$rwf_sv_state" ] || return 1
    [ "$(rwf_kv_get schema "$rwf_sv_state")" = router-wgpay-fallback-state-v1 ] || return 2
    for rwf_sv_selector in cs1 cs2 cs3 cs4 cs5; do
        rwf_sv_slot="$(rwf_kv_get "effective.${rwf_sv_selector}.slot" "$rwf_sv_state")"
        rwf_sv_iface="$(rwf_kv_get "effective.${rwf_sv_selector}.interface" "$rwf_sv_state")"
        rwf_sv_table="$(rwf_kv_get "effective.${rwf_sv_selector}.table" "$rwf_sv_state")"
        rwf_sv_mark="$(rwf_kv_get "effective.${rwf_sv_selector}.mark" "$rwf_sv_state")"
        [ -n "$rwf_sv_slot" ] && [ -n "$rwf_sv_iface" ] && [ -n "$rwf_sv_table" ] && [ -n "$rwf_sv_mark" ] || return 3
        [ "$(rwf_slot_field "$rwf_sv_rows" "$rwf_sv_slot" 3)" = "$rwf_sv_iface" ] || return 4
        [ "$(rwf_slot_field "$rwf_sv_rows" "$rwf_sv_slot" 4)" = "$rwf_sv_table" ] || return 5
        [ "$(rwf_slot_field "$rwf_sv_rows" "$rwf_sv_slot" 5)" = "$rwf_sv_mark" ] || return 6
    done
    return 0
}
