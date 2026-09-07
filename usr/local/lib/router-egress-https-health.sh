#!/bin/sh
# Shared VM101 HTTPS 2/3 health oracle. BusyBox ash compatible.
set -u

VM101_CONF="${VM101_CONF:-/etc/router-egress-vm101.conf}"
[ -r "$VM101_CONF" ] && . "$VM101_CONF"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
CONNECT_TIMEOUT="${HTTPS_HEALTH_CONNECT_TIMEOUT_SEC:-3}"
MAX_TIME="${HTTPS_HEALTH_MAX_TIME_SEC:-6}"
SUCCESS_QUORUM="${HTTPS_HEALTH_SUCCESS_QUORUM:-2}"
IFACE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --iface) [ "$#" -ge 2 ] || exit 2; IFACE="$2"; shift 2 ;;
        *) echo "ERROR=unsupported_argument:$1" >&2; exit 2 ;;
    esac
done
[ -n "$IFACE" ] || { echo 'ERROR=iface_required' >&2; exit 2; }
case "$CONNECT_TIMEOUT:$MAX_TIME:$SUCCESS_QUORUM" in *[!0-9:]*) echo 'ERROR=invalid_https_oracle_config' >&2; exit 2;; esac
[ -x "$CURL_BIN" ] || { echo "ERROR=curl_missing:$CURL_BIN" >&2; exit 2; }

TMP="$(mktemp -d /tmp/router-egress-https.XXXXXX)" || exit 70
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

probe() {
    name="$1"; url="$2"; rc=0
    out="$(
        "$CURL_BIN" -4 --http1.1 \
          --interface "$IFACE" \
          --connect-timeout "$CONNECT_TIMEOUT" \
          --max-time "$MAX_TIME" \
          --silent --show-error \
          --output /dev/null \
          --write-out '%{http_code},%{time_namelookup},%{time_connect},%{time_appconnect},%{time_starttransfer},%{time_total},%{remote_ip}' \
          "$url" 2>/dev/null
    )" || rc=$?
    [ -n "$out" ] || out='000,0,0,0,0,0,-'
    printf '%s,%s\n' "$rc" "$out" >"$TMP/$name"
}

probe google 'https://www.google.com/generate_204' &
probe cloudflare 'https://www.cloudflare.com/cdn-cgi/trace' &
probe mozilla 'https://detectportal.firefox.com/canonical.html' &
wait || true

ok_one() {
    line="$(cat "$TMP/$1" 2>/dev/null || true)"
    rc="${line%%,*}"
    rest="${line#*,}"
    http="${rest%%,*}"
    [ "$rc" = 0 ] && [ -n "$http" ] && [ "$http" != 000 ]
}
q=0
for name in google cloudflare mozilla; do ok_one "$name" && q=$((q+1)); done

printf 'schema=router-egress-https-health-v1 iface=%s quorum=%s/3 google=%s cloudflare=%s mozilla=%s\n' \
    "$IFACE" "$q" \
    "$(cat "$TMP/google" 2>/dev/null || echo '1,000,0,0,0,0,0,-')" \
    "$(cat "$TMP/cloudflare" 2>/dev/null || echo '1,000,0,0,0,0,0,-')" \
    "$(cat "$TMP/mozilla" 2>/dev/null || echo '1,000,0,0,0,0,0,-')"
[ "$q" -ge "$SUCCESS_QUORUM" ]
