#!/bin/sh

REG_STATE_DIR="${REG_STATE_DIR:-/var/lib/router-egress-recovery}"
REG_QUARANTINE_TSV="${REG_QUARANTINE_TSV:-$REG_STATE_DIR/quarantine.tsv}"
REG_COUNTER_DIR="${REG_COUNTER_DIR:-$REG_STATE_DIR/fail-counter}"
REG_STATE_KV="${REG_STATE_KV:-$REG_STATE_DIR/state.kv}"
REG_LOCK_DIR="${REG_LOCK_DIR:-$REG_STATE_DIR/locks}"

reg_now_epoch() {
  date +%s
}

reg_now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

reg_today_utc() {
  date -u '+%Y%m%d'
}

reg_key_safe() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9_.:-]/_/g'
}

reg_clean_tsv() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

reg_init_state() {
  mkdir -p "$REG_STATE_DIR" "$REG_COUNTER_DIR" "$REG_LOCK_DIR" 2>/dev/null || return 1
  if [ ! -e "$REG_QUARANTINE_TSV" ]; then
    printf 'ts_epoch\tts_utc\tegress\tiface\tendpoint\treplacement\treason\tpool_path\tpool_mtime_epoch\tsource_step\n' > "$REG_QUARANTINE_TSV" || return 1
  fi
  touch "$REG_STATE_KV" 2>/dev/null || return 1
  return 0
}

reg_pool_mtime_epoch() {
  p="$1"
  [ -n "$p" ] && [ -e "$p" ] || {
    echo 0
    return 0
  }

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

  v="$(find "$p" -maxdepth 0 -printf '%T@\n' 2>/dev/null | sed 's/\..*$//' | head -1)"
  if printf '%s\n' "$v" | grep -Eq '^[0-9]+$'; then
    echo "$v"
    return 0
  fi

  echo 0
  return 0
}

reg_set_state() {
  key="$(reg_key_safe "$1")"
  val="$2"
  reg_init_state || return 1
  tmp="${REG_STATE_KV}.$$"
  grep -v "^${key}=" "$REG_STATE_KV" 2>/dev/null > "$tmp" || true
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$REG_STATE_KV"
}

reg_get_state() {
  key="$(reg_key_safe "$1")"
  def="${2:-}"
  reg_init_state >/dev/null 2>&1 || {
    printf '%s\n' "$def"
    return 1
  }
  val="$(grep "^${key}=" "$REG_STATE_KV" 2>/dev/null | tail -1 | sed 's/^[^=]*=//')"
  if [ -n "$val" ]; then
    printf '%s\n' "$val"
  else
    printf '%s\n' "$def"
  fi
}

reg_quarantine_endpoint() {
  endpoint="$1"
  egress="${2:-}"
  iface="${3:-}"
  replacement="${4:-}"
  reason="${5:-unspecified}"
  pool_path="${6:-}"
  source_step="${7:-manual}"

  reg_init_state || return 1

  ts="$(reg_now_epoch)"
  utc="$(reg_now_utc)"
  pool_mtime="$(reg_pool_mtime_epoch "$pool_path")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(reg_clean_tsv "$ts")" \
    "$(reg_clean_tsv "$utc")" \
    "$(reg_clean_tsv "$egress")" \
    "$(reg_clean_tsv "$iface")" \
    "$(reg_clean_tsv "$endpoint")" \
    "$(reg_clean_tsv "$replacement")" \
    "$(reg_clean_tsv "$reason")" \
    "$(reg_clean_tsv "$pool_path")" \
    "$(reg_clean_tsv "$pool_mtime")" \
    "$(reg_clean_tsv "$source_step")" >> "$REG_QUARANTINE_TSV"
}

reg_latest_quarantine_ts() {
  endpoint="$1"
  reg_init_state >/dev/null 2>&1 || return 1
  awk -F '\t' -v ep="$endpoint" 'NR > 1 && $5 == ep { ts = $1 } END { if (ts != "") print ts }' "$REG_QUARANTINE_TSV" 2>/dev/null
}

reg_endpoint_quarantined_for_pool() {
  endpoint="$1"
  pool_path="${2:-}"

  qts="$(reg_latest_quarantine_ts "$endpoint" 2>/dev/null || true)"
  [ -n "$qts" ] || return 1

  pool_mtime="$(reg_pool_mtime_epoch "$pool_path")"
  [ -n "$pool_mtime" ] || pool_mtime=0

  if [ "$pool_mtime" -gt "$qts" ] 2>/dev/null; then
    return 1
  fi

  return 0
}

