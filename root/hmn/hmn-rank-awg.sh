#!/bin/ash
# Provider-only HMN quality ranker. Throughput primary, RTT secondary.
set -eu
umask 077
RESULTS="${1:-}"
CONFIG_DIR="${CONFIG_DIR:-/root/hmn/configs/awg1/latest}"
BASE="${HMN_BASE:-/root/hmn}"
CACHE="$BASE/cache"
STATE_HELPER="${STATE_HELPER:-/usr/local/lib/router-egress-recovery-state.sh}"
EXCLUDE_REGEX="${HMN_RANK_EXCLUDE_REGEX:-RU-Russia|US-USA|HK-Hong-Kong|CL-Chile|JP-Japan|PS-UAE|KR-South-Korea|South-Korea}"
MIN_CANDIDATES="${HMN_RANK_MIN_CANDIDATES:-1}"
IDENTITY_BIN="${HMN_TUNNEL_IDENTITY:-/usr/local/lib/router-egress-hmn-identity.sh}"
[ -n "$RESULTS" ] || RESULTS="$(ls -t "$BASE"/test-runs/*/results.tsv 2>/dev/null | head -n1 || true)"
[ -f "$RESULTS" ] || { echo "ERROR=results_tsv_missing" >&2; exit 1; }
[ -d "$CONFIG_DIR" ] || { echo "ERROR=config_dir_missing:$CONFIG_DIR" >&2; exit 1; }
[ -r "$STATE_HELPER" ] || { echo "ERROR=state_helper_missing:$STATE_HELPER" >&2; exit 1; }
case "$MIN_CANDIDATES" in ''|*[!0-9]*) echo 'ERROR=invalid_min_candidates' >&2; exit 1;; esac
. "$STATE_HELPER"; reg_init_state
mkdir -p "$CACHE"; chmod 700 "$CACHE"
TS="$(date +%Y%m%d-%H%M%S)"
LEGACY="$CACHE/ranked-awg1-$TS.tsv"; LEGACY_LATEST="$CACHE/ranked-awg1-latest.tsv"; CANDIDATE_POOL="$CACHE/candidate-pool-awg1-latest.tsv"
QUALITY="$CACHE/ranked-awg1-quality-$TS.tsv"; QUALITY_LATEST="$CACHE/ranked-awg1-quality-latest.tsv"
RAW="/tmp/hmn-rank-raw.$$"; FILTERED="/tmp/hmn-rank-filtered.$$"; trap 'rm -f "$RAW" "$FILTERED"' EXIT HUP INT TERM
HEADER="$(head -n1 "$RESULTS")"
NEW_HEADER="$(printf 'status\tfile\tendpoint\ttunnel_id\tactive_iface\thttps_quorum\thttps_google\thttps_cloudflare\thttps_mozilla\tping_loss\tping_rtt_avg\tthroughput_bps\tconfig_path\tshow_file\tdetail_file')"
OLD_HEADER="$(printf 'status\tfile\tendpoint\tlatest_handshake\ttransfer\tping_loss\tping_rtt_avg\tshow_file\tping_file')"
if [ "$HEADER" = "$NEW_HEADER" ]; then
    awk -F '\t' -v ex="$EXCLUDE_REGEX" 'BEGIN{OFS="\t"}
      NR>1 && $1=="OK" && $6 ~ /^[23]\/3$/ && $12 ~ /^[0-9.]+$/ && $12+0>0 && $2 !~ ex {
        rtt=($11 ~ /^[0-9.]+$/ ? $11 : 999999); print $12,rtt,$2,$3,$4,$10,$13
      }' "$RESULTS" | sort -t "$(printf '\t')" -k1,1nr -k2,2n >"$RAW"
elif [ "$HEADER" = "$OLD_HEADER" ]; then
    awk -F '\t' -v ex="$EXCLUDE_REGEX" -v cfg="$CONFIG_DIR" 'BEGIN{OFS="\t"}
      NR>1 && $1=="OK" && $7 ~ /^[0-9.]+$/ && $2 !~ ex {print 0,$7,$2,$3,"-",$6,cfg "/" $2}' "$RESULTS" | sort -t "$(printf '\t')" -k2,2n >"$RAW"
else
    echo "ERROR=unsupported_results_schema:$HEADER" >&2; exit 1
fi
: >"$FILTERED"; TAB="$(printf '\t')"
while IFS="$TAB" read -r THR RTT FILE ENDPOINT ID LOSS CFG_PATH; do
    [ -n "$FILE" ] || continue; [ -f "$CFG_PATH" ] || continue
    [ "$ID" != '-' ] || ID="$($IDENTITY_BIN "$CFG_PATH" 2>/dev/null || echo '-')"
    if reg_endpoint_quarantined_for_pool "$ENDPOINT" "$RESULTS"; then echo "excluded_quarantine=$ENDPOINT" >&2; continue; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$THR" "$RTT" "$FILE" "$ENDPOINT" "$ID" "$LOSS" "$CFG_PATH" >>"$FILTERED"
done <"$RAW"
printf 'rank\tthroughput_bps\tavg_ms\tfile\tendpoint\ttunnel_id\tloss\tconfig_path\n' >"$QUALITY"
printf 'rank\tavg_ms\tfile\tendpoint\tloss\tconfig_path\n' >"$LEGACY"
N=0
while IFS="$TAB" read -r THR RTT FILE ENDPOINT ID LOSS CFG_PATH; do
    [ -n "$FILE" ] || continue; N=$((N+1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$N" "$THR" "$RTT" "$FILE" "$ENDPOINT" "$ID" "$LOSS" "$CFG_PATH" >>"$QUALITY"
    legacy_rtt="$RTT"; [ "$legacy_rtt" != 999999 ] || legacy_rtt=999999.000
    printf '%s\t%010.3f\t%s\t%s\t0%%\t%s\n' "$N" "$legacy_rtt" "$FILE" "$ENDPOINT" "$CFG_PATH" >>"$LEGACY"
done <"$FILTERED"
[ "$N" -ge "$MIN_CANDIDATES" ] || { echo "ERROR=insufficient_ranked_candidates:$N" >&2; exit 1; }
cp "$QUALITY" "$QUALITY_LATEST"; cp "$LEGACY" "$LEGACY_LATEST"; cp "$LEGACY" "$CANDIDATE_POOL"
chmod 600 "$QUALITY" "$QUALITY_LATEST" "$LEGACY" "$LEGACY_LATEST" "$CANDIDATE_POOL"
echo RESULT=PASS_HMN_PROVIDER_QUALITY_RANK
echo "RESULTS=$RESULTS"
echo "RANKED_QUALITY=$QUALITY"
echo "RANKED_QUALITY_LATEST=$QUALITY_LATEST"
echo "RANKED_LEGACY=$LEGACY"
echo "CANDIDATE_POOL=$CANDIDATE_POOL"
echo "CANDIDATE_COUNT=$N"
echo SLOT_ASSIGNMENT_PERFORMED=false
