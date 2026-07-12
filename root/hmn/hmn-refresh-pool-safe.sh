#!/bin/ash

set -u

# BEGIN CANONICAL_M07_REFRESH_POOL_SAFE
VM101_RUNTIME_LIB="${VM101_RUNTIME_LIB:-/usr/local/lib/router-egress-vm101-runtime.sh}"

if [ ! -r "$VM101_RUNTIME_LIB" ]; then
  echo "ERROR: missing runtime library $VM101_RUNTIME_LIB" >&2
  exit 70
fi

. "$VM101_RUNTIME_LIB"

CANONICAL_BACKUP_ROOT="${CANONICAL_BACKUP_ROOT:-/tmp/hmn-refresh-backups}"

canonical_backup_dir() {
  printf '%s\n' "${BACK:-}"
}

canonical_verify_backup_manifest() {
  backup_dir="$1"
  manifest="$backup_dir/manifest.tsv"
  complete="$backup_dir/manifest.complete"

  [ -d "$backup_dir" ] || return 90
  [ -s "$manifest" ] || return 90
  [ -s "$complete" ] || return 90

  while IFS="$(printf '\t')" read -r expected_hash expected_size relative
  do
    [ -n "$expected_hash" ] || return 91
    [ -n "$expected_size" ] || return 91
    [ -n "$relative" ] || return 91

    file="$backup_dir/$relative"

    [ -s "$file" ] || return 91

    actual_hash="$(vm101_file_sha256 "$file")" ||
      return 91

    actual_size="$(
      wc -c < "$file" |
        tr -d '[:space:]'
    )"

    [ "$actual_hash" = "$expected_hash" ] ||
      return 92

    [ "$actual_size" = "$expected_size" ] ||
      return 92
  done < "$manifest"

  return 0
}

canonical_prepare_backup_manifest() {
  backup_dir="$(canonical_backup_dir)"

  [ -n "$backup_dir" ] || return 74
  [ -d "$backup_dir" ] || return 74

  manifest="$backup_dir/manifest.tsv"
  complete="$backup_dir/manifest.complete"

  rm -f "$manifest" "$complete"

  find "$backup_dir" \
    -type f \
    ! -name manifest.tsv \
    ! -name manifest.complete \
    -print |
  sort |
  while IFS= read -r file
  do
    [ -s "$file" ] || exit 75

    hash="$(vm101_file_sha256 "$file")" ||
      exit 75

    size="$(
      wc -c < "$file" |
        tr -d '[:space:]'
    )"

    relative="${file#${backup_dir}/}"

    printf '%s\t%s\t%s\n' \
      "$hash" \
      "$size" \
      "$relative"
  done > "$manifest" || return 75

  [ -s "$manifest" ] || return 75

  printf 'complete=true\n' > "$complete"

  canonical_verify_backup_manifest "$backup_dir"
}

canonical_download_all_awg() {
  canonical_prepare_backup_manifest || return $?

  "$DOWNLOADER_ORIGINAL" "$@"
}
# END CANONICAL_M07_REFRESH_POOL_SAFE

BASE="/root/hmn"
LOGDIR="$BASE/logs"
STATE="$BASE/state"
BACKUPDIR="$CANONICAL_BACKUP_ROOT"

DOWNLOADER="$BASE/hmn-download-all-awg.sh"
DOWNLOADER_ORIGINAL="$DOWNLOADER"
VALIDATE="$BASE/hmn-validate-current-pool.sh"
MAN="/usr/bin/vpn-egress-manager.sh"

LOCK="/tmp/hmn-refresh-pool-safe.lock"

MODE="${1:-fresh-download}"

mkdir -p "$LOGDIR" "$STATE" "$BACKUPDIR"

TS="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/refresh-pool-safe-$TS-$$.log"
RCFILE="/tmp/hmn-refresh-pool-safe.rc.$$"

BACK=""

