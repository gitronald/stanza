---
id: 4
slug: release-preflight
status: draft
branch:
created: 2026-10-09T18:49:08-07:00
concluded:
pr:
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
