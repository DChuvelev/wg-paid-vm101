#!/bin/sh
set -eu
umask 077

GIT_DIR="/root/.vm101-source.git"
WORK_TREE="/"
BRANCH="main"
REMOTE="origin"

MODE="${1:---check}"
MESSAGE="${2:-}"

BASE="/tmp/router-vm101-git-publish.$$"
CURRENT="${BASE}.current"
TRACKED="${BASE}.tracked"
MANAGED="${BASE}.managed"
STAGED="${BASE}.staged"
SECRET_MATCHES="${BASE}.secrets"
REVIEW_MATCHES="${BASE}.review"
TMP_INDEX="${BASE}.index"

cleanup() {
    rm -f \
        "$CURRENT" \
        "$TRACKED" \
        "$MANAGED" \
        "$STAGED" \
        "$SECRET_MATCHES" \
        "$REVIEW_MATCHES" \
        "$TMP_INDEX" \
        "${TMP_INDEX}.lock"
}

trap cleanup EXIT INT TERM

log() {
    echo ">>> [vm101-git] $*"
}

git_root() {
    git \
        -C "$WORK_TREE" \
        --git-dir="$GIT_DIR" \
        --work-tree="$WORK_TREE" \
        "$@"
}

git_meta() {
    git \
        --git-dir="$GIT_DIR" \
        "$@"
}

add_matches() {
    for PATHNAME in "$@"; do
        if [ ! -f "$PATHNAME" ] && [ ! -L "$PATHNAME" ]; then
            continue
        fi

        case "$PATHNAME" in
            *.bak|*.bak.*|*.before-*|*.before_*|\
            *.core-step*|*.orig|*.rej|*~|\
            *.swp|*.tmp|*.tmp.*)
                continue
                ;;
        esac

        printf '%s\n' "${PATHNAME#/}" >> "$CURRENT"
    done
}

