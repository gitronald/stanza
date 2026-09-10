#!/bin/bash
# Test release workflow (local mode only, no remote operations)
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
    local haystack="$2"
    local needle="$3"

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
    local haystack="$2"
    local needle="$3"

    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected NOT to contain '$needle', got '$haystack')"
        FAIL=$((FAIL + 1))
    fi
}

setup_repo() {
    TEST_TMPDIR=$(mktemp -d)
    cd "$TEST_TMPDIR"
    git init -q
    git commit -q --allow-empty -m "initial commit"

    # Create main branch and dev branch
    git branch -M main
    cat > pyproject.toml << 'EOF'
[project]
name = "test-project"
version = "0.1.0a0"
requires-python = ">=3.10"
dependencies = []

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"
EOF
    git add pyproject.toml
    git commit -q -m "add pyproject.toml"
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

source_release() {
    PROJECT_TYPE=""
    LOCAL_ONLY=true
    YES_TO_ALL=true
    VERBOSE=false
    source "$STANZA_DIR/lib/stanza-common"
    # Source workflow functions from stanza-release without running the script
    eval "$(extract_function bump_version "$STANZA_DIR/lib/stanza-release")"
    eval "$(extract_function set_version "$STANZA_DIR/lib/stanza-release")"
    eval "$(extract_function bump_and_commit_version "$STANZA_DIR/lib/stanza-release")"
    eval "$(extract_function print_doc_sync_rows "$STANZA_DIR/lib/stanza-release")"
    eval "$(extract_function update_init_version "$STANZA_DIR/lib/stanza-release")"
    eval "$(extract_function find_package_init "$STANZA_DIR/lib/stanza-release")"
    eval "$(extract_function git_tag_version "$STANZA_DIR/lib/stanza-release")"
    eval "$(extract_function gh_create_pr "$STANZA_DIR/lib/stanza-release")"
    eval "$(extract_function gh_merge_pr "$STANZA_DIR/lib/stanza-release")"
    eval "$(extract_function gh_get_last_open_pr_number "$STANZA_DIR/lib/stanza-release")"
    eval "$(extract_function git_merge_dev_into_main "$STANZA_DIR/lib/stanza-release")"
    eval "$(extract_function create_new_prerelease_cycle "$STANZA_DIR/lib/stanza-release")"
    eval "$(extract_function print_branch_version "$STANZA_DIR/lib/stanza-release")"
    BASE_BRANCH="main"
}

# --- Subprocess (real bin/stanza) helpers ----------------------------------
# Phase parsing, dispatch, the pr STOP, JSON, and error paths all live at
# top-level script scope (not in extractable functions), so they are exercised
# by invoking bin/stanza in a temp repo. A gh mock on PATH makes the remote
# phases deterministic and offline.

STANZA="$STANZA_DIR/bin/stanza"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Write a gh mock that records a single PR in $GH_MOCK_STATE and performs a
# real local merge (against the bare remote) on `gh pr merge`.
make_gh_mock() {
    local bindir="$1"
    mkdir -p "$bindir"
    cat > "$bindir/gh" <<'MOCK'
#!/bin/bash
set -e
STATE="${GH_MOCK_STATE:?}"
cmd="$1"; shift || true
case "$cmd" in
  auth) exit 0 ;;
  pr)
    sub="$1"; shift || true
    case "$sub" in
      create)
        title=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --title) title="$2"; shift 2 ;;
            --base|--head|--assignee) shift 2 ;;
            --fill) shift ;;
            *) shift ;;
          esac
        done
        echo 1 > "$STATE/number"
        printf '%s' "$title" > "$STATE/title"
        echo open > "$STATE/state"
        echo "https://example.test/pull/1" > "$STATE/url"
        printf 'filled body' > "$STATE/body"
        git rev-parse dev > "$STATE/head"
        ;;
      list)
        jq=""; prev=""
        for a in "$@"; do [[ "$prev" == "--jq" ]] && jq="$a"; prev="$a"; done
        if [[ -f "$STATE/state" && "$(cat "$STATE/state")" == "open" ]]; then
          if [[ "$jq" == *length* ]]; then echo 1; else cat "$STATE/number"; fi
        else
          if [[ "$jq" == *length* ]]; then echo 0; else printf ''; fi
        fi
        ;;
      view)
        shift || true   # PR number
        field=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --json) field="$2"; shift 2 ;;
            --jq) shift 2 ;;
            *) shift ;;
          esac
        done
        case "$field" in
          url) cat "$STATE/url" ;;
          body) cat "$STATE/body" ;;
          title) cat "$STATE/title" ;;
          headRefOid) cat "$STATE/head" ;;
          *) printf '' ;;
        esac
        ;;
      edit)
        shift || true   # PR number
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --body) printf '%s' "$2" > "$STATE/body"; shift 2 ;;
            *) shift ;;
          esac
        done
        ;;
      merge)
        # Like GitHub's --merge: always a merge commit, honoring --subject.
        subject=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --subject) subject="$2"; shift 2 ;;
            --body) shift 2 ;;
            *) shift ;;
          esac
        done
        printf '%s' "$subject" > "$STATE/merge_subject"
        git checkout -q main
        if [[ -n "$subject" ]]; then
          git merge -q --no-ff -m "$subject" dev
        else
          git merge -q --no-ff --no-edit dev
        fi
        git push -q origin main
        echo closed > "$STATE/state"
        ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
