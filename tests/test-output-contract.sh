#!/usr/bin/env bash
# Description: The output contract, as a matrix. Each command with a JSON shape
#              runs under every verbosity (-q, default, -v, -vv), in text and
#              --json mode, on success and on each forced failure, and every
#              run is held to the same rules:
#                - exit 0 on success, non-zero on failure
#                - --json: stdout is one JSON document on one line, naming the
#                  command and whether it succeeded (ok); everything else
#                  went to stderr. On success it carries the -q value; on
#                  failure it carries the error, and a release names its step
#                - -q text: stdout is the one documented value on success,
#                  and empty on failure
#                - text: stdout never carries a JSON document
#              A new command is a row in COMMANDS, not a new block.
set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
STANZA="$ROOT/bin/stanza"
PASS=0
FAIL=0

GIT_AUTHOR_NAME=t
GIT_AUTHOR_EMAIL=t@t
GIT_COMMITTER_NAME=t
GIT_COMMITTER_EMAIL=t@t
NO_COLOR=1
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL NO_COLOR

if ! command -v jq > /dev/null; then
    echo "Error: jq is required for the output contract tests"
    exit 1
fi

pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

T=""
cleanup() {
    cd / 2>/dev/null || true
    if [[ -n "$T" ]]; then
        rm -rf "$T"
        T=""
    fi
}
trap cleanup EXIT INT TERM

# --- Fixtures --------------------------------------------------------------
# Each case runs in a fresh $T holding a repo at $T/repo, with HOME at $T/home
# so nothing reads or writes the real ~/.claude.

# repo VERSION: a main/dev repo whose dev carries VERSION and a tracked file
repo() {
    T=$(mktemp -d)
    mkdir "$T/home"
    git -c init.defaultBranch=main init -q "$T/repo"
    cd "$T/repo"
    # Hooks come from .git/hooks whatever the user's core.hooksPath says
    git config core.hooksPath .git/hooks
    git commit --allow-empty -q -m initial
    echo "$1" > VERSION
    echo notes > notes
    git add VERSION notes
    git commit -q -m "add VERSION"
    git checkout -q -b dev
}

setup_alpha() { repo 0.1.0a0; }
setup_stable() { repo 0.1.0; }

# A gh stand-in for init: creating the repo adds a local bare remote
setup_init() {
    repo 0.1.0
    mkdir "$T/bin"
    git init -q --bare "$T/remote.git"
    cat > "$T/bin/gh" <<MOCK
#!/usr/bin/env bash
[[ -f "$T/gh-fails" ]] && { echo "gh: forced failure" >&2; exit 1; }
case "\$1 \$2" in
    'repo create') git remote add origin "$T/remote.git"; echo 'created repository' ;;
    'repo view') echo 'https://example.test/repo' ;;
    *) exit 1 ;;
esac
MOCK
    chmod +x "$T/bin/gh"
}

# Forced failures, applied after setup
fail_hook() {
    printf '#!/bin/sh\nexit 1\n' > .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
}
fail_dirty() { echo changed >> notes; }
fail_gh() { touch "$T/gh-fails"; }
fail_usage() { EXTRA_ARGS="--no-such-option"; }
fail_handwritten() {
    mkdir -p "$T/home/.claude/rules"
    echo "a rule someone wrote" > "$T/home/.claude/rules/stanza.md"
}

# --- The table ---------------------------------------------------------------
# id | setup | stanza arguments | JSON command | -q value | JSON field | failures
#
# The -q value is what -q prints in text mode and what the jq filter in JSON
# field reads from the --json document; @T@ in it stands for the case's $T.
# A failure is fail_<name>:<step>, where step is the failed_step of the
# release's ok=false document, or "-" for a command without steps.
COMMANDS='
release-full|setup_alpha|release patch --local -y|release|0.1.0|.to_version|hook:bump dirty:preflight usage:preflight
release-pr|setup_alpha|release pr patch --local -y|release|0.1.0|.to_version|hook:bump dirty:preflight usage:preflight
release-merge|setup_stable|release merge --local -y|release|0.1.0|.tag.name[1:]|hook:cycle dirty:preflight usage:preflight
release-prerelease|setup_alpha|release prerelease --local -y|release|0.1.0a1|.to_version|hook:bump dirty:preflight usage:preflight
init|setup_init|init -y|init|https://example.test/repo|.repo_url|gh:- usage:-
rules-install|setup_stable|rules install|rules|@T@/home/.claude/rules/stanza.md|.path|handwritten:- usage:-
'

# --- One case ------------------------------------------------------------------

