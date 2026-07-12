#!/bin/ash

set -eu

RESULTS="${1:-}"
CONFIG_DIR="${CONFIG_DIR:-/root/hmn/configs/awg1/latest}"
QUARANTINE="${HMN_RANK_QUARANTINE:-/root/hmn/cache/quarantine-awg1-latest.tsv}"

# По умолчанию не берём дальние/нежелательные географии для обычного foreign VPN-egress.
# Временно плохие туннели текущего набора исключаются через QUARANTINE,
# а не через вечный blacklist.
EXCLUDE_REGEX="${HMN_RANK_EXCLUDE_REGEX:-RU-Russia|US-USA|HK-Hong-Kong|CL-Chile|JP-Japan|PS-UAE|KR-South-Korea|South-Korea}"

if [ -z "$RESULTS" ]; then
  RESULTS="$(ls -t /root/hmn/test-runs/*/results.tsv 2>/dev/null | head -n 1 || true)"
fi

if [ -z "$RESULTS" ] || [ ! -f "$RESULTS" ]; then
  echo "ERROR: не найден results.tsv"
  echo "Запусти сначала:"
  echo "  /root/hmn/hmn-test-all-awg.sh"
  exit 1
fi

if [ ! -d "$CONFIG_DIR" ]; then
  echo "ERROR: не найден каталог конфигов:"
  echo "  $CONFIG_DIR"
  exit 1
fi

if [ ! -f "$QUARANTINE" ]; then
  QUARANTINE="/dev/null"
fi

mkdir -p /root/hmn/cache
chmod 700 /root/hmn/cache

TS="$(date +%Y%m%d-%H%M%S)"
OUT="/root/hmn/cache/ranked-awg1-$TS.tsv"
OUT_LATEST="/root/hmn/cache/ranked-awg1-latest.tsv"
SELECTED="/root/hmn/cache/selected-awg1-$TS.tsv"
SELECTED_LATEST="/root/hmn/cache/selected-awg1-latest.tsv"
TMP="/tmp/hmn-rank-awg.$$"

echo "Ranking:"
echo "  results:    $RESULTS"
echo "  config dir: $CONFIG_DIR"
echo "  exclude:    $EXCLUDE_REGEX"
echo "  quarantine: $QUARANTINE"
echo

awk -F '\t' -v ex="$EXCLUDE_REGEX" -v cfg="$CONFIG_DIR" -v qfile="$QUARANTINE" '
FILENAME == qfile {
  if (FNR == 1) next
  if ($1 != "") q_endpoint[$1] = 1
  if ($2 != "") q_file[$2] = 1
  next
}

FILENAME != qfile &&
FNR > 1 &&
$1 == "OK" &&
$6 == "0%" &&
$7 ~ /^[0-9.]+$/ &&
$2 !~ ex &&
!($3 in q_endpoint) &&
!($2 in q_file) {
  printf "%010.3f\t%s\t%s\t%s\t%s/%s\n", $7, $2, $3, $6, cfg, $2
}
' "$QUARANTINE" "$RESULTS" | sort -n > "$TMP"

printf "rank\tavg_ms\tfile\tendpoint\tloss\tconfig_path\n" > "$OUT"

N=0
TAB="$(printf '\t')"

while IFS="$TAB" read -r AVG FILE ENDPOINT LOSS CFG_PATH; do
  [ -n "$AVG" ] || continue

  if [ ! -f "$CFG_PATH" ]; then
    echo "WARN: config file not found, skip: $CFG_PATH" >&2
    continue
  fi

  N=$((N + 1))
  printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$N" "$AVG" "$FILE" "$ENDPOINT" "$LOSS" "$CFG_PATH" >> "$OUT"
done < "$TMP"

rm -f "$TMP"

if [ "$N" -lt 2 ]; then
  echo "ERROR: найдено меньше двух подходящих живых туннелей: $N"
  echo
  echo "Что есть в ranked:"
  cat "$OUT"
  exit 1
fi

cp "$OUT" "$OUT_LATEST"

printf "slot\tfile\tendpoint\tavg_ms\tconfig_path\n" > "$SELECTED"

awk -F '\t' '
NR == 2 { printf "vpn1\t%s\t%s\t%s\t%s\n", $3, $4, $2, $6 }
NR == 3 { printf "vpn2\t%s\t%s\t%s\t%s\n", $3, $4, $2, $6 }
' "$OUT" >> "$SELECTED"

cp "$SELECTED" "$SELECTED_LATEST"

echo "Ranked:"
echo "  $OUT"
echo "  $OUT_LATEST"
echo

echo "Selected:"
echo "  $SELECTED"
echo "  $SELECTED_LATEST"
echo

echo "Top candidates:"
sed -n '1,12p' "$OUT"

echo
echo "Selected slots:"
cat "$SELECTED"
