#!/bin/sh
set -u

HELPER="${HELPER:-/usr/local/lib/router-egress-recovery-state.sh}"
POOL="${POOL:-/root/hmn/cache/ok-awg1-strict-foreign-latest.tsv}"
FALLBACK_POOL="${FALLBACK_POOL:-/root/hmn/cache/ok-awg1-strict-all-latest.tsv}"
WORK="/tmp/router-egress-hmn-plan-top5.$$"
SLOTS="egress1:vpn1 egress2:vpn2 egress3:vpn3 egress4:vpn4 egress5:vpn5"

mkdir -p "$WORK" 2>/dev/null || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM

json_s() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

pool_mtime_epoch_local() {
  p="$1"
  if [ -n "$p" ] && [ -e "$p" ]; then
    v="$(stat -c %Y "$p" 2>/dev/null | head -1)"
    if printf '%s\n' "$v" | grep -Eq '^[0-9]+$'; then
      echo "$v"
      return 0
    fi
    v="$(date -r "$p" +%s 2>/dev/null | head -1)"
    if printf '%s\n' "$v" | grep -Eq '^[0-9]+$'; then
      echo "$v"
      return 0
    fi
  fi
  echo 0
}

contains_endpoint() {
  ep="$1"
  file="$2"
  [ -n "$ep" ] || return 1
  [ -f "$file" ] || return 1
  awk -F '\t' -v ep="$ep" '$1 == ep { found=1 } END { exit found ? 0 : 1 }' "$file"
}

candidate_row_for_endpoint() {
  ep="$1"
  file="$2"
  awk -F '\t' -v ep="$ep" '$1 == ep { print; exit }' "$file"
}

pick_replacement() {
  desired="$1"
  keepers="$2"
  assigned="$3"
  while IFS="$(printf '\t')" read -r ep rank avg; do
    [ -n "$ep" ] || continue
    if contains_endpoint "$ep" "$keepers"; then
      continue
    fi
    if contains_endpoint "$ep" "$assigned"; then
      continue
    fi
    printf '%s\t%s\t%s\n' "$ep" "$rank" "$avg"
    return 0
  done < "$desired"
  return 1
}

if [ ! -f "$POOL" ] && [ -f "$FALLBACK_POOL" ]; then
  POOL="$FALLBACK_POOL"
fi

if [ ! -f "$POOL" ]; then
  echo "{\"schema\":\"router-egress-hmn-plan-top5-v2\",\"decision\":\"missing_pool\",\"pool\":\"$(json_s "$POOL")\",\"changes_count\":0,\"plan\":[]}"
  exit 0
fi

if [ -r "$HELPER" ]; then
  . "$HELPER"
  reg_init_state >/dev/null 2>&1 || true
  QUARANTINE_ENABLED=true
else
  QUARANTINE_ENABLED=false
fi

CAND="$WORK/candidates.tsv"
DESIRED="$WORK/desired.tsv"
CURRENT="$WORK/current.tsv"
KEEPERS="$WORK/keepers.tsv"
ASSIGNED="$WORK/assigned.tsv"
PLAN="$WORK/plan.tsv"
: > "$CAND"
: > "$DESIRED"
: > "$CURRENT"
: > "$KEEPERS"
: > "$ASSIGNED"
: > "$PLAN"

quarantine_excluded=0
duplicate_excluded=0

{
  read -r header || true
  while IFS="$(printf '\t')" read -r rank file endpoint avg_ms ping_loss config_path rest; do
    [ -n "$endpoint" ] || continue
    case "$endpoint" in endpoint|\#*) continue ;; esac

    if contains_endpoint "$endpoint" "$CAND"; then
      duplicate_excluded=$((duplicate_excluded + 1))
      continue
    fi

    if [ "$QUARANTINE_ENABLED" = "true" ] && reg_endpoint_quarantined_for_pool "$endpoint" "$POOL"; then
      quarantine_excluded=$((quarantine_excluded + 1))
      continue
    fi

    printf '%s\t%s\t%s\n' "$endpoint" "${rank:-0}" "${avg_ms:-}" >> "$CAND"
  done
} < "$POOL"

sed -n '1,5p' "$CAND" > "$DESIRED"
desired_count="$(wc -l < "$DESIRED" | tr -d ' ')"

for pair in $SLOTS; do
  slot="${pair%%:*}"
  iface="${pair#*:}"
  cur="$(uci -q get network.${iface}.hmn_endpoint 2>/dev/null || true)"
  printf '%s\t%s\t%s\n' "$slot" "$iface" "$cur" >> "$CURRENT"
  if contains_endpoint "$cur" "$DESIRED"; then
    printf '%s\n' "$cur" >> "$KEEPERS"
  fi
done

changes=0

while IFS="$(printf '\t')" read -r slot iface cur; do
  if contains_endpoint "$cur" "$DESIRED"; then
    row="$(candidate_row_for_endpoint "$cur" "$DESIRED")"
    target="$cur"
    rank="$(printf '%s\n' "$row" | awk -F '\t' '{print $2}')"
    avg="$(printf '%s\n' "$row" | awk -F '\t' '{print $3}')"
    change=false
  else
    row="$(pick_replacement "$DESIRED" "$KEEPERS" "$ASSIGNED" || true)"
    target="$(printf '%s\n' "$row" | awk -F '\t' '{print $1}')"
    rank="$(printf '%s\n' "$row" | awk -F '\t' '{print $2}')"
    avg="$(printf '%s\n' "$row" | awk -F '\t' '{print $3}')"
    if [ -n "$target" ]; then
      printf '%s\n' "$target" >> "$ASSIGNED"
    fi
    if [ "$target" = "$cur" ]; then
      change=false
    else
      change=true
      changes=$((changes + 1))
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$slot" "$iface" "$cur" "$target" "$change" "$rank" "$avg" >> "$PLAN"
done < "$CURRENT"

decision="plan_ok"
if [ "$desired_count" -lt 5 ]; then
  decision="not_enough_candidates"
fi

pool_mtime="$(pool_mtime_epoch_local "$POOL")"

echo "{"
echo "  \"schema\": \"router-egress-hmn-plan-top5-v2\","
echo "  \"decision\": \"$(json_s "$decision")\","
echo "  \"pool\": \"$(json_s "$POOL")\","
echo "  \"pool_mtime_epoch\": $pool_mtime,"
echo "  \"quarantine_enabled\": $QUARANTINE_ENABLED,"
echo "  \"quarantine_excluded_count\": $quarantine_excluded,"
echo "  \"duplicate_excluded_count\": $duplicate_excluded,"
echo "  \"desired_count\": $desired_count,"
echo "  \"changes_count\": $changes,"
echo "  \"plan\": ["
i=0
while IFS="$(printf '\t')" read -r slot iface cur target change rank avg; do
  [ "$i" -gt 0 ] && echo "    ,"
  printf '    {"slot":"%s","iface":"%s","current":"%s","target":"%s","change":%s,"target_rank":"%s","target_avg_ms":"%s"}\n' \
    "$(json_s "$slot")" \
    "$(json_s "$iface")" \
    "$(json_s "$cur")" \
    "$(json_s "$target")" \
    "$change" \
    "$(json_s "$rank")" \
    "$(json_s "$avg")"
  i=$((i + 1))
done < "$PLAN"
echo "  ]"
echo "}"
