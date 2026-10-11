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
    eval "$(extract_function step_start "$STANZA_DIR/lib/stanza-release")"
    eval "$(extract_function step_done "$STANZA_DIR/lib/stanza-release")"
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
#
# CI is scripted per call: the Nth `gh pr checks` prints $GH_MOCK_STATE/checks.N
# (or the highest-numbered file once the calls run past it), already in the
# "<bucket>\t<name>" form stanza's --jq asks for. No file, or one that reads
# NONE, is gh's "no checks reported" error. `gh run list` does the same with
# runs.N ("<status>\t<conclusion>\t<workflow>" lines; no file prints nothing)
# and records each --commit it was asked about in runs_commits. An auth_fail
# file makes `gh auth status` fail.
make_gh_mock() {
    local bindir="$1"
    mkdir -p "$bindir"
    cat > "$bindir/gh" <<'MOCK'
#!/bin/bash
set -e
STATE="${GH_MOCK_STATE:?}"
# Print the scripted response for call N of a CI read (see make_gh_mock).
scripted() {
  local kind="$1" n f
  n=$(( $(cat "$STATE/$kind.calls" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$STATE/$kind.calls"
  f="$STATE/$kind.$n"
  if [[ ! -f "$f" ]]; then
    f=$(ls "$STATE/$kind".[0-9]* 2>/dev/null | sort -t. -k2 -n | tail -1)
  fi
  [[ -n "$f" ]] && cat "$f"
}
cmd="$1"; shift || true
case "$cmd" in
  auth) [[ ! -f "$STATE/auth_fail" ]] || { echo "You are not logged into any GitHub hosts" >&2; exit 1; } ;;
  run)
    [[ "${1:-}" == list ]] || exit 0
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --commit) echo "$2" >> "$STATE/runs_commits"; shift 2 ;;
        *) shift ;;
      esac
    done
    scripted runs || true
    ;;
  pr)
    sub="$1"; shift || true
    case "$sub" in
      create)
        [[ ! -f "$STATE/create_fail" ]] || { echo "gh mock: could not create the pull request" >&2; exit 1; }
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
        echo main > "$STATE/base"
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
          headRefOid,baseRefName,state)
            [[ ! -f "$STATE/view_fail" ]] || exit 1
            printf '%s|%s|%s\n' "$(cat "$STATE/head")" "$(cat "$STATE/base")" "$(tr '[:lower:]' '[:upper:]' < "$STATE/state")"
            ;;
          *) printf '' ;;
        esac
        ;;
      checks)
        out=$(scripted checks || true)
        if [[ -z "$out" || "$out" == NONE ]]; then
          echo "no checks reported on the 'dev' branch" >&2
          exit 1
        fi
        printf '%s\n' "$out"
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
        [[ ! -f "$STATE/merge_fail" ]] || { echo "gh mock: the merge was refused" >&2; exit 1; }
        subject=""; match_head=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --subject) subject="$2"; shift 2 ;;
            --match-head-commit) match_head="$2"; shift 2 ;;
            --body) shift 2 ;;
            *) shift ;;
          esac
        done
        [[ ! -f "$STATE/race" ]] || echo changed > "$STATE/head"
        [[ -z "$match_head" || "$match_head" == "$(cat "$STATE/head")" ]] || exit 1
        printf '%s' "$match_head" > "$STATE/match_head"
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
    # Scripted CI answers at once: no grace period and no poll interval.
    export STANZA_CHECKS_GRACE_SECONDS=0 STANZA_CHECKS_INTERVAL=0
    make_gh_mock "$TEST_TMPDIR/bin"
    ORIG_PATH="$PATH"
    PATH="$TEST_TMPDIR/bin:$PATH"
    export PATH
}

teardown_remote_repo() {
    [[ -n "$ORIG_PATH" ]] && PATH="$ORIG_PATH" && export PATH
    unset GH_MOCK_STATE STANZA_CHECKS_GRACE_SECONDS STANZA_CHECKS_INTERVAL STANZA_CHECKS_TIMEOUT
    if [[ -n "${STALL_PID:-}" ]]; then
        kill "$STALL_PID" 2>/dev/null || true
        wait "$STALL_PID" 2>/dev/null || true
        STALL_PID=""
    fi
    cleanup
}

# Start a TCP server on 127.0.0.1 that accepts connections and never answers,
# as a stalled HTTPS remote does. Sets STALL_PORT and STALL_PID (stopped by
# teardown_remote_repo; the server also exits on its own after 60 seconds).
# Returns 1 when uv is not available to run it.
start_stall_server() {
    command -v uv >/dev/null 2>&1 || return 1
    cat > "$TEST_TMPDIR/stall.py" <<'PY'
import socket, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(16)
print(s.getsockname()[1], flush=True)
s.settimeout(0.5)
held = []
end = time.time() + 60
while time.time() < end:
    try:
        held.append(s.accept()[0])
    except socket.timeout:
        pass
PY
    uv run --no-project python "$TEST_TMPDIR/stall.py" > "$TEST_TMPDIR/stall.port" 2>/dev/null &
    STALL_PID=$!
    local _
    for _ in $(seq 1 100); do
        [[ -s "$TEST_TMPDIR/stall.port" ]] && break
        sleep 0.1
    done
    STALL_PORT=$(cat "$TEST_TMPDIR/stall.port")
    [[ -n "$STALL_PORT" ]]
}

# Refuse pushes on the bare remote with an update hook (per ref, as GitHub
# branch protection does). The hook body is passed as the argument.
remote_update_hook() {
    printf '#!/bin/bash\n%s\nexit 0\n' "$1" > "$TEST_TMPDIR/remote.git/hooks/update"
    chmod +x "$TEST_TMPDIR/remote.git/hooks/update"
}

# Arm a failure in one release step of a full 'release patch' over the gh mock,
# and print the error text that step's failure must show.
arm_step_failure() {
    case "$1" in
        bump)
            printf '#!/bin/bash\necho "pre-commit refuses" >&2\nexit 1\n' > .git/hooks/pre-commit
            chmod +x .git/hooks/pre-commit
            git config core.hooksPath "$PWD/.git/hooks"
            echo "pre-commit refuses"
            ;;
        push)
            remote_update_hook '[[ "$1" == refs/heads/dev ]] && { echo "dev is protected" >&2; exit 1; }'
            echo "dev is protected"
            ;;
        pr)
            touch "$GH_MOCK_STATE/create_fail"
            echo "could not create the pull request"
            ;;
        checks)
            printf 'fail\ttest\n' > "$GH_MOCK_STATE/checks.1"
            echo "has failing checks: test"
            ;;
        merge)
            touch "$GH_MOCK_STATE/merge_fail"
            echo "the merge was refused"
            ;;
        tag)
            remote_update_hook '[[ "$1" == refs/tags/* ]] && { echo "tags are refused" >&2; exit 1; }'
            echo "tags are refused"
            ;;
        cycle)
            # Refuse dev only once the release tag is on the remote: the cycle's push.
            remote_update_hook '[[ "$1" == refs/heads/dev ]] && git rev-parse -q --verify refs/tags/v0.1.0 >/dev/null && { echo "dev is frozen" >&2; exit 1; }'
            echo "dev is frozen"
            ;;
    esac
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

# --- --no-pr (plan 002) ----------------------------------------------------

test_no_pr_full_release() {
    echo ""
    echo "Full --no-pr release merges dev directly and pushes main with the tag"
    setup_remote_repo

    local out
    out=$(NO_COLOR=1 "$STANZA" --json release patch -y --no-pr 2>/dev/null)
    assert_eq "no PR opened" "" "$(cat "$GH_MOCK_STATE/number" 2>/dev/null)"
    assert_eq "tag created" "v0.1.0" "$(git tag -l v0.1.0)"
    assert_eq "tag sits on the no-PR release merge" "version [release]: v0.1.0" \
        "$(git log -1 --format=%s v0.1.0)"
    assert_eq "remote main is the release merge" "$(git rev-parse v0.1.0)" \
        "$(git --git-dir="$TEST_TMPDIR/remote.git" rev-parse main)"
    assert_eq "tag pushed" "$(git rev-parse v0.1.0)" \
        "$(git --git-dir="$TEST_TMPDIR/remote.git" rev-parse v0.1.0^{commit} 2>/dev/null)"
    assert_eq "back on dev" "dev" "$(git branch --show-current)"
    assert_eq "dev on next prerelease" "0.1.1a0" "$(cat VERSION)"
    assert_eq "dev cycle pushed" "$(git rev-parse dev)" \
        "$(git --git-dir="$TEST_TMPDIR/remote.git" rev-parse dev)"
    assert_contains "JSON pr is null" "$out" '"pr":null'
    assert_contains "JSON tag pushed" "$out" '"pushed":true}'

    teardown_remote_repo
}

