---
id: 11
slug: release-waits-for-checks
status: active
branch: feature/release-waits-for-checks
created: 2026-10-10T20:04:32-07:00
concluded:
pr: https://github.com/gitronald/stanza/pull/15
---

# Wait for green checks before merging a release

## Plan

### Problem

`stanza release` opens the release PR and merges it in the same run without
looking at its checks. `gh_merge_pr` (`lib/stanza-release`) verifies that the
PR is open, targets the base branch, and that its head matches `dev`, then
calls `gh pr merge` at once. On a repository whose plan offers no branch
protection (private repositories on GitHub's free plan return HTTP 403 for
it), nothing else stops the merge.

Observed: a downstream repo's release PR was merged while its test check was
still pending. The check then failed on the base branch, and the release tag
pointed at a commit with a failing test. The same failure had already shown on
`dev`'s CI for that commit, which stanza did not consult either.

### Change

1. **Wait for the release PR's checks before merging.** In `gh_merge_pr`,
   after the head check and before `confirm_step`, run
   `gh pr checks "$RELEASE_PR_NUMBER" --watch --fail-fast` (quiet, with a
   `checks` row naming the result). Any failed or cancelled check stops the
   release with `print_error` and a resume hint
   (`fix on dev, then: stanza release pr <type>`); nothing is merged or
   tagged. A full release and the `merge` phase both go through this, so a
   PR opened earlier with `release pr` is checked when it is merged.
2. **No checks is not a failure.** A repository with no workflows makes
   `gh pr checks` report that no checks exist; treat that as a pass and say
   so in the row (`checks  none reported`). Allow a few seconds for checks to
   register after the PR opens before concluding there are none (poll, as
   the merge step already must for mergeability).
3. **The no-PR path checks `dev`'s tip.** For `--no-pr` (remote mode
   without a PR), look up the latest workflow runs for `dev`'s head commit
   (`gh run list --commit <sha>`) and refuse when any concluded as a
   failure; wait on runs still in progress. Local mode (`--local`, no
   remote) has no CI to read and is unchanged.
4. **Fail before the bump when `dev` is already red.** Before
   `create_version_bump_on_dev`, read the latest runs on `dev`'s head the
   same way and stop on a failure, so a known-red `dev` does not get a
   version bump commit pushed onto it.
5. **Bound the wait.** `STANZA_CHECKS_TIMEOUT` (seconds, default 1800; 0
   means no limit), in the spirit of `STANZA_NET_STALL_SECONDS`. A timeout
   stops the release with the resume command, leaving the PR open.
6. **An explicit override.** `--skip-checks` merges without waiting, for a
   repo whose checks are known broken for unrelated reasons; the run prints a
   warning row saying the checks were skipped. Never the default.

### Tests

- `tests/test-release-workflow.sh`: with a stubbed `gh`, cover checks
  passing, failing (no merge, no tag, resume hint printed), pending then
  passing, none reported, timeout, and `--skip-checks`; the `--no-pr` path
  with a failed and a passing run on `dev`'s head; the pre-bump refusal on a
  red `dev`.
- `--json` output carries the checks result.

### Docs

- `stanza release --help` and `lib/stanza-guide.md`: the merge waits for
  checks, the timeout variable, and `--skip-checks`.
- `lib/stanza-rules.md` (the generated rule): one line saying the release
  merge waits for the PR's checks, so sessions do not pre-poll them.
- CHANGELOG `[Unreleased]`.

### Done when

- A release whose PR has a failing check stops before the merge, with no tag
  and the PR left open, and says how to resume.
- A release on a repo with no CI still completes.
- The tests above pass.

### Out of scope

- Configuring branch protection or rulesets on GitHub.
- Running a repository's own test suite locally from stanza.

## Log

- **2026-10-10T20:14:48-07:00** — Activated.
  - Branch: `feature/release-waits-for-checks`
  - Base: `dev` at `df3ccb5`
  - Worktree: `.worktrees/release-waits-for-checks`
  - PR: pending
- **2026-10-10T20:25:17-07:00** — PR opened: https://github.com/gitronald/stanza/pull/15
