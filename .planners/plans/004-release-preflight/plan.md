---
id: 4
slug: release-preflight
status: done
branch: feature/release-preflight
created: 2026-10-09T18:49:08-07:00
concluded: 2026-10-11T00:10:48-07:00
pr: https://github.com/gitronald/stanza/pull/17
---

# Check release preconditions before the first mutation

## Plan

### Problem

`stanza release` checks some preconditions up front (clean tree, on `dev`,
`dev` level with origin) but finds others only after it has changed
something. The clearest case is the tag: `git_tag_version` refuses an
existing tag, but it runs after the release merge, so a tag collision leaves
the base branch merged and nothing tagged. A missing `gh` login has the same
shape for the PR path: the bump is committed and pushed before `gh pr create`
fails.

The review on `feature/review-simplify` fixed the three cases where a release
could ship the wrong thing (merge from a non-`dev` branch, a failed PR head
lookup treated as a match, a tag taken from an unvalidated PR title). This plan
covers the remaining "fails halfway" cases. Telling the user how to resume
after a mid-run failure is plan 003's scope, not this one.

### Changes

1. **One `release_preflight` function**, called before the first commit,
   push, merge, or tag in every phase (`full`, `pr`, `merge`, `prerelease`).
   It gathers the existing scattered checks (`check_uncommitted_changes`,
   `require_branch dev`, `check_branch_up_to_date`) in one place, so each
   phase states what it requires instead of repeating the calls.
2. **Compute the target version and tag first.** Derive the new version
   with a dry-run of the bump (a pure function over the current version
   string, which `bump_version_string` already is) and check:
   - the version string is valid for the project type;
   - the tag is free locally (`git tag -l`) and, in remote mode, on origin
     (`git ls-remote --tags origin refs/tags/<tag>`);
   - the target is not lower than the latest existing tag.
3. **Remote-mode checks:** `gh auth status` succeeds for the PR path; the
   base branch exists on origin; for `merge`, the PR is open, targets the
   base branch, and its head equals local `dev` (the head and state parts
   already exist in `gh_merge_pr` after the review fixes; move them here).
4. **Report all failures at once.** Collect every failed check and print them
   together with their hints before exiting 1, so a user does not fix them
   one run at a time. In `--json` mode emit
   `{"ok":false,"phase":"preflight","errors":[...]}`.
5. **`--check` flag (optional, decide during implementation):** run preflight
   only and exit 0/1, for CI or a pre-release sanity check.

### Tests

In `tests/test-release-workflow.sh`, with the existing gh mock and bare remote:
existing tag (local, and remote-only) refused before any commit is made
(assert `git log` and `git rev-parse main` unchanged); gh auth failure refused
before the bump commit; several failures reported in one run.

### Order

1 -> 2 -> 3 -> 4 -> 5. Land after plan 003, or coordinate: both touch the
step boundaries in `lib/stanza-release`.

## Log

- **2026-10-10T23:30:34-07:00** — Activated.
  - Branch: `feature/release-preflight`
  - Base: `dev` at `66df759`
  - Worktree: `.worktrees/release-preflight`
  - PR: pending
