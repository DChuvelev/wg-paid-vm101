#!/bin/sh
# Deterministic provider tunnel identity; emits only SHA256, never secret fields.
set -eu
CONF="${1:-}"
[ -r "$CONF" ] || { echo "ERROR=config_missing:$CONF" >&2; exit 2; }

value() {
    key="$1"
    awk -v key="$key" '$0 ~ "^[[:space:]]*" key "[[:space:]]*=" {sub(/^[^=]*=[[:space:]]*/,"",$0); sub(/[[:space:]]*$/, "", $0); print; exit}' "$CONF"
}
TMP="$(mktemp /tmp/hmn-identity.XXXXXX)" || exit 70
trap 'rm -f "$TMP"' EXIT HUP INT TERM
for key in PrivateKey Address Jc Jmin Jmax S1 S2 H1 H2 H3 H4 PublicKey Endpoint AllowedIPs PersistentKeepalive; do
    v="$(value "$key")"
    case "$key" in
        PrivateKey|Address|Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4|PublicKey|Endpoint)
            [ -n "$v" ] || { echo "ERROR=identity_field_missing:$key" >&2; exit 3; } ;;
    esac
    printf '%s=%s\n' "$key" "$v" >>"$TMP"
done
sha256sum "$TMP" | awk '{print $1}'
