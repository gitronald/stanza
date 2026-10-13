#!/usr/bin/env bash
# Test git_net's stall bounds and the captured output of failed quiet calls
set -e

STANZA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
PASS=0
FAIL=0

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

# Each test runs in a fresh repo with no global or system git config, so the
# defaults under test are not masked by the machine's own http.* or ssh setup.
setup_repo() {
    TEST_TMPDIR=$(mktemp -d)
    cd "$TEST_TMPDIR"
    : > "$TEST_TMPDIR/global.gitconfig"
    export GIT_CONFIG_GLOBAL="$TEST_TMPDIR/global.gitconfig" GIT_CONFIG_NOSYSTEM=1
    git init -q
}

cleanup() {
    cd /
    if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" && "$TEST_TMPDIR" == *tmp* ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

VERBOSE=false
VERBOSITY=1
JSON_OUTPUT=false
source "$STANZA_DIR/lib/stanza-common"

# The -c options git_net passes, one per line. A git stand-in records the
# arguments of the call git_net makes; its own 'git config' reads go to git.
git_net_options() {
    git() {
        if [[ "${1:-}" == "config" ]]; then
            command git "$@"
            return
        fi
        local prev="" arg
        for arg in "$@"; do
            [[ "$prev" == "-c" ]] && printf '%s\n' "$arg"
            prev="$arg"
        done
    }
    git_net ls-remote origin
    unset -f git
}

# --- Tests -----------------------------------------------------------------

test_default_options() {
    echo ""
    echo "git_net bounds HTTP transfers and adds SSH keepalives by default"
    setup_repo
    local opts
    opts=$(unset GIT_SSH GIT_SSH_COMMAND STANZA_NET_STALL_SECONDS; git_net_options)
    assert_contains "low speed limit" "$opts" "http.lowSpeedLimit=1000"
    assert_contains "low speed time" "$opts" "http.lowSpeedTime=30"
    assert_contains "ssh keepalive" "$opts" \
        "core.sshCommand=ssh -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=2"
    cleanup
}

test_stall_seconds_env() {
    echo ""
    echo "STANZA_NET_STALL_SECONDS sets the window; 0 turns the bounds off"
    setup_repo
    local opts
    opts=$(unset GIT_SSH GIT_SSH_COMMAND; STANZA_NET_STALL_SECONDS=5 git_net_options)
    assert_contains "window of 5 seconds" "$opts" "http.lowSpeedTime=5"
    assert_contains "keepalive at half the window" "$opts" "ServerAliveInterval=3"
    opts=$(STANZA_NET_STALL_SECONDS=0 git_net_options)
    assert_eq "no options at 0" "" "$opts"
    opts=$(unset GIT_SSH GIT_SSH_COMMAND; STANZA_NET_STALL_SECONDS=soon git_net_options)
    assert_contains "a non-number falls back to 30" "$opts" "http.lowSpeedTime=30"

    # A leading zero is decimal, not octal (08 is not a bash arithmetic error).
    local err
    err=$(unset GIT_SSH GIT_SSH_COMMAND; STANZA_NET_STALL_SECONDS=08 git_net_options 2>&1 >/dev/null)
    opts=$(unset GIT_SSH GIT_SSH_COMMAND; STANZA_NET_STALL_SECONDS=08 git_net_options 2>/dev/null)
    assert_contains "08 is a window of 8 seconds" "$opts" "http.lowSpeedTime=8"
    assert_contains "08 keeps the keepalive" "$opts" "ServerAliveInterval=4"
    assert_eq "08 prints no arithmetic error" "" "$err"
    cleanup
}

test_user_config_wins() {
    echo ""
    echo "The user's own http.lowSpeed* and ssh command are left alone"
    setup_repo
    git config http.lowSpeedTime 99
    local opts
    opts=$(unset GIT_SSH GIT_SSH_COMMAND; git_net_options)
    assert_not_contains "configured lowSpeedTime is not overridden" "$opts" "http.lowSpeedTime="
    assert_contains "unconfigured lowSpeedLimit is still set" "$opts" "http.lowSpeedLimit=1000"

    opts=$(GIT_SSH_COMMAND="ssh -i key" git_net_options)
    assert_not_contains "GIT_SSH_COMMAND keeps its ssh command" "$opts" "core.sshCommand"
    opts=$(unset GIT_SSH_COMMAND; GIT_SSH=/usr/bin/ssh git_net_options)
    assert_not_contains "GIT_SSH keeps its ssh command" "$opts" "core.sshCommand"
    git config core.sshCommand "ssh -i key"
    opts=$(unset GIT_SSH GIT_SSH_COMMAND; git_net_options)
    assert_not_contains "core.sshCommand is kept" "$opts" "core.sshCommand="
    cleanup
}

test_ssh_receives_keepalive() {
    echo ""
    echo "git runs ssh with the keepalive options for an SSH remote"
    setup_repo
    mkdir bin
    printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "%s/ssh.args"\nexit 1\n' "$TEST_TMPDIR" > bin/ssh
    chmod +x bin/ssh
    git remote add origin "ssh://git@example.invalid/repo.git"
    (unset GIT_SSH GIT_SSH_COMMAND; PATH="$TEST_TMPDIR/bin:$PATH" git_net ls-remote origin >/dev/null 2>&1) || true
    local args
    args=$(cat ssh.args 2>/dev/null)
    assert_contains "ssh got ServerAliveInterval" "$args" "ServerAliveInterval=15"
    assert_contains "ssh got ServerAliveCountMax" "$args" "ServerAliveCountMax=2"
    cleanup
}

test_quiet_failure_keeps_output() {
    echo ""
    echo "A failed quiet call prints the command and its output; success is silent"
    setup_repo
    local err code=0
    err=$(NO_COLOR=1 git_quiet checkout no-such-branch 2>&1 >/dev/null) || code=$?
    assert_eq "returns git's status" "1" "$code"
    assert_contains "names the command" "$err" "[ERROR] git checkout no-such-branch failed (exit 1)"
    assert_contains "keeps git's message, indented" "$err" "    error: pathspec 'no-such-branch'"
    assert_eq "records the error" "git checkout no-such-branch failed (exit 1)" \
        "$(git_quiet checkout no-such-branch >/dev/null 2>&1 || true; echo "$STANZA_LAST_ERROR")"

    local out
    out=$(git_quiet status 2>&1)
    assert_eq "success prints nothing" "" "$out"
    cleanup
}

test_verbose_failure_is_named() {
    echo ""
    echo "Every wrapper names a failed command, at any verbosity"
    setup_repo
    local err
    err=$(NO_COLOR=1 VERBOSITY=2 run_verbose git checkout no-such-branch 2>&1) || true
    assert_contains "run_verbose -v names the command" "$err" \
        "[ERROR] git checkout no-such-branch failed (exit 1)"
    err=$(NO_COLOR=1 VERBOSE=true git_quiet checkout no-such-branch 2>&1) || true
    assert_contains "git_quiet -vv names the command" "$err" \
        "[ERROR] git checkout no-such-branch failed (exit 1)"
    cleanup
}

test_quiet_try_warns() {
    echo ""
    echo "quiet_try reports a failure the caller recovers from as a warning"
    setup_repo
    local err code=0
    err=$(NO_COLOR=1 quiet_try git checkout no-such-branch 2>&1 >/dev/null) || code=$?
    assert_eq "returns git's status" "1" "$code"
    assert_contains "warns naming the command" "$err" \
        "[WARNING] git checkout no-such-branch failed (exit 1)"
    assert_contains "keeps git's message, indented" "$err" "    error: pathspec 'no-such-branch'"
    assert_not_contains "is not an error" "$err" "[ERROR]"
    assert_eq "records no error" "" \
        "$(STANZA_LAST_ERROR=""; quiet_try git checkout no-such-branch >/dev/null 2>&1 || true; echo "$STANZA_LAST_ERROR")"
    cleanup
}

test_command_label() {
    echo ""
    echo "command_label quotes, flattens, and shortens"
    assert_eq "git_net shows as git" "git push origin dev" "$(command_label git_net push origin dev)"
    assert_eq "spaced args are quoted" 'git commit -m "version [patch]: 1.0.0"' \
        "$(command_label git commit -m "version [patch]: 1.0.0")"
    assert_eq "empty args are quoted" 'gh pr merge 1 --body ""' "$(command_label gh pr merge 1 --body "")"
    assert_eq "newlines are flattened" 'gh pr edit 1 --body "a b"' "$(command_label gh pr edit 1 --body $'a\nb')"
    local long
    long=$(command_label gh pr edit 1 --body "$(printf 'x%.0s' $(seq 1 200))")
    assert_eq "long labels are cut to 100" "100" "${#long}"
}

trap cleanup EXIT

test_default_options
test_stall_seconds_env
test_user_config_wins
test_ssh_receives_keepalive
test_quiet_failure_keeps_output
test_verbose_failure_is_named
test_quiet_try_warns
test_command_label

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