RETRY_FLAG="$STATE/refresh-retry-needed"
RETRY_REASON="$STATE/refresh-retry-reason"
LAST_FRESH_DOWNLOAD_RC="$STATE/last-fresh-download-rc"
LAST_FRESH_DOWNLOAD_AT="$STATE/last-fresh-download-at"
LAST_REFRESH_POOL_SOURCE="$STATE/last-refresh-pool-source"

say() {
  echo "$(date -Iseconds) $*"
}

write_status() {
  echo "$1" > "$STATE/refresh-status"
  date -Iseconds > "$STATE/last-refresh-status-at"
}

record_download_rc() {
  echo "$1" > "$LAST_FRESH_DOWNLOAD_RC"
  date -Iseconds > "$LAST_FRESH_DOWNLOAD_AT"
}

set_retry_needed() {
  REASON="$1"
  date -Iseconds > "$RETRY_FLAG"
  echo "$REASON" > "$RETRY_REASON"
  say "retry-needed set: $REASON"
}

clear_retry_needed() {
  rm -f "$RETRY_FLAG" "$RETRY_REASON"
  say "retry-needed cleared"
}

restore_backup() {

  backup_dir="$(canonical_backup_dir)"

  if ! canonical_verify_backup_manifest "$backup_dir"
  then
    echo "ERROR: rollback refused; backup manifest incomplete" >&2
    return 90
  fi
  if [ -z "${BACK:-}" ] || [ ! -d "$BACK" ]; then
    say "rollback: no backup dir available"
    return 1
  fi

  say "rollback: restoring published pointers/tables from $BACK"

  LATEST_DIR="$BASE/configs/awg1/latest"
  OLD_LINK="$(cat "$BACK/configs-latest-readlink.txt" 2>/dev/null || true)"
  OLD_REAL="$(cat "$BACK/configs-latest-realpath.txt" 2>/dev/null || true)"

  if [ -n "$OLD_LINK" ]; then
    rm -rf "$LATEST_DIR"
    ln -s "$OLD_LINK" "$LATEST_DIR"
    say "rollback: latest symlink restored to readlink target: $OLD_LINK"
  elif [ -n "$OLD_REAL" ] && [ -d "$OLD_REAL" ]; then
    rm -rf "$LATEST_DIR"
    ln -s "$OLD_REAL" "$LATEST_DIR"
    say "rollback: latest symlink restored to realpath: $OLD_REAL"
  else
    say "rollback WARN: no usable old latest target"
  fi

  for BN in \
    ok-awg1-strict-all-latest.tsv \
    ok-awg1-strict-foreign-latest.tsv \
    selected-awg1-latest.tsv
  do
    if [ -f "$BACK/$BN" ]; then
      cp "$BACK/$BN" "$BASE/cache/$BN"
      say "rollback: restored cache/$BN"
    fi
  done

  return 0
}

run_validate_current_pool() {
  if [ ! -x "$VALIDATE" ]; then
    say "ERROR: missing executable validator: $VALIDATE"
    write_status "REFRESH_FAILED_NO_VALIDATOR"
    return 1
  fi

  "$VALIDATE"
  VALIDATE_RC="$?"
  say "validate_current_pool_rc=$VALIDATE_RC"

  if [ "$VALIDATE_RC" -ne 0 ]; then
    write_status "REFRESH_FAILED_CURRENT_POOL_RETEST_FAILED"
    return "$VALIDATE_RC"
  fi

  return 0
}

