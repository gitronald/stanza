---
id: 3
slug: harden-release-network-steps
status: implemented
branch: feature/harden-release-network-steps
created: 2026-10-09T17:17:19-07:00
concluded:
pr: https://github.com/gitronald/stanza/pull/8
---

# Time out stalled git calls and name the failed release step

## Plan

### Problem

A `stanza release merge -y` run merged the release PR, pushed the tag, and then
stopped partway into step 3, the post-release dev cycle. The output showed the
`merge` and `tag` rows and nothing else: no `cycle` row, no error, and no hint.
`dev` was left without the merge-back from the base branch and without the
prerelease bump, and the person running it learned that only by inspecting the
branch.

Two things combined:

1. **A stalled network call never times out.** `create_new_prerelease_cycle`
   runs `git_quiet pull origin dev`. That fetch sat on a stalled HTTPS
   connection for several minutes. Neither stanza nor git bounds it: git aborts
   a slow HTTP transfer only when `http.lowSpeedLimit` and `http.lowSpeedTime`
   are set (or `GIT_HTTP_LOW_SPEED_LIMIT`/`_TIME`), and both are unset by
   default. Without them, a dead connection can wait until TCP keepalive drops
   it, if ever.
2. **A failed step aborts silently.** `lib/stanza-release` runs under `set -e`,
   and `git_quiet`/`gh_quiet` send all output to `/dev/null` unless `--verbose`.
   When a call fails, `set -e` ends the run with the call's exit status, but
   the error git or gh printed has already been discarded, and stanza prints no
   row of its own. A wrapper that pipes the output (`stanza ... | tail`) also
   loses the exit status, so the failure can read as success.

### Changes

1. **Bound every network git call.** Route the calls that touch a remote
   (`fetch`, `pull`, `push`, `ls-remote`) through one helper, e.g.
   `git_net`, that adds `-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30`
   (the values overridable by env, e.g. `STANZA_NET_STALL_SECONDS`). A user's
   own `http.lowSpeed*` config, when set, wins over the default. This covers
   HTTPS remotes; for SSH remotes, set `-c core.sshCommand` only if the user
   has none, adding `-o ServerAliveInterval=15 -o ServerAliveCountMax=2`, or
   document that SSH is out of scope.
2. **Keep the error a failed call printed.** Capture stderr in `git_quiet` and
   `gh_quiet` (to a temp file or variable) instead of discarding it, and print
   it through `print_error` when the call fails. Successful calls stay quiet.
3. **Name the step that failed, and how to resume.** Add an `ERR` trap (or an
   explicit check around each step) that prints which release step stopped
   (`bump`, `push`, `pr`, `merge`, `tag`, `cycle`) and the resume command for
   that point. For the dev cycle, the resume is: check out `dev`, pull it,
   merge the base branch with `--no-ff`, push, and run `stanza release
   prerelease -y`. Exit non-zero.
4. **Make a re-run of `release merge` resume, not fail.** When the release PR
   is already merged and its tag already exists, `stanza release merge` should
   skip to the dev cycle (or report that dev is already advanced) rather than
   failing on "no open pull requests". Check whether `dev` already contains the
   release merge and already carries the next prerelease version, so the cycle
   is idempotent.
5. **Document the JSON contract for a partial run.** With `--json`, a failed
   run reports the last completed step and the failed one, so a calling
   pipeline does not depend on the exit status surviving a pipe.

### Tests

- A fake remote whose fetch hangs (a `GIT_SSH`/`ext::` transport or a local
  HTTP server that accepts the connection and sends nothing) shows that
  `git_net` gives up within the stall window and the run stops with a
  `cycle` error row and the resume hint.
- A forced failure in each step prints that step's name and the captured
  git/gh error, and exits non-zero.
- `release merge` re-run after a merged PR and pushed tag completes the dev
  cycle, and a second re-run is a no-op.

### Order

1 -> 2 -> 3 -> 4 -> 5. Items 1 to 3 fix the reported failure. Item 4 makes
recovery a single command. Item 5 is for callers.

### Out of scope

- Retrying network calls automatically. A stall that times out is reported,
  and the person running the release decides whether to re-run.
- Wrapping `gh` calls in a timeout. `gh` has its own HTTP client, and none
  stalled here; revisit only if one does.

## Log

- **2026-10-09T21:37:20-07:00** — Activated.
  - Branch: `feature/harden-release-network-steps`
  - Base: `dev` at `9458d33`
  - Worktree: `.worktrees/harden-release-network-steps`
  - PR: pending
