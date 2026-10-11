---
id: 7
slug: resume-earlier-release-steps
status: active
branch: feature/resume-earlier-release-steps
created: 2026-10-09T23:02:03-07:00
concluded:
pr:
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