- **2026-10-10T23:45:06-07:00** — PR opened: https://github.com/gitronald/stanza/pull/17
- **2026-10-10T23:45:25-07:00** — Implemented (commits `4a38288`, `b5295c0`).
  - **Changes 1-4.** `release_preflight` in `lib/stanza-release` runs before
    the first commit, push, merge, or tag of every phase. It records each
    failure with `preflight_fail` (error, hints, command output) and
    `preflight_report` prints them all, then exits 1. Checks whose input an
    earlier failure leaves unknown are skipped: off `dev`, the version and
    everything derived from it (tag, resume, PR title); without gh auth, the
    PR and the pre-bump CI read.
  - **Change 2.** The target comes from `bump_version_string` /
    `bump_latex_version_string` (pure). The tag is checked in this clone and
    on origin, and ordered against the latest `v<version>` tag from both, by a
    new `version_lt` (alpha below its release, missing LaTeX components as 0).
    One `ls-remote origin refs/heads/<base> 'refs/tags/v*'` call reads both
    the base branch (change 3) and the remote tags.
  - **Change 3.** The merge-phase PR guards (count, open, base, head, title)
    moved from `gh_merge_pr` and the merge case into `preflight_merge_pr`.
    `gh_merge_pr` now merges with `--match-head-commit` set to local `dev`'s
    head rather than the PR head it read, so the full flow keeps the race
    guard without a second lookup.
  - **Change 4, deviation.** The plan's JSON shape
    (`{"ok":false,"phase":"preflight","errors":[...]}`) predates plan 003's
    failure document, where `phase` is the release phase and the stopped
    step is `failed_step`. The preflight failure keeps that document
    (`failed_step: "preflight"`, `error`/`hint` from the first failure) and
    adds `errors: [{error, hint}]`.
  - **Change 5, decided: built.** `--check` runs the preflight only and exits
    0/1; the success row and JSON (`"check":true`, `to_version`, `tag`, and
    for merge `resumed`, `pr`) say what the run would do.
  - **Merge resume.** `find_shipped_release` runs inside preflight; its exits
    (unreadable or conflicting remote tag, failed tag fetch) became recorded
    failures. A resumed merge skips the tag and PR checks.
  - **Stale premise.** The `gh auth` check already ran before the bump
    commit; it moved into preflight unchanged in effect.
  - **Prerelease ordering (addition).** A prerelease that would sort below the
    latest tag (dev on `0.1.0a3` after `v0.1.0`) is refused; the plan's
    ordering check did not exclude prereleases.
  - **Removed.** `require_branch`, `check_not_protected_branch`, and
    `check_branch_up_to_date` in `lib/stanza-common` had no callers left;
    `check_changelog_before_release` folded into preflight.
  - **Tests.** `test-release-workflow.sh`: existing tag (local and
    origin-only, full and pr) refused with dev, main, and origin refs
    unchanged and no PR opened; gh auth failure refused before the bump;
    three failures in one run (human and `errors` length 3); below-latest
    (local, origin-only, prerelease); missing base on origin; `--check` pass
    and fail, and `merge --check` leaving the PR open; `version_lt` cases.
    The direct `gh_merge_pr` call with no `dev` became a `release merge`
    run. All suites pass: release-workflow 481, install 116, latex 38,
    network 34, output-modes 50, release-asset 27, rules 115, version-bumps
    16, version-file-detection 101.
  - **Not verified.** bash 3.2 (no local bash 3.2; plan 005's CI job would
    cover it). shellcheck is not installed here, so it was not run.
  - **Not covered (follow-up candidate).** Under `--no-pr`, a local base
    branch that cannot fast-forward to `origin/<base>` still fails at the
    merge step, after the bump is pushed. Catching it in preflight needs a
    fetch of the base branch.
- **2026-10-10T23:45:38-07:00** — Implemented: 5 commits ahead of `dev`.
- **2026-10-11T00:11:06-07:00** — Review follow-up (commits `847e4e6`, `aff6515`).
  - **Raised.** `/code-review` at medium on PR #17: 9 findings, 6 confirmed
    and 3 plausible; posted to the PR.
  - **Fixed, each with a test in `test_preflight_review_followups`** (the
    new tests fail on the pre-fix code, 12 assertions):
    - A clone with no local `dev` crashed preflight: `check_dev_ci_before_bump`
      ran `git rev-parse dev` after the branch check had failed, and set -e
      exited with git's error before the report. The dev-CI read now also
      waits on the branch check, so off `dev` it is neither read nor reported.
    - `latest_version_tag` counted LaTeX-shaped tags in a semver project, so a
      floating `v1` (common in GitHub Actions repos) refused every release. It
      now takes the project type and counts only tags of that form.
    - Prereleases ordered against this clone's tags only. They now read
      origin's tags too; the missing-base check stays for releases that merge.
    - `release merge --check` fetched an origin-only tag into the clone. Under
      `--check` the fetch is left to the real run.
  - **Also fixed.** The README function reference listed the three removed
    helpers. The dirty-tree check now shares `has_uncommitted_changes` with
    `check_uncommitted_changes`, and the local tag check reads the `git tag -l`
    list it already had.
  - **Conscious no-op.** A non-resumed `release merge` reads origin twice
    (`find_shipped_release` for its tag, then the base branch and `v*` tags).
    The first read decides the resume before anything else runs; folding them
    together would couple `find_shipped_release` to preflight's remote read
    for one round trip.
  - **Checks.** All suites pass: release-workflow 499, install 116, latex 38,
    network 34, output-modes 50, release-asset 27, rules 115, version-bumps
    16, version-file-detection 101. bash 3.2 and shellcheck still not run.

## Retrospective

- Collecting failures instead of exiting changed the failure model under
  every check: a helper that used to run only after the branch check passed
  now ran after it failed. Two of the review's confirmed bugs were that
  pattern. Next time a guard turns from exit into record-and-continue, list
  every later check's inputs and gate each on the checks that produce them.
- "Report every failure at once" and "skip what an earlier failure leaves
  unknown" pull against each other; the `on_branch` / `gh_ok` flags were the
  right shape, but they were applied by hand per check and one was missed.
- The ordering check was new behavior, not a move of old code, and that is
  where the false refusal (`v1` tags) came from. New refusals deserve a probe
  against real-world tag sets, not only the repo's own conventions.
- `--check` needed its own definition of "changes nothing". A fetch that
  creates a ref counts; a fetch that refreshes remote-tracking refs does not.
- Follow-up still open from the implementation log: under `--no-pr`, a base
  branch that cannot fast-forward to origin fails after the bump is pushed.
