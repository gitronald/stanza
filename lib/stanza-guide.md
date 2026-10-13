# Driving stanza releases (agent guide)

`stanza release` ships a version bump from `dev` to `main`: it bumps the version
on `dev`, opens a PR into the base branch, merges it, tags the release, and opens
the next prerelease cycle on `dev`. You can run it all at once, or in two stages
so you can review the PR before merging.

## Two-stage release (recommended when you want to review)

Run phase 1, inspect the PR, then run phase 2:

```bash
stanza release pr <type> -y          # bump on dev, push, open the PR, then STOP
gh pr view                           # read the PR (diff, body, checks)
# optionally run a code review here
stanza release merge -y              # merge the PR, tag, open the next cycle
```

- `<type>` is `patch`, `minor`, or `major`.
- Phase 1 prints the PR URL and a `resume` hint. With `--json`, the PR number and
  `"resume": "stanza release merge"` are on stdout.
- Phase 2 re-derives everything it needs (the open PR, the tag from the version
  on `dev`, which the PR title must match), so it needs no memory of phase 1. If more than one open `dev -> base` PR exists,
  pin the target: `stanza release merge <pr-number>`.
- Phase 2 refuses to merge if `dev` advanced past the reviewed PR head, so new
  commits can't sneak into the tagged release.
- Phase 2 waits for the PR's checks before it merges (see *CI checks*), so
  there is no need to poll them yourself first.
- Phase 2 also resumes a release that stopped after its merge: re-run
  `stanza release merge -y` (see *When a release stops partway*). A phase 1
  that stopped before its PR opened resumes the same way: re-run
  `stanza release pr <type> -y`.

## One-shot release (no pause)

When you don't need to pause for review:

```bash
stanza release <type> -y             # bump, PR, merge, tag, new cycle — all at once
```

## Skipping the post-release dev cycle

By default a release ends by cycling back to `dev`: it merges the base branch
back and bumps `dev` to the next prerelease. Pass `--no-dev-cycle` to stop
right after tagging instead — `dev` is left untouched and you stay on the base
branch. Applies to the one-shot release and to `merge` (the `pr` phase stops
before the cycle, so it ignores the flag).

```bash
stanza release <type> -y --no-dev-cycle   # release, but don't touch dev
stanza release merge -y --no-dev-cycle    # phase 2, without the dev cycle
```

Cycle the dev branch yourself afterwards when ready (merge the base branch back
and `stanza release prerelease`).

For LaTeX projects there is no prerelease bump, so the normal cycle only merges
the base branch back into `dev` to keep histories in sync. `--no-dev-cycle`
skips that sync-back too, leaving `dev` behind the tagged release until you merge
the base branch back yourself.

## Releasing without a PR

`--no-pr` merges `dev` into the base branch directly instead of through a PR,
then pushes the base branch and the tag together. Every other step (bump,
changelog promotion, tag, dev cycle) runs as usual. It applies to the one-shot
release and to `merge`; `release pr` ignores it with a warning, as `--pr-note`
is ignored with a warning when no PR is opened.

```bash
stanza release patch -y --no-pr      # bump, merge dev directly, tag, new cycle
stanza release merge -y --no-pr      # phase 2, merging dev instead of the PR
```

The base branch and the tag are pushed atomically, so a protected base branch
refuses both: no tag lands on the remote. The bump is already on `origin/dev`
by then, and the error names the recovery: reset the local base branch to its
remote, open the PR, and run `stanza release merge`.

## CI checks

A release does not merge on a red or unfinished CI:

- **The merge waits for the PR's checks.** After the PR is verified and before
  it is merged, stanza polls its checks until all have finished. A failed or
  cancelled check stops the release at the `checks` step, with the PR open and
  nothing merged or tagged. Fix it on `dev` and push (the PR picks up the
  fix), then `stanza release merge -y`.
- **No checks is a pass.** A repository without CI reports `checks  none
  reported` after a short grace period for checks to register.
- **`--no-pr` reads the workflow runs on `dev`'s head** (`gh run list`) the
  same way. Without `gh`, or with a remote `gh` cannot read, it says so and
  merges. `--local` has no CI to read.
- **A red `dev` is not bumped.** Before the version bump, a full release and
  `release pr` refuse when a workflow run on `dev`'s head has failed. Runs
  still in progress are left to the merge gate.
