---
id: 7
slug: resume-earlier-release-steps
status: active
branch: feature/resume-earlier-release-steps
created: 2026-10-09T23:02:03-07:00
concluded:
pr: https://github.com/gitronald/stanza/pull/18
---

# Resume a release that stopped before its tag

## Plan

### Problem

Plan 003 made `stanza release merge` resume a release that is already merged
and tagged: it pushes a tag only the local clone has, then runs the dev cycle.
A release that stops earlier still needs commands typed by hand, which the
failure row prints as hints. Three cases are left, inherited from plan 003's
Handoff (questions 1 and 2) and its review:

1. **Merge step, PR merged, no tag.** `gh pr merge` succeeded and a later call
   in the step failed (the checkout or pull of the base branch). The hint tags
   by hand: `git checkout main && git pull origin main && git tag vX && git
   checkout dev && stanza release merge`. An automatic resume would find the
   PR's merge commit on the base branch (the merge whose second parent is
   dev's head at the release bump) and tag it.
2. **Push or PR step.** `dev` carries the stable bump and no PR is open. The
   hints give `git push origin dev && gh pr create ...`. `stanza release pr`
   could detect that state (dev on a stable version, no tag, no open PR) and
   finish the push and PR instead of bumping again.
3. **A `--local` release finished later against the remote.** After
   `stanza release patch --local`, a remote `release merge` finds the
   local-only tag, then `git fetch origin main:main` is refused as
   non-fast-forward, because local `main` carries the release merge that origin
   lacks. The resume hint repeats the same failing command. Resuming would push
   the base branch and the tag together (`git push --atomic`), or the error
   should say that the base branch has to be pushed first.

### Approach

For each case, decide first whether automatic resume is worth the detection
logic, or whether a sharper hint is enough. Case 1 is the riskiest to automate:
tagging the wrong commit ships the wrong release, so detection must check that
the candidate commit's tree matches dev at the bump. Case 3 may only need its
error and hint fixed.

### Tests

In `tests/test-release-workflow.sh`, with the gh mock and bare remote: a merge
step that fails after `gh pr merge` succeeds; a push refused at the push step,
then `release pr` re-run; a `--local --no-dev-cycle` release, then a remote
`release merge`.

### Order

3 (the hint, at least) -> 1 -> 2.

### Out of scope

- The preflight checks before the first mutation (plan 004).

## Log

- **2026-10-11T00:23:52-07:00** — Activated.
  - Branch: `feature/resume-earlier-release-steps`
  - Base: `dev` at `7966f2c`
  - Worktree: `.worktrees/resume-earlier-release-steps`
  - PR: pending
- **2026-10-11T00:36:56-07:00** — PR opened: https://github.com/gitronald/stanza/pull/18
- **2026-10-11T00:39:38-07:00** — Implemented all three cases, in the planned
  order, each automated rather than left as a hint. Tests at `e4e06d1`: all
  nine `tests/test-*.sh` files pass (release workflow 514 -> 594 checks).
  - Case 3 (`8b82c84`): `resume_shipped_release` fetches the base branch
    into `origin/<base>` and compares, instead of `fetch <base>:<base>`.
    Behind or level: fast-forward. Ahead with the tag at its head: one
    `git push --atomic` of the base branch and the tag. Diverged, or commits
    after the tag: refuse before pushing anything. `find_shipped_release`
    now checks origin for the tag on its prerelease path too, so a `--local`
    release that ran its dev cycle is also pushed. The new test fails on the
    old code (checked by pointing it at the main checkout's `bin/stanza`).
  - Case 1 (`68243b7`): `find_merged_release` runs in the merge preflight
    once no tag is found. When dev's head is on `origin/<base>`, it takes the
    earliest merge commit on the ancestry path whose second parent is dev's
    head, and requires its tree to equal dev's. A fast-forward (no merge
    commit) or a tree mismatch is refused with a tag-by-hand hint.
    `git_tag_version` takes an optional commit. The merge-step advice for a
    merged PR is now `git checkout dev && stanza release merge`.
  - Case 2 (`e0eec5a`): `find_unfinished_bump` matches dev's last commit
    `version [patch|minor|major]: <version on dev>` with no tag locally or on
    origin. The full and `pr` phases then skip the bump, the changelog check,
    and the red-dev check, allow dev ahead of origin, push if needed, and
    take an open PR whose title is the tag. A different bump type, a
    differently titled open PR, or a bump already merged into origin's base
    branch is refused. The push/pr advice is now the same command again.
  - Decisions: case 1 does not require the `version [release]` subject (a PR
    merged by hand in the web UI still resumes); the second parent and the
    tree are the proof. The case 3 push runs without `--no-pr`, because a
    `--local` release has no PR to go through, and a protected base branch
    refuses the atomic push with nothing pushed.
  - Side changes: the resume and re-run advice carries `--no-dev-cycle`
    (it used to drop it). The full and `pr` JSON documents gain `resumed`,
    and `from_version` is `null` on a resumed bump. `release --check`
    reports `resumed` for full and `pr` too.
  - Cost: every remote `release merge` preflight now does one extra
    `git fetch origin <base>` (to look for a merge that has no tag).
  - Docs (`e4e06d1`): help text, README, guide, CHANGELOG `[Unreleased]`.

## Handoff

State: implemented on `feature/resume-earlier-release-steps`, PR #18. All
committed and pushed.

Questions: none open.

Not verified:

- A run against real GitHub. The gh mock merges locally; real `gh pr merge`
  leaves the local base branch behind, which the case 1 test simulates by
  resetting it.
- bash 3.2 (plan 005) and ShellCheck (not installed here).