MOCK
    chmod +x "$bindir/gh"
}

# Set up a bash (VERSION-file) project with a bare remote and a gh mock on PATH.
# Leaves the shell in the working repo on branch dev at 0.1.0a0. Exports
# GH_MOCK_STATE and prepends the mock dir to PATH.
setup_remote_repo() {
    TEST_TMPDIR=$(mktemp -d)
    git init -q --bare "$TEST_TMPDIR/remote.git"
    git -c init.defaultBranch=main init -q "$TEST_TMPDIR/work"
    cd "$TEST_TMPDIR/work"
    git commit -q --allow-empty -m "initial commit"
    echo "0.1.0a0" > VERSION
    git add VERSION
    git commit -q -m "version [prerelease]: 0.1.0a0"
    git remote add origin "$TEST_TMPDIR/remote.git"
    git push -q -u origin main
    git remote set-head origin main
    git checkout -q -b dev
    git push -q -u origin dev

    GH_MOCK_STATE="$TEST_TMPDIR/ghstate"
    mkdir -p "$GH_MOCK_STATE"
    export GH_MOCK_STATE
    make_gh_mock "$TEST_TMPDIR/bin"
    ORIG_PATH="$PATH"
    PATH="$TEST_TMPDIR/bin:$PATH"
    export PATH
}

teardown_remote_repo() {
    [[ -n "$ORIG_PATH" ]] && PATH="$ORIG_PATH" && export PATH
    unset GH_MOCK_STATE
    cleanup
}

# --- Tests -----------------------------------------------------------------

test_local_patch_release() {
    echo ""
    echo "Local patch release workflow"
    setup_repo
    source_release

    # Set a prerelease version on dev
    uv version "0.2.0a0" --frozen > /dev/null
    git add pyproject.toml
    git commit -q -m "version [prerelease]: 0.2.0a0"

    # Step 1: bump version on dev
    BUMP_TYPE="patch"
    bump_and_commit_version "$BUMP_TYPE"
    local dev_version
    dev_version=$(uv version --short)
    assert_eq "dev bumped to stable" "0.2.0" "$dev_version"

    # Step 2: merge dev into main (local)
    local version_tag="v${dev_version}"
    git_merge_dev_into_main "$version_tag"
    local on_main
    on_main=$(git branch --show-current)
    assert_eq "on main after merge" "main" "$on_main"
    assert_eq "local merge subject" "version [release]: v0.2.0" "$(git log -1 --format=%s)"
    assert_eq "local merge is a merge commit (no fast-forward)" "2" \
        "$(git log -1 --format=%p | wc -w | tr -d ' ')"

    # Tag version (should not fail with "already exists")
    git_tag_version "$version_tag"
    local tag_exists
    tag_exists=$(git tag -l "$version_tag")
    assert_eq "tag created" "$version_tag" "$tag_exists"

    # Step 3: new prerelease cycle on dev
    create_new_prerelease_cycle > /dev/null 2>&1
    local final_branch
    final_branch=$(git branch --show-current)
    assert_eq "back on dev" "dev" "$final_branch"

    local next_version
    next_version=$(uv version --short)
    assert_eq "dev on next prerelease" "0.2.1a0" "$next_version"
    assert_eq "dev fast-forwarded onto the release merge" "yes" \
        "$(git merge-base --is-ancestor "$version_tag" dev && echo yes || echo no)"

    cleanup
}

