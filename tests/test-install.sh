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

# Print a directory of links to every tool on PATH except $1, for use as PATH
path_without() {
    local missing="$1" dir="$CASE_TMP/no-$1" tool name
    mkdir -p "$dir"
    while IFS= read -r -d '' tool; do
        name=$(basename "$tool")
        [[ "$name" == "$missing" || -e "$dir/$name" ]] || ln -s "$tool" "$dir/$name"
    done < <(IFS=:; for d in $PATH; do [[ -d "$d" ]] && find "$d" -maxdepth 1 \( -type f -o -type l \) -perm -u+x -print0 2>/dev/null; done)
    echo "$dir"
}

# Run the first $1 bytes of the installer piped; succeed when main ran. main
# prints its header before the prompt, and every error before that point says
# nothing was installed, so a cut that ran it shows up even when it then
# stopped short of installing (e.g. arguments lost, no --yes)
cut_runs_main() {
    local out
    setup
    out=$(head -c "$1" "$INSTALLER" | bash -s -- --yes 2>&1) || true
    [[ -e "$HOME/.local" || "$out" == *"stanza install"* || "$out" == *"nothing was installed"* ]]
}

# Print the installer's output-helper block from file $1
helpers_of() {
    sed -n '/^# --- Output helpers/,/^# --- End of output helpers/p' "$1"
}

# Print a directory holding a uname stub that reports $1, for prepending to PATH
uname_stub() {
    local dir="$CASE_TMP/uname-$1"
    mkdir -p "$dir"
    printf '#!/bin/sh\necho %s\n' "$1" > "$dir/uname"
    chmod +x "$dir/uname"
    echo "$dir"
}

