#!/bin/sh
# Pure planner for R21B daily quality optimization.
# ACTIVE_TSV rows: iface slot throughput_bps rtt_ms tunnel_id endpoint config_path
set -eu
umask 077

ACTIVE="${1:?active tsv required}"
QUALITY="${2:?quality pool required}"
OUT="${3:?output plan required}"
MIN_PCT="${4:?min pct required}"
MIN_BPS="${5:?min bps required}"
MAX_REPL="${6:?max replacements required}"

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
for v in "$MIN_PCT" "$MIN_BPS" "$MAX_REPL"; do is_uint "$v" || exit 2; done
[ "$MAX_REPL" -le 5 ] || exit 2
[ -s "$ACTIVE" ] && [ -s "$QUALITY" ] || exit 2
[ "$(wc -l <"$ACTIVE" | tr -d ' ')" -eq 5 ] || exit 2
EXPECTED="$(printf 'rank\tthroughput_bps\tavg_ms\tfile\tendpoint\ttunnel_id\tloss\tconfig_path')"
[ "$(head -n1 "$QUALITY")" = "$EXPECTED" ] || exit 2

# Reject ambiguous/malformed measurements before producing any plan. The
# caller must supply the same five identities and measurements as the pool.
awk -F '\t' '
    FNR==NR {
        if (NF!=7 || $1 !~ /^vpn[1-5]$/ || $2!="egress" substr($1,4) ||
            $3 !~ /^[0-9]+$/ || $3+0<=0 || $4 !~ /^[0-9]+([.][0-9]+)?$/ ||
            $5=="" || $6=="" || $7=="" || iface[$1]++ || id[$5]++) bad=1
        thr[$5]=$3; rtt[$5]=$4; next
    }
    FNR==1 { next }
    {
        if (NF!=8 || $1!=FNR-1 || $2 !~ /^[0-9]+$/ || $2+0<=0 ||
            $3 !~ /^[0-9]+([.][0-9]+)?$/ || $4=="" || $5=="" || $6=="" ||
            $8=="" || seen[$6]++) bad=1
        if (FNR>2 && ($2+0>prev_thr || ($2+0==prev_thr && $3+0<prev_rtt))) bad=1
        prev_thr=$2+0; prev_rtt=$3+0
        if (id[$6] && ($2+0!=thr[$6]+0 || $3+0!=rtt[$6]+0)) bad=1
    }
    END { for (i in id) if (!seen[i]) bad=1; exit bad?1:0 }
' "$ACTIVE" "$QUALITY" || exit 2

tmp="${OUT}.tmp.$$"
active_ids="${tmp}.ids"
virtual_active="${tmp}.active"
virtual_inactive="${tmp}.inactive"
trap 'rm -f "$tmp" "$active_ids" "$virtual_active" "$virtual_inactive" "${virtual_active}.new" "${virtual_inactive}.new"' EXIT HUP INT TERM

cut -f5 "$ACTIVE" >"$active_ids"
cp "$ACTIVE" "$virtual_active"
awk -F '\t' -v ids="$active_ids" '
  BEGIN{while((getline line < ids)>0) active[line]=1; OFS="\t"}
  NR>1 && !active[$6] {print $2,$3,$6,$5,$8,$4,$1}
' "$QUALITY" >"$virtual_inactive"

printf 'seq\tslot\tiface\told_tunnel_id\told_throughput_bps\told_rtt_ms\tnew_tunnel_id\tnew_throughput_bps\tnew_rtt_ms\tnew_endpoint\tnew_config_path\tgain_bps\tgain_pct\n' >"$tmp"
seqn=0
while [ "$seqn" -lt "$MAX_REPL" ]; do
    worst="$(sort -t "$(printf '\t')" -k3,3n -k4,4nr "$virtual_active" | head -n1)"
    best="$(head -n1 "$virtual_inactive")"
    [ -n "$worst" ] && [ -n "$best" ] || break

    old_if="$(printf '%s\n' "$worst" | cut -f1)"
    old_slot="$(printf '%s\n' "$worst" | cut -f2)"
    old_thr="$(printf '%s\n' "$worst" | cut -f3)"
    old_rtt="$(printf '%s\n' "$worst" | cut -f4)"
    old_id="$(printf '%s\n' "$worst" | cut -f5)"

    new_thr="$(printf '%s\n' "$best" | cut -f1)"
    new_rtt="$(printf '%s\n' "$best" | cut -f2)"
    new_id="$(printf '%s\n' "$best" | cut -f3)"
    new_ep="$(printf '%s\n' "$best" | cut -f4)"
    new_cfg="$(printf '%s\n' "$best" | cut -f5)"

    case "$old_thr:$new_thr" in *[!0-9:]*) exit 2 ;; esac
    gain=$((new_thr - old_thr))
    [ "$gain" -gt 0 ] || break
    gain_pct="$(awk -v n="$new_thr" -v o="$old_thr" 'BEGIN{if(o<=0)printf "999.0";else printf "%.1f",((n-o)*100)/o}')"
    # Display rounding must never relax the actual hysteresis threshold.
    pct_ok="$(awk -v n="$new_thr" -v o="$old_thr" -v m="$MIN_PCT" 'BEGIN{print ((n-o)*100>=o*m)?1:0}')"
    [ "$gain" -ge "$MIN_BPS" ] && [ "$pct_ok" = 1 ] || break

    seqn=$((seqn+1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$seqn" "$old_slot" "$old_if" "$old_id" "$old_thr" "$old_rtt" \
        "$new_id" "$new_thr" "$new_rtt" "$new_ep" "$new_cfg" "$gain" "$gain_pct" >>"$tmp"

    awk -F '\t' -v id="$old_id" '$5!=id' "$virtual_active" >"${virtual_active}.new"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$old_if" "$old_slot" "$new_thr" "$new_rtt" "$new_id" "$new_ep" "$new_cfg" >>"${virtual_active}.new"
    mv "${virtual_active}.new" "$virtual_active"

    awk -F '\t' -v id="$new_id" '$3!=id' "$virtual_inactive" >"${virtual_inactive}.new"
    mv "${virtual_inactive}.new" "$virtual_inactive"
done

mv "$tmp" "$OUT"
trap - EXIT HUP INT TERM
rm -f "$active_ids" "$virtual_active" "$virtual_inactive" "${virtual_active}.new" "${virtual_inactive}.new"
echo RESULT=PASS_R21B_DAILY_QUALITY_PLAN
echo "PLAN=$OUT"
echo "PLAN_COUNT=$seqn"