reg_counter_file() {
  key="$(reg_key_safe "$1")"
  printf '%s/%s.count\n' "$REG_COUNTER_DIR" "$key"
}

reg_counter_get() {
  key="$1"
  reg_init_state >/dev/null 2>&1 || {
    echo 0
    return 1
  }
  f="$(reg_counter_file "$key")"
  if [ -e "$f" ]; then
    cat "$f" 2>/dev/null | tail -1 | sed 's/[^0-9].*$//' | grep -E '^[0-9]+$' || echo 0
  else
    echo 0
  fi
}

reg_counter_inc() {
  key="$1"
  reg_init_state || return 1
  cur="$(reg_counter_get "$key")"
  [ -n "$cur" ] || cur=0
  next=$((cur + 1))
  f="$(reg_counter_file "$key")"
  printf '%s\n' "$next" > "$f" || return 1
  printf '%s\n' "$next"
}

reg_daily_repair_key() {
  printf 'repairs_%s\n' "$(reg_today_utc)"
}

reg_daily_repair_get() {
  reg_counter_get "$(reg_daily_repair_key)"
}

reg_daily_repair_inc() {
  reg_counter_inc "$(reg_daily_repair_key)"
}

reg_selftest() {
  old_state_dir="$REG_STATE_DIR"
  old_quarantine="$REG_QUARANTINE_TSV"
  old_counter="$REG_COUNTER_DIR"
  old_state_kv="$REG_STATE_KV"
  old_lock="$REG_LOCK_DIR"

  test_root="/tmp/router-egress-recovery-state-selftest-$$"
  REG_STATE_DIR="$test_root/state"
  REG_QUARANTINE_TSV="$REG_STATE_DIR/quarantine.tsv"
  REG_COUNTER_DIR="$REG_STATE_DIR/fail-counter"
  REG_STATE_KV="$REG_STATE_DIR/state.kv"
  REG_LOCK_DIR="$REG_STATE_DIR/locks"

  endpoint="203.0.113.77:1111"
  replacement="198.51.100.88:2222"
  pool="$test_root/pool.tsv"

  mkdir -p "$test_root" || return 1
  printf 'rank\tfile\tendpoint\tavg_ms\tping_loss\tconfig_path\n1\tx\t%s\t50\t0\tx\n' "$endpoint" > "$pool"

  old_mtime="$(reg_pool_mtime_epoch "$pool")"
  echo "selftest.pool_mtime_initial=$old_mtime"

  reg_init_state || return 1
  sleep 2
  reg_quarantine_endpoint "$endpoint" egressX vpnX "$replacement" selftest "$pool" STEP_050B2_SELFTEST || return 1
  qts="$(reg_latest_quarantine_ts "$endpoint")"
  echo "selftest.quarantine_ts=$qts"

  if reg_endpoint_quarantined_for_pool "$endpoint" "$pool"; then
    echo "selftest.quarantine_active_old_pool=true"
  else
    echo "selftest.quarantine_active_old_pool=false"
    return 1
  fi

  sleep 2
  printf '\n# refreshed-after-quarantine %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$pool"
  touch "$pool" 2>/dev/null || true
  new_mtime="$(reg_pool_mtime_epoch "$pool")"
  echo "selftest.pool_mtime_refreshed=$new_mtime"

  if [ "$new_mtime" -le "$qts" ] 2>/dev/null; then
    echo "selftest.pool_mtime_gt_quarantine=false"
    return 1
  else
    echo "selftest.pool_mtime_gt_quarantine=true"
  fi

  if reg_endpoint_quarantined_for_pool "$endpoint" "$pool"; then
    echo "selftest.quarantine_released_new_pool=false"
    return 1
  else
    echo "selftest.quarantine_released_new_pool=true"
  fi

  reg_set_state mode NORMAL || return 1
  val="$(reg_get_state mode UNKNOWN)"
  echo "selftest.state_get=$val"
  [ "$val" = "NORMAL" ] || return 1

  c1="$(reg_counter_inc selftest_counter)"
  c2="$(reg_counter_inc selftest_counter)"
  echo "selftest.counter_after_two=$c2"
  [ "$c1" = "1" ] || return 1
  [ "$c2" = "2" ] || return 1

  rm -rf "$test_root"

  REG_STATE_DIR="$old_state_dir"
  REG_QUARANTINE_TSV="$old_quarantine"
  REG_COUNTER_DIR="$old_counter"
  REG_STATE_KV="$old_state_kv"
  REG_LOCK_DIR="$old_lock"

  echo "selftest.ok=true"
  return 0
}
