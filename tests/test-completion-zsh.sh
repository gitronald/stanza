#!/usr/bin/env bash
# Description: The zsh completion parses and registers under compinit, the way
#              an fpath install loads it (as _stanza). Skips when zsh is absent.
set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
COMPLETION="$ROOT/completions/stanza.zsh"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if ! command -v zsh > /dev/null; then
    echo "  SKIP: zsh not available"
    echo "Results: $PASS passed, $FAIL failed"
    exit 0
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

echo "zsh completion ($(zsh --version))"

if out=$(zsh -n "$COMPLETION" 2>&1); then
    pass "parses (zsh -n)"
else
    fail "parses (zsh -n): $out"
fi

# A clean zsh (-f: no startup files) with the file installed as _stanza on
# fpath, the layout the installer and the file's own header describe. The
# compdump goes to $T, not ~/.zcompdump.
mkdir "$T/functions"
cp "$COMPLETION" "$T/functions/_stanza"
if out=$(HOME="$T" zsh -fc '
    fpath=("$1" $fpath)
    autoload -Uz compinit && compinit -u -d "$1/../zcompdump" || exit 1
    [[ ${_comps[stanza]} == _stanza ]] || { print "stanza maps to: ${_comps[stanza]:-nothing}"; exit 1; }
    autoload +X _stanza || exit 1
    (( $+functions[_stanza] )) || { print "_stanza not defined"; exit 1; }
' zsh "$T/functions" 2>&1); then
    pass "compinit registers stanza -> _stanza and the function loads"
    if [[ -z "$out" ]]; then
        pass "loads without printing anything"
    else
        fail "loads without printing anything: $out"
    fi
else
    fail "compinit registers stanza -> _stanza and the function loads: $out"
fi

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
