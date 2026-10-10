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

# Build a stand-in for the GitHub repo: a git repo whose tag v<version>
# carries stanza's files with that VERSION. No assets are published yet.
make_remote() {
    REMOTE="$SUITE_TMP/remote"
    git -c init.defaultBranch=main init -q "$REMOTE"
    cp -r "$STANZA_DIR/bin" "$STANZA_DIR/lib" "$STANZA_DIR/completions" "$REMOTE/"
    local v
    for v in "$@"; do
        echo "$v" > "$REMOTE/VERSION"
        git -C "$REMOTE" add -A
        git -C "$REMOTE" commit -q -m "v$v"
        git -C "$REMOTE" tag "v$v"
    done
    export STANZA_REPO_URL="file://$REMOTE"
}

# Publish v$1's asset and checksum under releases/download/v$1/, the way
# GitHub serves release assets, built by the script the release workflow runs
publish_asset() {
    (cd "$REMOTE" && "$STANZA_DIR/scripts/release-asset.sh" --out "releases/download/v$1" "v$1" > /dev/null)
}

# Path of v$1's published file; $2 is "" for the asset or ".sha256"
asset_path() {
    echo "$REMOTE/releases/download/v$1/stanza-$1.tar.gz$2"
}

# Change one byte in the middle of file $1
flip_byte() {
    local file="$1" offset byte new
    offset=$(( $(wc -c < "$file") / 2 ))
    byte=$(od -An -tx1 -j "$offset" -N 1 "$file" | tr -d ' ')
    new='X'
    [[ "$byte" == "58" ]] && new='Y'
    printf '%s' "$new" | dd of="$file" bs=1 seek="$offset" conv=notrunc 2> /dev/null
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
# highest stable tag by number rather than by string. 1.0.1-1.0.4 are
# published broken, one way each, for the verification cases.
make_remote 1.0.0 1.0.1 1.0.2 1.0.3 1.0.4 1.9.0 1.10.0 1.11.0a1
for v in 1.0.0 1.0.2 1.0.3 1.0.4 1.9.0 1.10.0; do
    publish_asset "$v"
done
# 1.0.1: no asset at all (a tag from before release assets)
flip_byte "$(asset_path 1.0.2)"             # 1.0.2: asset differs from its checksum
rm "$(asset_path 1.0.3 .sha256)"            # 1.0.3: checksum missing
echo "not-a-checksum  stanza-1.0.4.tar.gz" > "$(asset_path 1.0.4 .sha256)"  # 1.0.4: malformed

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
assert_contains "verifies the checksum" "$out" \
    "Verified SHA-256 $(awk '{print $1}' "$(asset_path 1.10.0 .sha256)")"
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
assert_contains "names the failed download" "$out" "Could not download the release asset for v9.9.9"
assert_eq "nothing installed" "none" "$(installed_version)"
assert_eq "temp directory removed" "" "$(ls -A "$TMPDIR")"

# --- Verification ----------------------------------------------------------

echo "Tag without a release asset"
setup
status=0
out=$(piped --yes --version 1.0.1 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "names the missing asset" "$out" "Could not download the release asset for v1.0.1"
assert_contains "points at the clone path" "$out" "git clone --branch v1.0.1"
assert_eq "nothing installed" "none" "$(installed_version)"
assert_eq "temp directory removed" "" "$(ls -A "$TMPDIR")"

echo "Asset that does not match its checksum"
setup
status=0
out=$(piped --yes --version 1.0.2 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "reports the mismatch" "$out" "Checksum mismatch for stanza-1.0.2.tar.gz"
assert_not_contains "does not unpack it" "$out" "Verified"
assert_eq "nothing installed" "none" "$(installed_version)"
assert_eq "temp directory removed" "" "$(ls -A "$TMPDIR")"

echo "Asset without a checksum"
setup
status=0
out=$(piped --yes --version 1.0.3 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "names the missing checksum" "$out" "Could not download the checksum for v1.0.3"
assert_eq "nothing installed" "none" "$(installed_version)"

echo "Malformed checksum"
setup
status=0
out=$(piped --yes --version 1.0.4 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "rejects it" "$out" "Malformed checksum file"
assert_eq "nothing installed" "none" "$(installed_version)"

echo "shasum when sha256sum is absent"
if command -v shasum > /dev/null; then
    setup
    nosum="$CASE_TMP/nosum"
    mkdir -p "$nosum"
    # A PATH of links to every tool on PATH except sha256sum
    while IFS= read -r -d '' tool; do
        name=$(basename "$tool")
        [[ "$name" == sha256sum || -e "$nosum/$name" ]] || ln -s "$tool" "$nosum/$name"
    done < <(IFS=:; for d in $PATH; do [[ -d "$d" ]] && find "$d" -maxdepth 1 \( -type f -o -type l \) -perm -u+x -print0 2>/dev/null; done)
    PATH="$nosum" bash -s -- --yes --version 1.9.0 < "$INSTALLER" > /dev/null 2>&1 || true
    assert_eq "installs with shasum" "1.9.0" "$(installed_version)"
else
    echo "  SKIP: shasum not available"
fi

echo "Invalid version"
setup
status=0
out=$(piped --yes --version '../x' 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "rejects it" "$out" "Invalid version"

echo "Empty version"
setup
status=0
out=$(STANZA_VERSION=1.0.0 piped --yes --version= 2>&1) || status=$?
assert_eq "--version= exits non-zero" "1" "$status"
assert_contains "--version= asks for a tag" "$out" "--version requires a tag"
assert_eq "--version= installs nothing" "none" "$(installed_version)"

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
    out=$(head -c "$n" "$INSTALLER" | bash -s -- --yes 2>&1) || true
    # main prints its banner first, so a cut that ran it shows up even when
    # it then stopped short of installing (e.g. arguments lost, no --yes)
    if [[ -e "$HOME/.local" || "$out" == *"Stanza CLI Tool Installer"* ]]; then
        ran=$((ran + 1))
        echo "    main ran after a cut at byte $n"
    fi
done
# Every cut within the final line, up to but not including its last
# character, must not run main either (a bare `main` would run it argless)
for ((n = size - last_line; n < size - 1; n++)); do
    setup
    out=$(head -c "$n" "$INSTALLER" | bash -s -- --yes 2>&1) || true
    # main prints its banner first, so a cut that ran it shows up even when
    # it then stopped short of installing (e.g. arguments lost, no --yes)
    if [[ -e "$HOME/.local" || "$out" == *"Stanza CLI Tool Installer"* ]]; then
        ran=$((ran + 1))
        echo "    main ran after a cut at byte $n"
    fi
done
assert_eq "no truncated prefix runs main" "0" "$ran"
setup
cat "$INSTALLER" | bash -s -- --yes > /dev/null 2>&1
assert_eq "the whole script, piped the same way, installs" "1.10.0" "$(installed_version)"

# --- Summary ---------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
