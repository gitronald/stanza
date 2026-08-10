#!/bin/bash
# Description: Test output modes (default, --quiet, --verbose, --json)
#              for stanza release prerelease/patch and stanza version.
set -e

STANZA="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/bin/stanza"
PASS=0
FAIL=0

GIT_AUTHOR_NAME=t
GIT_AUTHOR_EMAIL=t@t
GIT_COMMITTER_NAME=t
GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# --- Helpers ---------------------------------------------------------------

fresh_repo() {
    TMPDIR=$(mktemp -d)
    cd "$TMPDIR"
    # Pin the initial branch to 'main' so full-release assertions are stable
    # regardless of the user's git init.defaultBranch.
    git -c init.defaultBranch=main init -q
    git commit --allow-empty -q -m initial
    echo "0.1.0" > VERSION
    git add VERSION
    git commit -q -m "add VERSION"
    git checkout -q -b dev
}

fresh_repo_alpha() {
    fresh_repo
    echo "0.1.0a0" > VERSION
    git add VERSION
    git commit -q -m "version [prerelease]: 0.1.0a0"
}

cleanup() {
    cd / 2>/dev/null || true
    if [[ -n "${TMPDIR:-}" ]]; then
        rm -rf "$TMPDIR"
        unset TMPDIR
    fi
}

# Always clean up the temp dir, even on test failure or interrupt.
trap cleanup EXIT INT TERM

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Validate JSON via python3 (required) — produces empty output on success.
parse_json() {
    python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)))" "$@"
}

# --- Tests -----------------------------------------------------------------

echo "stanza version --json (flag before subcommand)"
out=$("$STANZA" --json version 2>/dev/null)
if echo "$out" | parse_json >/dev/null 2>&1; then
    pass "valid JSON"
else
    fail "valid JSON: got $out"
fi
if echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['command']=='version'; assert d['schema_version']==1; assert 'version' in d" 2>/dev/null; then
    pass "expected keys (command, schema_version, version)"
else
    fail "expected keys: got $out"
fi

echo ""
echo "stanza version --json (flag after subcommand)"
out_after=$("$STANZA" version --json 2>/dev/null)
if echo "$out_after" | parse_json >/dev/null 2>&1; then
    pass "valid JSON"
else
    fail "valid JSON (flag-after-subcommand): got $out_after"
fi

echo ""
echo "stanza --version shows stanza's own version (not the project's)"
SELF_VERSION=$(head -1 "$(dirname "$STANZA")/../VERSION" | tr -d '[:space:]')
fresh_repo
out=$("$STANZA" --version 2>/dev/null)
if [[ "$out" == "stanza $SELF_VERSION" ]]; then
    pass "--version prints 'stanza <self-version>'"
else
    fail "expected 'stanza $SELF_VERSION', got '$out'"
fi
out=$("$STANZA" -V 2>/dev/null)
if [[ "$out" == "stanza $SELF_VERSION" ]]; then
    pass "-V prints 'stanza <self-version>'"
else
    fail "expected 'stanza $SELF_VERSION', got '$out'"
fi
proj=$("$STANZA" version 2>/dev/null)
if [[ "$proj" == "0.1.0" ]]; then
    pass "version command still reports the project version"
else
    fail "expected project version '0.1.0', got '$proj'"
fi
cleanup

echo ""
echo "stanza release prerelease --json"
fresh_repo
out=$(NO_COLOR=1 "$STANZA" --json release prerelease -y --local 2>/dev/null)
if echo "$out" | parse_json >/dev/null 2>&1; then
    pass "valid JSON"
else
    fail "valid JSON: got $out"
fi
if echo "$out" | python3 -c "
import json, sys, re
d = json.load(sys.stdin)
assert d['command'] == 'release'
assert d['bump_type'] == 'prerelease'
assert d['from_version'] == '0.1.0'
assert d['to_version'] == '0.1.1a0'
assert d['branch'] == 'dev'
assert re.match(r'^[0-9a-f]{7,}$', d['commit'])
assert d['pushed'] is False
" 2>/dev/null; then
    pass "expected keys"
else
    fail "expected keys: got $out"
fi
cleanup

