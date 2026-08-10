#!/bin/bash
# Description: Tests for LaTeX .cls/.sty version detection and bumping.
set -e

STANZA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
STANZA="$STANZA_DIR/bin/stanza"
PASS=0
FAIL=0

GIT_AUTHOR_NAME=t
GIT_AUTHOR_EMAIL=t@t
GIT_COMMITTER_NAME=t
GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# --- Helpers ---------------------------------------------------------------

# Source helpers in a sub-shell-friendly way: each test sets up its own
# fixture dir, sources stanza-common (which uses CWD-relative detection),
# runs assertions, then resets PROJECT_TYPE so the next test can re-detect.
fresh_dir() {
    TMPDIR=$(mktemp -d)
    cd "$TMPDIR"
    PROJECT_TYPE=""
}

cleanup() {
    cd / 2>/dev/null || true
    if [[ -n "${TMPDIR:-}" ]]; then
        rm -rf "$TMPDIR"
        unset TMPDIR
    fi
    PROJECT_TYPE=""
}

trap cleanup EXIT INT TERM

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local label="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$label ($actual)"
    else
        fail "$label: expected '$expected', got '$actual'"
    fi
}

# Bring in stanza-common helpers for detection / bump logic.
source "$STANZA_DIR/lib/stanza-common"

# --- detect_project_type ---------------------------------------------------

echo "detect_project_type"

fresh_dir
cat > mypkg.cls <<'EOF'
\NeedsTeXFormat{LaTeX2e}
\ProvidesClass{mypkg}[2024/01/15 v1.20 My Class]
EOF
assert_eq "detects latex from .cls" "$(detect_project_type)" "latex"
cleanup

fresh_dir
cat > mypkg.sty <<'EOF'
\ProvidesPackage{mypkg}[2024/05/10 v0.3 My Package]
EOF
assert_eq "detects latex from .sty" "$(detect_project_type)" "latex"
cleanup

fresh_dir
cat > mypkg.cls <<'EOF'
\NeedsTeXFormat{LaTeX2e}
% no provides line here
EOF
assert_eq ".cls without \\Provides falls through to none" "$(detect_project_type)" "none"
cleanup

fresh_dir
echo "0.1.0" > VERSION
cat > also.cls <<'EOF'
\ProvidesClass{also}[2024/01/15 v1.0 also]
EOF
assert_eq "VERSION takes precedence over .cls" "$(detect_project_type)" "bash"
cleanup

# --- get_version_from_latex / set_version_in_latex -------------------------

echo ""
echo "read / write LaTeX version"

fresh_dir
cat > x.cls <<'EOF'
\ProvidesClass{x}[2024/01/15 v1.20 My Class]
EOF
assert_eq "reads version (without v prefix)" "$(get_version_from_latex)" "1.20"

set_version_in_latex "1.21"
assert_eq "writes new version" "$(get_version_from_latex)" "1.21"
today=$(date +%Y/%m/%d)
if grep -q "\[$today v1.21" x.cls; then
    pass "updates date to today"
else
    fail "date not updated to today: $(grep -o '\[[0-9]*/[0-9]*/[0-9]* v[^ ]*' x.cls)"
fi
cleanup

fresh_dir
cat > x.sty <<'EOF'
\ProvidesPackage{x}[2024/01/15 v2.5.3 desc]
EOF
assert_eq "reads three-component version" "$(get_version_from_latex)" "2.5.3"
cleanup

# --- validate_latex_version_string -----------------------------------------

echo ""
echo "validate LaTeX version string"

