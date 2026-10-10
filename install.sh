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
# Path of this script, or empty when it arrives on stdin (curl | bash). Read
# at top level: inside a function a piped script reports "bash" instead.
SCRIPT_PATH="${BASH_SOURCE[0]:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored messages
info() {
    printf '%b\n' "${BLUE}==>${NC} $*"
}

success() {
    printf '%b\n' "${GREEN}==>${NC} $*"
}

warn() {
    printf '%b\n' "${YELLOW}Warning:${NC} $*"
}

error() {
    printf '%b\n' "${RED}Error:${NC} $*" >&2
}

# Show help message
show_help() {
    cat <<EOF
Usage: ./install.sh [OPTIONS]

Install stanza CLI tool. Run from a checkout, it installs that checkout's
files. Run any other way (e.g. piped from curl), it downloads a tagged
release from GitHub first.

Options:
  --prefix=PATH         Install to custom location (default: ~/.local)
  --system              Install system-wide to /usr/local (requires sudo)
  --version=TAG         Download and install this tag (e.g. 1.1.3 or v1.1.3)
                        instead of the checkout or the latest release
                        (also read from STANZA_VERSION)
  -y, --yes             Skip the confirmation prompt
  --no-completions      Skip shell completion installation
  --no-rules            Skip the Claude Code rule (~/.claude/rules/stanza.md)
  -h, --help            Show this help message

Examples:
  ./install.sh                    # User install to ~/.local
  sudo ./install.sh --system      # System install to /usr/local
  ./install.sh --prefix=~/tools   # Custom location
  curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/gitronald/stanza/main/install.sh | bash
  curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/gitronald/stanza/main/install.sh | bash -s -- --version=1.1.3
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
                    error "--version requires a tag (e.g. --version=1.1.3)"
                    exit 1
                fi
                shift
                ;;
            --version)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    error "--version requires a tag (e.g. --version 1.1.3)"
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
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                echo ""
                show_help
                exit 1
                ;;
        esac
    done
}

# Check for required dependencies
check_dependencies() {
    local missing_deps=()

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

    # Downloading a release needs a fetcher and tar
    if [[ -z "$SOURCE_DIR" ]]; then
        if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
            missing_deps+=("curl")
        fi
        if ! command -v tar &> /dev/null; then
            missing_deps+=("tar")
        fi
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        error "Missing required dependencies: ${missing_deps[*]}"
        echo ""
        echo "Please install the missing dependencies:"
        for dep in "${missing_deps[@]}"; do
            case "$dep" in
                git)
                    echo "  - git: https://git-scm.com/downloads"
                    ;;
                uv)
                    echo "  - uv: https://docs.astral.sh/uv/getting-started/installation/"
                    ;;
                gh)
                    echo "  - gh: https://cli.github.com/manual/installation"
                    ;;
                curl)
                    echo "  - curl or wget, to download the release"
                    ;;
                tar)
                    echo "  - tar, to unpack the release"
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
# for or there is no checkout; then set FETCH_VERSION for fetch_release.
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
            error "Invalid version: $REQUESTED_VERSION"
            exit 1
        fi
    else
        info "Finding the latest stanza release..."
        FETCH_VERSION="$(latest_version)"
        if [[ -z "$FETCH_VERSION" ]]; then
            error "Could not find the latest release at $REPO_URL"
            echo "Check your connection, or pass a tag: --version=X.Y.Z"
            exit 1
        fi
    fi
}

# Remove the download directory on exit
cleanup_fetch() {
    if [[ -n "$FETCH_DIR" && -d "$FETCH_DIR" ]]; then
        rm -rf "$FETCH_DIR"
    fi
}