echo ""
echo "stanza release prerelease --quiet"
fresh_repo
out=$(NO_COLOR=1 "$STANZA" -q release prerelease -y --local 2>/dev/null)
line_count=$(echo "$out" | wc -l | tr -d ' ')
if [[ "$line_count" == "1" ]]; then
    pass "exactly one line of output"
else
    fail "expected 1 line, got $line_count: $out"
fi
if [[ "$out" == "0.1.1a0" ]]; then
    pass "output is the new version"
else
    fail "expected '0.1.1a0', got '$out'"
fi
cleanup

echo ""
echo "stanza release patch --json (full release, --local)"
fresh_repo_alpha
out=$(NO_COLOR=1 "$STANZA" --json release patch -y --local 2>/dev/null)
if echo "$out" | parse_json >/dev/null 2>&1; then
    pass "valid JSON"
else
    fail "valid JSON: got $out"
fi
if echo "$out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['command'] == 'release'
assert d['bump_type'] == 'patch'
assert d['from_version'] == '0.1.0a0'
assert d['to_version'] == '0.1.0'
assert d['branch_from'] == 'dev'
assert d['branch_to'] == 'main'
assert d['pr'] is None
assert d['tag']['name'] == 'v0.1.0'
assert d['tag']['pushed'] is False
assert d['next_cycle_version'] == '0.1.1a0'
" 2>/dev/null; then
    pass "expected keys (full release schema)"
else
    fail "expected keys: got $out"
fi
cleanup

echo ""
echo "stanza release prerelease default output"
fresh_repo
out=$(NO_COLOR=1 "$STANZA" release prerelease -y --local 2>&1)
if echo "$out" | grep -q "stanza release prerelease  (dev, bash, local)"; then
    pass "header line present (with local marker)"
else
    fail "header missing: $out"
fi
if echo "$out" | grep -q "  bump    0.1.0 -> 0.1.1a0"; then
    pass "bump row present"
else
    fail "bump row missing: $out"
fi
if echo "$out" | grep -q "  done    0.1.1a0 on dev"; then
    pass "done row present"
else
    fail "done row missing: $out"
fi
if echo "$out" | grep -Eq '^ -{6,}'; then
    fail "old ASCII frame should be gone"
else
    pass "no old ASCII frame"
fi
cleanup

echo ""
echo "stanza release prerelease --verbose adds checks row"
fresh_repo
out=$(NO_COLOR=1 "$STANZA" -v release prerelease -y --local 2>&1)
if echo "$out" | grep -q "  checks  branch=dev"; then
    pass "checks row present in verbose mode"
else
    fail "checks row missing: $out"
fi
cleanup

echo ""
echo "mutual exclusion: --quiet and --verbose"
if "$STANZA" --quiet --verbose version 2>&1 | grep -q "mutually exclusive"; then
    pass "errors when both passed before subcommand"
else
    fail "expected mutual-exclusion error (both before)"
fi
fresh_repo
if NO_COLOR=1 "$STANZA" release prerelease -q -v -y --local 2>&1 | grep -q "mutually exclusive"; then
    pass "errors when both passed to subcommand"
else
    fail "expected mutual-exclusion error (both after)"
fi
cleanup
if "$STANZA" -q version --verbose 2>&1 | grep -q "mutually exclusive"; then
    pass "errors when split across positions (-q before, --verbose after)"
else
    fail "expected mutual-exclusion error (split positions)"
fi

echo ""
echo "stanza release prerelease --quiet --json (combined)"
fresh_repo
out=$(NO_COLOR=1 "$STANZA" --quiet --json release prerelease -y --local 2>/dev/null)
if echo "$out" | parse_json >/dev/null 2>&1; then
    pass "valid JSON when --quiet and --json combined"
else
    fail "expected valid JSON: got $out"
fi
line_count=$(echo "$out" | wc -l | tr -d ' ')
if [[ "$line_count" == "1" ]]; then
    pass "exactly one line of stdout"
else
    fail "expected 1 line, got $line_count"
fi
cleanup

echo ""
echo "stanza -vvv release prerelease (multi-v)"
fresh_repo
out=$(NO_COLOR=1 "$STANZA" -vvv release prerelease -y --local 2>&1)
if echo "$out" | grep -q "  bump    0.1.0 -> 0.1.1a0"; then
    pass "-vvv accepted (release succeeded)"
else
    fail "-vvv flag rejected: $out"
fi
cleanup

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
