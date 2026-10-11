#!/usr/bin/env bash
set -e

# Stanza CLI Tool Installer
# This script installs the stanza command-line tool and its libraries

# Default installation prefix
PREFIX="$HOME/.local"
SYSTEM_INSTALL=false
INSTALL_COMPLETIONS=true
INSTALL_RULES=true
ASSUME_YES=false
# Tag to fetch when installing without a checkout (or with --version)
REQUESTED_VERSION="${STANZA_VERSION:-}"
# Repository to fetch from; overridable so tests can point at a local copy
REPO_URL="${STANZA_REPO_URL:-https://github.com/gitronald/stanza}"
# Directory holding bin/, lib/, and completions/ (set by choose_source or fetch_release)
SOURCE_DIR=""
FETCH_DIR=""
FETCH_VERSION=""
# Where completions go when ~/.local/share cannot be written; these need a
# line in the shell startup file, so install_completions checks for them
BASH_COMPLETION_FALLBACK="$HOME/.bash_completion.d/stanza"
ZSH_COMPLETION_FALLBACK="$HOME/.zsh/completions/_stanza"
# Version being installed, and where each optional file goes (empty when it
# is not installed); set by plan_install before the prompt
INSTALL_VERSION=""
BASH_COMPLETION_DEST=""
ZSH_COMPLETION_DEST=""
RULE_DEST=""
# Path of this script, or empty when it arrives on stdin (curl | bash). Read
# at top level: inside a function a piped script reports "bash" instead.
SCRIPT_PATH="${BASH_SOURCE[0]:-}"

# --- Output helpers ----------------------------------------------------------
# The row grammar of `stanza release`: a bold "stanza <command>" header, then
# "  label   content" rows whose label alone carries color. A copy of
# print_header, print_row, print_hint, and print_done in lib/stanza-common,
# which neither installer can source: install.sh runs before the download,
# and uninstall.sh is often downloaded on its own. Both carry this same
# block; keep the three in step (tests/test-install.sh checks them).
LABEL_WIDTH=8
SGR_BOLD='1'
SGR_LABEL='1;38;5;151'    # bold pale green: rows that report a step
SGR_PLAN='1;38;5;110'     # bold light blue: rows that list the plan before the prompt
SGR_WARN='0;33'    # never bold: bold yellow turns bright yellow on white
SGR_HINT='0;36'
SGR_ERROR='0;31'
SGR_DONE='0;32'
NO_COLOR_FLAG=false

# Succeed when fd $1 (default 1) should get color: never under NO_COLOR or
# --no-color, always under a non-zero CLICOLOR_FORCE, otherwise only for a
# terminal other than TERM=dumb
use_color() {
    [[ -z "${NO_COLOR:-}" && "$NO_COLOR_FLAG" != true ]] || return 1
    [[ -z "${CLICOLOR_FORCE:-}" || "$CLICOLOR_FORCE" == 0 ]] || return 0
    [[ "${TERM:-dumb}" != dumb && -t "${1:-1}" ]]
}

# "stanza $1  ($2)", the name in bold
header() {
    local on="" off=""
    if use_color 1; then on="\033[${SGR_BOLD}m" off='\033[0m'; fi
    printf "%bstanza %s%b%s\n" "$on" "$1" "$off" "${2:+  ($2)}"
}

# "  label   content" to fd $3 (default 1), the label in SGR $4 (default
# SGR_LABEL). An empty label continues the row above.
row() {
    local label="$1" content="${2:-}" fd="${3:-1}" on="" off=""
    if [[ -n "$label" ]] && use_color "$fd"; then
        on="\033[${4:-$SGR_LABEL}m" off='\033[0m'
    fi
    printf "  %b%-${LABEL_WIDTH}s%b%s\n" "$on" "$label" "$off" "$content" >&"$fd"
}

warn() { row warn "$1" 2 "$SGR_WARN"; }
hint() { row hint "$1" 2 "$SGR_HINT"; }
error() { row error "$1" 2 "$SGR_ERROR"; }
more() { row "" "$1" 2; }
done_row() { row "done" "$1" 1 "$SGR_DONE"; }
plan_row() { row "$1" "$2" 1 "$SGR_PLAN"; }