test_local_minor_release() {
    echo ""
    echo "Local minor release workflow"
    setup_repo
    source_release

    uv version "0.1.0" --frozen > /dev/null
    git add pyproject.toml
    git commit -q -m "version: 0.1.0"

    BUMP_TYPE="minor"
    bump_and_commit_version "$BUMP_TYPE"
    local dev_version
    dev_version=$(uv version --short)
    assert_eq "dev bumped to minor" "0.2.0" "$dev_version"

    local version_tag="v${dev_version}"
    git_merge_dev_into_main "$version_tag"
    git_tag_version "$version_tag"
    assert_eq "tag created" "$version_tag" "$(git tag -l "$version_tag")"

    create_new_prerelease_cycle > /dev/null 2>&1
    assert_eq "back on dev" "dev" "$(git branch --show-current)"
    assert_eq "dev on next prerelease" "0.2.1a0" "$(uv version --short)"

    cleanup
}

test_local_major_release() {
    echo ""
    echo "Local major release workflow"
    setup_repo
    source_release

    uv version "1.0.0" --frozen > /dev/null
    git add pyproject.toml
    git commit -q -m "version: 1.0.0"

    BUMP_TYPE="major"
    bump_and_commit_version "$BUMP_TYPE"
    local dev_version
    dev_version=$(uv version --short)
    assert_eq "dev bumped to major" "2.0.0" "$dev_version"

    local version_tag="v${dev_version}"
    git_merge_dev_into_main "$version_tag"
    git_tag_version "$version_tag"
    assert_eq "tag created" "$version_tag" "$(git tag -l "$version_tag")"

    create_new_prerelease_cycle > /dev/null 2>&1
    assert_eq "back on dev" "dev" "$(git branch --show-current)"
    assert_eq "dev on next prerelease" "2.0.1a0" "$(uv version --short)"

    cleanup
}

test_duplicate_tag_rejected() {
    echo ""
    echo "Duplicate tag is rejected"
    setup_repo
    source_release

    git tag "v0.1.0"
    local exit_code=0
    (git_tag_version "v0.1.0") >/dev/null 2>&1 || exit_code=$?
    assert_eq "exits non-zero on duplicate tag" "1" "$exit_code"

    cleanup
}

# --- Phase tests (subprocess) ----------------------------------------------

test_local_two_stage() {
    echo ""
    echo "Local two-stage release (pr stops, merge completes; --local, no gh)"
    setup_repo

    NO_COLOR=1 "$STANZA" release pr patch -y --local >/dev/null 2>&1
    assert_eq "dev bumped to stable" "0.1.0" "$(uv version --short)"
    assert_eq "still on dev after pr phase" "dev" "$(git branch --show-current)"
    assert_eq "no tag after pr phase" "" "$(git tag -l)"

    NO_COLOR=1 "$STANZA" release merge -y --local >/dev/null 2>&1
    assert_eq "tag created after merge" "v0.1.0" "$(git tag -l v0.1.0)"
    assert_eq "back on dev after merge" "dev" "$(git branch --show-current)"
    assert_eq "dev on next prerelease" "0.1.1a0" "$(uv version --short)"
    assert_eq "tag sits on the local release merge" "version [release]: v0.1.0" \
        "$(git log -1 --format=%s v0.1.0)"
    assert_eq "dev carries the release merge and its tag" "yes" \
        "$(git merge-base --is-ancestor v0.1.0 dev && echo yes || echo no)"

    cleanup
}

test_remote_two_stage() {
    echo ""
    echo "Remote two-stage release over gh mock (pr stops, merge completes)"
    setup_remote_repo

    # Phase 1: bump on dev, open the PR, then STOP.
    out=$(NO_COLOR=1 "$STANZA" --json release pr patch -y 2>/dev/null)
    assert_eq "dev bumped to stable" "0.1.0" "$(cat VERSION)"
    assert_eq "still on dev after pr phase" "dev" "$(git branch --show-current)"
    assert_eq "no tag after pr phase" "" "$(git tag -l)"
    assert_eq "PR is open" "open" "$(cat "$GH_MOCK_STATE/state")"
    assert_contains "pr-phase JSON has phase" "$out" '"phase":"pr"'
    assert_contains "pr-phase JSON has resume hint" "$out" '"resume":"stanza release merge"'
    assert_contains "pr-phase JSON has pr number" "$out" '"pr":{"number":1'

    # Phase 2: merge the open PR, tag, open the next cycle.
    out=$(NO_COLOR=1 "$STANZA" --json release merge -y 2>/dev/null)
    assert_eq "tag created after merge" "v0.1.0" "$(git tag -l v0.1.0)"
    assert_eq "back on dev after merge" "dev" "$(git branch --show-current)"
    assert_eq "dev on next prerelease" "0.1.1a0" "$(cat VERSION)"
    assert_eq "PR closed after merge" "closed" "$(cat "$GH_MOCK_STATE/state")"
    assert_contains "merge-phase JSON has phase" "$out" '"phase":"merge"'
    assert_eq "merge phase passes the release subject to gh" "version [release]: v0.1.0 - PR #1" \
        "$(cat "$GH_MOCK_STATE/merge_subject")"
    assert_eq "tag sits on the release merge" "version [release]: v0.1.0 - PR #1" \
        "$(git log -1 --format=%s v0.1.0)"

    teardown_remote_repo
}