test_no_pr_merge_phase() {
    echo ""
    echo "release merge --no-pr merges dev directly after the pr phase"
    setup_remote_repo

    NO_COLOR=1 "$STANZA" release pr patch -y >/dev/null 2>&1
    NO_COLOR=1 "$STANZA" release merge -y --no-pr >/dev/null 2>&1
    assert_eq "tag created" "v0.1.0" "$(git tag -l v0.1.0)"
    assert_eq "gh merge not called" "" "$(cat "$GH_MOCK_STATE/merge_subject" 2>/dev/null)"
    assert_eq "tag sits on the no-PR release merge" "version [release]: v0.1.0" \
        "$(git log -1 --format=%s v0.1.0)"
    assert_eq "remote main is the release merge" "$(git rev-parse v0.1.0)" \
        "$(git --git-dir="$TEST_TMPDIR/remote.git" rev-parse main)"
    assert_eq "dev on next prerelease" "0.1.1a0" "$(cat VERSION)"

    teardown_remote_repo
}

test_no_pr_protected_base_pushes_nothing() {
    echo ""
    echo "--no-pr against a protected base: push refused, no tag on the remote"
    setup_remote_repo

    # An update hook refuses per ref, as GitHub branch protection does
    # (pre-receive would refuse the whole push and hide a non-atomic push).
    remote_update_hook '[[ "$1" == refs/heads/main ]] && { echo "main is protected" >&2; exit 1; }'

    local err exit_code=0
    err=$(NO_COLOR=1 "$STANZA" release patch -y --no-pr 2>&1) || exit_code=$?
    assert_eq "exits non-zero" "1" "$exit_code"
    assert_eq "no tag on the remote" "" \
        "$(git --git-dir="$TEST_TMPDIR/remote.git" tag -l)"
    assert_eq "local tag removed" "" "$(git tag -l v0.1.0)"
    assert_eq "bump is on origin/dev" "0.1.0" \
        "$(git --git-dir="$TEST_TMPDIR/remote.git" show dev:VERSION)"
    assert_contains "hints the PR recovery" "$err" "stanza release merge"
    assert_contains "hints resetting the base branch" "$err" "git branch -f main origin/main"
    assert_contains "shows the remote's refusal" "$err" "remote: main is protected"

    teardown_remote_repo
}

test_no_pr_merge_phase_protected_skips_pr_create() {
    echo ""
    echo "merge --no-pr refused after 'release pr': the hint does not reopen a PR"
    setup_remote_repo

    NO_COLOR=1 "$STANZA" release pr patch -y >/dev/null 2>&1
    remote_update_hook '[[ "$1" == refs/heads/main ]] && { echo "main is protected" >&2; exit 1; }'

    local err exit_code=0
    err=$(NO_COLOR=1 "$STANZA" release merge -y --no-pr 2>&1) || exit_code=$?
    assert_eq "exits non-zero" "1" "$exit_code"
    assert_not_contains "no gh pr create hint" "$err" "gh pr create"
    assert_contains "hints the merge recovery" "$err" "stanza release merge"

    teardown_remote_repo
}

test_no_pr_diverged_base_refused() {
    echo ""
    echo "--no-pr with a diverged base branch: refused before the bump"
    local phase err exit_code
    for phase in full merge; do
        setup_remote_repo
        # merge: a pr phase has promoted dev to the release version.
        if [[ "$phase" == merge ]]; then
            echo "0.1.0" > VERSION
            git commit -q -am "version [patch]: 0.1.0"
            git push -q origin dev
        fi

        git checkout -q main
        git commit -q --allow-empty -m "local only"
        git checkout -q -b remote-side origin/main
        git commit -q --allow-empty -m "remote only"
        git push -q origin remote-side:main
        git checkout -q dev
        git branch -q -D remote-side
        preflight_snapshot

        local args=(release patch -y --no-pr)
        [[ "$phase" == merge ]] && args=(release merge -y --no-pr)
        exit_code=0
        err=$(NO_COLOR=1 "$STANZA" "${args[@]}" 2>&1) || exit_code=$?
        assert_eq "$phase: exits non-zero" "1" "$exit_code"
        assert_contains "$phase: names the divergence" "$err" \
            "main has diverged from origin/main"
        assert_contains "$phase: shows how to compare" "$err" \
            "git log --oneline --left-right main...origin/main"
        preflight_unchanged "$phase, diverged base"
        teardown_remote_repo
    done

    # A local base ahead of origin's still fast-forwards (the pull is a no-op).
    setup_remote_repo
    git checkout -q main
    git commit -q --allow-empty -m "local only"
    git checkout -q dev
    exit_code=0
    NO_COLOR=1 "$STANZA" release patch --no-pr --check >/dev/null 2>&1 || exit_code=$?
    assert_eq "base ahead of origin: check passes" "0" "$exit_code"
    teardown_remote_repo
}

test_no_pr_ignored_by_prerelease() {
    echo ""
    echo "prerelease --no-pr warns and the header does not claim 'no PR'"
    setup_remote_repo

    local out
    out=$(NO_COLOR=1 "$STANZA" release prerelease -y --no-pr 2>&1)
    assert_contains "warns --no-pr is ignored" "$out" "--no-pr is ignored by prerelease"
    assert_not_contains "header lacks 'no PR'" "$out" ", no PR"

    teardown_remote_repo
}

test_pr_path_push_failure_hints_dev_cycle() {
    echo ""
    echo "PR release whose tag push is refused: the hint covers the dev cycle"
    setup_remote_repo

    remote_update_hook '[[ "$1" == refs/tags/* ]] && { echo "tags are refused" >&2; exit 1; }'

    local err exit_code=0
    err=$(NO_COLOR=1 "$STANZA" release patch -y 2>&1) || exit_code=$?
    assert_eq "exits non-zero" "1" "$exit_code"
    assert_contains "shows the remote's refusal" "$err" "remote: tags are refused"
    assert_contains "hints the retry" "$err" "git push --atomic origin main refs/tags/v0.1.0"
    assert_contains "hints the resume" "$err" "git checkout dev && stanza release merge -y"
    assert_contains "names the failed step" "$err" "  tag     failed; main has the release merge"
    assert_not_contains "own hints replace the generic resume" "$err" "hint    resume:"

    # The local tag is kept, so 'release merge' resumes: pushes it, runs the cycle.
    rm "$TEST_TMPDIR/remote.git/hooks/update"
    git checkout -q dev
    local out code=0
    out=$(NO_COLOR=1 "$STANZA" release merge -y 2>&1) || code=$?
    assert_eq "resume exits 0" "0" "$code"
    assert_contains "resume pushes the tag" "$out" "v0.1.0  pushed (resumed)"
    assert_eq "tag on the remote" "$(git rev-parse v0.1.0)" \
        "$(git --git-dir="$TEST_TMPDIR/remote.git" rev-parse v0.1.0 2>/dev/null)"
    assert_eq "dev on next prerelease" "0.1.1a0" "$(cat VERSION)"
    assert_eq "dev cycle pushed" "$(git rev-parse dev)" \
        "$(git --git-dir="$TEST_TMPDIR/remote.git" rev-parse dev)"

    teardown_remote_repo
}

test_no_pr_ignored_flags_warn() {
    echo ""
    echo "--no-pr is ignored by 'release pr'; --pr-note is ignored with --no-pr"
    setup_remote_repo

    local err
    err=$(NO_COLOR=1 "$STANZA" release pr patch -y --no-pr 2>&1 >/dev/null)
    assert_contains "warns --no-pr is ignored by pr" "$err" "--no-pr is ignored"
    assert_eq "pr phase still opened a PR" "open" "$(cat "$GH_MOCK_STATE/state")"
    teardown_remote_repo

    setup_remote_repo
    err=$(NO_COLOR=1 "$STANZA" release patch -y --no-pr --pr-note "a note" 2>&1 >/dev/null)
    assert_contains "warns --pr-note is ignored" "$err" "--pr-note is ignored with --no-pr"
    assert_eq "release still tagged" "v0.1.0" "$(git tag -l v0.1.0)"
    teardown_remote_repo
}

# --- Failed steps and resume (plan 003) ------------------------------------

test_failed_step_is_named() {
    echo ""
    echo "A failure in each release step names the step and keeps the error"
    local step expect out json code row
    for step in bump push pr checks merge tag cycle; do
        setup_remote_repo
        expect=$(arm_step_failure "$step")
        code=0
        out=$(NO_COLOR=1 "$STANZA" release patch -y 2>&1) || code=$?
        row=$(printf '  %-8sfailed' "$step")
        assert_eq "$step: exits 1" "1" "$code"
        assert_contains "$step: prints the failed row" "$out" "$row"
        assert_contains "$step: shows the captured error" "$out" "$expect"
        teardown_remote_repo

        setup_remote_repo
        arm_step_failure "$step" >/dev/null
        code=0
        json=$(NO_COLOR=1 "$STANZA" --json release patch -y 2>/dev/null) || code=$?
        assert_eq "$step --json: exits 1" "1" "$code"
        assert_contains "$step --json: ok is false" "$json" '"ok":false'
        assert_contains "$step --json: names the failed step" "$json" "\"failed_step\":\"$step\""
        if command -v jq >/dev/null 2>&1; then
            assert_eq "$step --json: stdout is one JSON document" "1" \
                "$(printf '%s' "$json" | jq -s 'length' 2>/dev/null)"
        fi
        teardown_remote_repo
    done
}