# $1 with a leading $HOME shown as ~
tilde() {
    case "$1" in
        "$HOME" | "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
        *) printf '%s' "$1" ;;
    esac
}
# --- End of output helpers ---------------------------------------------------

# Show help message
show_help() {
    cat <<EOF
Usage: ./install.sh [OPTIONS]

Install stanza CLI tool. Run from a checkout, it installs that checkout's
files. Run any other way (e.g. piped from curl), it downloads a release's
asset from GitHub first and checks it against the release's SHA-256.

Options:
  --prefix=PATH         Install to custom location (default: ~/.local)
  --system              Install system-wide to /usr/local (requires sudo)
  --version=TAG         Download and install this tag (X.Y.Z or vX.Y.Z)
                        instead of the checkout or the latest release
                        (also read from STANZA_VERSION)
  -y, --yes             Skip the confirmation prompt
  --no-completions      Skip shell completion installation
  --no-rules            Skip the Claude Code rule (~/.claude/rules/stanza.md)
  --no-color            Print without color (also NO_COLOR=1)
  -h, --help            Show this help message

Examples:
  ./install.sh                    # User install to ~/.local
  sudo ./install.sh --system      # System install to /usr/local
  ./install.sh --prefix=~/tools   # Custom location
  curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/gitronald/stanza/main/install.sh | bash
  curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/gitronald/stanza/main/install.sh | bash -s -- --version=X.Y.Z
EOF
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prefix=*)
                PREFIX="${1#*=}"
                # Expand tilde if present
                PREFIX="${PREFIX/#\~/$HOME}"
                shift
                ;;
            --system)
                SYSTEM_INSTALL=true
                PREFIX="/usr/local"
                shift
                ;;
            --version=*)
                REQUESTED_VERSION="${1#*=}"
                # Empty would read as "no version" and silently install latest
                if [[ -z "$REQUESTED_VERSION" ]]; then
                    error "--version requires a tag; nothing was installed"
                    hint "--version=X.Y.Z"
                    exit 1
                fi
                shift
                ;;
            --version)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    error "--version requires a tag; nothing was installed"
                    hint "--version X.Y.Z"
                    exit 1
                fi
                REQUESTED_VERSION="$2"
                shift 2
                ;;
            -y|--yes)
                ASSUME_YES=true
                shift
                ;;
            --no-completions)
                INSTALL_COMPLETIONS=false
                shift
                ;;
            --no-rules)
                INSTALL_RULES=false
                shift
                ;;
            --no-color)
                NO_COLOR_FLAG=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                error "unknown option: $1; nothing was installed"
                hint "install.sh --help lists the options"
                exit 1
                ;;
        esac
    done
}

# Check for required dependencies
check_dependencies() {
    local missing_deps=() dep list=""

    # Check for git
    if ! command -v git &> /dev/null; then
        missing_deps+=("git")
    fi

    # Check for uv
    if ! command -v uv &> /dev/null; then
        missing_deps+=("uv")
    fi

    # Check for gh (GitHub CLI)
    if ! command -v gh &> /dev/null; then
        missing_deps+=("gh")
    fi

    # Downloading a release needs a fetcher, a SHA-256 tool, and tar
    if [[ -z "$SOURCE_DIR" ]]; then
        if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
            missing_deps+=("curl")
        fi
        if ! command -v sha256sum &> /dev/null && ! command -v shasum &> /dev/null; then
            missing_deps+=("sha256sum")
        fi
        if ! command -v tar &> /dev/null; then
            missing_deps+=("tar")
        fi
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        for dep in "${missing_deps[@]}"; do
            list="${list:+$list, }$dep"
        done
        error "missing required tools: $list; nothing was installed"
        for dep in "${missing_deps[@]}"; do
            case "$dep" in
                git)
                    hint "git: https://git-scm.com/downloads"
                    ;;
                uv)
                    hint "uv: https://docs.astral.sh/uv/getting-started/installation/"
                    ;;
                gh)
                    hint "gh: https://cli.github.com/manual/installation"
                    ;;
                curl)
                    hint "curl or wget, to download the release"
                    ;;
                sha256sum)
                    hint "sha256sum (coreutils) or shasum, to verify the release"
                    ;;
                tar)
                    hint "tar, to unpack the release"
                    ;;
            esac
        done
        exit 1
    fi
}