test_full_release_remote() {
    echo ""
    echo "Full one-shot release over gh mock (regression: no phase field)"
    setup_remote_repo

    out=$(NO_COLOR=1 "$STANZA" --json release patch -y 2>/dev/null)
    assert_eq "tag created" "v0.1.0" "$(git tag -l v0.1.0)"
    assert_eq "back on dev" "dev" "$(git branch --show-current)"
    assert_eq "dev on next prerelease" "0.1.1a0" "$(cat VERSION)"
    assert_not_contains "full-release JSON omits phase field" "$out" '"phase"'
    assert_contains "JSON readme_synced false (no README token)" "$out" '"readme_synced":false'
    assert_contains "JSON changelog_promoted false (no CHANGELOG)" "$out" '"changelog_promoted":false'
    assert_eq "full release passes the release subject to gh" "version [release]: v0.1.0 - PR #1" \
        "$(cat "$GH_MOCK_STATE/merge_subject")"
    assert_eq "tag sits on the release merge" "version [release]: v0.1.0 - PR #1" \
        "$(git log -1 --format=%s v0.1.0)"
    assert_contains "back-merge into dev keeps git's default subject" \
        "$(git log --format=%s dev)" "Merge branch 'main' into dev"

    teardown_remote_repo
}

test_pr_note_reaches_body() {
    echo ""
    echo "--pr-note is appended to the PR body"
    setup_remote_repo

    NO_COLOR=1 "$STANZA" release pr patch -y --pr-note "release notes here" >/dev/null 2>&1
    assert_contains "PR body contains the note" "$(cat "$GH_MOCK_STATE/body")" "release notes here"
    assert_contains "PR body keeps the filled body" "$(cat "$GH_MOCK_STATE/body")" "filled body"

    teardown_remote_repo
}

test_pr_pre_rejected() {
    echo ""
    echo "release pr pre is rejected (prereleases open no PR)"
    setup_repo

    local err exit_code=0
    err=$(NO_COLOR=1 "$STANZA" release pr pre -y --local 2>&1) || exit_code=$?
    assert_eq "exits non-zero" "1" "$exit_code"
    assert_contains "explains prereleases open no PR" "$err" "prereleases open no PR"

    cleanup
}

test_no_dev_cycle_full() {
    echo ""
    echo "--no-dev-cycle on a full release skips the dev cycle"
    setup_repo

    out=$(NO_COLOR=1 "$STANZA" --json release patch -y --local --no-dev-cycle 2>/dev/null)
    assert_eq "tag created" "v0.1.0" "$(git tag -l v0.1.0)"
    assert_eq "left on base branch (no cycle back to dev)" "main" "$(git branch --show-current)"
    assert_contains "next_cycle_version is null in JSON" "$out" '"next_cycle_version":null'

    git checkout -q dev
    assert_eq "dev not bumped past the release" "0.1.0" "$(uv version --short)"

    cleanup
}

test_no_dev_cycle_merge() {
    echo ""
    echo "--no-dev-cycle on the merge phase skips the dev cycle"
    setup_repo

    NO_COLOR=1 "$STANZA" release pr patch -y --local >/dev/null 2>&1
    NO_COLOR=1 "$STANZA" release merge -y --local --no-dev-cycle >/dev/null 2>&1
    assert_eq "tag created after merge" "v0.1.0" "$(git tag -l v0.1.0)"
    assert_eq "left on base branch after merge" "main" "$(git branch --show-current)"

    git checkout -q dev
    assert_eq "dev not bumped past the release" "0.1.0" "$(uv version --short)"

    cleanup
}

test_merge_no_open_pr_errors() {
    echo ""
    echo "merge with no open dev->base PR errors with a hint"
    setup_remote_repo

    local err exit_code=0
    err=$(NO_COLOR=1 "$STANZA" release merge -y 2>&1) || exit_code=$?
    assert_eq "exits non-zero" "1" "$exit_code"
    assert_contains "hints to run the pr phase first" "$err" "stanza release pr <type>"

    teardown_remote_repo
}

# --- README + CHANGELOG release-time tests (plan 008) ----------------------

