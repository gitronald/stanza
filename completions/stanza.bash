#!/usr/bin/env bash
# Bash completion for stanza CLI tool
#
# This script provides tab completion for the stanza command line tool.
#
# Installation:
#   Source this file in your .bashrc or .bash_profile:
#     source /path/to/stanza/completions/stanza.bash
#
#   Or copy to your bash completion directory:
#     sudo cp stanza.bash /etc/bash_completion.d/stanza
#     # OR for user-local installation:
#     mkdir -p ~/.local/share/bash-completion/completions
#     cp stanza.bash ~/.local/share/bash-completion/completions/stanza
#
# Usage:
#   stanza <TAB>           # Show available commands
#   stanza release <TAB>   # Show release subcommands
#   stanza release -<TAB>  # Show release options

_stanza_completion() {
    local cur prev words cword
    local candidates=""
    _init_completion || return

    # Main commands
    local commands="release init guide rules help version"

    # Release subcommands: bump types plus the phase tokens (pr, merge)
    local release_types="patch minor major pre prerelease"
    local release_phases="pr merge"

    # Release options
    local release_opts="--pr-note --no-pr --no-dev-cycle --no-changelog --local -y --yes -q --quiet -v --verbose --json --no-color -h --help"

    # Init options
    local init_opts="-n --name -d --description --public --current-branch-only -y --yes -h --help"

    # Rules actions and options (--local and --force only where the action takes them)
    local rules_actions="install check uninstall"
    local rules_opts="-q --quiet -v --verbose --json --no-color -h --help"

    # Handle completion based on position
    case $cword in
        1)
            # Complete main commands
            candidates="$commands"
            ;;
        2)
            # Complete based on first command
            case ${words[1]} in
                release)
                    # Complete release subcommands (bump types + phases) or options
                    if [[ $cur == -* ]]; then
                        candidates="$release_opts"
                    else
                        candidates="$release_types $release_phases"
                    fi
                    ;;
                init)
                    # Complete init options
                    if [[ $cur == -* ]]; then
                        candidates="$init_opts"
                    fi
                    ;;
                rules)
                    # Complete rules actions or options
                    if [[ $cur == -* ]]; then
                        candidates="$rules_opts"
                    else
                        candidates="$rules_actions"
                    fi
                    ;;
                guide|help|version)
                    # No completion needed for guide, help, and version
                    ;;
            esac
            ;;
        *)
            # Complete options for commands at any position
            case ${words[1]} in
                release)
                    # --pr-note takes a free-text value; don't offer completions.
                    if [[ $prev == "--pr-note" ]]; then
                        return 0
                    fi
                    if [[ $cur == -* ]]; then
                        candidates="$release_opts"
                    elif [[ $cword -eq 3 && ${words[2]} == "pr" ]]; then
                        # After 'release pr', complete the bump type at position 3.
                        candidates="$release_types"
                    fi
                    ;;
                init)
                    # Handle options that require values
                    case $prev in
                        -n|--name|-d|--description)
                            # No completion for values, let user type
                            ;;
                        *)
                            if [[ $cur == -* ]]; then
                                candidates="$init_opts"
                            fi
                            ;;
                    esac
                    ;;
                rules)
                    if [[ $cur == -* ]]; then
                        case ${words[2]} in
                            install)   candidates="--local --force $rules_opts" ;;
                            uninstall) candidates="--local $rules_opts" ;;
                            *)         candidates="$rules_opts" ;;
                        esac
                    fi
                    ;;
            esac
            ;;
    esac

    if [[ -n "$candidates" ]]; then
        COMPREPLY=($(compgen -W "$candidates" -- "$cur"))
    fi

    return 0
}

# Register completion function
complete -F _stanza_completion stanza