# Directory of this script when it was run from a file inside a stanza
# checkout; empty when piped (curl | bash) or run from elsewhere.
checkout_dir() {
    local dir
    [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]] || return 0
    dir="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
    if [[ -f "$dir/bin/stanza" && -d "$dir/lib" ]]; then
        echo "$dir"
    fi
}

# Latest stable tag (vX.Y.Z, no prerelease suffix) on the remote, without the v
latest_version() {
    git ls-remote --tags --refs "$REPO_URL" 'v*' 2>/dev/null \
        | sed -n 's|.*refs/tags/v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$|\1|p' \
        | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}

# Install from the checkout this script sits in, unless a version was asked
# for or there is no checkout; then set FETCH_VERSION for fetch_release (left
# empty for find_latest_release when no version was asked for).
choose_source() {
    local dir
    dir="$(checkout_dir)"
    if [[ -n "$dir" && -z "$REQUESTED_VERSION" ]]; then
        SOURCE_DIR="$dir"
        return
    fi

    if [[ -n "$REQUESTED_VERSION" ]]; then
        FETCH_VERSION="${REQUESTED_VERSION#v}"
        if [[ ! "$FETCH_VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
            error "invalid version: $REQUESTED_VERSION; nothing was installed"
            hint "pass a release tag, e.g. --version=X.Y.Z"
            exit 1
        fi
    fi

    # Fetch over HTTPS only (file:// is the tests' local stand-in). This is
    # the only scheme check wget gets: its --https-only covers recursive
    # downloads, not a plain URL or a redirect.
    if [[ ! "$REPO_URL" =~ ^(https|file):// ]]; then
        error "refusing a non-HTTPS repository URL; nothing was installed"
        more "$REPO_URL"
        hint "set STANZA_REPO_URL to an https:// URL, or unset it"
        exit 1
    fi
}

# Set FETCH_VERSION to the latest release when downloading without a pinned
# version. Runs after check_dependencies, so a missing git is reported as
# such rather than as an unreachable remote.
find_latest_release() {
    [[ -z "$SOURCE_DIR" && -z "$FETCH_VERSION" ]] || return 0

    FETCH_VERSION="$(latest_version)"
    if [[ -z "$FETCH_VERSION" ]]; then
        error "could not find the latest release; nothing was installed"
        more "$REPO_URL"
        hint "check your connection, or pass a tag: --version=X.Y.Z"
        exit 1
    fi
}

# Remove the download directory on exit
cleanup_fetch() {
    if [[ -n "$FETCH_DIR" && -d "$FETCH_DIR" ]]; then
        rm -rf "$FETCH_DIR"
    fi
}

# Download $1 to the file $2
download() {
    if command -v curl &> /dev/null; then
        # HTTPS (or the tests' file://) for the request, HTTPS only for the
        # redirect GitHub serves assets through
        curl -fsSL --proto '=https,file' --tlsv1.2 --proto-redir '=https' \
            --retry 2 -o "$2" "$1"
    else
        wget -q -O "$2" "$1"
    fi
}

# SHA-256 of the file $1, as lowercase hex
sha256_of() {
    if command -v sha256sum &> /dev/null; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Hint for a failure that a retry may fix, naming where to report it
hint_retry() {
    hint "retry; if it fails again: ${REPO_URL#https://}/issues"
}

# Download release v$FETCH_VERSION's asset and its checksum, refuse to go on
# unless they match, unpack the asset to a temp directory, and point
# SOURCE_DIR at the unpacked tree. The asset and checksum are published by
# scripts/release-asset.sh; tags from before it have neither and are refused.
fetch_release() {
    [[ -z "$SOURCE_DIR" ]] || return 0

    local name="stanza-$FETCH_VERSION.tar.gz"
    local base="$REPO_URL/releases/download/v$FETCH_VERSION"
    local archive expected actual root

    FETCH_DIR="$(mktemp -d)"
    trap cleanup_fetch EXIT
    archive="$FETCH_DIR/$name"

    row fetch "$name"
    if ! download "$base/$name" "$archive"; then
        error "could not download the release asset for v$FETCH_VERSION; nothing was installed"
        more "$base/$name"
        hint "a release tagged in the last few minutes may still be publishing; retry"
        hint "a tag with no asset installs from a clone:"
        more "git clone --branch v$FETCH_VERSION $REPO_URL stanza && stanza/install.sh"
        exit 1
    fi
    if ! download "$base/$name.sha256" "$archive.sha256"; then
        error "could not download the checksum for v$FETCH_VERSION; nothing was installed"
        more "$base/$name.sha256"
        hint_retry
        exit 1
    fi

    expected="$(awk 'NR == 1 {print tolower($1)}' "$archive.sha256")"
    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        error "malformed checksum file for v$FETCH_VERSION; nothing was installed"
        more "$base/$name.sha256"
        hint_retry
        exit 1
    fi
    actual="$(sha256_of "$archive")"
    if [[ "$actual" != "$expected" ]]; then
        error "sha256 mismatch for $name; nothing was installed"
        more "expected $expected"
        more "actual   $actual"
        hint_retry
        exit 1
    fi
    row verify "sha256 ${actual:0:16}"

    mkdir "$FETCH_DIR/src"
    if ! tar -xzf "$archive" -C "$FETCH_DIR/src"; then
        error "could not unpack $name; nothing was installed"
        hint_retry
        exit 1
    fi

    # The asset holds a single top-level directory (stanza-X.Y.Z)
    for root in "$FETCH_DIR/src"/*/; do
        if [[ -f "$root/bin/stanza" && -d "$root/lib" ]]; then
            SOURCE_DIR="${root%/}"
            break
        fi
    done
    if [[ -z "$SOURCE_DIR" ]]; then
        error "bin/stanza not found in $name; nothing was installed"
        hint_retry
        exit 1
    fi
}

# Where a completion goes: $PREFIX/share/$1 when that directory can be
# written (or created), otherwise the per-user fallback $2. A --prefix other
# than ~/.local always uses its own share/, created as needed, so its
# completions stay out of $HOME.
completion_dest() {
    local dir="$PREFIX/share/$1"
    if [[ "$PREFIX" != "$HOME/.local" || $EUID -eq 0 || -w "$dir" ]] \
        || [[ ! -e "$dir" && -w "$PREFIX/share" ]]; then
        printf '%s' "$dir/$(basename "$2")"
    else
        printf '%s' "$2"
    fi
}

# Settle the version and where each optional file goes, so the block shown
# before the prompt names the same paths the install writes
plan_install() {
    if [[ -z "$SOURCE_DIR" ]]; then
        INSTALL_VERSION="$FETCH_VERSION"
    elif [[ -f "$SOURCE_DIR/VERSION" ]]; then
        INSTALL_VERSION="$(head -1 "$SOURCE_DIR/VERSION" | tr -d '[:space:]')"
    fi
    if [[ "$INSTALL_COMPLETIONS" == true ]]; then
        BASH_COMPLETION_DEST="$(completion_dest bash-completion/completions "$BASH_COMPLETION_FALLBACK")"
        ZSH_COMPLETION_DEST="$(completion_dest zsh/site-functions "$ZSH_COMPLETION_FALLBACK")"
    fi
    # Only for user installs where Claude Code is already set up: ~/.claude
    # is never created, and under sudo $HOME is the wrong home
    if [[ "$INSTALL_RULES" == true && "$SYSTEM_INSTALL" == false && -d "$HOME/.claude" ]]; then
        RULE_DEST="$HOME/.claude/rules/stanza.md"
    fi
}

# Ask before installing. When the script itself arrives on stdin (curl |
# bash), the answer comes from the terminal instead; with no terminal, --yes
# is required rather than assumed. Run from a file, the answer is read from
# stdin as always, so `printf y | ./install.sh` keeps working.
confirm_prompt() {
    local question="  Install stanza${INSTALL_VERSION:+ $INSTALL_VERSION}? [Y/n] "
    # read -p shows the question only when it reads from a terminal
    local shown=true

    if [[ "$ASSUME_YES" == true ]]; then
        return
    fi

    if [[ -n "$SCRIPT_PATH" ]]; then
        [[ -t 0 ]] || shown=false
        read -p "$question" -n 1 -r
    elif (exec < /dev/tty) 2>/dev/null; then
        read -p "$question" -n 1 -r < /dev/tty
    else
        error "no terminal to confirm the install; nothing was installed"
        hint "rerun with --yes, e.g. curl -fsSL <installer-url> | bash -s -- --yes"
        exit 1
    fi
    if [[ "$shown" == true ]]; then
        # Enter already ended the line; any other key did not
        [[ -z "$REPLY" ]] || printf '\n'
        printf '\n'
    fi
    if [[ ! $REPLY =~ ^[Yy]?$ ]]; then
        row cancel "nothing was installed"
        exit 0
    fi
}

# Show what will be installed where, then confirm with the user
confirm_installation() {
    # Check if running as root when system install is requested
    if [[ "$SYSTEM_INSTALL" == true && $EUID -ne 0 ]]; then
        error "a system install needs root; nothing was installed"
        hint "sudo ./install.sh --system"
        exit 1
    fi

    plan_install
    header install "${INSTALL_VERSION:+v$INSTALL_VERSION, }$(tilde "$PREFIX")"
    if [[ -z "$SOURCE_DIR" ]]; then
        plan_row source "${REPO_URL#https://}, release v$FETCH_VERSION"
    else
        plan_row source "$(tilde "$SOURCE_DIR"), checkout"
    fi
    plan_row bin "$(tilde "$PREFIX/bin/stanza")"
    plan_row lib "$(tilde "$PREFIX/lib/stanza")"
    [[ -z "$BASH_COMPLETION_DEST" ]] || plan_row bash "$(tilde "$BASH_COMPLETION_DEST")"
    [[ -z "$ZSH_COMPLETION_DEST" ]] || plan_row zsh "$(tilde "$ZSH_COMPLETION_DEST")"
    [[ -z "$RULE_DEST" ]] || plan_row rule "$(tilde "$RULE_DEST")"

    # Check if running as root for non-system install
    if [[ "$SYSTEM_INSTALL" == false && $EUID -eq 0 ]]; then
        warn "running as root for a user install"
        hint "rerun without sudo to install for your own user"
    fi

    printf '\n'
    confirm_prompt
}

# Copy the binary and libraries to the installation location
install_files() {
    # Check if required files exist
    if [[ ! -f "$SOURCE_DIR/bin/stanza" || ! -d "$SOURCE_DIR/lib" ]]; then
        error "bin/stanza or lib/ missing in $(tilde "$SOURCE_DIR"); nothing was installed"
        hint "install from a fresh clone: git clone $REPO_URL"
        exit 1
    fi

    mkdir -p "$PREFIX/bin"
    mkdir -p "$PREFIX/lib/stanza"

    # Copy binary
    cp "$SOURCE_DIR/bin/stanza" "$PREFIX/bin/stanza"
    chmod +x "$PREFIX/bin/stanza"

    # Copy library files
    cp -r "$SOURCE_DIR/lib/"* "$PREFIX/lib/stanza/"
    chmod +x "$PREFIX/lib/stanza/"*

    # Copy the tool's own VERSION file alongside lib so `stanza --help`
    # can display its version regardless of the user's cwd.
    if [[ -f "$SOURCE_DIR/VERSION" ]]; then
        cp "$SOURCE_DIR/VERSION" "$PREFIX/lib/stanza/VERSION"
    fi

    row files "$(tilde "$PREFIX/bin/stanza"), $(tilde "$PREFIX/lib/stanza")"
}

# Startup file a bash user edits: login bash on macOS reads ~/.bash_profile.
# The tilde is shown to the user, not expanded
# shellcheck disable=SC2088
bash_startup_file() {
    if [[ "$(uname -s 2>/dev/null)" == Darwin ]]; then
        printf '~/.bash_profile'
    else
        printf '~/.bashrc'
    fi
}

# Copy completion $2 to $3, shown as row $1; on a problem, warn and return 1
install_completion() {
    local shell="$1" src="$2" dest="$3"
    [[ -n "$dest" ]] || return 0
    if [[ ! -f "$src" ]]; then
        warn "no $shell completion in $(tilde "$SOURCE_DIR"); skipped"
        return 1
    fi
    if mkdir -p "$(dirname "$dest")" 2>/dev/null && cp "$src" "$dest" 2>/dev/null; then
        row "$shell" "$(tilde "$dest")"
    else
        warn "could not write $(tilde "$dest")"
        return 1
    fi
}

# Install shell completions, with the startup-file line a fallback location needs
install_completions() {
    if install_completion bash "$SOURCE_DIR/completions/stanza.bash" "$BASH_COMPLETION_DEST" \
        && [[ "$BASH_COMPLETION_DEST" == "$BASH_COMPLETION_FALLBACK" ]]; then
        hint "add to $(bash_startup_file): for f in ~/.bash_completion.d/*; do . \"\$f\"; done"
    fi
    if install_completion zsh "$SOURCE_DIR/completions/stanza.zsh" "$ZSH_COMPLETION_DEST" \
        && [[ "$ZSH_COMPLETION_DEST" == "$ZSH_COMPLETION_FALLBACK" ]]; then
        hint "add to ~/.zshrc: fpath=(~/.zsh/completions \$fpath)"
        more "and, if it has no compinit: autoload -Uz compinit && compinit"
    fi
}

# Install the generated Claude Code rule (~/.claude/rules/stanza.md) via the
# just-installed binary, when plan_install chose to
install_claude_rule() {
    if [[ "$INSTALL_RULES" == false ]]; then
        return
    fi
    if [[ "$SYSTEM_INSTALL" == true ]]; then
        hint "no rule for a system install; each user can run: stanza rules install"
        return
    fi
    if [[ -z "$RULE_DEST" ]]; then
        hint "no ~/.claude, so no rule; to add it later: stanza rules install"
        return
    fi

    if "$PREFIX/bin/stanza" -q rules install > /dev/null; then
        row rule "$(tilde "$RULE_DEST")"
    else
        warn "could not install $(tilde "$RULE_DEST")"
        hint "stanza rules install"
    fi
}

# The command that puts $1 on PATH for the user's shell
path_hint() {
    local bin="$1" ref="$1" line
    case "$bin" in
        "$HOME"/*) ref="\$HOME${bin#"$HOME"}" ;;
    esac
    line="export PATH=\"$ref:\$PATH\""
    case "${SHELL##*/}" in
        zsh) printf "echo '%s' >> ~/.zshrc" "$line" ;;
        bash) printf "echo '%s' >> %s" "$line" "$(bash_startup_file)" ;;
        fish) printf 'fish_add_path %s' "$(tilde "$bin")" ;;
        *) printf 'add to your shell startup file: %s' "$line" ;;
    esac
}