test_failed_step_json_fields() {
    echo ""
    echo "Failure JSON carries completed steps, the error, and the resume"
    setup_remote_repo
    arm_step_failure cycle >/dev/null
    local json
    json=$(NO_COLOR=1 "$STANZA" --json release patch -y 2>/dev/null) || true
    assert_contains "completed steps in order" "$json" \
        '"completed_steps":["bump","push","pr","checks","merge","tag"]'
    assert_contains "error names the failed call" "$json" '"error":"git push origin dev failed (exit 1)"'
    assert_contains "resume is release merge" "$json" '"resume":"git checkout dev && stanza release merge -y"'
    teardown_remote_repo

    setup_remote_repo
    arm_step_failure tag >/dev/null
    json=$(NO_COLOR=1 "$STANZA" --json release patch -y 2>/dev/null) || true
    assert_contains "own hints: resume is null" "$json" '"resume":null'
    assert_contains "own hints are in hint" "$json" 'retry: git push --atomic origin main refs/tags/v0.1.0'
    teardown_remote_repo

    setup_remote_repo
    git checkout -q -b feature
    json=$(NO_COLOR=1 "$STANZA" --json release merge -y 2>/dev/null) || true
    assert_contains "a refusal before any step is preflight" "$json" '"failed_step":"preflight"'
    assert_contains "preflight error is recorded" "$json" '"error":"This operation should be performed on dev branch"'
    if command -v jq >/dev/null 2>&1; then
        assert_eq "preflight stdout is one JSON document" "1" \
            "$(printf '%s' "$json" | jq -s 'length' 2>/dev/null)"
    fi
    teardown_remote_repo
}

test_cycle_push_failure_resumes() {
    echo ""
    echo "A refused dev-cycle push: release merge pushes the bump, then is a no-op"
    setup_remote_repo
    arm_step_failure cycle >/dev/null

    local out code=0
    out=$(NO_COLOR=1 "$STANZA" release patch -y 2>&1) || code=$?
    assert_eq "release exits 1" "1" "$code"
    assert_contains "says dev is advanced but not pushed" "$out" \
        "cycle   failed; v0.1.0 is released; dev is advanced locally but not pushed"
    assert_contains "hints the resume" "$out" "resume: git checkout dev && stanza release merge -y"
    assert_contains "hints the push by hand" "$out" "or by hand: git checkout dev && git push origin dev"
    assert_eq "dev bumped locally" "0.1.1a0" "$(cat VERSION)"

    # A resume that fails at the same push still knows dev is advanced, and
    # its by-hand hint does not bump a second time.
    code=0
    out=$(NO_COLOR=1 "$STANZA" release merge -y 2>&1) || code=$?
    assert_eq "refused resume exits 1" "1" "$code"
    assert_contains "refused resume says dev is advanced" "$out" \
        "cycle   failed; v0.1.0 is released; dev is advanced locally but not pushed"
    assert_not_contains "refused resume does not hint a second bump" "$out" "stanza release prerelease"
    assert_eq "refused resume does not bump" "0.1.1a0" "$(cat VERSION)"

    rm "$TEST_TMPDIR/remote.git/hooks/update"
    code=0
    out=$(NO_COLOR=1 "$STANZA" release merge -y 2>&1) || code=$?
    assert_eq "resume exits 0" "0" "$code"
    assert_contains "resume reports the release" "$out" "v0.1.0  already released; resuming"
    assert_contains "resume pushes the advanced dev" "$out" "0.1.1a0 on dev (already advanced, pushed)"
    assert_eq "resume does not bump again" "0.1.1a0" "$(cat VERSION)"
    assert_eq "dev pushed" "$(git rev-parse dev)" \
        "$(git --git-dir="$TEST_TMPDIR/remote.git" rev-parse dev)"

    local before
    before=$(git rev-parse dev)
    code=0
    out=$(NO_COLOR=1 "$STANZA" release merge -y 2>&1) || code=$?
    assert_eq "second resume exits 0" "0" "$code"
    assert_contains "second resume has nothing to do" "$out" "(already advanced, nothing to push)"
    assert_eq "second resume leaves dev unchanged" "$before" "$(git rev-parse dev)"

    teardown_remote_repo
}

test_resume_tag_fetch_failure_stops() {
    echo ""
    echo "Resume whose tag fetch fails stops there, without a re-tag hint"
    setup_remote_repo
    NO_COLOR=1 "$STANZA" release patch -y --no-dev-cycle >/dev/null 2>&1
    git checkout -q dev
    # The tag is on origin only, and a local v0.1.0/x ref blocks fetching it.
    git tag -d v0.1.0 >/dev/null
    git tag v0.1.0/x

    local out code=0
    out=$(NO_COLOR=1 "$STANZA" release merge -y 2>&1) || code=$?
    assert_eq "exits 1" "1" "$code"
    assert_contains "names the failed fetch" "$out" \
        "git fetch origin refs/tags/v0.1.0:refs/tags/v0.1.0 failed"
    assert_not_contains "does not go on to the tag step" "$out" "tag     failed"
    assert_not_contains "does not hint re-tagging" "$out" "git tag v0.1.0"
    teardown_remote_repo
}

test_subshell_error_reaches_json() {
    echo ""
    echo "An error printed inside a subshell reaches the failure JSON"
    setup_remote_repo
    rm VERSION
    local json
    json=$(NO_COLOR=1 "$STANZA" --json release patch -y 2>/dev/null) || true
    assert_contains "failed in preflight" "$json" '"failed_step":"preflight"'
    assert_contains "error carries the message" "$json" '"error":"No version file found'
    teardown_remote_repo
}

test_prerelease_push_failure_warns() {
    echo ""
    echo "A refused prerelease push warns, keeps the remote's reason, and succeeds"
    setup_remote_repo
    remote_update_hook '[[ "$1" == refs/heads/dev ]] && { echo "dev is protected" >&2; exit 1; }'
    local out code=0
    out=$(NO_COLOR=1 "$STANZA" release prerelease -y 2>&1) || code=$?
    assert_eq "exits 0" "0" "$code"
    assert_contains "warns naming the push" "$out" "[WARNING] git push origin dev failed (exit 1)"
    assert_contains "keeps the remote's reason" "$out" "remote: dev is protected"
    assert_not_contains "prints no error" "$out" "[ERROR]"
    teardown_remote_repo
}

test_stalled_fetch_stops_cycle() {
    echo ""
    echo "A stalled fetch in the dev cycle times out; release merge resumes it"
    setup_remote_repo
    if ! start_stall_server; then
        echo "  SKIP: uv is not available to run the stall server"
        teardown_remote_repo
        return 0
    fi

    # Once the tag reaches origin, fetches go to the stalled server; pushes still
    # reach the bare remote. The cycle's 'git pull origin dev' is the first fetch.
    local work="$PWD"
    cat > "$TEST_TMPDIR/remote.git/hooks/post-receive" <<HOOK
#!/bin/bash
grep -q ' refs/tags/' || exit 0
unset GIT_DIR GIT_WORK_TREE
git --git-dir="$work/.git" config remote.origin.pushurl "$TEST_TMPDIR/remote.git"
git --git-dir="$work/.git" config remote.origin.url "http://127.0.0.1:$STALL_PORT/stalled.git"
HOOK
    chmod +x "$TEST_TMPDIR/remote.git/hooks/post-receive"

    local out code=0 start elapsed
    start=$(date +%s)
    out=$(STANZA_NET_STALL_SECONDS=2 NO_COLOR=1 "$STANZA" release patch -y 2>&1) || code=$?
    elapsed=$(( $(date +%s) - start ))
    assert_eq "stalled run exits non-zero" "yes" "$([[ $code -ne 0 ]] && echo yes || echo no)"
    assert_eq "gives up within the stall window (${elapsed}s)" "yes" \
        "$([[ $elapsed -lt 20 ]] && echo yes || echo no)"
    assert_contains "shows git's stall error" "$out" "Operation too slow"
    assert_contains "names the stalled call" "$out" "git pull origin dev failed"
    assert_contains "names the cycle step" "$out" "cycle   failed; v0.1.0 is released; dev is not advanced"
    assert_contains "hints the resume" "$out" "resume: git checkout dev && stanza release merge -y"
    assert_eq "tag reached the remote" "$(git rev-parse v0.1.0)" \
        "$(git --git-dir="$TEST_TMPDIR/remote.git" rev-parse v0.1.0 2>/dev/null)"
    assert_eq "dev not advanced" "0.1.0" "$(cat VERSION)"

    # The network is back: one command finishes the cycle.
    rm "$TEST_TMPDIR/remote.git/hooks/post-receive"
    git config --unset remote.origin.pushurl
    git config remote.origin.url "$TEST_TMPDIR/remote.git"
    code=0
    out=$(NO_COLOR=1 "$STANZA" release merge -y 2>&1) || code=$?
    assert_eq "resume exits 0" "0" "$code"
    assert_contains "resume runs the cycle" "$out" "0.1.1a0 on dev (merged main back, pushed)"
    assert_eq "dev on next prerelease" "0.1.1a0" "$(cat VERSION)"
    assert_eq "dev cycle pushed" "$(git rev-parse dev)" \
        "$(git --git-dir="$TEST_TMPDIR/remote.git" rev-parse dev)"
    assert_contains "back-merge carries the release" \
        "$(git log --format=%s dev)" "Merge branch 'main' into dev"

    teardown_remote_repo
}

