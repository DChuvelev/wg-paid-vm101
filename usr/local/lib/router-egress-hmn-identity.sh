#!/bin/sh
# Canonical provider tunnel identity; endpoint changes do not create a second tunnel identity.
# Emits only SHA256 and never secret fields.
set -eu
CONF="${1:-}"
[ -r "$CONF" ] || { echo "ERROR=config_missing:$CONF" >&2; exit 2; }
value() {
    key="$1"
    awk -v key="$key" '$0 ~ "^[[:space:]]*" key "[[:space:]]*=" {sub(/^[^=]*=[[:space:]]*/,"",$0); sub(/[[:space:]]*$/, "", $0); print; exit}' "$CONF"
}
TMP="$(mktemp /tmp/hmn-identity.XXXXXX)" || exit 70
trap 'rm -f "$TMP"' EXIT HUP INT TERM
# PrivateKey + tunnel address + peer PublicKey identify the cryptographic client/peer
# relation. Endpoint and AWG transport parameters are mutable delivery metadata and
# MUST NOT permit the same underlying tunnel to be live twice.
for key in PrivateKey Address PublicKey; do
    v="$(value "$key")"
    [ -n "$v" ] || { echo "ERROR=identity_field_missing:$key" >&2; exit 3; }
    printf '%s=%s\n' "$key" "$v" >>"$TMP"
done
sha256sum "$TMP" | awk '{print $1}'