# "yes" when $1 holds an ESC byte, otherwise "no"
esc_state() {
    if [[ "$1" == *$'\033'* ]]; then echo yes; else echo no; fi
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
assert_not_contains "does not download" "$out" "fetch   "
assert_contains "names the checkout as the source" "$out" "source  $STANZA_DIR, checkout"

# --- Fetch mode ------------------------------------------------------------

echo "Piped, latest release"
setup
out=$(piped --yes 2>&1)
assert_eq "installs the highest stable tag" "1.10.0" "$(installed_version)"
assert_contains "downloads" "$out" "fetch   stanza-1.10.0.tar.gz"
sum=$(awk '{print $1}' "$(asset_path 1.10.0 .sha256)")
assert_contains "verifies the checksum" "$out" "verify  sha256 ${sum:0:16}"
assert_contains "names the release as the source" "$out" "source  file://$REMOTE, release v1.10.0"
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
(cd "$STANZA_DIR" && piped --yes > /dev/null 2>&1)
assert_eq "ignores the current directory" "1.10.0" "$(installed_version)"
setup
mkdir -p "$CASE_TMP/cwd" && cp -r "$STANZA_DIR/bin" "$STANZA_DIR/lib" "$CASE_TMP/cwd/"
cp "$STANZA_DIR/bin/stanza" "$CASE_TMP/cwd/bash"
(cd "$CASE_TMP/cwd" && piped --yes > /dev/null 2>&1)
assert_eq "ignores a file named bash in the current directory" "1.10.0" "$(installed_version)"

echo "Missing tag"
setup
status=0
out=$(piped --yes --version 9.9.9 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "names the failed download" "$out" \
    "could not download the release asset for v9.9.9; nothing was installed"
assert_eq "nothing installed" "none" "$(installed_version)"
assert_eq "temp directory removed" "" "$(ls -A "$TMPDIR")"

# --- Verification ----------------------------------------------------------

echo "Tag without a release asset"
setup
status=0
out=$(piped --yes --version 1.0.1 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "names the missing asset" "$out" "could not download the release asset for v1.0.1"
assert_contains "points at the clone path" "$out" "git clone --branch v1.0.1"
assert_eq "nothing installed" "none" "$(installed_version)"
assert_eq "temp directory removed" "" "$(ls -A "$TMPDIR")"

echo "Asset that does not match its checksum"
setup
status=0
out=$(piped --yes --version 1.0.2 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "reports the mismatch" "$out" \
    "error   sha256 mismatch for stanza-1.0.2.tar.gz; nothing was installed"
assert_contains "says what to do next" "$out" "hint    retry; if it fails again:"
assert_not_contains "does not unpack it" "$out" "verify  "
assert_eq "nothing installed" "none" "$(installed_version)"
assert_eq "temp directory removed" "" "$(ls -A "$TMPDIR")"

echo "Asset without a checksum"
setup
status=0
out=$(piped --yes --version 1.0.3 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "names the missing checksum" "$out" "could not download the checksum for v1.0.3"
assert_eq "nothing installed" "none" "$(installed_version)"

echo "Malformed checksum"
setup
status=0
out=$(piped --yes --version 1.0.4 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "rejects it" "$out" "malformed checksum file"
assert_eq "nothing installed" "none" "$(installed_version)"

echo "shasum when sha256sum is absent"
if command -v shasum > /dev/null; then
    setup
    nosum=$(path_without sha256sum)
    PATH="$nosum" bash -s -- --yes --version 1.9.0 < "$INSTALLER" > /dev/null 2>&1 || true
    assert_eq "installs with shasum" "1.9.0" "$(installed_version)"
else
    echo "  SKIP: shasum not available"
fi

echo "Piped without git"
setup
nogit=$(path_without git)
status=0
out=$(PATH="$nogit" bash -s -- --yes < "$INSTALLER" 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "names git as missing" "$out" "missing required tools: git"
assert_not_contains "does not blame the connection" "$out" "could not find the latest release"

echo "Invalid version"
setup
status=0
out=$(piped --yes --version '../x' 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "rejects it" "$out" "invalid version"

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

echo "Plain HTTP remote"
setup
status=0
out=$(STANZA_REPO_URL="http://127.0.0.1:9/stanza" piped --yes 2>&1) || status=$?
assert_eq "exits non-zero" "1" "$status"
assert_contains "names the non-HTTPS URL" "$out" "non-HTTPS repository URL"
assert_not_contains "fails before any lookup" "$out" "could not find the latest"
assert_eq "nothing installed" "none" "$(installed_version)"

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
# Every 97th cut before the final line, then every cut within the final
# line up to but not including its last character (a bare `main` would run
# it argless)
cuts=()
for ((n = 1; n < size - last_line; n += 97)); do cuts+=("$n"); done
for ((n = size - last_line; n < size - 1; n++)); do cuts+=("$n"); done
for n in "${cuts[@]}"; do
    if cut_runs_main "$n"; then
        ran=$((ran + 1))
        echo "    main ran after a cut at byte $n"
    fi
done
assert_eq "no truncated prefix runs main" "0" "$ran"
setup
cat "$INSTALLER" | bash -s -- --yes > /dev/null 2>&1
assert_eq "the whole script, piped the same way, installs" "1.10.0" "$(installed_version)"

# --- Output ----------------------------------------------------------------

echo "Rows before the prompt match the rows after it"
setup
mkdir -p "$HOME/.claude"
out=$(SHELL=/bin/zsh "$INSTALLER" --yes 2>&1)
assert_eq "bash path shown before and after" "2" \
    "$(grep -c '^  bash    ~/.bash_completion.d/stanza$' <<< "$out")"
assert_eq "zsh path shown before and after" "2" \
    "$(grep -c '^  zsh     ~/.zsh/completions/_stanza$' <<< "$out")"
assert_eq "rule path shown before and after" "2" \
    "$(grep -c '^  rule    ~/.claude/rules/stanza.md$' <<< "$out")"
assert_contains "fpath hint for the zsh fallback" "$out" \
    "hint    add to ~/.zshrc: fpath=(~/.zsh/completions \$fpath)"
assert_contains "one closing row" "$out" "done    stanza $SELF_VERSION."
assert_not_contains "no rules of box-drawing glyphs" "$out" "━"

echo "Completions under the prefix when it can be written"
setup
mkdir -p "$HOME/.local/share"
out=$("$INSTALLER" --yes 2>&1)
assert_contains "bash row names the share path" "$out" \
    "bash    ~/.local/share/bash-completion/completions/stanza"
assert_not_contains "no fallback hint" "$out" "fpath="
assert_eq "share path used" "yes" \
    "$([[ -f "$HOME/.local/share/zsh/site-functions/_stanza" ]] && echo yes || echo no)"

echo "Rows omitted for files that are not installed"
setup
mkdir -p "$HOME/.claude"
out=$("$INSTALLER" --yes --no-completions --no-rules 2>&1)
assert_not_contains "--no-completions: no bash row" "$out" "  bash    "
assert_not_contains "--no-completions: no zsh row" "$out" "  zsh     "
assert_not_contains "--no-rules: no rule row" "$out" "  rule    "
assert_not_contains "--no-rules: no rule hint" "$out" "stanza rules install"
setup
out=$("$INSTALLER" --yes 2>&1)
assert_not_contains "no ~/.claude: no rule row" "$out" "  rule    "
assert_contains "no ~/.claude: hint names the command" "$out" "stanza rules install"

echo "PATH hint names the user's startup file"
setup
out=$(SHELL=/bin/zsh "$INSTALLER" --yes 2>&1)
assert_contains "warns" "$out" "warn    ~/.local/bin is not on your PATH"
assert_contains "zsh: ~/.zshrc" "$out" \
    "hint    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
setup
out=$(SHELL=/bin/bash PATH="$(uname_stub Darwin):$PATH" "$INSTALLER" --yes 2>&1)
assert_contains "bash on Darwin: ~/.bash_profile" "$out" ">> ~/.bash_profile"
assert_contains "bash completion hint on Darwin: ~/.bash_profile" "$out" \
    "add to ~/.bash_profile: for f in ~/.bash_completion.d/*"
setup
out=$(SHELL=/bin/bash PATH="$(uname_stub Linux):$PATH" "$INSTALLER" --yes 2>&1)
assert_contains "bash elsewhere: ~/.bashrc" "$out" ">> ~/.bashrc"
setup
out=$(SHELL=/usr/bin/fish "$INSTALLER" --yes 2>&1)
assert_contains "fish: fish_add_path" "$out" "hint    fish_add_path ~/.local/bin"
setup
out=$(PATH="$HOME/.local/bin:$PATH" "$INSTALLER" --yes 2>&1)
assert_not_contains "on PATH: no warning" "$out" "warn    "
assert_contains "on PATH: run it now" "$out" "done    stanza $SELF_VERSION. Run: stanza --help"

echo "Color"
setup
out=$(env -u NO_COLOR TERM=xterm "$INSTALLER" --yes 2>&1)
assert_eq "piped: no ESC byte" "no" "$(esc_state "$out")"
setup
out=$(env -u NO_COLOR TERM=xterm CLICOLOR_FORCE=1 "$INSTALLER" --yes 2>&1)
assert_eq "CLICOLOR_FORCE=1 piped: colored" "yes" "$(esc_state "$out")"
setup
out=$(TERM=xterm CLICOLOR_FORCE=1 "$INSTALLER" --yes 2>&1)
assert_eq "NO_COLOR beats CLICOLOR_FORCE" "no" "$(esc_state "$out")"
setup
out=$(env -u NO_COLOR TERM=xterm CLICOLOR_FORCE=1 "$INSTALLER" --yes --no-color 2>&1)
assert_eq "--no-color beats CLICOLOR_FORCE" "no" "$(esc_state "$out")"
out=$(env -u NO_COLOR TERM=xterm CLICOLOR_FORCE=1 "$INSTALLER" --bogus --no-color 2>&1) || true
assert_eq "--no-color covers an earlier argument error" "no" "$(esc_state "$out")"

# The gate itself, for each fd state the suite cannot set up portably
eval "$(helpers_of "$INSTALLER")"
gate() { if use_color "$@"; then echo on; else echo off; fi; }
assert_eq "gate: NO_COLOR" "off" "$(NO_COLOR=1 CLICOLOR_FORCE=1 gate 1)"
assert_eq "gate: --no-color" "off" "$(NO_COLOR_FLAG=true; unset NO_COLOR; CLICOLOR_FORCE=1 gate 1)"
assert_eq "gate: CLICOLOR_FORCE=0 is not forcing" "off" "$(unset NO_COLOR; CLICOLOR_FORCE=0 gate 1)"
assert_eq "gate: not a terminal" "off" "$(unset NO_COLOR CLICOLOR_FORCE; TERM=xterm gate 1)"

echo "Color under a terminal"
. "$STANZA_DIR/tests/pty.sh"
if declare -f in_pty > /dev/null; then
    setup
    out=$(in_pty "env -u NO_COLOR TERM=xterm '$INSTALLER' --yes")
    assert_eq "terminal: colored" "yes" "$(esc_state "$out")"
    setup
    out=$(in_pty "env NO_COLOR=1 TERM=xterm '$INSTALLER' --yes")
    assert_eq "terminal, NO_COLOR=1: no ESC byte" "no" "$(esc_state "$out")"
    setup
    out=$(in_pty "env -u NO_COLOR TERM=dumb '$INSTALLER' --yes")
    assert_eq "terminal, TERM=dumb: no ESC byte" "no" "$(esc_state "$out")"
else
    echo "  SKIP: util-linux or BSD script not available"
fi

echo "Helpers match lib/stanza-common"
uninstall_helpers=$(helpers_of "$STANZA_DIR/uninstall.sh")
assert_eq "uninstall.sh carries the same block" "$(helpers_of "$INSTALLER")" "$uninstall_helpers"
# Values from lib/stanza-common, read in a subshell so its globals stay out
common=$(
    # shellcheck source=/dev/null
    source "$STANZA_DIR/lib/stanza-common"
    printf '%s|%b|%b|%b|%b|%b|%s\n' "$LABEL_WIDTH" "$DIM" "$CYAN" "$RED" "$GREEN" "$BOLD" "$YELLOW"
)
IFS='|' read -r c_width c_dim c_cyan c_red c_green c_bold c_yellow <<< "$common"
sgr_of() { printf '\033[%sm' "$1"; }
assert_eq "label width" "$c_width" "$LABEL_WIDTH"
assert_eq "label: DIM" "$c_dim" "$(sgr_of "$SGR_LABEL")"
assert_eq "hint: CYAN" "$c_cyan" "$(sgr_of "$SGR_HINT")"
assert_eq "error: RED" "$c_red" "$(sgr_of "$SGR_ERROR")"
assert_eq "done: GREEN" "$c_green" "$(sgr_of "$SGR_DONE")"
assert_eq "header: BOLD" "$c_bold" "$(sgr_of "$SGR_BOLD")"
# warn keeps YELLOW's hue but never its bold, which turns bright yellow on white
c_yellow="${c_yellow%m}"
assert_eq "warn: YELLOW's hue" "${c_yellow##*[[;]}" "${SGR_WARN##*;}"
assert_not_contains "warn: not bold" ";$SGR_WARN;" ";1;"

# --- Uninstall -------------------------------------------------------------

echo "Uninstall"
setup
mkdir -p "$HOME/.claude"
"$INSTALLER" --yes > /dev/null 2>&1
out=$(env -u NO_COLOR TERM=xterm "$STANZA_DIR/uninstall.sh" -y 2>&1)
assert_contains "header names the prefix" "$out" "stanza uninstall  (~/.local)"
assert_contains "row per removed path" "$out" "  zsh     ~/.zsh/completions/_stanza"
assert_contains "closing row" "$out" "done    stanza uninstalled; 5 items removed"
assert_eq "piped: no ESC byte" "no" "$(esc_state "$out")"
assert_eq "binary removed" "no" "$([[ -e "$HOME/.local/bin/stanza" ]] && echo yes || echo no)"
status=0
out=$("$STANZA_DIR/uninstall.sh" -y 2>&1) || status=$?
assert_eq "nothing left: exits non-zero" "1" "$status"
assert_contains "nothing left: says so" "$out" "error   no stanza installation found; nothing was removed"

# --- Summary ---------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
