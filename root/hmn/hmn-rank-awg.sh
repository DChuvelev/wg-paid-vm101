#!/bin/ash
# Provider-only HMN ranker. It never assigns production slots.
set -eu

RESULTS="${1:-}"
CONFIG_DIR="${CONFIG_DIR:-/root/hmn/configs/awg1/latest}"
BASE="${HMN_BASE:-/root/hmn}"
CACHE="$BASE/cache"
STATE_HELPER="${STATE_HELPER:-/usr/local/lib/router-egress-recovery-state.sh}"
EXCLUDE_REGEX="${HMN_RANK_EXCLUDE_REGEX:-RU-Russia|US-USA|HK-Hong-Kong|CL-Chile|JP-Japan|PS-UAE|KR-South-Korea|South-Korea}"
MIN_CANDIDATES="${HMN_RANK_MIN_CANDIDATES:-1}"

[ -n "$RESULTS" ] || RESULTS="$(ls -t "$BASE"/test-runs/*/results.tsv 2>/dev/null | head -n1 || true)"
[ -f "$RESULTS" ] || { echo "ERROR=results_tsv_missing" >&2; exit 1; }
[ -d "$CONFIG_DIR" ] || { echo "ERROR=config_dir_missing:$CONFIG_DIR" >&2; exit 1; }
[ -r "$STATE_HELPER" ] || { echo "ERROR=state_helper_missing:$STATE_HELPER" >&2; exit 1; }
case "$MIN_CANDIDATES" in ''|*[!0-9]*) echo 'ERROR=invalid_min_candidates' >&2; exit 1 ;; esac

# shellcheck disable=SC1090
. "$STATE_HELPER"
reg_init_state
mkdir -p "$CACHE"
chmod 700 "$CACHE"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$CACHE/ranked-awg1-$TS.tsv"
OUT_LATEST="$CACHE/ranked-awg1-latest.tsv"
CANDIDATE_POOL="$CACHE/candidate-pool-awg1-latest.tsv"
RAW="/tmp/hmn-rank-raw.$$"
FILTERED="/tmp/hmn-rank-filtered.$$"
trap 'rm -f "$RAW" "$FILTERED"' EXIT HUP INT TERM

awk -F '\t' -v ex="$EXCLUDE_REGEX" -v cfg="$CONFIG_DIR" '
    FNR > 1 && $1 == "OK" && $6 == "0%" && $7 ~ /^[0-9.]+$/ && $2 !~ ex {
        printf "%010.3f\t%s\t%s\t%s\t%s/%s\n", $7, $2, $3, $6, cfg, $2
    }
' "$RESULTS" | sort -n >"$RAW"

: >"$FILTERED"
TAB="$(printf '\t')"
while IFS="$TAB" read -r AVG FILE ENDPOINT LOSS CFG_PATH; do
    [ -n "$AVG" ] || continue
    [ -f "$CFG_PATH" ] || continue
    if reg_endpoint_quarantined_for_pool "$ENDPOINT" "$RESULTS"; then
        printf 'excluded_quarantine=%s\n' "$ENDPOINT" >&2
        continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$AVG" "$FILE" "$ENDPOINT" "$LOSS" "$CFG_PATH" >>"$FILTERED"
done <"$RAW"

printf 'rank\tavg_ms\tfile\tendpoint\tloss\tconfig_path\n' >"$OUT"
N=0
while IFS="$TAB" read -r AVG FILE ENDPOINT LOSS CFG_PATH; do
    [ -n "$AVG" ] || continue
    N=$((N + 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$N" "$AVG" "$FILE" "$ENDPOINT" "$LOSS" "$CFG_PATH" >>"$OUT"
done <"$FILTERED"

[ "$N" -ge "$MIN_CANDIDATES" ] || {
    echo "ERROR=insufficient_ranked_candidates:$N" >&2
    cat "$OUT" >&2
    exit 1
}

cp "$OUT" "$OUT_LATEST"
cp "$OUT" "$CANDIDATE_POOL"
chmod 600 "$OUT" "$OUT_LATEST" "$CANDIDATE_POOL"

echo "RESULT=PASS_HMN_PROVIDER_RANK"
echo "RESULTS=$RESULTS"
echo "RANKED=$OUT"
echo "RANKED_LATEST=$OUT_LATEST"
echo "CANDIDATE_POOL=$CANDIDATE_POOL"
echo "CANDIDATE_COUNT=$N"
echo "SLOT_ASSIGNMENT_PERFORMED=false"
