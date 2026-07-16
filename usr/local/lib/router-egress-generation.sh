#!/bin/sh
# VM101 staged-generation schema and validator.
# This library is read-only with respect to production vpn1..vpn5.
# STEP_050M07R15B1_GENERATION_SCHEMA_VALIDATOR_R02_REBUILT

GENERATION_CONF="${GENERATION_CONF:-/etc/router-egress-generation.conf}"
GEN_LAST_REASON=""
GEN_LAST_DETAIL=""

gen_fail() {
    GEN_LAST_REASON="$1"
    GEN_LAST_DETAIL="${2:-}"
    return 1
}

gen_load_conf() {
    [ -r "$GENERATION_CONF" ] || gen_fail config_missing "$GENERATION_CONF" || return 1
    # shellcheck disable=SC1090
    . "$GENERATION_CONF"

    [ "${GENERATION_SCHEMA:-}" = "router-egress-generation-v1" ] ||
        gen_fail config_schema "${GENERATION_SCHEMA:-missing}" || return 1
    [ "${GENERATION_SLOT_COUNT:-}" = "5" ] ||
        gen_fail config_slot_count "${GENERATION_SLOT_COUNT:-missing}" || return 1
    [ "${GENERATION_ACTIVATION_ALLOWED:-}" = "false" ] ||
        gen_fail activation_must_be_disabled "${GENERATION_ACTIVATION_ALLOWED:-missing}" || return 1

    case "${GENERATION_TEST_MAX_AGE_SEC:-}" in
        ''|*[!0-9]*) gen_fail config_test_age "${GENERATION_TEST_MAX_AGE_SEC:-missing}"; return 1 ;;
    esac
    case "${GENERATION_CLOCK_FUTURE_TOLERANCE_SEC:-}" in
        ''|*[!0-9]*) gen_fail config_future_tolerance "${GENERATION_CLOCK_FUTURE_TOLERANCE_SEC:-missing}"; return 1 ;;
    esac
}

gen_kv_get() {
    key="$1"
    file="$2"
    sed -n "s/^${key}=//p" "$file" 2>/dev/null | tail -n1
}

