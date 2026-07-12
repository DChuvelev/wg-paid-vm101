#!/bin/sh
set -u

REGISTRY="${1:-/etc/router-egress-slots/slots.conf}"
STATE_DIR="/run/router-egress-slots"
STATUS_JSON="$STATE_DIR/status.json"
STATUS_ENV="$STATE_DIR/status.env"
ACTIVE_FILE="$STATE_DIR/slots.active"
NFT_CACHE="$STATE_DIR/nft.ruleset"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"

mkdir -p "$STATE_DIR"

json_escape() {
  printf "%s" "$1" | sed "s/\\\\/\\\\\\\\/g; s/\"/\\\\\"/g"
}

: > "$STATUS_ENV"

if [ ! -f "$REGISTRY" ]; then
  echo "registry_missing=1" >> "$STATUS_ENV"
  cat > "$STATUS_JSON" <<JSON
{
  "schema": "router-egress-slots-status-v1",
  "generated_at_utc": "$(json_escape "$NOW")",
  "source_registry": "$(json_escape "$REGISTRY")",
  "active_probe": false,
  "manager_invoked": false,
  "error": "registry_missing",
  "slots": []
}
JSON
  cat "$STATUS_JSON"
  exit 1
fi

grep -Ev "^[[:space:]]*(#|$)" "$REGISTRY" > "$ACTIVE_FILE" 2>/dev/null || true
nft -a list ruleset > "$NFT_CACHE" 2>/dev/null || true

{
  echo "{"
  echo "  \"schema\": \"router-egress-slots-status-v1\","
  echo "  \"generated_at_utc\": \"$(json_escape "$NOW")\","
  echo "  \"source_registry\": \"$(json_escape "$REGISTRY")\","
  echo "  \"active_probe\": false,"
  echo "  \"manager_invoked\": false,"
  echo "  \"slots\": ["

  first=1

  while read -r slot_code selector_class fwmark table_id iface provider_type manager_id enabled allocation_weight label rest; do
    [ -n "${slot_code:-}" ] || continue

    mark_hex="$(printf "%s" "$fwmark" | sed -E "s/^0x//I")"

    ip link show "$iface" >/dev/null 2>&1
    iface_exists_rc=$?

    ip link show "$iface" 2>/dev/null | grep -Eq "<[^>]*UP|state UP|,UP,"
    iface_up_rc=$?

    ip rule show | grep -qi "fwmark $fwmark lookup $table_id"
    fwmark_rule_rc=$?

    ip route show table "$table_id" 2>/dev/null | grep -q "default dev $iface"
    table_route_rc=$?

    grep -Ei "ip dscp[[:space:]]+$selector_class.*meta mark set[[:space:]]+0x0*$mark_hex" "$NFT_CACHE" >/dev/null 2>&1
    mapper_rule_rc=$?

    grep -Ei "meta mark[[:space:]]+0x0*$mark_hex.*ip dscp[[:space:]]+$selector_class.*dscp set cs0" "$NFT_CACHE" >/dev/null 2>&1
    clear_rule_rc=$?

    status="healthy"
    reason="ok"

    if [ "$enabled" != "1" ]; then
      status="disabled"
      reason="slot_disabled"
    elif [ "$iface_exists_rc" -ne 0 ]; then
      status="down"
      reason="interface_missing"
    elif [ "$iface_up_rc" -ne 0 ]; then
      status="degraded"
      reason="interface_not_up"
    elif [ "$fwmark_rule_rc" -ne 0 ]; then
      status="down"
      reason="fwmark_rule_missing"
    elif [ "$table_route_rc" -ne 0 ]; then
      status="down"
      reason="table_route_missing"
    elif [ "$mapper_rule_rc" -ne 0 ]; then
      status="down"
      reason="mapper_rule_missing"
    elif [ "$clear_rule_rc" -ne 0 ]; then
      status="degraded"
      reason="clear_rule_missing"
    fi

    printf "%s_status=%s\n" "$slot_code" "$status" >> "$STATUS_ENV"
    printf "%s_reason=%s\n" "$slot_code" "$reason" >> "$STATUS_ENV"
    printf "%s_selector_class=%s\n" "$slot_code" "$selector_class" >> "$STATUS_ENV"
    printf "%s_fwmark=%s\n" "$slot_code" "$fwmark" >> "$STATUS_ENV"
    printf "%s_provider_type=%s\n" "$slot_code" "$provider_type" >> "$STATUS_ENV"
    printf "%s_iface_exists_rc=%s\n" "$slot_code" "$iface_exists_rc" >> "$STATUS_ENV"
    printf "%s_iface_up_rc=%s\n" "$slot_code" "$iface_up_rc" >> "$STATUS_ENV"
    printf "%s_fwmark_rule_rc=%s\n" "$slot_code" "$fwmark_rule_rc" >> "$STATUS_ENV"
    printf "%s_table_route_rc=%s\n" "$slot_code" "$table_route_rc" >> "$STATUS_ENV"
    printf "%s_mapper_rule_rc=%s\n" "$slot_code" "$mapper_rule_rc" >> "$STATUS_ENV"
    printf "%s_clear_rule_rc=%s\n" "$slot_code" "$clear_rule_rc" >> "$STATUS_ENV"

    if [ "$first" -eq 0 ]; then
      echo "    ,"
    fi
    first=0

    esc_slot="$(json_escape "$slot_code")"
    esc_class="$(json_escape "$selector_class")"
    esc_iface="$(json_escape "$iface")"
    esc_provider="$(json_escape "$provider_type")"
    esc_manager="$(json_escape "$manager_id")"
    esc_label="$(json_escape "$label")"
    esc_status="$(json_escape "$status")"
    esc_reason="$(json_escape "$reason")"

    cat <<JSON
    {
      "slot_code": "$esc_slot",
      "selector_class": "$esc_class",
      "fwmark": "$fwmark",
      "table_id": $table_id,
      "interface_name": "$esc_iface",
      "provider_type": "$esc_provider",
      "manager_id": "$esc_manager",
      "enabled": $enabled,
      "allocation_weight": $allocation_weight,
      "label": "$esc_label",
      "status": "$esc_status",
      "reason": "$esc_reason",
      "checks": {
        "iface_exists_rc": $iface_exists_rc,
        "iface_up_rc": $iface_up_rc,
        "fwmark_rule_rc": $fwmark_rule_rc,
        "table_route_rc": $table_route_rc,
        "mapper_rule_rc": $mapper_rule_rc,
        "clear_rule_rc": $clear_rule_rc
      }
    }
JSON

  done < "$ACTIVE_FILE"

  echo "  ]"
  echo "}"
} > "$STATUS_JSON.tmp"

mv "$STATUS_JSON.tmp" "$STATUS_JSON"
cat "$STATUS_JSON"
