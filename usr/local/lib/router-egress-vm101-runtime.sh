#!/bin/sh

# Canonical VM101 BusyBox-compatible runtime helpers.
# Functions are read-only unless explicitly stated otherwise.

vm101_runtime_cli() {
  if command -v amneziawg >/dev/null 2>&1; then
    command -v amneziawg
    return 0
  fi

  return 1
}

vm101_runtime_peer_line() {
  iface="$1"

  cli="$(
    vm101_runtime_cli ||
    true
  )"

  [ -n "$cli" ] || return 1

  "$cli" show "$iface" dump 2>/dev/null |
    sed -n '2p'
}

vm101_runtime_endpoint() {
  iface="$1"

  line="$(
    vm101_runtime_peer_line "$iface" ||
    true
  )"

  [ -n "$line" ] || return 1

  endpoint="$(
    printf '%s\n' "$line" |
      cut -f3
  )"

  case "$endpoint" in
    ""|"(none)")
      return 1
      ;;
  esac

  printf '%s\n' "$endpoint"
}

vm101_strict_iface() {
  iface="$1"
  attempts="${2:-3}"
  wait_seconds="${3:-1}"
  attempt=1

  while [ "$attempt" -le "$attempts" ]; do
    if ping \
      -I "$iface" \
      -c 1 \
      -W 3 \
      1.1.1.1 \
      >/dev/null 2>&1
    then
      return 0
    fi

    attempt=$((attempt + 1))

    if [ "$attempt" -le "$attempts" ]; then
      sleep "$wait_seconds"
    fi
  done

  return 1
}

vm101_healthy_bootstrap_iface() {
  candidate="$(
    ip -4 route show table 200 2>/dev/null |
      sed -n \
        's/^default dev \(vpn[1-5]\)\([[:space:]].*\)\{0,1\}$/\1/p' |
      head -n1
  )"

  if [ -n "$candidate" ] &&
     vm101_strict_iface "$candidate" 1 0
  then
    printf '%s\n' "$candidate"
    return 0
  fi

  for candidate in vpn1 vpn2 vpn3 vpn4 vpn5; do
    if ip link show dev "$candidate" >/dev/null 2>&1 &&
       vm101_strict_iface "$candidate" 1 0
    then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

vm101_routes_201_205_ok() {
  for table in 201 202 203 204 205; do
    ip route show table "$table" 2>/dev/null |
      grep -q '^default ' ||
      return 1
  done

  return 0
}

vm101_table200_default_present() {
  ip route show table 200 2>/dev/null |
    grep -q '^default '
}

vm101_storage_kb() {
  path="$1"

  df -Pk "$path" 2>/dev/null |
    awk 'NR == 2 {
      print "total_kb=" $2
      print "used_kb=" $3
      print "available_kb=" $4
    }'
}

vm101_require_free_kb() {
  path="$1"
  required_kb="$2"

  available="$(
    df -Pk "$path" 2>/dev/null |
      awk 'NR == 2 {print $4}'
  )"

  case "$available:$required_kb" in
    *[!0-9:]*|'')
      return 2
      ;;
  esac

  [ "$available" -ge "$required_kb" ]
}

vm101_file_sha256() {
  path="$1"

  sha256sum "$path" 2>/dev/null |
    sed 's/[[:space:]].*$//'
}