gen_is_uint() {
    case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

gen_generation_id_valid() {
    value="$1"
    [ -n "$value" ] || return 1
    [ "${#value}" -le 64 ] || return 1
    printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

gen_endpoint_valid() {
    endpoint="$1"
    awk -v ep="$endpoint" '
        BEGIN {
            n = split(ep, a, ":")
            if (n != 2 || a[2] !~ /^[0-9]+$/ || a[2] < 1 || a[2] > 65535) exit 1
            m = split(a[1], o, ".")
            if (m != 4) exit 1
            for (i = 1; i <= 4; i++) {
                if (o[i] !~ /^[0-9]+$/ || o[i] < 0 || o[i] > 255) exit 1
            }
            exit 0
        }
    '
}

gen_manifest_safe() {
    manifest="$1"
    [ -s "$manifest" ] || return 1
    awk '
        NF < 2 { exit 1 }
        {
            path = $2
            sub(/^\*/, "", path)
            sub(/^\.\/+/, "", path)
            if (path == "" || path ~ /^\// || path ~ /(^|\/)\.\.(\/|$)/ || path == "manifest.sha256")
                exit 1
            count++
        }
        END { if (count != 10) exit 1 }
    ' "$manifest"
}

gen_endpoint_in_active_snapshot() {
    endpoint="$1"
    file="$2"
    awk -F '\t' -v ep="$endpoint" 'NR > 1 && $2 == ep { found=1 } END { exit found ? 0 : 1 }' "$file"
}

gen_endpoint_in_quarantine_snapshot() {
    endpoint="$1"
    file="$2"
    awk -F '\t' -v ep="$endpoint" 'NR > 1 && $5 == ep { found=1 } END { exit found ? 0 : 1 }' "$file"
}

gen_source_pair_present() {
    rank="$1"
    endpoint="$2"
    file="$3"
    awk -F '\t' -v r="$rank" -v ep="$endpoint" '
        NR > 1 && $1 == r && $4 == ep { found=1 }
        END { exit found ? 0 : 1 }
    ' "$file"
}

gen_config_endpoint() {
    file="$1"
    sed -n 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*//p' "$file" |
        head -n1 |
        tr -d '\r'
}

gen_validate_dir() {
    dir="$1"
    now_epoch="${2:-$(date +%s)}"
    GEN_LAST_REASON=""
    GEN_LAST_DETAIL=""

    gen_load_conf || return 1
    [ -d "$dir" ] || gen_fail generation_dir_missing "$dir" || return 1
    gen_is_uint "$now_epoch" || gen_fail now_epoch_invalid "$now_epoch" || return 1

    metadata="$dir/metadata.kv"
    candidates="$dir/candidates.tsv"
    source_pool="$dir/source-pool.tsv"
    active_snapshot="$dir/active-endpoints.tsv"
    quarantine_snapshot="$dir/quarantine-snapshot.tsv"
    manifest="$dir/manifest.sha256"

    for required in "$metadata" "$candidates" "$source_pool" "$active_snapshot" "$quarantine_snapshot" "$manifest"; do
        [ -f "$required" ] || gen_fail required_file_missing "$required" || return 1
    done
    [ -d "$dir/configs" ] || gen_fail configs_dir_missing "$dir/configs" || return 1

    gen_manifest_safe "$manifest" || gen_fail manifest_unsafe "$manifest" || return 1
    (
        cd "$dir" || exit 1
        sha256sum -c manifest.sha256 >/dev/null 2>&1
    ) || gen_fail manifest_sha256_failed "$manifest" || return 1

    generation_id="$(gen_kv_get generation_id "$metadata")"
    schema="$(gen_kv_get schema "$metadata")"
    status="$(gen_kv_get status "$metadata")"
    mode="$(gen_kv_get mode "$metadata")"
    slot_count="$(gen_kv_get slot_count "$metadata")"
    created_at_epoch="$(gen_kv_get created_at_epoch "$metadata")"
    source_pool_sha="$(gen_kv_get source_pool_sha256 "$metadata")"
    activation_allowed="$(gen_kv_get activation_allowed "$metadata")"

    [ "$schema" = "$GENERATION_SCHEMA" ] || gen_fail metadata_schema "$schema" || return 1
    [ "$status" = "STAGED" ] || gen_fail metadata_status "$status" || return 1
    [ "$mode" = "SHADOW" ] || gen_fail metadata_mode "$mode" || return 1
    [ "$slot_count" = "5" ] || gen_fail metadata_slot_count "$slot_count" || return 1
    [ "$activation_allowed" = "false" ] || gen_fail metadata_activation "$activation_allowed" || return 1
    gen_generation_id_valid "$generation_id" || gen_fail generation_id_invalid "$generation_id" || return 1
    [ "$(basename "$dir")" = "$generation_id" ] || gen_fail generation_id_directory_mismatch "$generation_id" || return 1
    gen_is_uint "$created_at_epoch" || gen_fail created_at_invalid "$created_at_epoch" || return 1

    actual_source_sha="$(sha256sum "$source_pool" | awk '{print $1}')"
    [ "$source_pool_sha" = "$actual_source_sha" ] ||
        gen_fail source_pool_sha256_mismatch "$source_pool_sha/$actual_source_sha" || return 1

    expected_header='slot	iface	table	endpoint	config_path	config_sha256	tested_at_epoch	test_result	source_rank'
    actual_header="$(head -n1 "$candidates")"
    [ "$actual_header" = "$expected_header" ] ||
        gen_fail candidates_header "$actual_header" || return 1

    [ "$(head -n1 "$source_pool")" = 'rank	avg_ms	file	endpoint	loss	config_path' ] ||
        gen_fail source_pool_header "$(head -n1 "$source_pool")" || return 1
    [ "$(head -n1 "$active_snapshot")" = 'iface	endpoint' ] ||
        gen_fail active_snapshot_header "$(head -n1 "$active_snapshot")" || return 1
    [ "$(head -n1 "$quarantine_snapshot")" = 'ts_epoch	ts_utc	egress	iface	endpoint	replacement	reason	pool_path	pool_mtime_epoch	source_step' ] ||
        gen_fail quarantine_snapshot_header "$(head -n1 "$quarantine_snapshot")" || return 1

    row_count="$(awk 'END { print NR - 1 }' "$candidates")"
    [ "$row_count" = "5" ] || gen_fail candidate_row_count "$row_count" || return 1

    endpoints_seen="/tmp/router-egress-generation-endpoints.$$"
    ranks_seen="/tmp/router-egress-generation-ranks.$$"
    : >"$endpoints_seen"
    : >"$ranks_seen"
    trap 'rm -f "$endpoints_seen" "$ranks_seen"' EXIT HUP INT TERM

    TAB="$(printf '\t')"
    line_no=0
    while IFS="$TAB" read -r slot iface table endpoint config_path config_sha tested_at test_result source_rank extra; do
        line_no=$((line_no + 1))
        [ "$line_no" -eq 1 ] && continue
        [ -z "$extra" ] || gen_fail candidate_extra_field "line_$line_no" || return 1

        case "$line_no" in
            2) expected_slot=egress1; expected_iface=vpn1; expected_table=201 ;;
            3) expected_slot=egress2; expected_iface=vpn2; expected_table=202 ;;
            4) expected_slot=egress3; expected_iface=vpn3; expected_table=203 ;;
            5) expected_slot=egress4; expected_iface=vpn4; expected_table=204 ;;
            6) expected_slot=egress5; expected_iface=vpn5; expected_table=205 ;;
            *) gen_fail candidate_unexpected_line "$line_no"; return 1 ;;
        esac

        [ "$slot" = "$expected_slot" ] || gen_fail slot_mapping "$slot/$expected_slot" || return 1
        [ "$iface" = "$expected_iface" ] || gen_fail iface_mapping "$iface/$expected_iface" || return 1
        [ "$table" = "$expected_table" ] || gen_fail table_mapping "$table/$expected_table" || return 1
        gen_endpoint_valid "$endpoint" || gen_fail endpoint_invalid "$endpoint" || return 1

        if grep -Fxq "$endpoint" "$endpoints_seen"; then
            gen_fail duplicate_endpoint "$endpoint"
            return 1
        fi
        printf '%s\n' "$endpoint" >>"$endpoints_seen"

        gen_is_uint "$source_rank" || gen_fail source_rank_invalid "$source_rank" || return 1
        [ "$source_rank" -gt 0 ] || gen_fail source_rank_zero "$source_rank" || return 1
        if grep -Fxq "$source_rank" "$ranks_seen"; then
            gen_fail duplicate_source_rank "$source_rank"
            return 1
        fi
        printf '%s\n' "$source_rank" >>"$ranks_seen"

        [ "$test_result" = "PASS" ] || gen_fail candidate_test_result "$slot/$test_result" || return 1
        gen_is_uint "$tested_at" || gen_fail tested_at_invalid "$slot/$tested_at" || return 1
        [ "$tested_at" -le $((now_epoch + GENERATION_CLOCK_FUTURE_TOLERANCE_SEC)) ] ||
            gen_fail tested_at_future "$slot/$tested_at" || return 1
        age=$((now_epoch - tested_at))
        [ "$age" -le "$GENERATION_TEST_MAX_AGE_SEC" ] ||
            gen_fail tested_at_stale "$slot/$age" || return 1

        [ "$config_path" = "configs/${slot}.conf" ] ||
            gen_fail config_path_contract "$slot/$config_path" || return 1
        config_file="$dir/$config_path"
        [ -f "$config_file" ] || gen_fail config_missing "$config_file" || return 1
        actual_config_sha="$(sha256sum "$config_file" | awk '{print $1}')"
        [ "$config_sha" = "$actual_config_sha" ] ||
            gen_fail config_sha256_mismatch "$slot/$config_sha/$actual_config_sha" || return 1
        config_endpoint="$(gen_config_endpoint "$config_file")"
        [ "$config_endpoint" = "$endpoint" ] ||
            gen_fail config_endpoint_mismatch "$slot/$config_endpoint/$endpoint" || return 1

        gen_source_pair_present "$source_rank" "$endpoint" "$source_pool" ||
            gen_fail source_pool_pair_missing "$slot/$source_rank/$endpoint" || return 1
        if gen_endpoint_in_active_snapshot "$endpoint" "$active_snapshot"; then
            gen_fail active_endpoint_reuse "$slot/$endpoint"
            return 1
        fi
        if gen_endpoint_in_quarantine_snapshot "$endpoint" "$quarantine_snapshot"; then
            gen_fail quarantined_endpoint "$slot/$endpoint"
            return 1
        fi
    done <"$candidates"

    trap - EXIT HUP INT TERM
    rm -f "$endpoints_seen" "$ranks_seen"

    GEN_LAST_REASON="ok"
    GEN_LAST_DETAIL="$generation_id"
    return 0
}