test_release_promotes_changelog_and_readme() {
    echo ""
    echo "Full --local release promotes CHANGELOG and syncs README title"
    setup_repo

    printf '# test-project v0.1.0a0\n\nA tool.\n' > README.md
    cat > CHANGELOG.md << 'EOF'
# Changelog

## [Unreleased]

### Added
- A new thing

## [0.0.9] - 2026-01-01

### Added
- Older thing

[Unreleased]: https://github.com/owner/repo/compare/v0.0.9...HEAD
[0.0.9]: https://github.com/owner/repo/releases/tag/v0.0.9
EOF
    git add README.md CHANGELOG.md
    git commit -q -m "add README and CHANGELOG"

    NO_COLOR=1 "$STANZA" release patch -y --local >/dev/null 2>&1

    git checkout -q main
    local cl
    cl="$(< CHANGELOG.md)"
    assert_contains "main CHANGELOG has promoted version heading" "$cl" "## [0.1.0] - "
    assert_contains "main CHANGELOG keeps a fresh Unreleased" "$cl" "## [Unreleased]"
    assert_contains "main CHANGELOG preserved the entry" "$cl" "- A new thing"
    assert_contains "main CHANGELOG Unreleased link repointed" "$cl" "compare/v0.1.0...HEAD"
    assert_contains "main CHANGELOG new version compare link" "$cl" "[0.1.0]: https://github.com/owner/repo/compare/v0.0.9...v0.1.0"
    assert_eq "main README title synced to release version" "# test-project v0.1.0" "$(head -1 README.md)"

    git checkout -q dev
    assert_eq "dev README title on next prerelease" "# test-project v0.1.1a0" "$(head -1 README.md)"

    cleanup
}

test_empty_changelog_blocks_release() {
    echo ""
    echo "Empty CHANGELOG [Unreleased] blocks the release before any bump"
    setup_repo

    printf '# Changelog\n\n## [Unreleased]\n\n## [0.0.9] - 2026-01-01\n- Older\n' > CHANGELOG.md
    git add CHANGELOG.md
    git commit -q -m "add CHANGELOG with empty Unreleased"

    local before err exit_code=0
    before=$(uv version --short)
    err=$(NO_COLOR=1 "$STANZA" release patch -y --local 2>&1) || exit_code=$?
    assert_eq "release aborts non-zero" "1" "$exit_code"
    assert_contains "error explains empty Unreleased" "$err" "[Unreleased] is empty"
    assert_eq "version unchanged after abort" "$before" "$(uv version --short)"
    assert_eq "no tag created" "" "$(git tag -l)"
    assert_eq "working tree clean after abort" "" "$(git status --porcelain)"

    cleanup
}

test_no_changelog_flag_bypasses_block() {
    echo ""
    echo "--no-changelog bypasses the empty-Unreleased block and skips promotion"
    setup_repo

    printf '# Changelog\n\n## [Unreleased]\n\n## [0.0.9] - 2026-01-01\n- Older\n' > CHANGELOG.md
    git add CHANGELOG.md
    git commit -q -m "add CHANGELOG with empty Unreleased"

    NO_COLOR=1 "$STANZA" release patch -y --local --no-changelog >/dev/null 2>&1
    git checkout -q main
    assert_eq "tag created (release proceeded)" "v0.1.0" "$(git tag -l v0.1.0)"
    assert_not_contains "CHANGELOG not promoted" "$(< CHANGELOG.md)" "## [0.1.0]"

    cleanup
}

test_release_json_records_doc_syncs() {
    echo ""
    echo "Release JSON records readme_synced/changelog_promoted as booleans"
    setup_repo

    printf '# test-project v0.1.0a0\n' > README.md
    printf '# Changelog\n\n## [Unreleased]\n- A thing\n\n## [0.0.9] - 2026-01-01\n- old\n' > CHANGELOG.md
    git add README.md CHANGELOG.md
    git commit -q -m "add docs"

    local out
    out=$(NO_COLOR=1 "$STANZA" --json release patch -y --local 2>/dev/null)
    assert_contains "JSON readme_synced true" "$out" '"readme_synced":true'
    assert_contains "JSON changelog_promoted true" "$out" '"changelog_promoted":true'

    cleanup
}

# --- Run -------------------------------------------------------------------

trap cleanup EXIT

test_local_patch_release
test_local_minor_release
test_local_major_release
test_duplicate_tag_rejected
test_local_two_stage
test_remote_two_stage
test_full_release_remote
test_pr_note_reaches_body
test_pr_pre_rejected
test_merge_no_open_pr_errors
test_no_dev_cycle_full
test_no_dev_cycle_merge
test_release_promotes_changelog_and_readme
test_empty_changelog_blocks_release
test_no_changelog_flag_bypasses_block
test_release_json_records_doc_syncs

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