test_local_cycle_resume() {
    echo ""
    echo "--local: release merge resumes a release whose tag exists"
    setup_repo
    NO_COLOR=1 "$STANZA" release patch -y --local --no-dev-cycle >/dev/null 2>&1
    git checkout -q dev
    local out code=0
    out=$(NO_COLOR=1 "$STANZA" release merge -y --local 2>&1) || code=$?
    assert_eq "local resume exits 0" "0" "$code"
    assert_contains "local resume names the tag" "$out" "v0.1.0  already released; resuming"
    assert_eq "dev on next prerelease" "0.1.1a0" "$(uv version --short)"
    assert_eq "dev carries the release" "yes" \
        "$(git merge-base --is-ancestor v0.1.0 dev && echo yes || echo no)"
    cleanup
}

# --- Earlier steps resumed (plan 007) --------------------------------------

# The sha of <ref> on the bare remote, or empty.
remote_sha() {
    git --git-dir="$TEST_TMPDIR/remote.git" rev-parse -q --verify "$1" 2>/dev/null || true
}

test_local_release_finished_remotely() {
    echo ""
    echo "A --local release finished against the remote pushes main with the tag"
    setup_remote_repo
    NO_COLOR=1 "$STANZA" release patch -y --local --no-dev-cycle >/dev/null 2>&1
    git checkout -q dev
    local out code=0
    out=$(NO_COLOR=1 "$STANZA" release merge -y 2>&1) || code=$?
    assert_eq "resume exits 0" "0" "$code"
    assert_contains "pushes main with the tag" "$out" "v0.1.0  pushed with main (resumed)"
    assert_eq "release merge on origin/main" "$(git rev-parse main)" "$(remote_sha main)"
    assert_eq "tag on origin" "$(git rev-parse v0.1.0)" "$(remote_sha v0.1.0)"
    assert_eq "dev on next prerelease" "0.1.1a0" "$(cat VERSION)"
    assert_eq "dev cycle pushed" "$(git rev-parse dev)" "$(remote_sha dev)"
    teardown_remote_repo

    # The local release also ran its dev cycle: the resume pushes the rest.
    setup_remote_repo
    NO_COLOR=1 "$STANZA" release patch -y --local >/dev/null 2>&1
    code=0
    out=$(NO_COLOR=1 "$STANZA" release merge -y 2>&1) || code=$?
    assert_eq "cycled: resume exits 0" "0" "$code"
    assert_contains "cycled: pushes main with the tag" "$out" "v0.1.0  pushed with main (resumed)"
    assert_contains "cycled: pushes the advanced dev" "$out" "0.1.1a0 on dev (already advanced, pushed)"
    assert_eq "cycled: tag on origin" "$(git rev-parse v0.1.0)" "$(remote_sha v0.1.0)"
    assert_eq "cycled: dev pushed" "$(git rev-parse dev)" "$(remote_sha dev)"
    teardown_remote_repo

    # origin/main moved on meanwhile: refuse, push nothing.
    setup_remote_repo
    NO_COLOR=1 "$STANZA" release patch -y --local --no-dev-cycle >/dev/null 2>&1
    git checkout -q -b hotfix origin/main
    git commit -q --allow-empty -m "hotfix"
    git push -q origin hotfix:main
    git checkout -q dev
    git branch -q -D hotfix
    code=0
    out=$(NO_COLOR=1 "$STANZA" release merge -y 2>&1) || code=$?
    assert_eq "diverged: exits 1" "1" "$code"
    assert_contains "diverged: says so" "$out" "main has diverged from origin/main; not resuming"
    assert_not_contains "diverged: no fetch error" "$out" "non-fast-forward"
    assert_eq "diverged: tag not pushed" "" "$(remote_sha v0.1.0)"
    teardown_remote_repo

    # main gained a commit after the local release: not pushed along with it.
    setup_remote_repo
    NO_COLOR=1 "$STANZA" release patch -y --local --no-dev-cycle >/dev/null 2>&1
    git commit -q --allow-empty -m "unreleased"
    git checkout -q dev
    code=0
    out=$(NO_COLOR=1 "$STANZA" release merge -y 2>&1) || code=$?
    assert_eq "ahead: exits 1" "1" "$code"
    assert_contains "ahead: names the extra commits" "$out" "main has commits after v0.1.0 that origin/main lacks"
    assert_eq "ahead: main not pushed" "$(git rev-parse origin/main)" "$(remote_sha main)"
    teardown_remote_repo
}

# --- Run -------------------------------------------------------------------

test_merge_requires_dev() {
    setup_remote_repo
    "$STANZA" release pr patch -y --local >/dev/null 2>&1
    git checkout -q -b feature
    local out code=0
    out=$("$STANZA" release merge --local -y 2>&1) || code=$?
    assert_eq "local merge rejects feature branch" "1" "$code"
    assert_contains "local merge explains required branch" "$out" "dev"
    assert_eq "wrong-branch merge creates no tag" "" "$(git tag)"
    teardown_remote_repo
}

test_merge_requires_dev

test_pr_merge_guards() {
    local scenario out code before
    for scenario in view_fail empty_head closed wrong_base mismatch race; do
        setup_remote_repo
        "$STANZA" release pr patch -y >/dev/null 2>&1
        before=$(git rev-parse main)
        case "$scenario" in
            view_fail) touch "$GH_MOCK_STATE/view_fail" ;;
            empty_head) : > "$GH_MOCK_STATE/head" ;;
            closed) echo closed > "$GH_MOCK_STATE/state" ;;
            wrong_base) echo other > "$GH_MOCK_STATE/base" ;;
            mismatch) echo other > "$GH_MOCK_STATE/head" ;;
            race) touch "$GH_MOCK_STATE/race" ;;
        esac
        code=0
        out=$("$STANZA" release merge 1 -y 2>&1) || code=$?
        assert_eq "$scenario refuses PR merge" "1" "$code"
        assert_eq "$scenario leaves main unchanged" "$before" "$(git rev-parse main)"
        assert_eq "$scenario creates no tag" "" "$(git tag)"
        if [[ "$scenario" == view_fail || "$scenario" == empty_head ]]; then
            assert_contains "$scenario explains lookup failure" "$out" "Could not verify"
        fi
        teardown_remote_repo
    done
    # Without a local dev, preflight refuses before it reads the PR.
    setup_remote_repo
    "$STANZA" release pr patch -y >/dev/null 2>&1
    git branch -m dev feature
    before=$(git rev-parse main)
    code=0
    out=$("$STANZA" release merge 1 -y 2>&1) || code=$?
    assert_eq "missing dev head refuses PR merge" "1" "$code"
    assert_contains "missing dev head explains failure" "$out" "should be performed on dev"
    assert_eq "missing dev head leaves main unchanged" "$before" "$(git rev-parse main)"
    teardown_remote_repo
}

test_pr_merge_guards

test_merge_validates_release_title() {
    local title code out before
    for title in v9.9.9 'Release v0.1.0' ''; do
        setup_remote_repo
        "$STANZA" release pr patch -y >/dev/null 2>&1
        printf '%s' "$title" > "$GH_MOCK_STATE/title"
        before=$(git rev-parse main)
        code=0
        out=$("$STANZA" release merge -y 2>&1) || code=$?
        assert_eq "title '$title' rejected" "1" "$code"
        assert_contains "title mismatch hint" "$out" "PR title must be the release tag"
        assert_eq "title mismatch leaves main unchanged" "$before" "$(git rev-parse main)"
        assert_eq "title mismatch creates no tag" "" "$(git tag)"
        teardown_remote_repo
    done
    setup_remote_repo
    echo invalid > VERSION
    git add VERSION
    git commit -q -m invalid
    code=0
    out=$("$STANZA" release merge --local -y 2>&1) || code=$?
    assert_eq "invalid release version rejected" "1" "$code"
    assert_eq "invalid release version creates no tag" "" "$(git tag)"
    teardown_remote_repo
}

test_merge_validates_release_title