run_body() {
  say "=== hmn-refresh-pool-safe start ==="
  say "mode=$MODE"
  say "log=$LOG"

  if [ "$MODE" = "selftest-ok" ]; then
    say "selftest-ok: returning 0"
    write_status "SELFTEST_OK"
    return 0
  fi

  if [ "$MODE" = "selftest-fail" ]; then
    say "selftest-fail: returning 42"
    write_status "SELFTEST_FAIL"
    return 42
  fi

  echo
  echo "=== lock ==="
  if ! mkdir "$LOCK" 2>/dev/null; then
    say "another refresh instance is already running: $LOCK"
    write_status "REFRESH_ALREADY_RUNNING"
    return 2
  fi

  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

  echo
  echo "=== pre-state ==="
  echo "active=$(cat "$STATE/active-slot" 2>/dev/null || echo none)"
  ip route show table 200
  ip route get 9.9.9.9 from 10.200.0.2 2>/dev/null || true

  echo
  echo "=== backup current published pointers/tables ==="
  BACK="$BACKUPDIR/refresh-safe-before-$TS-$$"

mkdir -p "$BACKUPDIR" || {
  echo "ERROR: cannot create backup root $BACKUPDIR" >&2
  exit 72
}

vm101_require_free_kb / 4096 || {
  echo "ERROR: insufficient root storage" >&2
  exit 72
}

vm101_require_free_kb /tmp 32768 || {
  echo "ERROR: insufficient temporary storage" >&2
  exit 73
}
  mkdir -p "$BACK"

  readlink "$BASE/configs/awg1/latest" > "$BACK/configs-latest-readlink.txt" 2>/dev/null || true
  readlink -f "$BASE/configs/awg1/latest" > "$BACK/configs-latest-realpath.txt" 2>/dev/null || true

  for F in \
    "$BASE/cache/ok-awg1-strict-all-latest.tsv" \
    "$BASE/cache/ok-awg1-strict-foreign-latest.tsv" \
    "$BASE/cache/selected-awg1-latest.tsv"
  do
    [ -f "$F" ] && cp "$F" "$BACK/$(basename "$F")"
  done

  say "backup=$BACK"
  echo "latest before: $(readlink -f "$BASE/configs/awg1/latest" 2>/dev/null || echo none)"

  echo
  echo "=== fresh download stage ==="
  DOWNLOAD_RC=1

  case "$MODE" in
    fresh-download)
      say "trying fresh HMN download via: $DOWNLOADER"

      if [ ! -x "$DOWNLOADER" ]; then
        say "ERROR: missing executable downloader: $DOWNLOADER"
        DOWNLOAD_RC=127
      else
        canonical_download_all_awg
        DOWNLOAD_RC="$?"
      fi

      say "fresh_download_rc=$DOWNLOAD_RC"
      record_download_rc "$DOWNLOAD_RC"
      ;;

    simulate-download-fail)
      say "simulating HMN fresh download failure"
      DOWNLOAD_RC=77
      record_download_rc "$DOWNLOAD_RC"
      ;;

    *)
      say "ERROR: unknown mode: $MODE"
      say "allowed modes: fresh-download | simulate-download-fail | selftest-ok | selftest-fail"
      write_status "REFRESH_FAILED_UNKNOWN_MODE"
      return 64
      ;;
  esac

  echo
  echo "=== validation decision ==="
  if [ "$DOWNLOAD_RC" -eq 0 ]; then
    say "fresh download OK"
    say "validate fresh/current latest pool through vpn_test"

    if run_validate_current_pool; then
      write_status "USING_FRESH_POOL_RETESTED"
      echo "fresh" > "$LAST_REFRESH_POOL_SOURCE"
      clear_retry_needed
    else
      RC="$?"
      say "fresh pool validation failed; rolling back to previous published pool"
      restore_backup || true
      write_status "REFRESH_FAILED_FRESH_POOL_ROLLED_BACK"
      echo "rollback-after-fresh-validation-failed" > "$LAST_REFRESH_POOL_SOURCE"
      set_retry_needed "fresh_download_ok_but_validation_failed"
      return "$RC"
    fi
  else
    say "fresh download failed/unavailable rc=$DOWNLOAD_RC"
    say "fallback: keep old configs/latest and validate current local pool through vpn_test"

    if run_validate_current_pool; then
      write_status "USING_OLD_POOL_RETESTED"
      echo "old-after-download-fail" > "$LAST_REFRESH_POOL_SOURCE"
      if [ "$MODE" = "fresh-download" ]; then
        set_retry_needed "fresh_download_failed_rc_$DOWNLOAD_RC"
      else
        say "simulate mode: retry-needed not set"
      fi
    else
      RC="$?"
      say "old/current pool validation failed; rolling back published tables"
      restore_backup || true
      write_status "REFRESH_FAILED_OLD_POOL_ROLLED_BACK"
      echo "rollback-after-old-validation-failed" > "$LAST_REFRESH_POOL_SOURCE"
      if [ "$MODE" = "fresh-download" ]; then
        set_retry_needed "fresh_download_failed_and_old_pool_validation_failed_rc_$DOWNLOAD_RC"
      fi
      return "$RC"
    fi
  fi

  echo
  echo "=== run manager once after validation ==="
  if [ -x "$MAN" ]; then
    echo "STEP_048M: legacy manager stage quarantined; skipping $MAN"
    MAN_RC=0
    # STEP_048M_QUARANTINED_LEGACY_MANAGER original:     HMN_ALLOW_MANAGER_DURING_REFRESH=1 "$MAN"
    MAN_RC="$?"
    say "manager_rc=$MAN_RC"
    if [ "$MAN_RC" -ne 0 ]; then
      write_status "REFRESH_DONE_BUT_MANAGER_FAILED"
      return "$MAN_RC"
    fi
  else
    say "WARN: manager missing/not executable: $MAN"
    write_status "REFRESH_DONE_BUT_MANAGER_MISSING"
    return 1
  fi

  echo
  echo "=== final state ==="
  echo "active=$(cat "$STATE/active-slot" 2>/dev/null || echo none)"
  ip route show table 200
  ip route get 9.9.9.9 from 10.200.0.2 2>/dev/null || true
  echo "latest after: $(readlink -f "$BASE/configs/awg1/latest" 2>/dev/null || echo none)"

  echo
  echo "=== refresh status ==="
  cat "$STATE/refresh-status" 2>/dev/null || true
  cat "$STATE/last-refresh-status-at" 2>/dev/null || true
  echo "pool_source=$(cat "$LAST_REFRESH_POOL_SOURCE" 2>/dev/null || echo unknown)"
  echo "last_fresh_download_rc=$(cat "$LAST_FRESH_DOWNLOAD_RC" 2>/dev/null || echo unknown)"
  echo "last_fresh_download_at=$(cat "$LAST_FRESH_DOWNLOAD_AT" 2>/dev/null || echo unknown)"
  [ -e "$RETRY_FLAG" ] && echo "retry_needed_at=$(cat "$RETRY_FLAG")" || echo "retry_needed=no"
  [ -e "$RETRY_REASON" ] && echo "retry_reason=$(cat "$RETRY_REASON")" || true

  echo
  echo "=== strict foreign head ==="
  head -n 12 "$BASE/cache/ok-awg1-strict-foreign-latest.tsv" 2>/dev/null || echo "missing"

  echo
  echo "=== selected cache ==="
  cat "$BASE/cache/selected-awg1-latest.tsv" 2>/dev/null || echo "missing"

  echo
  echo "=== bad file today ==="
  BAD="$STATE/bad-endpoints-$(date +%Y%m%d).txt"
  [ -s "$BAD" ] && cat "$BAD" || echo "bad file empty/not present"

  say "=== hmn-refresh-pool-safe done ==="
  return 0
}

(
  run_body
  echo "$?" > "$RCFILE"
) 2>&1 | tee "$LOG"

RC="$(cat "$RCFILE" 2>/dev/null || echo 99)"
rm -f "$RCFILE"

echo "wrapper_rc=$RC"
echo "wrapper_log=$LOG"

exit "$RC"