# Download the archive of tag v$FETCH_VERSION, unpack it to a temp
# directory, and point SOURCE_DIR at the unpacked tree.
fetch_release() {
    [[ -z "$SOURCE_DIR" ]] || return 0

    local url="$REPO_URL/archive/refs/tags/v$FETCH_VERSION.tar.gz"
    local archive root

    FETCH_DIR="$(mktemp -d)"
    trap cleanup_fetch EXIT
    archive="$FETCH_DIR/stanza.tar.gz"

    info "Downloading stanza v$FETCH_VERSION..."
    if command -v curl &> /dev/null; then
        # Refuse a redirect off HTTPS (GitHub serves archives via a redirect)
        curl -fsSL --proto-redir '=https' --retry 2 -o "$archive" "$url" || {
            error "Download failed: $url"
            exit 1
        }
    else
        wget -q -O "$archive" "$url" || {
            error "Download failed: $url"
            exit 1
        }
    fi

    mkdir "$FETCH_DIR/src"
    if ! tar -xzf "$archive" -C "$FETCH_DIR/src"; then
        error "Could not unpack $url"
        exit 1
    fi

    # GitHub archives hold a single top-level directory (stanza-X.Y.Z)
    for root in "$FETCH_DIR/src"/*/; do
        if [[ -f "$root/bin/stanza" && -d "$root/lib" ]]; then
            SOURCE_DIR="${root%/}"
            break
        fi
    done
    if [[ -z "$SOURCE_DIR" ]]; then
        error "bin/stanza not found in the v$FETCH_VERSION archive"
        exit 1
    fi
}

# Ask before installing. When the script itself arrives on stdin (curl |
# bash), the answer comes from the terminal instead; with no terminal, --yes
# is required rather than assumed. Run from a file, the answer is read from
# stdin as always, so `printf y | ./install.sh` keeps working.
confirm_prompt() {
    if [[ "$ASSUME_YES" == true ]]; then
        return
    fi

    if [[ -n "$SCRIPT_PATH" ]]; then
        read -p "Continue with installation? [Y/n] " -n 1 -r
    elif (exec < /dev/tty) 2>/dev/null; then
        read -p "Continue with installation? [Y/n] " -n 1 -r < /dev/tty
    else
        error "No terminal to confirm the installation; rerun with --yes"
        echo "    e.g. curl -fsSL <installer-url> | bash -s -- --yes"
        exit 1
    fi
    echo ""
    if [[ ! $REPLY =~ ^[Yy]?$ ]]; then
        info "Installation cancelled"
        exit 0
    fi
}

# Confirm installation with user
confirm_installation() {
    info "Installation configuration:"
    if [[ -n "$SOURCE_DIR" ]]; then
        echo "  Source:              $SOURCE_DIR"
    else
        echo "  Source:              stanza v$FETCH_VERSION ($REPO_URL)"
    fi
    echo "  Installation prefix: $PREFIX"
    echo "  Binary directory:    $PREFIX/bin"
    echo "  Library directory:   $PREFIX/lib/stanza"
    if [[ "$INSTALL_COMPLETIONS" == true ]]; then
        echo "  Shell completions:   Yes"
    else
        echo "  Shell completions:   No"
    fi
    if [[ "$INSTALL_RULES" == true && "$SYSTEM_INSTALL" == false ]]; then
        echo "  Claude Code rule:    Yes, if ~/.claude exists"
    else
        echo "  Claude Code rule:    No"
    fi

    # Check if running as root when system install is requested
    if [[ "$SYSTEM_INSTALL" == true && $EUID -ne 0 ]]; then
        error "System-wide installation requires sudo/root privileges"
        echo "Please rerun it with sudo, e.g.: sudo ./install.sh --system"
        exit 1
    fi

    # Check if running as root for non-system install
    if [[ "$SYSTEM_INSTALL" == false && $EUID -eq 0 ]]; then
        warn "Running as root for user installation"
        warn "Consider running without sudo for user installation"
    fi

    echo ""
    confirm_prompt
}

# Create installation directories
create_directories() {
    info "Creating installation directories..."

    mkdir -p "$PREFIX/bin"
    mkdir -p "$PREFIX/lib/stanza"

    if [[ "$INSTALL_COMPLETIONS" == true ]]; then
        # Try to create system completion directories if we have permissions
        if [[ -w "$PREFIX/share" ]] || [[ $EUID -eq 0 ]]; then
            mkdir -p "$PREFIX/share/bash-completion/completions"
            mkdir -p "$PREFIX/share/zsh/site-functions"
        fi
    fi

    success "Directories created"
}

# Copy files to installation location
install_files() {
    info "Installing stanza files..."

    # Check if required files exist
    if [[ ! -f "$SOURCE_DIR/bin/stanza" ]]; then
        error "bin/stanza not found in $SOURCE_DIR"
        exit 1
    fi

    if [[ ! -d "$SOURCE_DIR/lib" ]]; then
        error "lib directory not found in $SOURCE_DIR"
        exit 1
    fi

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

    success "Files installed"
}

# Install shell completions
install_completions() {
    if [[ "$INSTALL_COMPLETIONS" == false ]]; then
        return
    fi

    info "Installing shell completions..."

    # Check if completion files exist
    local bash_completion="$SOURCE_DIR/completions/stanza.bash"
    local zsh_completion="$SOURCE_DIR/completions/stanza.zsh"

    if [[ ! -f "$bash_completion" && ! -f "$zsh_completion" ]]; then
        warn "No completion files found, skipping completion installation"
        return
    fi

    # Install bash completion
    if [[ -f "$bash_completion" ]]; then
        if [[ -w "$PREFIX/share/bash-completion/completions" ]] || [[ $EUID -eq 0 ]]; then
            cp "$bash_completion" "$PREFIX/share/bash-completion/completions/stanza"
            success "Bash completion installed to $PREFIX/share/bash-completion/completions/stanza"
        elif mkdir -p "$HOME/.bash_completion.d" 2>/dev/null; then
            cp "$bash_completion" "$HOME/.bash_completion.d/stanza"
            success "Bash completion installed to ~/.bash_completion.d/stanza"
            info "Add this to your ~/.bashrc to enable completions:"
            echo "    for f in ~/.bash_completion.d/*; do source \"\$f\"; done"
        else
            warn "Could not install bash completion"
        fi
    fi

    # Install zsh completion
    if [[ -f "$zsh_completion" ]]; then
        if [[ -w "$PREFIX/share/zsh/site-functions" ]] || [[ $EUID -eq 0 ]]; then
            cp "$zsh_completion" "$PREFIX/share/zsh/site-functions/_stanza"
            success "Zsh completion installed to $PREFIX/share/zsh/site-functions/_stanza"
        elif mkdir -p "$HOME/.zsh/completions" 2>/dev/null; then
            cp "$zsh_completion" "$HOME/.zsh/completions/_stanza"
            success "Zsh completion installed to ~/.zsh/completions/_stanza"
            info "Add this to your ~/.zshrc to enable completions:"
            echo "    fpath=(~/.zsh/completions \$fpath)"
            echo "    autoload -Uz compinit && compinit"
        else
            warn "Could not install zsh completion"
        fi
    fi
}

# Install the generated Claude Code rule (~/.claude/rules/stanza.md) via the
# just-installed binary. Only for user installs where Claude Code is already
# set up: ~/.claude is never created, and under sudo $HOME is the wrong home.
install_claude_rule() {
    if [[ "$INSTALL_RULES" == false ]]; then
        return
    fi
    if [[ "$SYSTEM_INSTALL" == true ]]; then
        info "Skipping the Claude Code rule for a system install; each user can run: stanza rules install"
        return
    fi
    if [[ ! -d "$HOME/.claude" ]]; then
        info "Claude Code not detected (~/.claude missing); to add the rule later: stanza rules install"
        return
    fi

    info "Installing Claude Code rule..."
    if "$PREFIX/bin/stanza" -q rules install > /dev/null; then
        success "Claude Code rule installed to ~/.claude/rules/stanza.md"
    else
        warn "Could not install the Claude Code rule; run: stanza rules install"
    fi
}

# Check if installation directory is in PATH
check_path() {
    if [[ ":$PATH:" == *":$PREFIX/bin:"* ]]; then
        success "$PREFIX/bin is in your PATH"
    else
        warn "$PREFIX/bin is not in your PATH"
        echo ""
        info "Add the following to your shell configuration file (~/.bashrc, ~/.zshrc, etc.):"
        echo "    export PATH=\"$PREFIX/bin:\$PATH\""
    fi
}

# Print success message
print_success() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    success "Stanza CLI tool installed successfully!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    info "Installation details:"
    echo "  Binary:    $PREFIX/bin/stanza"
    echo "  Libraries: $PREFIX/lib/stanza"
    echo ""

    # Check PATH and provide instructions if needed
    check_path

    echo ""
    info "Next steps:"
    echo "  1. Ensure $PREFIX/bin is in your PATH (see above if needed)"
    echo "  2. Test the installation: stanza --help"
    echo "  3. View available commands: stanza help"
    echo ""
    info "For more information, visit: https://github.com/gitronald/stanza"
    echo ""
}

# Main installation flow
main() {
    echo ""
    info "Stanza CLI Tool Installer"
    echo ""

    # Parse command-line arguments
    parse_args "$@"

    # Use this checkout, or pick the release to download
    choose_source

    # Check for required dependencies
    check_dependencies

    # Confirm installation with user
    confirm_installation

    # Download the release when not installing from a checkout
    fetch_release

    # Create installation directories
    create_directories

    # Install files
    install_files

    # Install shell completions (if not disabled and if they exist)
    install_completions

    # Install the Claude Code rule (user installs with ~/.claude present)
    install_claude_rule

    # Print success message
    print_success
}

# Run main function. Everything above only defines functions and variables,
# so a truncated download (curl | bash cut off mid-stream) never gets here.
# The braces make bash read the whole line before running it: a cut inside
# it is a syntax error, where a bare `main` cut before "$@" would run main
# with the arguments dropped.
{ main "$@"; }
