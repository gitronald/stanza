---
id: 12
slug: bound-remote-calls
status: active
branch: feature/bound-remote-calls
created: 2026-10-12T12:51:46-07:00
concluded:
pr: https://github.com/gitronald/stanza/pull/22
---

# Bound remote calls whose connection never opens

## Plan

### Problem

`git_net` (`lib/stanza-common`) bounds a stalled HTTPS transfer with
`http.lowSpeedLimit`/`http.lowSpeedTime`, and an SSH session with keepalives.
Neither bounds connection setup. git has no connect timeout for HTTPS, so
curl's default of 300 seconds applies, and curl checks the low-speed limit
only once the transfer is under way. To reproduce, against an address that
drops connection attempts:

```bash
time git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 \
  ls-remote https://10.255.255.1/none.git
```

The 10-second low-speed limit never fires; the command waits until curl's
connect timeout, or until an outer bound ends it.

Observed: a push whose HTTPS connection to GitHub never opened waited the full
300 seconds and failed with `Connection timed out after 300012 milliseconds`,
while other connections to the same host in the same minute went through in
seconds. In a release, each fetch, pull, or push can cost five minutes this
way before stanza reports anything.

Two related gaps:

- **`gh` calls have no bound.** `gh_quiet pr create`, `gh_quiet pr merge`,
  `gh pr view`, `gh pr list`, `gh pr edit`, and `gh run list` run as they
  are. The checks wait already retries a failed read and is bounded as a
  whole by `STANZA_CHECKS_TIMEOUT`; the single calls are not.
- **The failure message asserts what was pushed.** After a failed push,
  `git_tag_version` prints "neither was pushed" and the resume path prints
  "nothing was pushed". That holds for a refusal, and for a connection that
  never opened. Once a bound can end a push partway, it may not hold: the
  remote can take the refs before the client is stopped.

### Change

1. **A portable bound.** A helper in `lib/stanza-common`,
   `run_bounded <seconds> <cmd> [args...]`, that runs the command, ends it
   after the given seconds, and returns 124 when it does (as GNU `timeout`
   does). Built from bash builtins (a background job and a `kill`
   watchdog), not `timeout`, which macOS does not ship; bash 3.2
   compatible. Output and exit status otherwise as for a direct call. `0`
   seconds runs the command unbounded.
2. **Bound the remote calls.** `git_net` runs git under `run_bounded`, and a
   `gh_net` does the same for the `gh` calls above (`gh_quiet` routes
   through it). `STANZA_NET_TIMEOUT` sets the bound (seconds, default 120;
   `0` for none), beside `STANZA_NET_STALL_SECONDS`. The bound is per call
   and covers the whole call, since nothing separates connection setup from
   transfer from outside git. The default is wide for stanza's pushes, which
   carry a version bump, a merge, and a tag; the low-speed abort still
   catches a transfer that stalls sooner.
3. **SSH connect timeout.** The `core.sshCommand` that `git_net` builds gains
   `-o ConnectTimeout=<n>`, under the same conditions as the keepalives (left
   alone when the user chose an ssh command). That gives SSH remotes a real
   connect bound, independent of item 2.
4. **Retry reads once.** A read that ends on the bound (`fetch`,
   `ls-remote`, `gh pr view`, `gh pr list`, `gh run list`) is retried once
   before it is reported. Writes are not retried blindly (item 5).
5. **Say what landed.** After a push that fails without the remote's
   refusal (a bound, a dropped connection), compare `git ls-remote origin`
   for the pushed refs with the local refs, and report `pushed`, `not
   pushed`, or `unknown` (the check failed too), in place of the fixed
   "neither was pushed" and "nothing was pushed". The retry and resume hints
   follow the verdict. Do the same after `gh pr create` (look up the open
   PR from `dev`, as `gh_get_last_open_pr_number` does) and `gh pr merge`
   (read the PR's state). `push_with_retry` runs the check before it offers
   another attempt.

### Docs

`README.md` (beside `STANZA_NET_STALL_SECONDS`), `lib/stanza-guide.md`
(the remote-calls paragraph), and `CHANGELOG.md` under `[Unreleased]`:
`STANZA_NET_TIMEOUT`, the SSH connect timeout, and the landed check in the
push failure output.

### Tests

- `run_bounded`: a command that sleeps past the bound returns 124 within a
  second of it; one that finishes first returns its own status and output;
  a bound of `0` does not end a long command.
- A stub `git` whose push hangs: the release stops within the bound and
  reports `not pushed`. A stub that updates a local bare remote and then
  hangs: the release reports `pushed`, and its hint is the resume command,
  not the retry.
- A stub `gh` whose `pr view` hangs once: retried, then the release goes on.
  One that always hangs: the release stops with a hint, within twice the
  bound.
- `core.sshCommand` carries `ConnectTimeout` when the user set no ssh
  command, and is left alone when they did.
- The suite stays green on bash 3.2 and ShellCheck-clean.

### Out of scope

- A connect timeout for HTTPS itself: git offers no option for it.
- The checks wait, which `STANZA_CHECKS_TIMEOUT` already bounds.

## Log

- **2026-10-13T10:20:34-07:00** — Activated.
  - Branch: `feature/bound-remote-calls`
  - Base: `dev` at `7d9ceaa`
  - Worktree: `.worktrees/bound-remote-calls`
  - PR: pending
- **2026-10-13T10:28:54-07:00** — PR opened: https://github.com/gitronald/stanza/pull/22