test_local_release_without_gh() {
    setup_remote_repo
    local bindir="$TEST_TMPDIR/local-bin" cmd code=0 out
    mkdir -p "$bindir"
    # An allowlist ensures no system or mocked gh can be found through PATH.
    for cmd in bash git dirname head tr sed grep date awk mv cat wc; do
        ln -s "$(command -v "$cmd")" "$bindir/$cmd"
    done
    out=$(PATH="$bindir" bash -c 'command -v gh' || true)
    assert_eq "local fixture has no gh on PATH" "" "$out"
    out=$(PATH="$bindir" "$STANZA" release patch --local -y 2>&1) || code=$?
    assert_eq "local release without gh succeeds" "0" "$code"
    assert_eq "local release without gh tags version" "v0.1.0" "$(git tag)"
    assert_eq "local release without gh completes dev cycle" "0.1.1a0" "$(cat VERSION)"
    teardown_remote_repo
}
test_local_release_without_gh

# --- CI gate ---------------------------------------------------------------

test_checks_pass_then_merge() {
    echo ""
    echo "The release merge waits for passing checks, including pending ones"
    setup_remote_repo
    printf 'pending\ttest\n' > "$GH_MOCK_STATE/checks.1"
    printf 'pass\ttest\npass\tlint\n' > "$GH_MOCK_STATE/checks.2"
    local out code=0
    out=$(NO_COLOR=1 "$STANZA" release patch -y 2>&1) || code=$?
    assert_eq "release succeeds" "0" "$code"
    assert_contains "waiting row names the pending check" "$out" "checks  waiting on test"
    assert_contains "passed row after the wait" "$out" "checks  2 passed after"
    assert_eq "checks polled twice" "2" "$(cat "$GH_MOCK_STATE/checks.calls")"
    assert_eq "tag created" "v0.1.0" "$(git tag -l v0.1.0)"
    teardown_remote_repo

    setup_remote_repo
    printf 'pass\ttest\n' > "$GH_MOCK_STATE/checks.1"
    out=$(NO_COLOR=1 "$STANZA" --json release patch -y 2>/dev/null)
    assert_contains "JSON checks passed" "$out" '"checks":"passed"'
    teardown_remote_repo
}

test_checks_fail_stops_merge() {
    echo ""
    echo "A failing check stops the release before the merge; the merge resumes it"
    setup_remote_repo
    printf 'pass\tlint\nfail\ttest\npending\tdocs\n' > "$GH_MOCK_STATE/checks.1"
    local before out code=0 json
    before=$(git --git-dir="$TEST_TMPDIR/remote.git" rev-parse main)
    out=$(NO_COLOR=1 "$STANZA" release patch -y 2>&1) || code=$?
    assert_eq "exits 1" "1" "$code"
    assert_contains "names the failing check" "$out" "PR #1 has failing checks: test"
    assert_contains "checks row failed" "$out" "checks  failed; PR #1 is open; nothing is merged or tagged"
    assert_contains "resume with release merge" "$out" "resume: git checkout dev && stanza release merge -y"
    assert_contains "says to fix on dev first" "$out" "fix the failing checks on dev and push"
    assert_contains "names the override" "$out" "stanza release merge -y --skip-checks"
    assert_not_contains "does not suggest a second bump" "$out" "stanza release pr"
    assert_eq "gh merge not called" "" "$(cat "$GH_MOCK_STATE/merge_subject" 2>/dev/null)"
    assert_eq "remote main unchanged" "$before" "$(git --git-dir="$TEST_TMPDIR/remote.git" rev-parse main)"
    assert_eq "no tag" "" "$(git tag)"
    assert_eq "PR left open" "open" "$(cat "$GH_MOCK_STATE/state")"
    assert_eq "still on dev" "dev" "$(git branch --show-current)"

    # Fix on dev and push: the PR head follows dev, and the merge resumes.
    echo fix > fix.txt
    git add fix.txt
    git commit -q -m "fix the test"
    git push -q origin dev
    git rev-parse dev > "$GH_MOCK_STATE/head"
    rm -f "$GH_MOCK_STATE"/checks.*
    printf 'pass\ttest\n' > "$GH_MOCK_STATE/checks.1"
    code=0
    out=$(NO_COLOR=1 "$STANZA" release merge -y 2>&1) || code=$?
    assert_eq "resume exits 0" "0" "$code"
    assert_eq "resume tags the release" "v0.1.0" "$(git tag -l v0.1.0)"
    assert_eq "release carries the fix" "yes" \
        "$(git merge-base --is-ancestor "$(git log -1 --format=%H --grep='fix the test' dev)" v0.1.0 && echo yes || echo no)"
    teardown_remote_repo

    setup_remote_repo
    printf 'cancel\ttest\n' > "$GH_MOCK_STATE/checks.1"
    code=0
    json=$(NO_COLOR=1 "$STANZA" --json release patch -y 2>/dev/null) || code=$?
    assert_eq "cancelled check exits 1" "1" "$code"
    assert_contains "JSON names the checks step" "$json" '"failed_step":"checks"'
    assert_contains "JSON completed steps" "$json" '"completed_steps":["bump","push","pr"]'
    assert_contains "JSON error names the check" "$json" '"error":"PR #1 has failing checks: test"'
    teardown_remote_repo
}

test_checks_none_reported() {
    echo ""
    echo "No checks is a pass, after the grace period"
    setup_remote_repo
    local out
    out=$(NO_COLOR=1 "$STANZA" release patch -y 2>&1)
    assert_contains "none reported row" "$out" "checks  none reported"
    assert_eq "tag created" "v0.1.0" "$(git tag -l v0.1.0)"
    teardown_remote_repo

    setup_remote_repo
    out=$(NO_COLOR=1 "$STANZA" --json release patch -y 2>/dev/null)
    assert_contains "JSON checks none" "$out" '"checks":"none"'
    teardown_remote_repo

    # Checks that register late are waited on, not taken for none.
    setup_remote_repo
    echo NONE > "$GH_MOCK_STATE/checks.1"
    printf 'fail\ttest\n' > "$GH_MOCK_STATE/checks.2"
    local code=0
    out=$(STANZA_CHECKS_GRACE_SECONDS=30 NO_COLOR=1 "$STANZA" release patch -y 2>&1) || code=$?
    assert_eq "late failing check stops the release" "1" "$code"
    assert_contains "late check is read" "$out" "has failing checks: test"
    assert_eq "no tag" "" "$(git tag)"
    teardown_remote_repo
}

test_checks_timeout() {
    echo ""
    echo "Checks still pending at STANZA_CHECKS_TIMEOUT stop the release"
    setup_remote_repo
    printf 'pending\ttest\n' > "$GH_MOCK_STATE/checks.1"
    local out code=0
    out=$(STANZA_CHECKS_TIMEOUT=1 STANZA_CHECKS_INTERVAL=1 NO_COLOR=1 "$STANZA" release patch -y 2>&1) || code=$?
    assert_eq "exits 1" "1" "$code"
    assert_contains "names the timeout" "$out" "PR #1 checks still pending after 1s: test"
    assert_contains "resume waits again" "$out" "resume: git checkout dev && stanza release merge -y"
    assert_contains "names the setting" "$out" "STANZA_CHECKS_TIMEOUT"
    assert_eq "no tag" "" "$(git tag)"
    assert_eq "PR left open" "open" "$(cat "$GH_MOCK_STATE/state")"
    teardown_remote_repo
}

test_checks_read_error_stops_merge() {
    echo ""
    echo "A PR whose checks cannot be read is not merged; a passing blip is retried"
    setup_remote_repo
    "$STANZA" release pr patch -y >/dev/null 2>&1
    # A gh that fails on checks (the first $GH_CHECKS_FAILS reads, or every
    # read when unset), otherwise the mock.
    cat > "$TEST_TMPDIR/bin/gh-real" < "$TEST_TMPDIR/bin/gh"
    chmod +x "$TEST_TMPDIR/bin/gh-real"
    cat > "$TEST_TMPDIR/bin/gh" <<SHIM
#!/bin/bash
if [[ "\$1 \$2" == "pr checks" ]]; then
    echo x >> "\$GH_MOCK_STATE/checks_errors"
    n=\$(wc -l < "\$GH_MOCK_STATE/checks_errors")
    if [[ -z "\${GH_CHECKS_FAILS:-}" || \$n -le \$GH_CHECKS_FAILS ]]; then
        echo "HTTP 502" >&2; exit 1
    fi
fi
exec "$TEST_TMPDIR/bin/gh-real" "\$@"
SHIM
    local out code=0
    out=$(NO_COLOR=1 "$STANZA" release merge -y 2>&1) || code=$?
    assert_eq "exits 1" "1" "$code"
    assert_eq "read three times before stopping" "3" "$(wc -l < "$GH_MOCK_STATE/checks_errors" | tr -d ' ')"
    assert_contains "warns on each retry" "$out" "could not read the checks of PR #1; retrying"
    assert_contains "says the checks were not read" "$out" "could not read the checks of PR #1"
    assert_contains "shows gh's output" "$out" "HTTP 502"
    assert_eq "no tag" "" "$(git tag)"

    # One failed read, then the checks pass: the release goes through.
    rm -f "$GH_MOCK_STATE/checks_errors"
    printf 'pass\ttest\n' > "$GH_MOCK_STATE/checks.1"
    code=0
    out=$(GH_CHECKS_FAILS=1 NO_COLOR=1 "$STANZA" release merge -y 2>&1) || code=$?
    assert_eq "blip: release succeeds" "0" "$code"
    assert_contains "blip: retried" "$out" "could not read the checks of PR #1; retrying"
    assert_contains "blip: passed after the retry" "$out" "checks  1 passed"
    assert_eq "blip: tag created" "v0.1.0" "$(git tag -l v0.1.0)"
    teardown_remote_repo
}