- **The wait is bounded** by `STANZA_CHECKS_TIMEOUT` (seconds, default 1800;
  `0` waits without limit). A timeout leaves the PR open; `stanza release
  merge -y` waits again.
- **`--skip-checks`** merges without waiting and bumps a red `dev`, for checks
  known broken for unrelated reasons. The run prints a `checks  skipped` row.

```
  pr      #1 https://github.com/OWNER/REPO/pull/1
  checks  waiting on test
[ERROR] PR #1 has failing checks: test
  checks  failed; PR #1 is open; nothing is merged or tagged
  hint    resume: git checkout dev && stanza release merge -y
```

With `--json`, the success document carries `"checks"`: `"passed"`, `"none"`,
`"skipped"`, `"unavailable"` (`--no-pr` without a readable CI), or `null`
(`--local`, or a resumed release).

## Preflight: checked before anything changes

Before a release commits, pushes, merges, or tags anything, it checks
everything the phase needs, and reports every failure in one run:

- the branch (`dev`, or not `main`/`master` for a prerelease) and a clean tree;
- `dev` level with `origin/dev` (for `release merge`, only with `--no-pr`);
- `gh auth status`, on the PR path;
- an empty `## [Unreleased]`, and a `dev` whose CI already failed (full and
  `pr`);
- the target tag: free in this clone and on origin, and above the latest
  version tag (a prerelease must also sort above it);
- `origin` has the base branch, and with `--no-pr` the local base branch has
  not diverged from it;
- for `release merge`: the PR is open, targets the base branch, its head is
  local `dev`, and its title is the tag. Without `--no-pr`, an alpha version
  is refused.

```
[ERROR] Uncommitted changes, commit or stash them first.
     M NOTES
[ERROR] tag v0.1.0 already exists in this clone
  hint    inspect it (git show v0.1.0); release a higher version, or delete the tag if it is stale
```

With `--json`, the failure document has `"failed_step":"preflight"`, `error`
and `hint` from the first failure, and `errors`, a list of
`{"error":...,"hint":...}` for every failure.

