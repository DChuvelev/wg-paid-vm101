#!/bin/sh
set -u

CONF="${EMERGENCY_DECISION_CONF:-/etc/router-egress-emergency-decision.conf}"
[ -r "$CONF" ] && . "$CONF"

INTERVAL="${EMERGENCY_DECISION_INTERVAL_SECONDS:-60}"
RUNNER="${EMERGENCY_DECISION_RUNNER:-/usr/local/sbin/router-egress-emergency-refresh.sh}"
LOG="${EMERGENCY_DECISION_LOG_OVERRIDE:-${EMERGENCY_DECISION_LOG:-/var/log/router-egress-emergency-decision.log}}"
STATE="${EMERGENCY_DECISION_STATE_OVERRIDE:-${EMERGENCY_DECISION_STATE:-/var/lib/router-egress-recovery/emergency-decision-last.json}}"
COMMIT="${EMERGENCY_DECISION_COMMIT:-false}"
DIRECT="${EMERGENCY_DECISION_DIRECT_FAILOPEN:-false}"

mode="once"
quiet=false

for arg in "$@"; do
  case "$arg" in
    --once)
      mode="once"
      ;;
    --loop)
      mode="loop"
      ;;
    --quiet)
      quiet=true
      ;;
    --dry-run)
      mode="once"
      ;;
  esac
done

json_s() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

emit_fallback() {
  decision="$1"
  reason="$2"
  echo "{"
  echo "  \"schema\": \"router-egress-emergency-decision-hook-v1\","
  echo "  \"decision\": \"$(json_s "$decision")\","
  echo "  \"reason\": \"$(json_s "$reason")\","
  echo "  \"commit_allowed\": false,"
  echo "  \"direct_failopen_allowed\": false,"
  echo "  \"runner\": \"$(json_s "$RUNNER")\""
  echo "}"
}

run_once() {
  tmp="/tmp/router-egress-emergency-decision.$$.json"
  err="/tmp/router-egress-emergency-decision.$$.err"

  mkdir -p "$(dirname "$LOG")" "$(dirname "$STATE")" 2>/dev/null || true

  if [ "$COMMIT" = "true" ] || [ "$DIRECT" = "true" ]; then
    emit_fallback "unsafe_config_refused" "dry_run_hook_refuses_commit_or_direct_configuration" > "$tmp"
    rc=0
  elif [ ! -x "$RUNNER" ]; then
    emit_fallback "runner_missing" "configured_runner_not_executable" > "$tmp"
    rc=0
  else
    "$RUNNER" --dry-run > "$tmp" 2> "$err"
    rc=$?
  fi

  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
  one_line="$(tr '\n' ' ' < "$tmp" 2>/dev/null | sed 's/[[:space:]][[:space:]]*/ /g')"
  printf '%s rc=%s %s\n' "$ts" "$rc" "$one_line" >> "$LOG" 2>/dev/null || true

  cp "$tmp" "${STATE}.tmp" 2>/dev/null && mv "${STATE}.tmp" "$STATE" 2>/dev/null || true

  if [ "$quiet" != "true" ]; then
    cat "$tmp" 2>/dev/null || true
    if [ -s "$err" ]; then
      cat "$err" >&2 2>/dev/null || true
    fi
  fi

  rm -f "$tmp" "$err" 2>/dev/null || true
  return "$rc"
}

if [ "$mode" = "loop" ]; then
  while true; do
    quiet=true run_once >/dev/null 2>&1 || true
    sleep "$INTERVAL"
  done
fi

run_once
