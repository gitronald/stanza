---
name: bump-version
description: >
  Bump the version and cut a release for this repo using stanza. Use when the user wants to release,
  bump the version, cut a patch/minor/major, ship a release, tag a new version, or open a release PR.
  Covers the two-stage (review-before-merge) flow, the one-shot flow, and prereleases. Triggers on
  "bump the version", "cut a release", "release patch/minor/major", "ship it", or /bump-version.
---

# bump-version

Release this repo with [stanza](https://github.com/gitronald/stanza) (the tool this repo *is* — it
manages its own versions). `stanza release` bumps the version on `dev`, opens a PR into `main`,
merges it, tags the release, and opens the next prerelease cycle on `dev`.

For the full upstream reference, run `stanza guide` — this skill is the repo's house rules on top of
it.

## Default: two-stage release with a PR note

**This is our default. Always release in two stages, and always pass `--pr-note`.** The two stages
let the PR be reviewed before it merges; the note records *what changed* in the PR body so the
release is self-documenting.

```bash
stanza release pr <type> -y --pr-note "$(cat pr-notes.md)"   # phase 1: bump on dev, push, open PR, STOP
gh pr view                                                   # read the diff, body, and checks
# optionally run a code review here
stanza release merge -y                                      # phase 2: merge the PR, tag, open next cycle
```

- `<type>` is `patch`, `minor`, or `major`.
- **Write the note first.** Summarize the change set since the last release — drive it from
  `git log <last-tag>..HEAD`. A short inline note is fine for a small change
  (`--pr-note "fix tag double-creation; closes #42"`); for anything larger, write `pr-notes.md`
  (Markdown, multi-line — both are preserved) and pass it with `--pr-note "$(cat pr-notes.md)"`.
- Phase 1 prints the PR URL and a `resume` hint. With `--json`, the PR number and
  `"resume": "stanza release merge"` are on stdout.
- Phase 2 re-derives the open PR and the tag from the PR title, so it needs no memory of phase 1.
  If more than one open `dev -> main` PR exists, pin it: `stanza release merge <pr-number>`.
- Phase 2 refuses to merge if `dev` advanced past the reviewed PR head, so nothing sneaks into the
  tagged release.

## One-shot release (only when no review is wanted)

Still pass the note — skipping the pause is the only difference:

```bash
stanza release <type> -y --pr-note "$(cat pr-notes.md)"      # bump, PR, merge, tag, new cycle in one go
```

## Skipping the post-release dev cycle

Both the two-stage `merge` and the one-shot release accept `--no-dev-cycle`, which
stops right after tagging: `dev` is left untouched (no merge-back, no next prerelease bump)
and you stay on `main`. Use it when you want to land the release but defer or hand-manage the
next `dev` cycle yourself.

```bash
stanza release merge -y --no-dev-cycle           # phase 2, without the dev cycle
stanza release <type> -y --no-dev-cycle --pr-note "$(cat pr-notes.md)"   # one-shot, no dev cycle
```

## Prereleases (no PR, no note)

A prerelease never opens a PR, so phases and `--pr-note` do not apply:

```bash
stanza release prerelease -y                                 # bump to the next alpha on the current branch
```

## Choosing the bump type

- `patch` — bug fixes, doc/internal changes, no API change.
- `minor` — new backward-compatible features (new flags, commands, project types).
- `major` — breaking changes (removed/renamed flags or commands, changed output contract).
- `prerelease` / `pre` — iterate on `dev` without cutting a stable release.

## Rules of the road

- **Push `dev` before releasing** — stanza blocks if local commits are ahead of the remote.
- Use `-y` (`--yes`) for non-interactive runs.
- Alpha versions live on `dev`; stable releases are tagged on `main` only.
- Never tag or release directly from `main`; the flow always starts on `dev`.
- Add `--json` to any command for machine-readable output (`schema_version: 1`).

## Worked example (two-stage patch with a note)

```bash
# on dev, version 0.8.2a0, after merging some fixes
git log v0.8.1..HEAD --oneline > /tmp/changes && $EDITOR pr-notes.md   # draft the note from the log
stanza release pr patch -y --pr-note "$(cat pr-notes.md)"              # -> dev 0.8.2, PR "v0.8.2" opened, STOP
gh pr view                                                            # review the PR
stanza release merge -y                                               # merge, tag v0.8.2, dev -> 0.8.3a0
```
