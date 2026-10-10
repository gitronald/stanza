#!/usr/bin/env bash
# Description: Test scripts/release-asset.sh against a gh mock that keeps
#              each release's assets in a directory: creating a release,
#              re-running on a complete one, filling in a partial one, and
#              refusing a published checksum that does not match.
set -e

STANZA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SCRIPT="$STANZA_DIR/scripts/release-asset.sh"
PASS=0
FAIL=0

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# --- Helpers ---------------------------------------------------------------

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected to contain '$needle', got '$haystack')"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected NOT to contain '$needle', got '$haystack')"
        FAIL=$((FAIL + 1))
    fi
}

# A gh mock: release <tag> exists when $GH_MOCK_STATE/<tag>/ does, and its
# assets are the files in it. Every call is logged to $GH_MOCK_STATE/calls.
make_gh_mock() {
    mkdir -p "$1"
    cat > "$1/gh" <<'MOCK'
#!/usr/bin/env bash
set -e
STATE="$GH_MOCK_STATE"
echo "$*" >> "$STATE/calls"
[[ "$1" == release ]] || { echo "gh mock: unsupported: $*" >&2; exit 2; }
cmd="$2"; tag="$3"; shift 3
dir="$STATE/$tag"
case "$cmd" in
    view)
        [[ -d "$dir" ]] || { echo "release not found" >&2; exit 1; }
        if [[ "$1" == --json ]]; then
            ls "$dir" | grep -v '^\.notes$' || true
        fi
        ;;
    create)
        [[ ! -d "$dir" ]] || { echo "gh mock: release exists" >&2; exit 1; }
        mkdir "$dir"
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --notes) printf '%s' "$2" > "$dir/.notes"; shift 2 ;;
                --title) shift 2 ;;
                --*) shift ;;
                *) cp "$1" "$dir/"; shift ;;
            esac
        done
        ;;
    upload)
        [[ -d "$dir" ]] || { echo "release not found" >&2; exit 1; }
        [[ ! -e "$dir/$(basename "$1")" ]] || { echo "gh mock: asset exists" >&2; exit 1; }
        cp "$1" "$dir/"
        ;;
    download)
        local_pattern="" out="."
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --pattern) local_pattern="$2"; shift 2 ;;
                --dir) out="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        mkdir -p "$out"
        cp "$dir/$local_pattern" "$out/"
        ;;
    *)
        echo "gh mock: unsupported: release $cmd" >&2; exit 2 ;;
esac
MOCK
    chmod +x "$1/gh"
}

# Fresh repo with tag v1.2.0 and an empty mock release store
setup() {
    CASE_TMP=$(mktemp -d "$SUITE_TMP/case.XXXXXX")
    REPO="$CASE_TMP/repo"
    export GH_MOCK_STATE="$CASE_TMP/releases"
    mkdir -p "$GH_MOCK_STATE"
    git -c init.defaultBranch=main init -q "$REPO"
    mkdir -p "$REPO/bin"
    echo "echo stanza" > "$REPO/bin/stanza"
    echo "1.2.0" > "$REPO/VERSION"
    cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [1.2.0] - 2026-01-02

### Added

- A new thing.

## [1.1.0] - 2026-01-01

- An old thing.

[Unreleased]: https://example.com/compare/v1.2.0...HEAD
EOF
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m "initial commit"
    git -C "$REPO" tag v1.2.0
    git -C "$REPO" tag v1.3.0a1
}

run() {
    (cd "$REPO" && "$SCRIPT" "$@")
}

release_dir() {
    echo "$GH_MOCK_STATE/v1.2.0"
}

checksum_ok() {
    (cd "$(release_dir)" && sha256sum -c --status stanza-1.2.0.tar.gz.sha256) && echo yes || echo no
}

calls() {
    cat "$GH_MOCK_STATE/calls" 2>/dev/null || true
}

SUITE_TMP=$(mktemp -d)
trap 'rm -rf "$SUITE_TMP"' EXIT
make_gh_mock "$SUITE_TMP/bin"
PATH="$SUITE_TMP/bin:$PATH"

# --- Build only ------------------------------------------------------------

