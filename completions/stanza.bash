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
    _init_completion || return

    # Main commands
    local commands="release init guide rules help version"

    # Release subcommands: bump types plus the phase tokens (pr, merge)
    local release_types="patch minor major pre prerelease"
    local release_phases="pr merge"

    # Release options
    local release_opts="--pr-note --no-dev-cycle --no-changelog --local -y --yes -q --quiet -v --verbose --json --no-color -h --help"

    # Init options
    local init_opts="-n --name -d --description --public --current-branch-only -y --yes -h --help"

    # Rules actions and options
    local rules_actions="install check uninstall"
    local rules_opts="--local --force -q --quiet --json --no-color -h --help"

    # Handle completion based on position
    case $cword in
        1)
            # Complete main commands
            COMPREPLY=($(compgen -W "$commands" -- "$cur"))
            ;;
        2)
            # Complete based on first command
            case ${words[1]} in
                release)
                    # Complete release subcommands (bump types + phases) or options
                    if [[ $cur == -* ]]; then
                        COMPREPLY=($(compgen -W "$release_opts" -- "$cur"))
                    else
                        COMPREPLY=($(compgen -W "$release_types $release_phases" -- "$cur"))
                    fi
                    ;;
                init)
                    # Complete init options
                    if [[ $cur == -* ]]; then
                        COMPREPLY=($(compgen -W "$init_opts" -- "$cur"))
                    fi
                    ;;
                rules)
                    # Complete rules actions or options
                    if [[ $cur == -* ]]; then
                        COMPREPLY=($(compgen -W "$rules_opts" -- "$cur"))
                    else
                        COMPREPLY=($(compgen -W "$rules_actions" -- "$cur"))
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
                        COMPREPLY=($(compgen -W "$release_opts" -- "$cur"))
                    elif [[ $cword -eq 3 && ${words[2]} == "pr" ]]; then
                        # After 'release pr', complete the bump type at position 3.
                        COMPREPLY=($(compgen -W "$release_types" -- "$cur"))
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
                                COMPREPLY=($(compgen -W "$init_opts" -- "$cur"))
                            fi
                            ;;
                    esac
                    ;;
                rules)
                    if [[ $cur == -* ]]; then
                        COMPREPLY=($(compgen -W "$rules_opts" -- "$cur"))
                    fi
                    ;;
            esac
            ;;
    esac

    return 0
}

# Register completion function
complete -F _stanza_completion stanza
