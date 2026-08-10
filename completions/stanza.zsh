#compdef stanza
# Zsh completion for stanza CLI tool
#
# This script provides tab completion for the stanza command line tool.
#
# Installation:
#   Add this file to your fpath and enable compinit in your .zshrc:
#     fpath=(/path/to/stanza/completions $fpath)
#     autoload -Uz compinit && compinit
#
#   Or copy to your zsh completion directory:
#     sudo cp stanza.zsh /usr/local/share/zsh/site-functions/_stanza
#     # OR for user-local installation:
#     mkdir -p ~/.zsh/completions
#     cp stanza.zsh ~/.zsh/completions/_stanza
#     # Then add to .zshrc:
#     fpath=(~/.zsh/completions $fpath)
#     autoload -Uz compinit && compinit
#
# Usage:
#   stanza <TAB>           # Show available commands with descriptions
#   stanza release <TAB>   # Show release subcommands with descriptions
#   stanza release -<TAB>  # Show release options with descriptions

_stanza() {
    local context state state_descr line
    typeset -A opt_args

    _arguments -C \
        '1: :_stanza_commands' \
        '*::arg:->args'

    case $state in
        args)
            case $words[1] in
                release)
                    _stanza_release
                    ;;
                init)
                    _stanza_init
                    ;;
                guide)
                    # No arguments for guide
                    ;;
                help)
                    # No arguments for help
                    ;;
                version)
                    # No arguments for version
                    ;;
            esac
            ;;
    esac
}

_stanza_commands() {
    local -a commands
    commands=(
        'release:Create a release (patch|minor|major|prerelease)'
        'init:Initialize a GitHub repository'
        'guide:Print the agent-facing release guide'
        'help:Show help message'
        'version:Show stanza version'
    )
    _describe 'stanza command' commands
}

_stanza_release() {
    local -a release_types release_phases
    release_types=(
        'patch:Patch version release (promote alpha to stable, or bump patch)'
        'minor:Minor version release (e.g., 0.1.0 -> 0.2.0)'
        'major:Major version release (e.g., 0.1.0 -> 1.0.0)'
        'pre:Prerelease version (alias for prerelease)'
        'prerelease:Prerelease version (e.g., 0.1.0 -> 0.1.1a0); no PR'
    )
    release_phases=(
        'pr:Phase 1 - bump on dev, open the PR, then stop for review'
        'merge:Phase 2 - merge the open PR, tag, open the next cycle'
    )

    _arguments -C \
        '1: :->first' \
        '2: :->second' \
        '--pr-note[Append a note to the PR body]:note text:' \
        '--no-dev-cycle[Skip the post-release dev cycle (no merge-back or bump)]' \
        '--no-changelog[Skip CHANGELOG [Unreleased] promotion and its empty-section check]' \
        '--local[Local-only mode (skip all remote operations)]' \
        '(-y --yes)'{-y,--yes}'[Auto-confirm all prompts]' \
        '(-q --quiet)'{-q,--quiet}'[Reduce output to one-line outcomes]' \
        '(-v --verbose)'{-v,--verbose}'[Show step internals (-vv dumps git/gh commands)]' \
        '--json[Emit a single JSON document on stdout]' \
        '--no-color[Disable ANSI color]' \
        '(-h --help)'{-h,--help}'[Show help message]'

    case $state in
        first)
            # First arg: a bump type or a phase token.
            _describe 'release type' release_types
            _describe 'release phase' release_phases
            ;;
        second)
            # After the 'pr' phase, the second positional is a bump type.
            if [[ "$line[1]" == "pr" ]]; then
                _describe 'bump type' release_types
            fi
            ;;
    esac
}

_stanza_init() {
    _arguments \
        '(-n --name)'{-n,--name}'[Repository name]:name:' \
        '(-d --description)'{-d,--description}'[Repository description]:description:' \
        '--public[Create a public repository (default: private)]' \
        '--current-branch-only[Only push current branch (default: push all branches)]' \
        '(-y --yes)'{-y,--yes}'[Auto-confirm all prompts]' \
        '(-h --help)'{-h,--help}'[Show help message]'
}

# Run completion function
_stanza "$@"