test_skip_checks() {
    echo ""
    echo "--skip-checks merges without reading the checks"
    setup_remote_repo
    printf 'fail\ttest\n' > "$GH_MOCK_STATE/checks.1"
    printf 'completed\tfailure\tCI\n' > "$GH_MOCK_STATE/runs.1"
    local out code=0
    out=$(NO_COLOR=1 "$STANZA" release patch -y --skip-checks 2>&1) || code=$?
    assert_eq "release succeeds" "0" "$code"
    assert_contains "skipped row" "$out" "checks  skipped (--skip-checks)"
    assert_contains "warns" "$out" "merging without waiting for CI (--skip-checks)"
    assert_eq "checks never read" "" "$(cat "$GH_MOCK_STATE/checks.calls" 2>/dev/null)"
    assert_eq "dev runs never read" "" "$(cat "$GH_MOCK_STATE/runs.calls" 2>/dev/null)"
    assert_eq "tag created" "v0.1.0" "$(git tag -l v0.1.0)"
    teardown_remote_repo

    setup_remote_repo
    printf 'fail\ttest\n' > "$GH_MOCK_STATE/checks.1"
    out=$(NO_COLOR=1 "$STANZA" --json release patch -y --skip-checks 2>/dev/null)
    assert_contains "JSON checks skipped" "$out" '"checks":"skipped"'
    teardown_remote_repo

    setup_remote_repo
    out=$(NO_COLOR=1 "$STANZA" release pre -y --skip-checks 2>&1)
    assert_contains "prerelease warns that it reads no checks" "$out" "--skip-checks is ignored by prerelease"
    teardown_remote_repo
}

test_red_dev_blocks_bump() {
    echo ""
    echo "A dev whose head failed CI is not bumped"
    local mode out code json
    for mode in pr no-pr; do
        setup_remote_repo
        printf 'completed\tsuccess\tlint\ncompleted\tfailure\ttests\n' > "$GH_MOCK_STATE/runs.1"
        local flags=(-y)
        [[ "$mode" == no-pr ]] && flags+=(--no-pr)
        code=0
        out=$(NO_COLOR=1 "$STANZA" release patch "${flags[@]}" 2>&1) || code=$?
        assert_eq "$mode: exits 1" "1" "$code"
        assert_contains "$mode: names the failed run" "$out" "CI failed on dev's head"
        assert_contains "$mode: lists only the failed workflow" "$out" "): tests; not bumping"
        assert_contains "$mode: names the override" "$out" "--skip-checks"
        assert_eq "$mode: version unchanged" "0.1.0a0" "$(cat VERSION)"
        assert_eq "$mode: no bump commit" "version [prerelease]: 0.1.0a0" "$(git log -1 --format=%s)"
        assert_eq "$mode: read dev's head" "$(git rev-parse dev)" "$(head -1 "$GH_MOCK_STATE/runs_commits")"
        teardown_remote_repo
    done

    setup_remote_repo
    printf 'completed\tfailure\ttests\n' > "$GH_MOCK_STATE/runs.1"
    code=0
    json=$(NO_COLOR=1 "$STANZA" --json release pr patch -y 2>/dev/null) || code=$?
    assert_eq "pr phase: exits 1" "1" "$code"
    assert_contains "pr phase: refusal is preflight" "$json" '"failed_step":"preflight"'
    teardown_remote_repo

    # Runs still in progress on dev are not waited on before the bump.
    setup_remote_repo
    printf 'in_progress\t\ttests\n' > "$GH_MOCK_STATE/runs.1"
    code=0
    NO_COLOR=1 "$STANZA" release pr patch -y >/dev/null 2>&1 || code=$?
    assert_eq "pending dev runs do not block the bump" "0" "$code"
    assert_eq "bumped" "0.1.0" "$(cat VERSION)"
    teardown_remote_repo
}

test_no_pr_waits_for_dev_runs() {
    echo ""
    echo "--no-pr waits for the runs on dev's head and stops on a failure"
    setup_remote_repo
    # Call 1 is the pre-bump read; calls 2+ read the release commit.
    printf 'completed\tsuccess\tCI\n' > "$GH_MOCK_STATE/runs.1"
    printf 'in_progress\t\tCI\n' > "$GH_MOCK_STATE/runs.2"
    printf 'completed\tsuccess\tCI\n' > "$GH_MOCK_STATE/runs.3"
    local out code=0 before
    out=$(NO_COLOR=1 "$STANZA" --json release patch -y --no-pr 2>/dev/null) || code=$?
    assert_eq "passing runs: exits 0" "0" "$code"
    assert_contains "JSON checks passed" "$out" '"checks":"passed"'
    assert_eq "gate read the release commit" "$(git rev-parse v0.1.0^2)" "$(tail -1 "$GH_MOCK_STATE/runs_commits")"
    assert_eq "tag created" "v0.1.0" "$(git tag -l v0.1.0)"
    teardown_remote_repo

    setup_remote_repo
    printf 'completed\tsuccess\tCI\n' > "$GH_MOCK_STATE/runs.1"
    printf 'completed\tfailure\tCI\n' > "$GH_MOCK_STATE/runs.2"
    before=$(git --git-dir="$TEST_TMPDIR/remote.git" rev-parse main)
    code=0
    out=$(NO_COLOR=1 "$STANZA" release patch -y --no-pr 2>&1) || code=$?
    assert_eq "failed run: exits 1" "1" "$code"
    assert_contains "names the failed run" "$out" "has failing checks: CI"
    assert_contains "checks row failed" "$out" "checks  failed; v0.1.0 is pushed to dev; nothing is merged or tagged"
    assert_contains "resume with merge --no-pr" "$out" "stanza release merge --no-pr -y"
    assert_eq "remote main unchanged" "$before" "$(git --git-dir="$TEST_TMPDIR/remote.git" rev-parse main)"
    assert_eq "local main unchanged" "$before" "$(git rev-parse main)"
    assert_eq "no tag" "" "$(git tag)"
    teardown_remote_repo

    # The merge phase reads the runs too.
    setup_remote_repo
    NO_COLOR=1 "$STANZA" release pr patch -y >/dev/null 2>&1
    rm -f "$GH_MOCK_STATE"/runs.*
    printf 'completed\tfailure\tCI\n' > "$GH_MOCK_STATE/runs.1"
    code=0
    NO_COLOR=1 "$STANZA" release merge -y --no-pr >/dev/null 2>&1 || code=$?
    assert_eq "merge --no-pr: failed run exits 1" "1" "$code"
    assert_eq "merge --no-pr: no tag" "" "$(git tag)"
    teardown_remote_repo
}