- **2026-10-09T21:57:32-07:00** — PR opened: https://github.com/gitronald/stanza/pull/8
- **2026-10-09T21:57:47-07:00** — Items 1 to 5 implemented in `5dfefda`,
  `fd58526`, `203acfb`. All 7 suites pass (583 tests; 24 new in
  `tests/test-network.sh`, 87 new assertions in `tests/test-release-workflow.sh`).
  - **Item 1.** `git_net` in `lib/stanza-common` adds
    `-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=$STANZA_NET_STALL_SECONDS`
    (default 30; `0` turns it off; a non-number falls back to 30). A configured
    `http.lowSpeed*` is left alone, and `GIT_HTTP_LOW_SPEED_*` already beats
    `-c` inside git. SSH is in scope: `core.sshCommand` with
    `ServerAliveInterval` at half the window and `ServerAliveCountMax=2`, unless
    `core.sshCommand`, `GIT_SSH`, or `GIT_SSH_COMMAND` is set. `git_quiet` routes
    `fetch`/`pull`/`push`/`ls-remote` through it; the other remote calls
    (`git_tag_version`'s atomic push, the up-to-date fetches, init's pushes) call
    it directly. A grep of `lib/` finds no remote git call outside it.
  - **Item 2.** `quiet_run`/`run_captured` capture stdout and stderr, not
    stderr alone: `git merge` prints its CONFLICT lines on stdout. On failure
    they print `[ERROR] <command> failed (exit N)` and the output, indented.
    `run_verbose` (init) does the same below `-v`.
  - **Item 3.** An EXIT trap, not an ERR trap. ERR is not inherited by
    functions without `set -E`, and EXIT also covers the explicit `exit 1`
    paths. Steps call `step_start`/`step_done`; the trap prints
    `<step>  failed; <what is left>` and `resume: <command>`. An error that
    printed hints of its own (e.g. the tag-push refusal) keeps them, and the
    generic resume is left out.
  - **Item 4.** `find_shipped_release` resumes when dev is on a stable version
    whose tag exists locally or on origin, or when dev's last commit is the
    cycle bump that follows its nearest tag. It pushes a tag only this clone
    has, checks the tag is on the base branch, and runs the cycle. The cycle
    itself is now idempotent: no bump when dev is already on a prerelease, no
    push when `origin/dev` matches. A merge-step failure after the PR merged
    (no tag yet) is not auto-resumed; its hint tags by hand, then resumes.
  - **Item 5.** Failure JSON: `ok:false`, `failed_step` (`preflight` before
    the first step), `completed_steps`, `error`, `resume`, `hint`. Success
    documents gained `ok:true`, and `merge` gained `resumed`. Documented in
    `stanza guide`, the README, and the CHANGELOG.
  - **Beyond the plan.** Error details from `require_branch`,
    `check_uncommitted_changes`, `check_not_protected_branch`, and the gh login
    check moved from stdout to stderr, since the failure JSON shares stdout. A
    failed `--pr-note` edit now warns that the release continues.
  - **Stall test.** A local TCP server (via `uv run --no-project python`) that
    accepts and never answers. A post-receive hook on the bare remote points
    `origin`'s fetch URL at it once the tag lands, so the cycle's
    `git pull origin dev` is the stalled call. With
    `STANZA_NET_STALL_SECONDS=2`, the run stopped in about 2 seconds with
    git's "Operation too slow" and the `cycle` row; `release merge` then
    finished the cycle, and a second re-run changed nothing.
  - **Not verified:** bash 3.2 (no 3.2 on this host; plan 005 adds the CI
    job), ShellCheck (not installed here), SSH keepalives against a live
    stalled SSH server (the test only checks that git hands the options to
    ssh), and a run against real GitHub.
- **2026-10-09T21:58:07-07:00** — Implemented: 5 commits ahead of `dev`.

## Handoff

State: implemented and pushed on `feature/harden-release-network-steps`; PR
#8 waits on review. Nothing is uncommitted.

Open questions (not blocking review):

1. Should a merge-step failure after the PR has merged (no tag yet) resume
   automatically? It would need to find the PR's merge commit on the base
   branch (the merge whose second parent is dev's head) and tag it. Today the
   hint does it by hand.
2. Should `stanza release pr` resume after a failed `push` or `pr` step (dev
   already on the stable version, no open PR)? Today the hints give the
   commands.
3. For plan 004: its proposed `{"ok":false,"phase":"preflight",...}` clashes
   with the existing `phase` field (`pr`/`merge`). This plan already emits
   `"failed_step":"preflight"` for refusals before the first step; 004 can add
   its `errors` array to that document.
