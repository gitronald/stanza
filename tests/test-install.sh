#!/usr/bin/env bash
# Description: Test install.sh in checkout mode and in fetch mode (piped, as
#              from curl | bash). Fetch mode runs against a local stand-in for
#              GitHub (STANZA_REPO_URL=file://...), so no network is used, and
#              HOME and TMPDIR point at temp directories for every case.
set -e

STANZA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
INSTALLER="$STANZA_DIR/install.sh"
SELF_VERSION=$(head -1 "$STANZA_DIR/VERSION" | tr -d '[:space:]')
PASS=0
FAIL=0

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export NO_COLOR=1
unset STANZA_VERSION

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

# Build a stand-in for the GitHub repo: a git repo carrying the given tags,
# with archive/refs/tags/v<version>.tar.gz beside it laid out the way GitHub
# serves them (one top-level stanza-<version>/ directory).
make_remote() {
    REMOTE="$SUITE_TMP/remote"
    git -c init.defaultBranch=main init -q "$REMOTE"
    git -C "$REMOTE" commit -q --allow-empty -m "initial commit"
    mkdir -p "$REMOTE/archive/refs/tags"
    local v tree
    for v in "$@"; do
        git -C "$REMOTE" tag "v$v"
        tree="$SUITE_TMP/build/stanza-$v"
        mkdir -p "$tree"
        cp -r "$STANZA_DIR/bin" "$STANZA_DIR/lib" "$STANZA_DIR/completions" "$tree/"
        echo "$v" > "$tree/VERSION"
        tar -czf "$REMOTE/archive/refs/tags/v$v.tar.gz" -C "$SUITE_TMP/build" "stanza-$v"
    done
    export STANZA_REPO_URL="file://$REMOTE"
}

# Fresh HOME and TMPDIR for one case
setup() {
    CASE_TMP=$(mktemp -d "$SUITE_TMP/case.XXXXXX")
    export HOME="$CASE_TMP/home"
    export TMPDIR="$CASE_TMP/tmp"
    mkdir -p "$HOME" "$TMPDIR"
    INSTALLED="$HOME/.local/lib/stanza/VERSION"
}

installed_version() {
    if [[ -f "$INSTALLED" ]]; then head -1 "$INSTALLED"; else echo "none"; fi
}

# Run the installer the way curl | bash does: script on stdin, args after -s --
piped() {
    bash -s -- "$@" < "$INSTALLER"
}

SUITE_TMP=$(mktemp -d)
trap 'rm -rf "$SUITE_TMP"' EXIT
# Includes a prerelease and a two-digit minor, to check "latest" picks the
# highest stable tag by number rather than by string
make_remote 1.0.0 1.9.0 1.10.0 1.11.0a1

# --- Checkout mode ---------------------------------------------------------

echo "Checkout mode"
setup
out=$("$INSTALLER" --yes 2>&1)
assert_eq "installs the checkout's VERSION" "$SELF_VERSION" "$(installed_version)"
assert_not_contains "does not download" "$out" "Downloading"
assert_contains "names the checkout as the source" "$out" "Source:              $STANZA_DIR"

# --- Fetch mode ------------------------------------------------------------

echo "Piped, latest release"
setup
out=$(piped --yes 2>&1)
assert_eq "installs the highest stable tag" "1.10.0" "$(installed_version)"
assert_contains "downloads" "$out" "Downloading stanza v1.10.0"
assert_eq "binary installed" "yes" "$([[ -x "$HOME/.local/bin/stanza" ]] && echo yes || echo no)"
assert_eq "bash completion installed" "yes" \
    "$([[ -f "$HOME/.bash_completion.d/stanza" ]] && echo yes || echo no)"
assert_eq "temp directory removed" "" "$(ls -A "$TMPDIR")"

echo "Piped, pinned version"
setup
piped --yes --version 1.0.0 > /dev/null 2>&1
assert_eq "--version X.Y.Z" "1.0.0" "$(installed_version)"
setup
piped --yes --version=v1.9.0 > /dev/null 2>&1
assert_eq "--version=vX.Y.Z" "1.9.0" "$(installed_version)"
setup
STANZA_VERSION=1.0.0 piped --yes > /dev/null 2>&1
assert_eq "STANZA_VERSION" "1.0.0" "$(installed_version)"

echo "Checkout with --version"
setup
"$INSTALLER" --yes --version 1.0.0 > /dev/null 2>&1
assert_eq "--version downloads even from a checkout" "1.0.0" "$(installed_version)"

echo "Piped from inside a checkout"
setup
out=$(cd "$STANZA_DIR" && piped --yes 2>&1)
assert_eq "ignores the current directory" "1.10.0" "$(installed_version)"
setup
mkdir -p "$CASE_TMP/cwd" && cp -r "$STANZA_DIR/bin" "$STANZA_DIR/lib" "$CASE_TMP/cwd/"
cp "$STANZA_DIR/bin/stanza" "$CASE_TMP/cwd/bash"
out=$(cd "$CASE_TMP/cwd" && piped --yes 2>&1)
assert_eq "ignores a file named bash in the current directory" "1.10.0" "$(installed_version)"

echo "Missing tag"
setup
status=0
out=$(piped --yes --version 9.9.9 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "names the failed download" "$out" "Download failed"
assert_eq "nothing installed" "none" "$(installed_version)"
assert_eq "temp directory removed" "" "$(ls -A "$TMPDIR")"

echo "Invalid version"
setup
status=0
out=$(piped --yes --version '../x' 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "rejects it" "$out" "Invalid version"

echo "Unreachable remote"
setup
status=0
out=$(STANZA_REPO_URL="file://$SUITE_TMP/missing" piped --yes 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "points at --version" "$out" "--version=X.Y.Z"

# --- Confirmation ----------------------------------------------------------

echo "Piped without --yes and without a terminal"
if command -v setsid > /dev/null; then
    setup
    status=0
    out=$(setsid -w bash -s < "$INSTALLER" 2>&1) || status=$?
    assert_eq "exits non-zero" "1" "$status"
    assert_contains "names --yes" "$out" "--yes"
    assert_eq "nothing installed" "none" "$(installed_version)"
else
    echo "  SKIP: setsid not available"
fi

echo "Run from a file, answer on stdin"
setup
printf 'y' | "$INSTALLER" > /dev/null 2>&1
assert_eq "printf y | ./install.sh installs" "$SELF_VERSION" "$(installed_version)"
setup
printf 'n' | "$INSTALLER" > /dev/null 2>&1
assert_eq "printf n | ./install.sh cancels" "none" "$(installed_version)"

# --- Truncated download ----------------------------------------------------

echo "Truncated script"
size=$(wc -c < "$INSTALLER")
# Every cut short of the final line leaves main uncalled
last_line=$(tail -1 "$INSTALLER" | wc -c)
ran=0
for ((n = 1; n < size - last_line; n += 97)); do
    setup
    head -c "$n" "$INSTALLER" | bash -s -- --yes > /dev/null 2>&1 || true
    if [[ -e "$HOME/.local" ]]; then
        ran=$((ran + 1))
        echo "    installed after a cut at byte $n"
    fi
done
setup
head -c $((size - last_line)) "$INSTALLER" | bash -s -- --yes > /dev/null 2>&1 || true
[[ -e "$HOME/.local" ]] && ran=$((ran + 1))
assert_eq "no truncated prefix installs anything" "0" "$ran"
setup
cat "$INSTALLER" | bash -s -- --yes > /dev/null 2>&1
assert_eq "the whole script, piped the same way, installs" "1.10.0" "$(installed_version)"

# --- Summary ---------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
