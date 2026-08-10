#!/usr/bin/env bash
set -e

# Stanza CLI Tool Installer
# This script installs the stanza command-line tool and its libraries

# Default installation prefix
PREFIX="$HOME/.local"
SYSTEM_INSTALL=false
INSTALL_COMPLETIONS=true

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

Install stanza CLI tool

Options:
  --prefix=PATH         Install to custom location (default: ~/.local)
  --system              Install system-wide to /usr/local (requires sudo)
  --no-completions      Skip shell completion installation
  -h, --help            Show this help message

Examples:
  ./install.sh                    # User install to ~/.local
  sudo ./install.sh --system      # System install to /usr/local
  ./install.sh --prefix=~/tools   # Custom location
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
            --no-completions)
                INSTALL_COMPLETIONS=false
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
            esac
        done
        exit 1
    fi
}

# Confirm installation with user
confirm_installation() {
    info "Installation configuration:"
    echo "  Installation prefix: $PREFIX"
    echo "  Binary directory:    $PREFIX/bin"
    echo "  Library directory:   $PREFIX/lib/stanza"
    if [[ "$INSTALL_COMPLETIONS" == true ]]; then
        echo "  Shell completions:   Yes"
    else
        echo "  Shell completions:   No"
    fi

    # Check if running as root when system install is requested
    if [[ "$SYSTEM_INSTALL" == true && $EUID -ne 0 ]]; then
        error "System-wide installation requires sudo/root privileges"
        echo "Please run: sudo ./install.sh --system"
        exit 1
    fi

    # Check if running as root for non-system install
    if [[ "$SYSTEM_INSTALL" == false && $EUID -eq 0 ]]; then
        warn "Running as root for user installation"
        warn "Consider running without sudo for user installation"
    fi

    echo ""
    read -p "Continue with installation? [Y/n] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]?$ ]]; then
        info "Installation cancelled"
        exit 0
    fi
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

    # Get the directory where this script is located
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

    # Check if required files exist
    if [[ ! -f "$SCRIPT_DIR/bin/stanza" ]]; then
        error "bin/stanza not found in $SCRIPT_DIR"
        exit 1
    fi

    if [[ ! -d "$SCRIPT_DIR/lib" ]]; then
        error "lib directory not found in $SCRIPT_DIR"
        exit 1
    fi

    # Copy binary
    cp "$SCRIPT_DIR/bin/stanza" "$PREFIX/bin/stanza"
    chmod +x "$PREFIX/bin/stanza"

    # Copy library files
    cp -r "$SCRIPT_DIR/lib/"* "$PREFIX/lib/stanza/"
    chmod +x "$PREFIX/lib/stanza/"*

    # Copy the tool's own VERSION file alongside lib so `stanza --help`
    # can display its version regardless of the user's cwd.
    if [[ -f "$SCRIPT_DIR/VERSION" ]]; then
        cp "$SCRIPT_DIR/VERSION" "$PREFIX/lib/stanza/VERSION"
    fi

    success "Files installed"
}

# Install shell completions
install_completions() {
    if [[ "$INSTALL_COMPLETIONS" == false ]]; then
        return
    fi

    info "Installing shell completions..."

    # Get the directory where this script is located
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

    # Check if completion files exist
    local bash_completion="$SCRIPT_DIR/completions/stanza.bash"
    local zsh_completion="$SCRIPT_DIR/completions/stanza.zsh"

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

    # Check for required dependencies
    check_dependencies

    # Confirm installation with user
    confirm_installation

    # Create installation directories
    create_directories

    # Install files
    install_files

    # Install shell completions (if not disabled and if they exist)
    install_completions

    # Print success message
    print_success
}

# Run main function
main "$@"