gen_fixture_manifest() {
    dir="$1"
    (
        cd "$dir" || exit 1
        sha256sum \
            metadata.kv \
            candidates.tsv \
            source-pool.tsv \
            active-endpoints.tsv \
            quarantine-snapshot.tsv \
            configs/egress1.conf \
            configs/egress2.conf \
            configs/egress3.conf \
            configs/egress4.conf \
            configs/egress5.conf \
            >manifest.sha256
    )
}

gen_fixture_valid() {
    dir="$1"
    now="$2"
    mkdir -p "$dir/configs" || return 1

    printf 'rank\tavg_ms\tfile\tendpoint\tloss\tconfig_path\n' >"$dir/source-pool.tsv"
    printf 'iface\tendpoint\nvpn9\t198.51.100.250:4999\n' >"$dir/active-endpoints.tsv"
    printf 'ts_epoch\tts_utc\tegress\tiface\tendpoint\treplacement\treason\tpool_path\tpool_mtime_epoch\tsource_step\n' >"$dir/quarantine-snapshot.tsv"

    n=1
    while [ "$n" -le 5 ]; do
        slot="egress$n"
        endpoint="203.0.113.$((10 + n)):41$(printf '%02d' "$n")"
        config="$dir/configs/${slot}.conf"
        cat >"$config" <<EOF
[Interface]
PrivateKey = fixture-private-$n
Address = 10.99.0.$n/32
[Peer]
PublicKey = fixture-public-$n
Endpoint = $endpoint
AllowedIPs = 0.0.0.0/0
EOF
        printf '%s\t10.%s\tfixture-%s\t%s\t0%%\t%s\n' \
            "$n" "$n" "$n" "$endpoint" "$config" >>"$dir/source-pool.tsv"
        n=$((n + 1))
    done

    source_sha="$(sha256sum "$dir/source-pool.tsv" | awk '{print $1}')"
    cat >"$dir/metadata.kv" <<EOF
schema=router-egress-generation-v1
generation_id=$(basename "$dir")
status=STAGED
mode=SHADOW
slot_count=5
created_at_epoch=$now
source_pool_sha256=$source_sha
activation_allowed=false
EOF

    printf 'slot\tiface\ttable\tendpoint\tconfig_path\tconfig_sha256\ttested_at_epoch\ttest_result\tsource_rank\n' >"$dir/candidates.tsv"
    n=1
    while [ "$n" -le 5 ]; do
        slot="egress$n"
        iface="vpn$n"
        table=$((200 + n))
        endpoint="203.0.113.$((10 + n)):41$(printf '%02d' "$n")"
        cfg_sha="$(sha256sum "$dir/configs/${slot}.conf" | awk '{print $1}')"
        printf '%s\t%s\t%s\t%s\tconfigs/%s.conf\t%s\t%s\tPASS\t%s\n' \
            "$slot" "$iface" "$table" "$endpoint" "$slot" "$cfg_sha" "$now" "$n" \
            >>"$dir/candidates.tsv"
        n=$((n + 1))
    done

    gen_fixture_manifest "$dir"
}