validate_path() {
    RELATIVE="$1"

    case "$RELATIVE" in
        usr/local/bin/router-*|\
        usr/local/sbin/router-*|\
        usr/local/lib/router-*|\
        etc/init.d/router-*|\
        root/hmn/hmn-*.sh|\
        etc/nftables.d/*wg*.nft|\
        etc/nftables.d/*router*.nft|\
        etc/config/router_*|\
        etc/config/wgpay*|\
        etc/rc.local|\
        etc/crontabs/root)
            ;;
        *)
            echo "STOP_UNEXPECTED_MANAGED_PATH=$RELATIVE"
            exit 1
            ;;
    esac

    case "$RELATIVE" in
        .ssh/*|\
        */.ssh/*|\
        *hmn.env*|\
        root/hmn/configs/*|\
        root/hmn/cache/*|\
        root/hmn/state/*|\
        root/hmn/logs/*|\
        root/hmn/runs/*|\
        root/hmn/backups/*)
            echo "STOP_FORBIDDEN_PATH=$RELATIVE"
            exit 1
            ;;
    esac
}

case "$MODE" in
    --check|--publish)
        ;;
    *)
        echo "USAGE: $0 --check"
        echo "       $0 --publish [commit-message]"
        exit 2
        ;;
esac

: > "$CURRENT"
: > "$TRACKED"
: > "$MANAGED"
: > "$STAGED"
: > "$SECRET_MATCHES"
: > "$REVIEW_MATCHES"

log "precheck"

command -v git >/dev/null 2>&1
test -d "$GIT_DIR"
test -f "$GIT_DIR/config"
test -f "$GIT_DIR/HEAD"

CURRENT_BRANCH="$(git_root symbolic-ref --short HEAD)"
REMOTE_URL="$(git_meta remote get-url "$REMOTE")"
LOCAL_HEAD="$(git_meta rev-parse HEAD)"

echo "MODE=$MODE"
echo "GIT_DIR=$GIT_DIR"
echo "WORK_TREE=$WORK_TREE"
echo "BRANCH=$CURRENT_BRANCH"
echo "REMOTE_URL=$REMOTE_URL"
echo "LOCAL_HEAD=$LOCAL_HEAD"

test "$CURRENT_BRANCH" = "$BRANCH"

log "verify remote main"

REMOTE_HEAD="$(
    git \
        -c protocol.version=0 \
        --git-dir="$GIT_DIR" \
        ls-remote \
        "$REMOTE" \
        "refs/heads/$BRANCH" |
    awk '{print $1}'
)"

echo "REMOTE_HEAD=$REMOTE_HEAD"

if [ -z "$REMOTE_HEAD" ]; then
    echo "STOP_REMOTE_BRANCH_MISSING=$BRANCH"
    exit 1
fi

if [ "$REMOTE_HEAD" != "$LOCAL_HEAD" ]; then
    echo "STOP_LOCAL_REMOTE_DIVERGED=true"
    echo "LOCAL_HEAD=$LOCAL_HEAD"
    echo "REMOTE_HEAD=$REMOTE_HEAD"
    exit 1
fi

log "build current project allowlist"

add_matches \
    /usr/local/bin/router-* \
    /usr/local/sbin/router-* \
    /usr/local/lib/router-* \
    /etc/init.d/router-* \
    /root/hmn/hmn-*.sh \
    /etc/nftables.d/*wg*.nft \
    /etc/nftables.d/*router*.nft \
    /etc/config/router_* \
    /etc/config/wgpay*

if [ -f /etc/rc.local ] &&
   grep -Eq 'router-|hmn-|wgpay|wg_paid|vpn[1-5]' /etc/rc.local
then
    add_matches /etc/rc.local
fi

# Активный root crontab входит в управляемое дерево явно.
add_matches /etc/crontabs/root

sort -u "$CURRENT" -o "$CURRENT"

log "read paths already tracked by git"

git_root \
    ls-tree \
    -r \
    --full-tree \
    --name-only \
    HEAD \
    > "$TRACKED"

sort -u "$TRACKED" -o "$TRACKED"

# Объединяем актуальные разрешённые файлы и уже tracked-файлы.
# Благодаря этому Git сможет фиксировать и удаления.
sort -u "$CURRENT" "$TRACKED" > "$MANAGED"

CURRENT_COUNT="$(awk 'END {print NR + 0}' "$CURRENT")"
TRACKED_COUNT="$(awk 'END {print NR + 0}' "$TRACKED")"
MANAGED_COUNT="$(awk 'END {print NR + 0}' "$MANAGED")"

echo "CURRENT_ALLOWED_COUNT=$CURRENT_COUNT"
echo "TRACKED_COUNT=$TRACKED_COUNT"
echo "MANAGED_UNION_COUNT=$MANAGED_COUNT"

log "strict path validation"

while IFS= read -r RELATIVE; do
    [ -n "$RELATIVE" ] || continue
    validate_path "$RELATIVE"
done < "$MANAGED"

echo "STRICT_PATH_VALIDATION=true"

log "show tracked files now missing from vm101"

DELETED_COUNT=0

while IFS= read -r RELATIVE; do
    [ -n "$RELATIVE" ] || continue

    if [ ! -f "/$RELATIVE" ] && [ ! -L "/$RELATIVE" ]; then
        echo "TRACKED_PATH_MISSING=$RELATIVE"
        DELETED_COUNT=$((DELETED_COUNT + 1))
    fi
done < "$TRACKED"

echo "TRACKED_PATH_MISSING_COUNT=$DELETED_COUNT"

log "build simulated git index"

GIT_INDEX_FILE="$TMP_INDEX"
export GIT_INDEX_FILE

git_root read-tree HEAD

git_root \
    add \
    -A \
    --pathspec-from-file="$MANAGED"

git_root \
    diff \
    --cached \
    --name-only \
    > "$STAGED"

STAGED_COUNT="$(awk 'END {print NR + 0}' "$STAGED")"

echo "STAGED_CHANGE_COUNT=$STAGED_COUNT"

if [ "$STAGED_COUNT" -gt 0 ]; then
    echo "=== STAGED PATHS ==="
    cat "$STAGED"
else
    echo "STAGED_PATHS=NONE"
fi

log "validate simulated staged paths"

while IFS= read -r RELATIVE; do
    [ -n "$RELATIVE" ] || continue
    validate_path "$RELATIVE"
done < "$STAGED"

echo "STAGED_PATH_VALIDATION=true"

TREE_SHA="$(git_root write-tree)"

echo "SIMULATED_TREE_SHA=$TREE_SHA"

TREE_FILE_COUNT="$(
    git_root \
        ls-tree \
        -r \
        --full-tree \
        --name-only \
        "$TREE_SHA" |
    awk 'END {print NR + 0}'
)"

echo "SIMULATED_TREE_FILE_COUNT=$TREE_FILE_COUNT"

log "high-confidence secret scan of simulated tree"

set +e

git_meta \
    grep \
    -I \
    -l \
    -E \
    -e 'BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY' \
    -e '(PrivateKey|PresharedKey)[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{40,}' \
    -e 'Authorization:[[:space:]]*(Bearer|Basic)[[:space:]]+[A-Za-z0-9+/_.=-]{12,}' \
    -e '(PASSWORD|PASSWD|TOKEN|SECRET|ACCESS_CODE|API_KEY)[[:space:]]*=[[:space:]]*[^$[:space:]]{12,}' \
    "$TREE_SHA" -- \
    > "$SECRET_MATCHES" 2>/dev/null

SECRET_RC=$?

set -e

case "$SECRET_RC" in
    0)
        echo "STOP_POSSIBLE_SECRET_FOUND=true"
        echo "=== POSSIBLE SECRET FILES ==="
        cat "$SECRET_MATCHES"
        exit 1
        ;;
    1)
        echo "HIGH_CONFIDENCE_SECRET_MATCHES=0"
        ;;
    *)
        echo "STOP_SECRET_SCAN_ERROR_RC=$SECRET_RC"
        exit 1
        ;;
esac

log "keyword review scan"

set +e

git_meta \
    grep \
    -I \
    -l \
    -E \
    -e 'private[_-]?key' \
    -e 'preshared[_-]?key' \
    -e 'password' \
    -e 'passwd' \
    -e 'token' \
    -e 'secret' \
    -e 'access[_-]?code' \
    -e 'api[_-]?key' \
    -e 'credential' \
    "$TREE_SHA" -- \
    > "$REVIEW_MATCHES" 2>/dev/null

REVIEW_RC=$?

set -e

case "$REVIEW_RC" in
    0)
        echo "=== FILES REQUIRING KEYWORD REVIEW ==="
        cat "$REVIEW_MATCHES"
        ;;
    1)
        echo "KEYWORD_REVIEW_FILES=NONE"
        ;;
    *)
        echo "STOP_KEYWORD_SCAN_ERROR_RC=$REVIEW_RC"
        exit 1
        ;;
esac

if [ "$MODE" = "--check" ]; then
    echo
    echo "RESULT=PASS_VM101_GIT_PUBLISH_CHECK"
    echo "COMMIT_CREATED=false"
    echo "PUSH_PERFORMED=false"
    echo "EXPECTED_NEW_FILES=etc/crontabs/root,usr/local/sbin/router-vm101-git-publish.sh"
    exit 0
fi

log "verify real git index has no pre-staged changes"

unset GIT_INDEX_FILE

if ! git_root diff --cached --quiet; then
    echo "STOP_REAL_INDEX_ALREADY_HAS_STAGED_CHANGES=true"
    git_root diff --cached --name-only
    exit 1
fi

log "install validated simulated index"

cp "$TMP_INDEX" "${GIT_DIR}/index.new.$$"
chmod 600 "${GIT_DIR}/index.new.$$"
mv "${GIT_DIR}/index.new.$$" "${GIT_DIR}/index"

if git_root diff --cached --quiet; then
    echo "NO_CHANGES=true"
    echo "GIT_COMMIT=$LOCAL_HEAD"
    echo "REMOTE_COMMIT=$REMOTE_HEAD"
    echo "RESULT=PASS_VM101_GIT_NOTHING_TO_PUBLISH"
    exit 0
fi

if [ -z "$MESSAGE" ]; then
    MESSAGE="vm101: publish managed source $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi

log "create commit"

git_root commit -m "$MESSAGE"

NEW_HEAD="$(git_meta rev-parse HEAD)"
NEW_TREE="$(git_meta show -s --format=%T HEAD)"

echo "NEW_COMMIT=$NEW_HEAD"
echo "NEW_TREE=$NEW_TREE"

log "push main to github"

git \
    -c protocol.version=0 \
    -C "$WORK_TREE" \
    --git-dir="$GIT_DIR" \
    --work-tree="$WORK_TREE" \
    push \
    "$REMOTE" \
    "$BRANCH"

log "verify remote commit"

VERIFIED_REMOTE="$(
    git \
        -c protocol.version=0 \
        --git-dir="$GIT_DIR" \
        ls-remote \
        "$REMOTE" \
        "refs/heads/$BRANCH" |
    awk '{print $1}'
)"

echo "LOCAL_COMMIT=$NEW_HEAD"
echo "REMOTE_COMMIT=$VERIFIED_REMOTE"

test "$VERIFIED_REMOTE" = "$NEW_HEAD"

git_root \
    ls-tree \
    -r \
    --full-tree \
    --name-only \
    HEAD \
    > "${GIT_DIR}/code-paths.txt.tmp"

mv \
    "${GIT_DIR}/code-paths.txt.tmp" \
    "${GIT_DIR}/code-paths.txt"

chmod 600 "${GIT_DIR}/code-paths.txt"

{
    echo "CURRENT_COMMIT=$NEW_HEAD"
    echo "CURRENT_TREE=$NEW_TREE"
    echo "CURRENT_FILE_COUNT=$TREE_FILE_COUNT"
    echo "CURRENT_BRANCH=$BRANCH"
    echo "CURRENT_REMOTE=$REMOTE"
} > "${GIT_DIR}/current.env.tmp"

mv \
    "${GIT_DIR}/current.env.tmp" \
    "${GIT_DIR}/current.env"

chmod 600 "${GIT_DIR}/current.env"

echo
echo "RESULT=PASS_VM101_GIT_PUBLISH"
echo "GIT_COMMIT=$NEW_HEAD"
echo "GIT_TREE=$NEW_TREE"
echo "GIT_FILE_COUNT=$TREE_FILE_COUNT"
echo "PUSH_PERFORMED=true"
echo "REPOSITORY=https://github.com/DChuvelev/wg-paid-vm101"
