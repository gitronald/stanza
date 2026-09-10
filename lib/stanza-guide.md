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
- Phase 2 re-derives everything it needs (the open PR, the tag from the PR title),
  so it needs no memory of phase 1. If more than one open `dev -> base` PR exists,
  pin the target: `stanza release merge <pr-number>`.
- Phase 2 refuses to merge if `dev` advanced past the reviewed PR head, so new
  commits can't sneak into the tagged release.

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
- Use `-y` (`--yes`) for non-interactive runs.
- Alpha versions live on `dev`; stable releases are tagged on `main` only.
- A stable release blocks on an empty `## [Unreleased]`; fill it first (or pass `--no-changelog`).
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