# Warn when the binary's directory is not on PATH; the closing row says
# what to do next either way
finish() {
    local version="stanza${INSTALL_VERSION:+ $INSTALL_VERSION}"
    if [[ ":$PATH:" == *":$PREFIX/bin:"* ]]; then
        done_row "$version. Run: stanza --help"
    else
        warn "$(tilde "$PREFIX/bin") is not on your PATH"
        hint "$(path_hint "$PREFIX/bin")"
        done_row "$version. Open a new terminal, then run: stanza --help"
    fi
}

# Main installation flow
main() {
    local arg
    # Settle color before anything prints, even an error about an argument
    for arg in "$@"; do
        [[ "$arg" != --no-color ]] || NO_COLOR_FLAG=true
    done

    # Parse command-line arguments
    parse_args "$@"

    # Use this checkout, or pick the release to download
    choose_source

    # Check for required dependencies
    check_dependencies

    # Look up the latest release when downloading without a pinned version
    find_latest_release

    # Show the plan and confirm installation with user
    confirm_installation

    # Download the release when not installing from a checkout
    fetch_release

    # Install files
    install_files

    # Install shell completions (if not disabled and if they exist)
    install_completions

    # Install the Claude Code rule (user installs with ~/.claude present)
    install_claude_rule

    # PATH check and the closing row
    finish
}

# Run main function. Everything above only defines functions and variables,
# so a truncated download (curl | bash cut off mid-stream) never gets here.
# The braces make bash read the whole line before running it: a cut inside
# it is a syntax error, where a bare `main` cut before "$@" would run main
# with the arguments dropped.
{ main "$@"; }
