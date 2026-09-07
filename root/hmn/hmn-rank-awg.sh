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
[ -x "$IDENTITY_BIN" ] || { echo "ERROR=identity_helper_missing:$IDENTITY_BIN" >&2; exit 1; }
case "$MIN_CANDIDATES" in ''|*[!0-9]*) echo 'ERROR=invalid_min_candidates' >&2; exit 1;; esac
. "$STATE_HELPER"; reg_init_state
mkdir -p "$CACHE"; chmod 700 "$CACHE"
TS="$(date +%Y%m%d-%H%M%S)-$$"
LEGACY="$CACHE/ranked-awg1-$TS.tsv"; LEGACY_LATEST="$CACHE/ranked-awg1-latest.tsv"; CANDIDATE_POOL="$CACHE/candidate-pool-awg1-latest.tsv"
QUALITY="$CACHE/ranked-awg1-quality-$TS.tsv"; QUALITY_LATEST="$CACHE/ranked-awg1-quality-latest.tsv"
RAW="/tmp/hmn-rank-raw.$$"; FILTERED="/tmp/hmn-rank-filtered.$$"; SEEN="/tmp/hmn-rank-seen.$$"
PUBLISH_LOCK="$(reg_lock_acquire provider-rank.lock provider-quality-rank 2>/dev/null || true)"
[ -n "$PUBLISH_LOCK" ] || { echo 'ERROR=provider_rank_lock_busy' >&2; exit 1; }
CURRENT="$CACHE/ranked-awg1-current"
LINK_TMP="${CURRENT}.new.$$"
ALIAS_TMP="$CACHE/ranked-awg1-alias.new.$$"
cleanup_rank() { rm -f "$RAW" "$FILTERED" "$SEEN" "$LINK_TMP" "$ALIAS_TMP"; reg_lock_release "$PUBLISH_LOCK" >/dev/null 2>&1 || true; }
trap 'cleanup_rank' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
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
: >"$FILTERED"; : >"$SEEN"; TAB="$(printf '\t')"
while IFS="$TAB" read -r THR RTT FILE ENDPOINT ID LOSS CFG_PATH; do
    [ -n "$FILE" ] || continue; [ -f "$CFG_PATH" ] || continue
    ACTUAL_ID="$("$IDENTITY_BIN" "$CFG_PATH" 2>/dev/null || true)"
    [ -n "$ACTUAL_ID" ] || continue
    [ "$ID" = '-' ] && ID="$ACTUAL_ID"
    [ "$ID" = "$ACTUAL_ID" ] || continue
    grep -Fqx "$ID" "$SEEN" 2>/dev/null && continue
    if reg_endpoint_quarantined_for_pool "$ENDPOINT" "$RESULTS"; then echo "excluded_quarantine=$ENDPOINT" >&2; continue; fi
    printf '%s\n' "$ID" >>"$SEEN"
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
# All public pool names resolve through one pointer. Build a complete immutable
# generation first, then commit it with one rename; failures retain the whole LKG.
GEN_NAME="ranked-awg1-generation-$TS"
GEN_DIR="$CACHE/$GEN_NAME"
mkdir "$GEN_DIR"; chmod 700 "$GEN_DIR"
cp "$QUALITY" "$GEN_DIR/ranked-awg1-quality-latest.tsv"
cp "$LEGACY" "$GEN_DIR/ranked-awg1-latest.tsv"
cp "$LEGACY" "$GEN_DIR/candidate-pool-awg1-latest.tsv"
chmod 600 "$QUALITY" "$LEGACY" "$GEN_DIR"/*.tsv
if [ ! -L "$CURRENT" ]; then
    [ ! -e "$CURRENT" ] || { echo 'ERROR=ranked_current_not_symlink' >&2; exit 1; }
    OLD_NAME="ranked-awg1-generation-before-$TS"
    mkdir "$CACHE/$OLD_NAME"; chmod 700 "$CACHE/$OLD_NAME"
    for NAME in ranked-awg1-quality-latest.tsv ranked-awg1-latest.tsv candidate-pool-awg1-latest.tsv; do
        [ ! -e "$CACHE/$NAME" ] || cp -p "$CACHE/$NAME" "$CACHE/$OLD_NAME/$NAME"
    done
    ln -s "$OLD_NAME" "$LINK_TMP"
    mv -fT "$LINK_TMP" "$CURRENT"
fi
for NAME in ranked-awg1-quality-latest.tsv ranked-awg1-latest.tsv candidate-pool-awg1-latest.tsv; do
    [ "$(readlink "$CACHE/$NAME" 2>/dev/null || true)" = "ranked-awg1-current/$NAME" ] && continue
    ln -s "ranked-awg1-current/$NAME" "$ALIAS_TMP"
    mv -fT "$ALIAS_TMP" "$CACHE/$NAME"
done
ln -s "$GEN_NAME" "$LINK_TMP"
mv -fT "$LINK_TMP" "$CURRENT"
echo RESULT=PASS_HMN_PROVIDER_QUALITY_RANK
echo "RESULTS=$RESULTS"
echo "RANKED_QUALITY=$QUALITY"
echo "RANKED_QUALITY_LATEST=$QUALITY_LATEST"
echo "RANKED_LEGACY=$LEGACY"
echo "CANDIDATE_POOL=$CANDIDATE_POOL"
echo "CANDIDATE_COUNT=$N"
echo SLOT_ASSIGNMENT_PERFORMED=false
