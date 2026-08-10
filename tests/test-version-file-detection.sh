#!/bin/bash
# Test project type detection, VERSION file operations, and cross-path parity
set -e

STANZA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
PASS=0
FAIL=0

# --- Helpers ---------------------------------------------------------------

assert_eq() {
    local label="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1"
    local needle="$2"
    local haystack="$3"

    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected to contain '$needle', got '$haystack')"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local label="$1"
    local needle="$2"
    local haystack="$3"

    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected NOT to contain '$needle', got '$haystack')"
        FAIL=$((FAIL + 1))
    fi
}

setup_git_repo() {
    TEST_TMPDIR=$(mktemp -d)
    cd "$TEST_TMPDIR"
    git init -q
    git commit -q --allow-empty -m "initial commit"
    git checkout -q -b dev
}

cleanup() {
    cd /
    if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" && "$TEST_TMPDIR" == "$(cd "$TEST_TMPDIR" && pwd)" && "$TEST_TMPDIR" == *tmp* ]]; then
        rm -rf "$TEST_TMPDIR"
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

source_common() {
    # Reset cached project type between tests
    PROJECT_TYPE=""
    source "$STANZA_DIR/lib/stanza-common"
}

# Source bump_version_string and other functions from stanza-common
source_common_fresh() {
    PROJECT_TYPE=""
    source "$STANZA_DIR/lib/stanza-common"
}

# --- Detection tests -------------------------------------------------------

test_detect_uv_project() {
    echo ""
    echo "Detection: uv project"
    setup_git_repo

    cat > pyproject.toml << 'EOF'
[project]
name = "test-project"
version = "1.0.0"
EOF
    source_common
    assert_eq "pyproject.toml with [project] version -> uv" "uv" "$(detect_project_type)"
    cleanup
}

test_detect_uv_missing_version() {
    echo ""
    echo "Detection: pyproject.toml without version field"
    setup_git_repo

    cat > pyproject.toml << 'EOF'
[project]
name = "test-project"
dynamic = ["version"]
EOF
    source_common
    assert_eq "pyproject.toml with dynamic version -> none" "none" "$(detect_project_type)"
    cleanup
}

test_detect_uv_no_project_section() {
    echo ""
    echo "Detection: pyproject.toml without [project] section"
    setup_git_repo

    cat > pyproject.toml << 'EOF'
[tool.ruff]
line-length = 88
EOF
    source_common
    assert_eq "pyproject.toml without [project] -> none" "none" "$(detect_project_type)"
    cleanup
}

test_detect_bash_project() {
    echo ""
    echo "Detection: bash project (VERSION file)"
    setup_git_repo
    echo "0.1.0" > VERSION
    source_common
    assert_eq "VERSION file only -> bash" "bash" "$(detect_project_type)"
    cleanup
}

test_detect_none() {
    echo ""
    echo "Detection: no version file"
    setup_git_repo
    source_common
    assert_eq "no version files -> none" "none" "$(detect_project_type)"
    cleanup
}

test_detect_precedence() {
    echo ""
    echo "Detection: pyproject.toml takes precedence over VERSION"
    setup_git_repo
    cat > pyproject.toml << 'EOF'
[project]
name = "test-project"
version = "1.0.0"
EOF
    echo "2.0.0" > VERSION
    source_common
    assert_eq "both files present -> uv" "uv" "$(detect_project_type)"
    cleanup
}

test_detect_fallthrough_to_version() {
    echo ""
    echo "Detection: pyproject.toml without [project] falls through to VERSION"
    setup_git_repo
    cat > pyproject.toml << 'EOF'
[tool.ruff]
line-length = 88
EOF
    echo "0.5.0" > VERSION
    source_common
    assert_eq "pyproject.toml (no [project]) + VERSION -> bash" "bash" "$(detect_project_type)"
    cleanup
}

test_detect_commented_project() {
    echo ""
    echo "Detection: commented-out [project] section"
    setup_git_repo
    cat > pyproject.toml << 'EOF'
# [project]
# name = "old-project"
# version = "0.0.1"

[tool.ruff]
line-length = 88
EOF
    source_common
    assert_eq "commented [project] -> none" "none" "$(detect_project_type)"
    cleanup
}

test_detect_version_latex_warns() {
    echo ""
    echo "Detection: VERSION + LaTeX warns and resolves to bash"
    setup_git_repo
    echo "1.2.3" > VERSION
    cat > project.cls << 'EOF'
\ProvidesClass{project}[2024/01/01 v1.0 test class]
EOF
    source_common
    local warning
    warning=$(detect_project_type 2>&1 >/dev/null)
    assert_contains "VERSION + LaTeX warns" "Found both VERSION and project.cls" "$warning"
    assert_eq "VERSION + LaTeX -> bash" "bash" "$(detect_project_type)"
    cleanup
}

test_detect_latex_only_no_warn() {
    echo ""
    echo "Detection: LaTeX only resolves to latex with no warning"
    setup_git_repo
    cat > project.cls << 'EOF'
\ProvidesClass{project}[2024/01/01 v1.0 test class]
EOF
    source_common
    local warning
    warning=$(detect_project_type 2>&1 >/dev/null)
    assert_not_contains "LaTeX only does not warn" "Found both" "$warning"
    assert_eq "LaTeX only -> latex" "latex" "$(detect_project_type)"
    cleanup
}

test_detect_version_only_no_latex_warn() {
    echo ""
    echo "Detection: VERSION only does not warn about LaTeX"
    setup_git_repo
    echo "1.2.3" > VERSION
    source_common
    local warning
    warning=$(detect_project_type 2>&1 >/dev/null)
    assert_not_contains "VERSION only does not warn about LaTeX" "Found both VERSION and" "$warning"
    assert_eq "VERSION only -> bash" "bash" "$(detect_project_type)"
    cleanup
}

# --- VERSION file read/write tests ----------------------------------------

test_version_file_read() {
    echo ""
    echo "VERSION file: read"
    setup_git_repo
    echo "1.2.3" > VERSION
    source_common
    assert_eq "read VERSION" "1.2.3" "$(get_version_from_file)"
    cleanup
}

test_version_file_read_crlf() {
    echo ""
    echo "VERSION file: read with CRLF"
    setup_git_repo
    printf "1.2.3\r\n" > VERSION
    source_common
    assert_eq "read VERSION with CRLF" "1.2.3" "$(get_version_from_file)"
    cleanup
}

test_version_file_read_whitespace() {
    echo ""
    echo "VERSION file: read with whitespace"
    setup_git_repo
    echo "  1.2.3  " > VERSION
    source_common
    assert_eq "read VERSION with whitespace" "1.2.3" "$(get_version_from_file)"
    cleanup
}

test_version_file_write() {
    echo ""
    echo "VERSION file: write"
    setup_git_repo
    source_common
    set_version_in_file "2.0.0"
    assert_eq "write VERSION" "2.0.0" "$(get_version_from_file)"
    cleanup
}

# --- Bash semver bump tests (must match uv behavior) ----------------------

test_bump_version_string() {
    echo ""
    echo "bump_version_string"
    source_common_fresh

    assert_eq "stable -> prerelease"     "0.3.7a0" "$(bump_version_string "0.3.6" prerelease)"
    assert_eq "prerelease -> prerelease" "0.3.7a1" "$(bump_version_string "0.3.7a0" prerelease)"
    assert_eq "prerelease -> stable"     "0.3.7"   "$(bump_version_string "0.3.7a1" patch)"
    assert_eq "stable -> patch"          "0.3.8"   "$(bump_version_string "0.3.7" patch)"
    assert_eq "stable -> minor"          "0.4.0"   "$(bump_version_string "0.3.8" minor)"
    assert_eq "prerelease -> minor"      "0.4.0"   "$(bump_version_string "0.3.7a2" minor)"
    assert_eq "stable -> major"          "1.0.0"   "$(bump_version_string "0.4.0" major)"
    assert_eq "prerelease -> major"      "1.0.0"   "$(bump_version_string "0.3.7a2" major)"
}

# --- Cross-path parity: VERSION file bump_version matches uv bump_version --

test_cross_path_parity() {
    echo ""
    echo "Cross-path parity: VERSION bump_version vs uv bump_version"

    local cases=(
        "0.3.6:prerelease:0.3.7a0"
        "0.3.7a0:prerelease:0.3.7a1"
        "0.3.7a1:patch:0.3.7"
        "0.3.7:patch:0.3.8"
        "0.3.8:minor:0.4.0"
        "0.3.7a2:minor:0.4.0"
        "0.4.0:major:1.0.0"
        "0.3.7a2:major:1.0.0"
    )

    # Test VERSION file path
    setup_git_repo
    echo "0.0.0" > VERSION
    git add VERSION
    git commit -q -m "add VERSION"
    source_common_fresh

    # Source bump_version and set_version from stanza-release
    eval "$(extract_function bump_version "$STANZA_DIR/lib/stanza-release")"
    eval "$(extract_function set_version "$STANZA_DIR/lib/stanza-release")"

    for case_str in "${cases[@]}"; do
        IFS=: read -r start bump_type expected <<< "$case_str"
        # Write start version directly
        set_version_in_file "$start"
        PROJECT_TYPE="bash"
        bump_version "$bump_type" > /dev/null
        local actual
        actual=$(get_version_from_file)
        assert_eq "VERSION: $start + $bump_type -> $expected" "$expected" "$actual"
    done
    cleanup
}

# --- Error case tests ------------------------------------------------------

test_get_current_version_no_file() {
    echo ""
    echo "Error: get_current_version with no version file"
    setup_git_repo
    source_common

    # Run in subshell to capture exit code
    local output
    local exit_code=0
    output=$(get_current_version 2>&1) || exit_code=$?
    assert_eq "exits non-zero" "1" "$exit_code"
    cleanup
}

test_validate_invalid_version() {
    echo ""
    echo "Error: validate_version_string rejects bad input"
    source_common_fresh

    local cases=("not-a-version" "1.0" "v1.0.0" "" "1.0.0b1" "1.0.0-beta")
    for ver in "${cases[@]}"; do
        local exit_code=0
        (validate_version_string "$ver") 2>/dev/null || exit_code=$?
        assert_eq "rejects '$ver'" "1" "$exit_code"
    done
}

# --- README title version tests (plan 008) --------------------------------

test_readme_version_read() {
    echo ""
    echo "README title: read version token"
    setup_git_repo
    printf '# pbz2 v0.2.0\n\ntext\n' > README.md
    source_common
    assert_eq "reads title version" "0.2.0" "$(get_version_from_readme)"
    cleanup
}

test_readme_version_update() {
    echo ""
    echo "README title: update token in place"
    setup_git_repo
    printf '# pbz2 v0.2.0\n\ntext\n' > README.md
    source_common
    set_version_in_readme "0.2.1"
    assert_eq "title updated, rest of line kept" "# pbz2 v0.2.1" "$(head -1 README.md)"
    cleanup
}

test_readme_version_idempotent() {
    echo ""
    echo "README title: already in sync is a no-op"
    setup_git_repo
    printf '# pbz2 v0.2.0\n' > README.md
    source_common
    local ec=0
    set_version_in_readme "0.2.0" || ec=$?
    assert_eq "no-op returns non-zero" "1" "$ec"
    cleanup
}

test_readme_version_absent() {
    echo ""
    echo "README title: no token is left untouched"
    setup_git_repo
    printf '# pbz2 - a tool\n' > README.md
    source_common
    local ec=0
    set_version_in_readme "0.3.0" || ec=$?
    assert_eq "no token -> non-zero" "1" "$ec"
    assert_eq "title untouched" "# pbz2 - a tool" "$(head -1 README.md)"
    cleanup
}

test_readme_version_no_file() {
    echo ""
    echo "README title: missing README is a no-op"
    setup_git_repo
    source_common
    local ec=0
    set_version_in_readme "0.3.0" || ec=$?
    assert_eq "no README -> non-zero" "1" "$ec"
    cleanup
}

test_readme_version_only_first_h1() {
    echo ""
    echo "README title: only the first H1 is touched"
    setup_git_repo
    printf '# pbz2 v0.2.0\n\n# Another v0.2.0 heading\n' > README.md
    source_common
    set_version_in_readme "0.2.1"
    assert_eq "first H1 updated" "# pbz2 v0.2.1" "$(head -1 README.md)"
    assert_contains "later H1 untouched" "# Another v0.2.0 heading" "$(< README.md)"
    cleanup
}

test_readme_version_latex_and_alpha() {
    echo ""
    echo "README title: LaTeX-style and alpha tokens"
    setup_git_repo
    source_common
    printf '# cls v1.20\n' > README.md
    set_version_in_readme "1.21"
    assert_eq "latex token updated" "# cls v1.21" "$(head -1 README.md)"
    printf '# tool v0.2.0\n' > README.md
    set_version_in_readme "0.2.0a1"
    assert_eq "alpha token written" "# tool v0.2.0a1" "$(head -1 README.md)"
    cleanup
}

# --- CHANGELOG promotion tests (plan 008) ---------------------------------

test_changelog_status_absent() {
    echo ""
    echo "CHANGELOG status: absent"
    setup_git_repo
    source_common
    assert_eq "no CHANGELOG -> absent" "absent" "$(changelog_unreleased_status)"
    cleanup
}

test_changelog_status_empty() {
    echo ""
    echo "CHANGELOG status: empty Unreleased"
    setup_git_repo
    printf '# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-01-01\n- x\n' > CHANGELOG.md
    source_common
    assert_eq "empty section -> empty" "empty" "$(changelog_unreleased_status)"
    cleanup
}

test_changelog_status_missing() {
    echo ""
    echo "CHANGELOG status: no Unreleased heading"
    setup_git_repo
    printf '# Changelog\n\n## [0.1.0] - 2026-01-01\n- x\n' > CHANGELOG.md
    source_common
    assert_eq "no heading -> missing" "missing" "$(changelog_unreleased_status)"
    cleanup
}

test_changelog_status_nonempty() {
    echo ""
    echo "CHANGELOG status: nonempty Unreleased"
    setup_git_repo
    printf '# Changelog\n\n## [Unreleased]\n### Added\n- thing\n\n## [0.1.0] - 2026-01-01\n- x\n' > CHANGELOG.md
    source_common
    assert_eq "content -> nonempty" "nonempty" "$(changelog_unreleased_status)"
    cleanup
}

test_changelog_promote_with_links() {
    echo ""
    echo "CHANGELOG promote: heading + compare links"
    setup_git_repo
    cat > CHANGELOG.md << 'EOF'
# Changelog

## [Unreleased]

### Added
- New feature

## [0.1.0] - 2026-01-01

### Added
- Initial

[Unreleased]: https://github.com/owner/repo/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/owner/repo/compare/v0.0.9...v0.1.0
EOF
    source_common
    promote_changelog "0.2.0"
    local content
    content="$(< CHANGELOG.md)"
    assert_contains "new version heading present" "## [0.2.0] - " "$content"
    assert_contains "fresh Unreleased present" "## [Unreleased]" "$content"
    assert_contains "entry moved under new version" "- New feature" "$content"
    assert_contains "Unreleased link repointed" "compare/v0.2.0...HEAD" "$content"
    assert_contains "new version compare link inserted" "[0.2.0]: https://github.com/owner/repo/compare/v0.1.0...v0.2.0" "$content"
    cleanup
}

test_changelog_promote_heading_only() {
    echo ""
    echo "CHANGELOG promote: heading-only when no link refs"
    setup_git_repo
    printf '# Changelog\n\n## [Unreleased]\n- thing\n\n## [0.1.0] - 2026-01-01\n- x\n' > CHANGELOG.md
    source_common
    promote_changelog "0.2.0"
    local content
    content="$(< CHANGELOG.md)"
    assert_contains "new version heading present" "## [0.2.0] - " "$content"
    assert_contains "fresh Unreleased present" "## [Unreleased]" "$content"
    assert_contains "entry preserved" "- thing" "$content"
    cleanup
}

test_changelog_promote_empty_noop() {
    echo ""
    echo "CHANGELOG promote: empty section is a no-op"
    setup_git_repo
    printf '## [Unreleased]\n\n## [0.1.0] - 2026-01-01\n- x\n' > CHANGELOG.md
    source_common
    local before ec=0
    before="$(< CHANGELOG.md)"
    promote_changelog "0.2.0" || ec=$?
    assert_eq "empty -> non-zero" "1" "$ec"
    assert_eq "file untouched" "$before" "$(< CHANGELOG.md)"
    cleanup
}

# --- Run all tests ---------------------------------------------------------

trap cleanup EXIT

test_detect_uv_project
test_detect_uv_missing_version
test_detect_uv_no_project_section
test_detect_bash_project
test_detect_none
test_detect_precedence
test_detect_fallthrough_to_version
test_detect_commented_project
test_detect_version_latex_warns
test_detect_latex_only_no_warn
test_detect_version_only_no_latex_warn
test_version_file_read
test_version_file_read_crlf
test_version_file_read_whitespace
test_version_file_write
test_bump_version_string
test_cross_path_parity
test_get_current_version_no_file
test_validate_invalid_version
test_readme_version_read
test_readme_version_update
test_readme_version_idempotent
test_readme_version_absent
test_readme_version_no_file
test_readme_version_only_first_h1
test_readme_version_latex_and_alpha
test_changelog_status_absent
test_changelog_status_empty
test_changelog_status_missing
test_changelog_status_nonempty
test_changelog_promote_with_links
test_changelog_promote_heading_only
test_changelog_promote_empty_noop

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