gen_expect_invalid() {
    case_name="$1"
    dir="$2"
    now="$3"
    expected="$4"
    if gen_validate_dir "$dir" "$now"; then
        printf 'SELFTEST_%s=FAIL_UNEXPECTED_PASS\n' "$case_name"
        return 1
    fi
    [ "$GEN_LAST_REASON" = "$expected" ] || {
        printf 'SELFTEST_%s=FAIL reason=%s expected=%s detail=%s\n' \
            "$case_name" "$GEN_LAST_REASON" "$expected" "$GEN_LAST_DETAIL"
        return 1
    }
    printf 'SELFTEST_%s=PASS reason=%s\n' "$case_name" "$GEN_LAST_REASON"
}

gen_selftest() {
    gen_load_conf || return 1
    root="/tmp/router-egress-generation-selftest.$$"
    now="$(date +%s)"
    rm -rf "$root"
    mkdir -p "$root" || return 1
    trap 'rm -rf "$root"' EXIT HUP INT TERM

    valid="$root/gen-valid"
    gen_fixture_valid "$valid" "$now" || return 1
    if gen_validate_dir "$valid" "$now"; then
        echo "SELFTEST_valid=PASS"
    else
        echo "SELFTEST_valid=FAIL reason=$GEN_LAST_REASON detail=$GEN_LAST_DETAIL"
        return 1
    fi

    duplicate="$root/gen-duplicate"
    cp -a "$valid" "$duplicate"
    sed -i "s/^generation_id=.*/generation_id=$(basename "$duplicate")/" "$duplicate/metadata.kv"
    sed -i '4s/203\.0\.113\.13:4103/203.0.113.12:4102/' "$duplicate/candidates.tsv"
    gen_fixture_manifest "$duplicate"
    gen_expect_invalid duplicate "$duplicate" "$now" duplicate_endpoint || return 1

    quarantined="$root/gen-quarantined"
    cp -a "$valid" "$quarantined"
    sed -i "s/^generation_id=.*/generation_id=$(basename "$quarantined")/" "$quarantined/metadata.kv"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$now" 2026-01-01T00:00:00Z egress2 vpn2 203.0.113.12:4102 none fixture \
        "$quarantined/source-pool.tsv" "$now" selftest \
        >>"$quarantined/quarantine-snapshot.tsv"
    gen_fixture_manifest "$quarantined"
    gen_expect_invalid quarantined "$quarantined" "$now" quarantined_endpoint || return 1

    active="$root/gen-active"
    cp -a "$valid" "$active"
    sed -i "s/^generation_id=.*/generation_id=$(basename "$active")/" "$active/metadata.kv"
    printf 'vpn8\t203.0.113.13:4103\n' >>"$active/active-endpoints.tsv"
    gen_fixture_manifest "$active"
    gen_expect_invalid active "$active" "$now" active_endpoint_reuse || return 1

    missing="$root/gen-missing"
    cp -a "$valid" "$missing"
    sed -i "s/^generation_id=.*/generation_id=$(basename "$missing")/" "$missing/metadata.kv"
    sed -i '$d' "$missing/candidates.tsv"
    gen_fixture_manifest "$missing"
    gen_expect_invalid missing "$missing" "$now" candidate_row_count || return 1

    stale="$root/gen-stale"
    cp -a "$valid" "$stale"
    sed -i "s/^generation_id=.*/generation_id=$(basename "$stale")/" "$stale/metadata.kv"
    stale_epoch=$((now - GENERATION_TEST_MAX_AGE_SEC - 1))
    awk -F '\t' -v OFS='\t' -v v="$stale_epoch" 'NR == 2 {$7=v} {print}' \
        "$stale/candidates.tsv" >"$stale/candidates.new"
    mv "$stale/candidates.new" "$stale/candidates.tsv"
    gen_fixture_manifest "$stale"
    gen_expect_invalid stale "$stale" "$now" tested_at_stale || return 1

    config_mismatch="$root/gen-config-mismatch"
    cp -a "$valid" "$config_mismatch"
    sed -i "s/^generation_id=.*/generation_id=$(basename "$config_mismatch")/" "$config_mismatch/metadata.kv"
    printf '\n# changed\n' >>"$config_mismatch/configs/egress4.conf"
    gen_fixture_manifest "$config_mismatch"
    gen_expect_invalid config_mismatch "$config_mismatch" "$now" config_sha256_mismatch || return 1

    malformed="$root/gen-malformed"
    cp -a "$valid" "$malformed"
    sed -i "s/^generation_id=.*/generation_id=$(basename "$malformed")/" "$malformed/metadata.kv"
    sed -i '3s/203\.0\.113\.12:4102/999.0.0.1:99999/' "$malformed/candidates.tsv"
    gen_fixture_manifest "$malformed"
    gen_expect_invalid malformed "$malformed" "$now" endpoint_invalid || return 1

    manifest_bad="$root/gen-manifest-bad"
    cp -a "$valid" "$manifest_bad"
    sed -i "s/^generation_id=.*/generation_id=$(basename "$manifest_bad")/" "$manifest_bad/metadata.kv"
    printf '\n# tamper\n' >>"$manifest_bad/metadata.kv"
    gen_expect_invalid manifest_bad "$manifest_bad" "$now" manifest_sha256_failed || return 1

    trap - EXIT HUP INT TERM
    rm -rf "$root"
    echo "RESULT=PASS_ROUTER_EGRESS_GENERATION_VALIDATOR_SELFTEST"
}
