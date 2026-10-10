---
id: 3
slug: harden-release-network-steps
status: done
branch: feature/harden-release-network-steps
created: 2026-10-09T17:17:19-07:00
concluded: 2026-10-09T23:01:35-07:00
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
- **2026-10-09T23:02:35-07:00** — Review follow-up (`96f9d8e`, `1ff204a`).
  `/code-review` at medium on PR #8 (2 finders, 5 verifiers): 13 findings, 8
  confirmed and 5 plausible; 6 candidates rejected. Posted to the PR. All 7
  suites pass (607 tests; 24 new assertions).
  - **Actioned, each with a regression test:**
    - A failed tag fetch in `find_shipped_release` was ignored: the function
      runs as an `if` condition, so set -e is off in its body, and the resume
      went on to a `tag` failure hinting `git tag vX main`. The fetch now exits
      (`test_resume_tag_fetch_failure_stops`).
    - A resumed run that failed at the cycle push said "dev is not advanced"
      and hinted a second prerelease bump, because `CYCLE_BUMPED` was set only
      by the run that bumped. Renamed `DEV_ADVANCED` and set whenever the cycle
      finds dev on a prerelease (`test_cycle_push_failure_resumes`).
    - `STANZA_NET_STALL_SECONDS=08` was read as octal: the `[[ -gt ]]` erred as
      false and git_net added no options. Normalized with `10#`
      (`test_stall_seconds_env`).
    - The failure JSON's `error` was null for a `print_error` inside `$(...)`
      (e.g. no version file). `print_error` also writes a per-run
      `STANZA_ERROR_LOG`, which `step_start` clears and the exit trap reads and
      removes (`test_subshell_error_reaches_json`).
    - Recoverable calls (the prerelease push, the `--pr-note` edit) printed
      `[ERROR]` on a run that exits 0. A new `quiet_try` reports them as a
      warning; every wrapper now goes through one `run_reported`
      (`test_prerelease_push_failure_warns`, `test_quiet_try_warns`).
    - `run_verbose -v` never named a failed command; it shares `run_reported`
      now (`test_verbose_failure_is_named`).
    - The three inline remote update hooks in `tests/test-release-workflow.sh`
      use `remote_update_hook`.
    - The README lists `hint` among the failure fields. README and guide say to
      raise `STANZA_NET_STALL_SECONDS` for a remote that stays silent while it
      works: curl counts silence, and git's keepalives are far below 1000 B/s.
  - **Conscious no-ops:**
    - A `--local` release resumed later against the remote dies on a
      non-fast-forward `fetch origin main:main`, and its hint repeats the
      command. Outside the supported flow; carried to plan 007 (case 3).
    - The `ls-remote` arm of `git_quiet` has no caller. Kept, so a future
      caller stays under git_net's bounds.
    - `STANZA_NET_STALL_BYTES` keeps its name: the prefix also marks internal
      state (`STANZA_LAST_ERROR`, `STANZA_HINTS`), and no doc names it a knob.
    - `check_branch_up_to_date` keeps its own fetch report; `git_quiet` would
      change the message and stream the fetch at `-vv`.
  - **Rejected by verification:** repeated `get_current_version` reads, the
    duplicate tag-push resume hint, the recipes in `release_failure_advice`,
    repeated `git config` spawns, and `--json -vv` stdout from
    `git_tag_version` (pre-existing on `dev`; see Handoff).
  - Merged `dev` (plan 007's add) into the branch, so the index does not
    conflict on GitHub.

## Handoff

State: closed. The implementation, review fixes, and docs are on
`feature/harden-release-network-steps` and merge into `dev` through PR #8.
Nothing is uncommitted.

Questions:

1. Should a merge-step failure after the PR has merged (no tag yet) resume
   automatically? Handed to plan 007, case 1 (2026-10-09).
2. Should `stanza release pr` resume after a failed `push` or `pr` step (dev
   already on the stable version, no open PR)? Handed to plan 007, case 2
   (2026-10-09).
3. Plan 004's proposed `{"ok":false,"phase":"preflight",...}` clashes with the
   existing `phase` field (`pr`/`merge`). Handed to plan 004 (2026-10-09): this
   plan emits `"failed_step":"preflight"` for refusals before the first step,
   and 004 can add its `errors` array to that document.

Not verified:

- bash 3.2 (no 3.2 on this host; plan 005 adds the CI job).
- ShellCheck (not installed here).
- SSH keepalives against a live stalled SSH server (the test checks only that
  git hands the options to ssh).
- A run against real GitHub.
- Known and pre-existing on `dev`: under `--json -vv`, `git_tag_version` prints
  the tag push output on stdout ahead of the JSON document. Plan 005's
  output-mode matrix is where a test would catch it.

## Retrospective

- The five items landed as specified. The one change of mechanism was an EXIT
  trap in place of an ERR trap: ERR is not inherited by functions without
  `set -E`, and it misses the explicit `exit 1` paths.
- State that a failure report depends on cannot live in a per-process flag.
  `CYCLE_BUMPED` and `STANZA_LAST_ERROR` were both lost in exactly the cases
  this plan is about (a resumed run, an error inside `$(...)`). Derive it from
  the repo, or carry it through a file.
- Calling a function as an `if` condition turns off `set -e` for its whole
  body, with no sign of it. A function used that way needs an explicit
  `|| exit` on every call that can fail.
- Capturing output so failures are reported made every caught failure an
  `[ERROR]`, including those the caller recovers from. A reporting wrapper
  needs a severity, not only a capture.
- The stall test (a TCP server that accepts and never answers, with origin's
  fetch URL repointed by a post-receive hook) reproduced the original incident
  in about 2 seconds. Plan 007's tests can reuse the pattern.