if (validate_latex_version_string "1" 2>/dev/null); then pass "accepts '1'"; else fail "rejects '1'"; fi
if (validate_latex_version_string "1.0" 2>/dev/null); then pass "accepts '1.0'"; else fail "rejects '1.0'"; fi
if (validate_latex_version_string "1.20" 2>/dev/null); then pass "accepts '1.20'"; else fail "rejects '1.20'"; fi
if (validate_latex_version_string "1.2.3" 2>/dev/null); then pass "accepts '1.2.3'"; else fail "rejects '1.2.3'"; fi
if (validate_latex_version_string "v1.0" 2>/dev/null); then fail "incorrectly accepted 'v1.0'"; else pass "rejects 'v1.0' (with prefix)"; fi
if (validate_latex_version_string "1.2.3.4" 2>/dev/null); then fail "incorrectly accepted '1.2.3.4'"; else pass "rejects '1.2.3.4' (4 components)"; fi
if (validate_latex_version_string "1.0a" 2>/dev/null); then fail "incorrectly accepted '1.0a'"; else pass "rejects '1.0a' (alpha)"; fi
if (validate_latex_version_string "" 2>/dev/null); then fail "incorrectly accepted ''"; else pass "rejects empty"; fi

# --- bump_latex_version_string --------------------------------------------

echo ""
echo "bump LaTeX version"

assert_eq "patch bumps last (1.20 -> 1.21)" "$(bump_latex_version_string 1.20 patch)" "1.21"
assert_eq "patch on three-comp (1.2.3 -> 1.2.4)" "$(bump_latex_version_string 1.2.3 patch)" "1.2.4"
assert_eq "patch on one-comp (5 -> 6)" "$(bump_latex_version_string 5 patch)" "6"
assert_eq "minor on two-comp (1.20 -> 2.0)" "$(bump_latex_version_string 1.20 minor)" "2.0"
assert_eq "minor on three-comp (1.2.3 -> 1.3.0)" "$(bump_latex_version_string 1.2.3 minor)" "1.3.0"
assert_eq "major on two-comp (1.20 -> 2.0)" "$(bump_latex_version_string 1.20 major)" "2.0"
assert_eq "major on three-comp (1.2.3 -> 2.0.0)" "$(bump_latex_version_string 1.2.3 major)" "2.0.0"
assert_eq "major on one-comp (5 -> 6)" "$(bump_latex_version_string 5 major)" "6"

if (bump_latex_version_string 1.0 prerelease 2>/dev/null); then
    fail "prerelease should error on LaTeX"
else
    pass "prerelease errors on LaTeX"
fi

# --- end-to-end: stanza release prerelease errors on latex -----------------

echo ""
echo "stanza release on LaTeX project"

fresh_dir
git -c init.defaultBranch=main init -q
git commit --allow-empty -q -m initial
cat > mypkg.cls <<'EOF'
\NeedsTeXFormat{LaTeX2e}
\ProvidesClass{mypkg}[2024/01/15 v1.20 My LaTeX class]
EOF
git add mypkg.cls
git commit -q -m "add mypkg.cls"
git checkout -q -b dev

out=$(NO_COLOR=1 "$STANZA" --json release patch -y --local 2>&1)
if echo "$out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['project_type'] == 'latex', f'project_type={d.get(\"project_type\")}'
assert d['from_version'] == '1.20', f'from={d.get(\"from_version\")}'
assert d['to_version'] == '1.21', f'to={d.get(\"to_version\")}'
assert d['tag']['name'] == 'v1.21', f'tag={d.get(\"tag\")}'
" 2>/dev/null; then
    pass "release patch on LaTeX bumps 1.20 -> 1.21 and tags v1.21"
else
    fail "release patch on LaTeX produced unexpected JSON: $out"
fi

# After the patch release, the cycle step should NOT bump a prerelease
# (LaTeX has no prerelease concept). Verify by reading the file.
PROJECT_TYPE=""
ver_after=$(get_version_from_latex)
if [[ "$ver_after" == "1.21" ]]; then
    pass "no prerelease bump after release patch on LaTeX"
else
    fail "expected version to stay 1.21 after release; got $ver_after"
fi

# Verify stanza release prerelease errors out cleanly on a LaTeX project.
err=$(NO_COLOR=1 "$STANZA" release prerelease -y --local 2>&1 || true)
if echo "$err" | grep -q "don't support prerelease"; then
    pass "stanza release prerelease errors on LaTeX"
else
    fail "expected prerelease error: $err"
fi

cleanup

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
