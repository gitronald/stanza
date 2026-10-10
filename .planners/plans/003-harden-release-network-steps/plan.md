---
id: 3
slug: harden-release-network-steps
status: active
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