`--check` runs the preflight only and changes nothing: exit 0 when the release
could go ahead, 1 with the failures when it could not. The success row (and
the JSON's `"check":true`, `to_version`, and `tag`) says what the run would do:

```bash
stanza release patch --check         # check a full patch release
stanza release merge --check         # check the open release PR can merge
```

## When a release stops partway

A failed step prints the error that git or gh gave, then a row naming the step
(`bump`, `push`, `pr`, `checks`, `merge`, `tag`, or `cycle`), what it left behind, and the
command that resumes from there:

```
  merge   #1 merged into main
  tag     v0.4.1  pushed
[ERROR] git pull origin dev failed (exit 1)
    fatal: unable to access '...': Operation too slow. Less than 1000 bytes/sec transferred the last 30 seconds
  cycle   failed; v0.4.1 is released; dev is not advanced
  hint    resume: git checkout dev && stanza release merge -y
```

What the resume command does depends on where the run stopped:

- **Before the merge** (`push` or `pr`): run the same `stanza release <type>`
  or `stanza release pr <type>` again. It finds the bump already on `dev`
  (dev's last commit, untagged) and pushes `dev` and opens the PR, or takes the
  PR that is already open, instead of bumping again. A different bump type is
  refused, and so is a bump that is already merged into the base branch (that
  is the merge phase's to finish).
- **After the merge** (`merge`, `tag`, or `cycle`): `stanza release merge`. When
  the PR is merged and the tag is missing, it finds the merge commit on the
  base branch (the merge of dev's head, with dev's tree) and tags it. When only
  this clone has the tag, it pushes it, together with the base branch when
  that is ahead of origin's, as after a `--local` release. Then it runs the dev
  cycle. A re-run after the cycle has finished changes nothing.

When the error carries a hint of its own, that hint replaces the generic
resume line.

With `--json`, a failed run still prints one JSON document on stdout, so a
caller that loses the exit status in a pipe (`stanza ... | tail`) still sees the
failure:

```json
{"schema_version":1,"command":"release","phase":"merge","ok":false,
 "failed_step":"cycle","completed_steps":["merge","tag"],
 "error":"git pull origin dev failed (exit 1)",
 "resume":"git checkout dev && stanza release merge -y",
 "hint":"or by hand: git checkout dev && git pull origin dev && ..."}
```

- `ok` is `true` on success and `false` on failure.
- `failed_step` is `"preflight"` when the run stopped before its first step,
  including on a usage error such as an unknown option.
- `completed_steps` lists the steps this run finished, in order.
- `resume` is `null` when the error gave its own hints, which are then in
  `hint`.
- On success, `resumed` is `true` when the run resumed an earlier one. A
  resumed bump reports `from_version` as `null`, since the run did not see the
  version before the bump.

`stanza init` and `stanza rules` follow the same rule: their documents carry
`ok`, and a failure prints `{"command":...,"ok":false,"error":...,"hint":...}`
(with `action` for `rules`). `stanza rules check` reports a drifted or missing
rule with `ok: false` in its own document and exits 1.

Git calls that reach the remote give up after `STANZA_NET_STALL_SECONDS`
(default 30) below 1000 bytes/s, instead of waiting on a stalled connection.
A remote that sends nothing while it works counts as stalled too (git's
keepalives are far below the limit), so raise it for a slow server-side hook.
Set it to `0` to turn this off. Your own `http.lowSpeedLimit`/`http.lowSpeedTime`
git config wins. For SSH remotes, stanza adds `ServerAlive` keepalives and a
`ConnectTimeout` of the same window unless you set `core.sshCommand`,
`GIT_SSH`, or `GIT_SSH_COMMAND` yourself.

Neither catches an HTTPS connection that never opens, which git would wait on
for curl's five minutes. So every git and gh call that reaches the remote also
ends after `STANZA_NET_TIMEOUT` seconds (default 120; `0` for no limit). A read
(a fetch, `ls-remote`, a gh view or list) that hits it is tried once more. A
write is not: a push or a PR create or merge can land before it is cut off.
After one fails that way, stanza reads the remote and reports what landed,
`pushed`, `not pushed`, or `unknown` (the remote could not be read either), and
its hint follows: the retry for a push that did not land, the resume command
for one that did.

## Attaching a note to the PR

`--pr-note` appends text to the PR body (applies to the `pr` and full phases):

```bash
stanza release pr minor -y --pr-note "summary of the change set; closes #42"
```

To attach a longer, formatted note, write it to a file (e.g. `pr-notes.md`) and
pass its contents — Markdown and multiple lines are preserved:

```bash
stanza release pr minor -y --pr-note "$(cat pr-notes.md)"
```

## README title and CHANGELOG (release-time docs sync)

A release keeps two docs in sync with the version, in the same `version [type]:`
commit (so they flow through the PR and are present at tag time):

- **README title.** If the README's first H1 has a `v<version>` token (e.g.
  `# pbz2 v0.2.0`), it's rewritten to the new version. No token → left alone.
- **CHANGELOG `[Unreleased]`.** On a stable release, a non-empty `## [Unreleased]`
  section in `CHANGELOG.md` is promoted to `## [X.Y.Z] - YYYY-MM-DD` with a fresh
  empty `## [Unreleased]` above it (compare-link references are updated too).

A stable release **aborts before bumping** if `CHANGELOG.md` exists with an empty
`## [Unreleased]`. So when a changelog is present, write the entries first:

```bash
# fill ## [Unreleased] in CHANGELOG.md, commit it, then release
stanza release <type> -y
stanza release <type> -y --no-changelog   # or skip promotion + the check entirely
```

## Prereleases

A prerelease never opens a PR, so phases do not apply to it:

```bash
stanza release prerelease -y         # bump to the next alpha on the current branch
```

## Rules of the road

- Push `dev` before releasing — stanza blocks if local commits are ahead of the remote.
- A release checks its preconditions before it changes anything; `--check` runs only those checks.
- Use `-y` (`--yes`) for non-interactive runs.
- Alpha versions live on `dev`; stable releases are tagged on `main` only.
- A stable release blocks on an empty `## [Unreleased]`; fill it first (or pass `--no-changelog`).
- The release merge waits for CI and stops on a failure; don't pre-poll the checks.
- Add `--json` to any command for machine-readable output (`schema_version: 1`).
- stanza writes its own `version [...]` commit subjects; `stanza rules` lists
  them, and `stanza rules install` makes that list an always-on Claude Code rule.

## Worked example (two-stage patch)

```bash
# on dev, version 0.4.1a3
stanza release pr patch -y           # -> dev 0.4.1, PR "v0.4.1" opened, STOP
gh pr view                           # review the PR
stanza release merge -y              # merge, tag v0.4.1, dev -> 0.4.2a0
```