# check_case ID SETUP ARGS JSON_COMMAND QUIET_VALUE JSON_FIELD VERBOSITY MODE FAILURE EXPECT
# VERBOSITY is -q, -v, -vv, or "" (default); MODE is text or json; FAILURE and
# EXPECT are empty for the success case.
check_case() {
    local id="$1" setup="$2" args="$3" command="$4" quiet_value="$5" field="$6"
    local verbosity="$7" mode="$8" failure="$9" expect="${10}"
    local label="$id ${verbosity:-default} $mode ${failure:-success}"
    local -a flags=()
    [[ -n "$verbosity" ]] && flags+=("$verbosity")
    [[ "$mode" == json ]] && flags+=(--json)

    "$setup"
    EXTRA_ARGS=""
    [[ -n "$failure" ]] && "fail_$failure"
    local status=0
    # shellcheck disable=SC2086  # ARGS is a word list from the table
    HOME="$T/home" PATH="$T/bin:$PATH" "$STANZA" ${flags[@]+"${flags[@]}"} $args $EXTRA_ARGS \
        > "$T/stdout" 2> "$T/stderr" < /dev/null || status=$?
    local out want
    out=$(cat "$T/stdout")
    want="${quiet_value//@T@/$T}"

    if [[ -z "$failure" ]]; then
        [[ $status -eq 0 ]] && pass || fail "$label: exit $status, expected 0
$(sed 's/^/      /' "$T/stderr")"
    else
        [[ $status -ne 0 ]] && pass || fail "$label: exit 0, expected non-zero"
    fi

    if [[ "$mode" == json ]]; then
        local count lines
        count=$(jq -s length < "$T/stdout" 2>/dev/null) || count="unparseable"
        lines=$(wc -l < "$T/stdout" | tr -d ' ')
        if [[ "$count" == 1 && "$lines" == 1 ]]; then
            pass
        else
            fail "$label: stdout is not one JSON line (documents: $count, lines: $lines): $out"
            cleanup
            return 0
        fi
        jq -e --arg c "$command" '.command == $c and .schema_version == 1' "$T/stdout" > /dev/null \
            && pass || fail "$label: command is not \"$command\": $out"
        if [[ -z "$failure" ]]; then
            local got
            got=$(jq -r "$field" "$T/stdout")
            [[ "$got" == "$want" ]] && pass || fail "$label: $field is '$got', expected '$want'"
            jq -e '.ok == true' "$T/stdout" > /dev/null && pass || fail "$label: ok is not true: $out"
        else
            jq -e --arg step "$expect" '.ok == false and (.error | type) == "string"
                and (.failed_step // "-") == $step' "$T/stdout" > /dev/null \
                && pass || fail "$label: expected ok=false with an error, step $expect: $out"
        fi
    else
        [[ "$out" != *'"schema_version"'* ]] && pass || fail "$label: JSON on stdout in text mode"
        if [[ "$verbosity" == -q && -z "$failure" ]]; then
            [[ "$out" == "$want" ]] && pass || fail "$label: stdout is '$out', expected '$want'"
        elif [[ "$verbosity" == -q ]]; then
            [[ -z "$out" ]] && pass || fail "$label: stdout is '$out', expected nothing"
        fi
    fi
    cleanup
}

# --- The matrix ----------------------------------------------------------------

while IFS='|' read -r id setup args command quiet_value field failures; do
    [[ -n "$id" ]] || continue
    echo "$id"
    for verbosity in -q "" -v -vv; do
        for mode in text json; do
            check_case "$id" "$setup" "$args" "$command" "$quiet_value" "$field" "$verbosity" "$mode" "" ""
            for f in $failures; do
                check_case "$id" "$setup" "$args" "$command" "$quiet_value" "$field" "$verbosity" "$mode" "${f%%:*}" "${f#*:}"
            done
        done
    done
done <<< "$COMMANDS"

# rules check prints its own document and exits 1 when the rule is not
# current: the exit trap must not add a second document
echo "rules-check"
setup_stable
mkdir -p "$T/home/.claude/rules"
echo "an old rule" > "$T/home/.claude/rules/stanza.md"
status=0
HOME="$T/home" "$STANZA" --json rules check > "$T/stdout" 2> /dev/null || status=$?
[[ $status -eq 1 ]] && pass || fail "rules-check drifted: exit $status, expected 1"
[[ "$(jq -s length < "$T/stdout" 2>/dev/null)" == 1 ]] && pass || fail "rules-check drifted: not one document: $(cat "$T/stdout")"
jq -e '.ok == false and .status == "drifted"' "$T/stdout" > /dev/null \
    && pass || fail "rules-check drifted: expected ok=false and the status: $(cat "$T/stdout")"
cleanup

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