test_ci_edge_cases() {
    echo ""
    echo "Unfinished runs, unnamed checks, late checks, superseded and unreadable runs"
    local out code

    # An unfinished run's empty conclusion is a field, not a gap: the gate waits.
    setup_remote_repo
    printf 'completed\tsuccess\tCI\n' > "$GH_MOCK_STATE/runs.1"
    printf 'in_progress\t\tCI\n' > "$GH_MOCK_STATE/runs.2"
    printf 'completed\tsuccess\tCI\n' > "$GH_MOCK_STATE/runs.3"
    out=$(NO_COLOR=1 "$STANZA" release patch -y --no-pr 2>&1)
    assert_contains "--no-pr: waits on the in-progress run" "$out" "checks  waiting on CI"
    assert_eq "--no-pr: read until the run finished" "3" "$(cat "$GH_MOCK_STATE/runs.calls")"
    teardown_remote_repo

    # A pending check without a name still counts as pending.
    setup_remote_repo
    printf 'pending\t\n' > "$GH_MOCK_STATE/checks.1"
    printf 'pass\t\n' > "$GH_MOCK_STATE/checks.2"
    out=$(NO_COLOR=1 "$STANZA" release patch -y 2>&1)
    assert_contains "unnamed pending check is waited on" "$out" "checks  waiting on (unnamed)"
    assert_eq "unnamed: checks polled twice" "2" "$(cat "$GH_MOCK_STATE/checks.calls")"
    teardown_remote_repo

    # A check that registers within the grace period after a pass is not missed.
    setup_remote_repo
    printf 'pass\tlint\n' > "$GH_MOCK_STATE/checks.1"
    printf 'pass\tlint\nfail\ttest\n' > "$GH_MOCK_STATE/checks.2"
    code=0
    out=$(STANZA_CHECKS_GRACE_SECONDS=2 STANZA_CHECKS_INTERVAL=1 NO_COLOR=1 \
        "$STANZA" release patch -y 2>&1) || code=$?
    assert_eq "late failing check: exits 1" "1" "$code"
    assert_contains "late failing check: named" "$out" "PR #1 has failing checks: test"
    assert_eq "late failing check: no tag" "" "$(git tag)"
    teardown_remote_repo

    # Only the newest run of each workflow counts; gh lists runs newest first.
    setup_remote_repo
    printf 'completed\tsuccess\tCI\ncompleted\tfailure\tCI\n' > "$GH_MOCK_STATE/runs.1"
    code=0
    NO_COLOR=1 "$STANZA" release pr patch -y >/dev/null 2>&1 || code=$?
    assert_eq "superseded failed run does not block the bump" "0" "$code"
    assert_eq "superseded: bumped" "0.1.0" "$(cat VERSION)"
    teardown_remote_repo

    # Unreadable runs on dev warn before the bump; the PR's checks gate the merge.
    setup_remote_repo
    cat > "$TEST_TMPDIR/bin/gh-real" < "$TEST_TMPDIR/bin/gh"
    chmod +x "$TEST_TMPDIR/bin/gh-real"
    printf '#!/bin/bash\n[[ "$1 $2" == "run list" ]] && { echo "HTTP 403" >&2; exit 1; }\nexec "%s" "$@"\n' \
        "$TEST_TMPDIR/bin/gh-real" > "$TEST_TMPDIR/bin/gh"
    printf 'pass\ttest\n' > "$GH_MOCK_STATE/checks.1"
    code=0
    out=$(NO_COLOR=1 "$STANZA" release patch -y 2>&1) || code=$?
    assert_eq "unreadable dev runs: release succeeds" "0" "$code"
    assert_contains "unreadable dev runs: warns" "$out" "could not read the CI runs on dev"
    assert_eq "unreadable dev runs: tag created" "v0.1.0" "$(git tag -l v0.1.0)"
    teardown_remote_repo
}

test_no_pr_without_gh() {
    echo ""
    echo "--no-pr without gh releases and says the runs were not read"
    setup_remote_repo
    local bindir="$TEST_TMPDIR/nogh-bin" cmd code=0 out
    mkdir -p "$bindir"
    for cmd in bash git dirname head tr sed grep date awk mv cat wc mktemp rm sleep; do
        ln -s "$(command -v "$cmd")" "$bindir/$cmd"
    done
    out=$(PATH="$bindir" NO_COLOR=1 "$STANZA" release patch --no-pr -y 2>&1) || code=$?
    assert_eq "exits 0" "0" "$code"
    assert_contains "not-read row" "$out" "checks  not read (gh is not installed or not authenticated)"
    assert_eq "tag created" "v0.1.0" "$(git tag -l v0.1.0)"
    teardown_remote_repo
}

# --- Preflight (plan 004) --------------------------------------------------

# Record the refs a refused release must leave alone; preflight_unchanged
# asserts they did not move.
preflight_snapshot() {
    SNAP_DEV=$(git rev-parse dev)
    SNAP_MAIN=$(git rev-parse main)
    SNAP_ORIGIN_DEV=$(git --git-dir="$TEST_TMPDIR/remote.git" rev-parse dev)
    SNAP_ORIGIN_MAIN=$(git --git-dir="$TEST_TMPDIR/remote.git" rev-parse main 2>/dev/null || true)
}

preflight_unchanged() {
    local label="$1"
    assert_eq "$label: dev unchanged" "$SNAP_DEV" "$(git rev-parse dev)"
    assert_eq "$label: main unchanged" "$SNAP_MAIN" "$(git rev-parse main)"
    assert_eq "$label: origin/dev unchanged" "$SNAP_ORIGIN_DEV" \
        "$(git --git-dir="$TEST_TMPDIR/remote.git" rev-parse dev)"
    assert_eq "$label: origin/main unchanged" "$SNAP_ORIGIN_MAIN" \
        "$(git --git-dir="$TEST_TMPDIR/remote.git" rev-parse main 2>/dev/null || true)"
    assert_eq "$label: no PR opened" "" "$(cat "$GH_MOCK_STATE/number" 2>/dev/null)"
}

test_version_order() {
    echo ""
    echo "version_lt orders semver, alpha, and LaTeX versions"
    eval "$(extract_function version_lt "$STANZA_DIR/lib/stanza-release")"
    local pair
    for pair in "0.1.0a0 0.1.0" "0.1.0 0.1.1a0" "0.1.0a1 0.1.0a2" "0.9.9 0.10.0" \
        "1.2 1.10" "1 1.0.1" "0.1.0a9 0.1.0a10"; do
        assert_eq "${pair% *} < ${pair#* }" "yes" \
            "$(version_lt ${pair% *} ${pair#* } && echo yes || echo no)"
        assert_eq "not ${pair#* } < ${pair% *}" "no" \
            "$(version_lt ${pair#* } ${pair% *} && echo yes || echo no)"
    done
    assert_eq "equal versions are not lower" "no" "$(version_lt 1.0.0 1.0 && echo yes || echo no)"
}

test_preflight_existing_tag() {
    echo ""
    echo "A release whose tag exists is refused before anything changes"
    local where phase out code
    for where in local remote; do
        for phase in full pr; do
            setup_remote_repo
            git tag v0.1.0 main
            if [[ "$where" == remote ]]; then
                git push -q origin v0.1.0
                git tag -d v0.1.0 >/dev/null
            fi
            preflight_snapshot
            local args=(release patch -y)
            [[ "$phase" == pr ]] && args=(release pr patch -y)
            code=0
            out=$(NO_COLOR=1 "$STANZA" "${args[@]}" 2>&1) || code=$?
            assert_eq "$where tag, $phase: exits 1" "1" "$code"
            if [[ "$where" == local ]]; then
                assert_contains "$where tag, $phase: names the tag" "$out" "tag v0.1.0 already exists in this clone"
            else
                assert_contains "$where tag, $phase: names the tag" "$out" "tag v0.1.0 already exists on origin"
            fi
            assert_eq "$where tag, $phase: version unchanged" "0.1.0a0" "$(cat VERSION)"
            preflight_unchanged "$where tag, $phase"
            teardown_remote_repo
        done
    done
}

test_preflight_gh_auth() {
    echo ""
    echo "A gh that is not logged in is refused before the bump commit"
    setup_remote_repo
    touch "$GH_MOCK_STATE/auth_fail"
    preflight_snapshot
    local out code=0
    out=$(NO_COLOR=1 "$STANZA" release patch -y 2>&1) || code=$?
    assert_eq "exits 1" "1" "$code"
    assert_contains "says gh is not authenticated" "$out" "GitHub CLI is not authenticated"
    assert_contains "hints the login" "$out" "gh auth login"
    assert_eq "version unchanged" "0.1.0a0" "$(cat VERSION)"
    preflight_unchanged "gh auth"
    teardown_remote_repo

    # --no-pr makes no gh calls, so it does not need the login.
    setup_remote_repo
    touch "$GH_MOCK_STATE/auth_fail"
    code=0
    NO_COLOR=1 "$STANZA" release patch -y --no-pr >/dev/null 2>&1 || code=$?
    assert_eq "--no-pr releases without the login" "0" "$code"
    assert_eq "--no-pr tagged" "v0.1.0" "$(git tag -l v0.1.0)"
    teardown_remote_repo
}

test_preflight_reports_all() {
    echo ""
    echo "Several failed checks are reported in one run"
    setup_remote_repo
    echo notes > NOTES
    git add NOTES
    git commit -q -m "add notes"
    git push -q origin dev
    echo changed >> NOTES
    git tag v0.1.0 main
    touch "$GH_MOCK_STATE/auth_fail"
    preflight_snapshot

    local out json code=0
    out=$(NO_COLOR=1 "$STANZA" release patch -y 2>&1) || code=$?
    assert_eq "exits 1" "1" "$code"
    assert_contains "reports the dirty tree" "$out" "Uncommitted changes"
    assert_contains "shows the changed file" "$out" "M NOTES"
    assert_contains "reports gh" "$out" "GitHub CLI is not authenticated"
    assert_contains "reports the tag" "$out" "tag v0.1.0 already exists"
    preflight_unchanged "all at once"

    code=0
    json=$(NO_COLOR=1 "$STANZA" --json release patch -y 2>/dev/null) || code=$?
    assert_eq "--json: exits 1" "1" "$code"
    assert_contains "--json: failed in preflight" "$json" '"failed_step":"preflight"'
    assert_contains "--json: error is the first failure" "$json" '"error":"Uncommitted changes, commit or stash them first."'
    assert_contains "--json: lists the gh failure" "$json" '{"error":"GitHub CLI is not authenticated","hint":"authenticate: gh auth login\nor release without GitHub: stanza release patch --local"}'
    if command -v jq >/dev/null 2>&1; then
        assert_eq "--json: errors lists all three" "3" "$(printf '%s' "$json" | jq '.errors | length')"
        assert_eq "--json: stdout is one JSON document" "1" "$(printf '%s' "$json" | jq -s 'length')"
    fi
    teardown_remote_repo
}

