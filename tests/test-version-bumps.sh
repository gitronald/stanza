#!/bin/bash
# Test version bump behavior for uv-based version management
set -e

STANZA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
PASS=0
FAIL=0

# --- Helpers ---------------------------------------------------------------

setup_repo() {
    TEST_TMPDIR=$(mktemp -d)
    cd "$TEST_TMPDIR"
    git init -q
    git commit -q --allow-empty -m "initial commit"
    git checkout -q -b dev

    cat > pyproject.toml << 'EOF'
[project]
name = "test-project"
version = "0.0.0"
requires-python = ">=3.10"
dependencies = []

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"
EOF
    git add pyproject.toml
    git commit -q -m "add pyproject.toml"
}

cleanup() {
    cd /
    if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" && "$TEST_TMPDIR" == "$(cd "$TEST_TMPDIR" && pwd)" && "$TEST_TMPDIR" == *tmp* ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

assert_bump() {
    local label="$1"
    local start="$2"
    local bump_type="$3"
    local expected="$4"

    # Set start version directly in pyproject.toml to avoid uv no-op errors
    sed "s/^version = .*/version = \"$start\"/" pyproject.toml > pyproject.toml.tmp && mv pyproject.toml.tmp pyproject.toml
    bump_version "$bump_type" > /dev/null
    local actual
    actual=$(uv version --short)

    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $label ($start -> $actual)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected $start -> $expected, got $actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_set() {
    local start="$1"
    local target="$2"

    sed "s/^version = .*/version = \"$start\"/" pyproject.toml > pyproject.toml.tmp && mv pyproject.toml.tmp pyproject.toml
    set_version "$target" > /dev/null
    local actual
    actual=$(uv version --short)

    if [[ "$actual" == "$target" ]]; then
        echo "  PASS: set_version $target ($actual)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: set_version $target (expected $target, got $actual)"
        FAIL=$((FAIL + 1))
    fi
}

# Extract a complete function definition from a file (handles nested braces)
extract_function() {
    local func_name="$1"
    local file="$2"
    awk "/^${func_name}\\(\\)/ {found=1; depth=0}
         found && /{/ {depth++}
         found {print}
         found && /}/ {depth--; if(depth==0) exit}" "$file"
}

# Source only the functions we need (avoid running the release workflow)
source_functions() {
    source "$STANZA_DIR/lib/stanza-common"
    eval "$(extract_function bump_version "$STANZA_DIR/lib/stanza-release")"
    eval "$(extract_function set_version "$STANZA_DIR/lib/stanza-release")"
}

# --- Run -------------------------------------------------------------------

trap cleanup EXIT
setup_repo
source_functions

echo ""
echo "Prerelease bumps"
assert_bump "stable -> prerelease"       "0.3.6"   prerelease "0.3.7a0"
assert_bump "prerelease -> prerelease"   "0.3.7a0" prerelease "0.3.7a1"

echo ""
echo "Patch bumps"
assert_bump "prerelease -> stable"       "0.3.7a1" patch "0.3.7"
assert_bump "stable -> patch"            "0.3.7"   patch "0.3.8"

echo ""
echo "Minor bumps"
assert_bump "stable -> minor"            "0.3.8"   minor "0.4.0"
assert_bump "prerelease -> minor"        "0.3.7a2" minor "0.4.0"

echo ""
echo "Major bumps"
assert_bump "stable -> major"            "0.4.0"   major "1.0.0"
assert_bump "prerelease -> major"        "0.3.7a2" major "1.0.0"

echo ""
echo "Set version"
assert_set "1.0.0" "2.5.0"
assert_set "2.5.0" "0.1.0"
assert_set "0.1.0" "1.0.0a0"
assert_set "1.0.0a0" "0.5.0"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