echo "--out builds the asset and checksum without gh"
setup
run --out "$CASE_TMP/dist" v1.2.0 > /dev/null
assert_eq "checksum verifies" "yes" \
    "$( (cd "$CASE_TMP/dist" && sha256sum -c --status stanza-1.2.0.tar.gz.sha256) && echo yes || echo no)"
assert_eq "one top-level stanza-1.2.0/ directory" "stanza-1.2.0/" \
    "$(tar -tzf "$CASE_TMP/dist/stanza-1.2.0.tar.gz" | cut -d/ -f1 | sort -u)/"
assert_eq "carries the tagged files" "1.2.0" \
    "$(tar -xzOf "$CASE_TMP/dist/stanza-1.2.0.tar.gz" stanza-1.2.0/VERSION)"
assert_eq "no gh calls" "" "$(calls)"

# --- Publishing ------------------------------------------------------------

echo "No release yet"
setup
out=$(run v1.2.0 2>&1)
assert_contains "creates the release" "$out" "Created release v1.2.0"
assert_contains "verifies the tag" "$(calls)" "release create v1.2.0 --verify-tag"
assert_eq "uploads both files" "stanza-1.2.0.tar.gz stanza-1.2.0.tar.gz.sha256" \
    "$(ls "$(release_dir)" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "checksum matches the asset" "yes" "$(checksum_ok)"
notes=$(cat "$(release_dir)/.notes")
assert_contains "notes carry the changelog section" "$notes" "- A new thing."
assert_not_contains "notes stop at the next version" "$notes" "An old thing"

echo "Re-run on a complete release"
: > "$GH_MOCK_STATE/calls"
out=$(run v1.2.0 2>&1)
assert_contains "reports it complete" "$out" "already has stanza-1.2.0.tar.gz and a matching checksum"
assert_not_contains "creates nothing" "$(calls)" "create"
assert_not_contains "uploads nothing" "$(calls)" "upload"

echo "Release with only the asset"
setup
mkdir "$(release_dir)"
# A published asset whose bytes differ from a fresh build (other gzip level),
# as after a git upgrade: the checksum must describe the published bytes
(cd "$REPO" && git archive --prefix=stanza-1.2.0/ v1.2.0 | gzip -1 > "$(release_dir)/stanza-1.2.0.tar.gz")
before=$(sha256sum "$(release_dir)/stanza-1.2.0.tar.gz")
out=$(run v1.2.0 2>&1)
assert_contains "uploads the checksum" "$out" "Uploaded stanza-1.2.0.tar.gz.sha256"
assert_eq "does not re-upload the asset" "0" "$(calls | grep -c 'upload .*\.tar\.gz$' || true)"
assert_eq "asset unchanged" "$before" "$(sha256sum "$(release_dir)/stanza-1.2.0.tar.gz")"
assert_eq "checksum matches the published asset" "yes" "$(checksum_ok)"

echo "Release with no assets"
setup
mkdir "$(release_dir)"
out=$(run v1.2.0 2>&1)
assert_contains "uploads the asset" "$out" "Uploaded stanza-1.2.0.tar.gz to v1.2.0"
assert_contains "uploads the checksum" "$out" "Uploaded stanza-1.2.0.tar.gz.sha256"
assert_eq "checksum matches the asset" "yes" "$(checksum_ok)"

echo "Published checksum that does not match"
setup
run v1.2.0 > /dev/null 2>&1
echo "0000000000000000000000000000000000000000000000000000000000000000  stanza-1.2.0.tar.gz" \
    > "$(release_dir)/stanza-1.2.0.tar.gz.sha256"
status=0
out=$(run v1.2.0 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "reports the mismatch" "$out" "does not match"

# --- Refusals --------------------------------------------------------------

echo "Prerelease tag"
setup
status=0
out=$(run v1.3.0a1 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "names the expected form" "$out" "Not a stable release tag"
assert_eq "no gh calls" "" "$(calls)"

echo "Unknown tag"
setup
status=0
out=$(run v9.9.9 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "names the tag" "$out" "Tag v9.9.9 not found"

# --- Summary ---------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