test_preflight_version_order() {
    echo ""
    echo "A release below the latest version tag is refused"
    local out code
    setup_repo
    git tag v0.2.0 main
    code=0
    out=$(NO_COLOR=1 "$STANZA" release patch -y --local 2>&1) || code=$?
    assert_eq "patch below the latest tag exits 1" "1" "$code"
    assert_contains "names both versions" "$out" "v0.1.0 is lower than the latest tag v0.2.0"
    assert_eq "version unchanged" "0.1.0a0" "$(uv version --short)"
    code=0
    NO_COLOR=1 "$STANZA" release major -y --local >/dev/null 2>&1 || code=$?
    assert_eq "a bump past it releases" "0" "$code"
    assert_eq "tagged above the latest" "v1.0.0" "$(git tag -l v1.0.0)"
    cleanup

    # Only origin has the higher tag.
    setup_remote_repo
    git tag v0.2.0 main
    git push -q origin v0.2.0
    git tag -d v0.2.0 >/dev/null
    preflight_snapshot
    code=0
    out=$(NO_COLOR=1 "$STANZA" release patch -y 2>&1) || code=$?
    assert_eq "below a tag only origin has: exits 1" "1" "$code"
    assert_contains "below a tag only origin has: named" "$out" "v0.1.0 is lower than the latest tag v0.2.0"
    preflight_unchanged "origin-only tag"
    teardown_remote_repo

    # A prerelease that would sort below the last release.
    setup_repo
    git tag v0.1.0
    code=0
    out=$(NO_COLOR=1 "$STANZA" release prerelease -y --local 2>&1) || code=$?
    assert_eq "prerelease below the release exits 1" "1" "$code"
    assert_contains "prerelease below the release named" "$out" "v0.1.0a1 is lower than the latest tag v0.1.0"
    assert_eq "prerelease not bumped" "0.1.0a0" "$(uv version --short)"
    cleanup
}

test_preflight_base_missing() {
    echo ""
    echo "A release into a base branch origin lacks is refused"
    setup_remote_repo
    git --git-dir="$TEST_TMPDIR/remote.git" config receive.denyDeleteCurrent ignore
    git push -q origin :main 2>/dev/null
    preflight_snapshot
    local out code=0
    out=$(NO_COLOR=1 "$STANZA" release patch -y --no-pr 2>&1) || code=$?
    assert_eq "exits 1" "1" "$code"
    assert_contains "names the missing branch" "$out" "origin has no main branch"
    preflight_unchanged "no base on origin"
    teardown_remote_repo
}

# Review follow-ups: checks that depend on the branch, and the tags they read.
test_preflight_review_followups() {
    echo ""
    echo "Preflight skips dev's checks off dev, and reads tags of the project's form"
    local out code

    # No local dev: the branch failure is reported, not a raw git error.
    setup_remote_repo
    git checkout -q main
    git branch -q -D dev
    code=0
    out=$(NO_COLOR=1 "$STANZA" release patch -y 2>&1) || code=$?
    assert_eq "no local dev: exits 1" "1" "$code"
    assert_contains "no local dev: reports the branch" "$out" "should be performed on dev"
    assert_not_contains "no local dev: no raw git error" "$out" "fatal:"
    teardown_remote_repo

    # Off dev, a red dev is not read or reported.
    setup_remote_repo
    printf 'completed\tfailure\ttests\n' > "$GH_MOCK_STATE/runs.1"
    git checkout -q -b feature
    code=0
    out=$(NO_COLOR=1 "$STANZA" release patch -y 2>&1) || code=$?
    assert_eq "off dev: exits 1" "1" "$code"
    assert_not_contains "off dev: dev's CI not reported" "$out" "CI failed on dev"
    assert_eq "off dev: dev's CI not read" "" "$(cat "$GH_MOCK_STATE/runs_commits" 2>/dev/null)"
    teardown_remote_repo

    # A floating major tag does not count as a semver release.
    setup_remote_repo
    git tag v1 main
    git push -q origin v1
    code=0
    out=$(NO_COLOR=1 "$STANZA" release patch --check 2>&1) || code=$?
    assert_eq "floating v1 tag: check passes" "0" "$code"
    assert_contains "floating v1 tag: target unchanged" "$out" "would release 0.1.0a0 -> v0.1.0"
    teardown_remote_repo

    # A prerelease is ordered against origin's tags too.
    setup_remote_repo
    git tag v0.1.0 main
    git push -q origin v0.1.0
    git tag -d v0.1.0 >/dev/null
    preflight_snapshot
    code=0
    out=$(NO_COLOR=1 "$STANZA" release prerelease -y 2>&1) || code=$?
    assert_eq "prerelease below an origin-only tag: exits 1" "1" "$code"
    assert_contains "prerelease below an origin-only tag: named" "$out" "v0.1.0a1 is lower than the latest tag v0.1.0"
    preflight_unchanged "prerelease, origin-only tag"
    teardown_remote_repo

    # merge --check reports a resume without fetching the tag it lacks.
    setup_remote_repo
    NO_COLOR=1 "$STANZA" release patch -y --no-dev-cycle >/dev/null 2>&1
    git checkout -q dev
    git tag -d v0.1.0 >/dev/null
    code=0
    out=$(NO_COLOR=1 "$STANZA" release merge --check 2>&1) || code=$?
    assert_eq "merge --check resume: exits 0" "0" "$code"
    assert_contains "merge --check resume: says so" "$out" "would resume v0.1.0"
    assert_eq "merge --check resume: tag not fetched" "" "$(git tag -l v0.1.0)"
    teardown_remote_repo
}

test_release_check() {
    echo ""
    echo "--check runs preflight only"
    setup_remote_repo
    preflight_snapshot
    local out json code=0
    out=$(NO_COLOR=1 "$STANZA" release patch --check 2>&1) || code=$?
    assert_eq "passing check exits 0" "0" "$code"
    assert_contains "says what would happen" "$out" "check   passed; would release 0.1.0a0 -> v0.1.0"
    assert_contains "says nothing changed" "$out" "preflight passed; nothing changed"
    assert_eq "version unchanged" "0.1.0a0" "$(cat VERSION)"
    assert_eq "no tag" "" "$(git tag -l)"
    preflight_unchanged "--check"

    json=$(NO_COLOR=1 "$STANZA" --json release patch --check 2>/dev/null)
    assert_contains "--json: ok and check" "$json" '"ok":true,"check":true'
    assert_contains "--json: target" "$json" '"to_version":"0.1.0","tag":"v0.1.0"'

    git tag v0.1.0 main
    code=0
    out=$(NO_COLOR=1 "$STANZA" release patch --check 2>&1) || code=$?
    assert_eq "failing check exits 1" "1" "$code"
    assert_contains "failing check names the failure" "$out" "tag v0.1.0 already exists"
    git tag -d v0.1.0 >/dev/null

    # merge --check finds the PR the pr phase opened and leaves it open.
    NO_COLOR=1 "$STANZA" release pr patch -y >/dev/null 2>&1
    code=0
    out=$(NO_COLOR=1 "$STANZA" release merge --check 2>&1) || code=$?
    assert_eq "merge check exits 0" "0" "$code"
    assert_contains "merge check names the PR" "$out" "would merge and tag v0.1.0 from PR #1"
    assert_eq "PR still open" "open" "$(cat "$GH_MOCK_STATE/state")"
    assert_eq "still untagged" "" "$(git tag -l)"
    teardown_remote_repo
}

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
test_no_pr_full_release
test_no_pr_merge_phase
test_no_pr_protected_base_pushes_nothing
test_no_pr_ignored_flags_warn
test_no_pr_merge_phase_protected_skips_pr_create
test_no_pr_diverged_base_refused
test_no_pr_ignored_by_prerelease
test_pr_path_push_failure_hints_dev_cycle
test_failed_step_is_named
test_failed_step_json_fields
test_cycle_push_failure_resumes
test_resume_tag_fetch_failure_stops
test_subshell_error_reaches_json
test_prerelease_push_failure_warns
test_stalled_fetch_stops_cycle
test_local_cycle_resume
test_local_release_finished_remotely
test_checks_pass_then_merge
test_checks_fail_stops_merge
test_checks_none_reported
test_checks_timeout
test_checks_read_error_stops_merge
test_skip_checks
test_red_dev_blocks_bump
test_no_pr_waits_for_dev_runs
test_ci_edge_cases
test_no_pr_without_gh
test_version_order
test_preflight_existing_tag
test_preflight_gh_auth
test_preflight_reports_all
test_preflight_version_order
test_preflight_base_missing
test_preflight_review_followups
test_release_check

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
