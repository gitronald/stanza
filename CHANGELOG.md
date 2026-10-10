# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.3] - 2026-10-09

### Added

- Shell completions offer the global flags (`--json`, `-q`, `-v`, `-vv`,
  `--no-color`, `-V`, `-h`) and the missing `init` options (`-t/--type`, output
  flags), and bash completion works after leading global flags.

### Changed

- `stanza release merge` must run on `dev` in every mode, including `--local`.
- `stanza release merge` takes the tag from the version on `dev` and refuses a
  release PR whose title differs, instead of using the PR title as the tag.
- `stanza release merge` refuses a PR that is not open, does not target the base
  branch, or whose head cannot be read, and passes `--match-head-commit` so a
  push between the check and the merge fails the merge.
- uv and bash projects reject versions with leading zeros (`1.2.08`), which
  semver forbids. LaTeX versions keep them and bump in base 10.
- `gh` is required only on the PR path; `--local`, `--no-pr`, and prerelease
  runs work without it installed.

### Fixed

- A successful `-q --json` run of `release` or `init` exited 1.
- With `--json`, `-v`/`-vv` printed prompts and git/gh output to stdout ahead of
  the JSON document; they now go to stderr.
- LaTeX version parsing read `\ProvidesClass{x}[2026/01/01 v1.2]` as `1.2]`,
  and a bump dropped the closing bracket.
- JSON output left control characters other than newline, carriage return, and
  tab unescaped, producing invalid JSON.
- README title sync matched partial tokens such as `v1.2.3beta` and rewrote
  them as `v1.2.4beta`.

## [1.1.2] - 2026-10-09

### Added

- `stanza release <type> --no-pr` (and `release merge --no-pr`) merges `dev`
  into the base branch directly, without a PR, while keeping every remote step.
  A protected base branch refuses the push, and the error names the recovery.

### Changed

- The release tag is pushed with its base branch in one `git push --atomic`, and
  only that tag is pushed (previously `--tags` pushed every local tag).
  When that push fails, the error shows git's output (the remote's reason) and
  names the steps to finish the release, including the dev cycle.

## [1.1.1] - 2026-09-27

### Added

- `stanza init` offers to initialize a git repository when run outside one
  (auto-confirmed with `-y`), and skips pushing while the new repo has no
  commits. Declining the GitHub step afterwards keeps the local-only repo.

## [1.1.0] - 2026-09-10

### Added

- `stanza rules` prints a generated Claude Code rule that documents the commits
  stanza writes. `stanza rules install` writes it to `~/.claude/rules/stanza.md`
  (or the repo's `.claude/rules/` with `--local`), `check` reports drift, and
  `uninstall` removes it. Files stanza did not generate are never overwritten or
  removed without `--force`.
- `install.sh` installs the rule when `~/.claude` exists (`--no-rules` skips it),
  and `uninstall.sh` removes it.

### Changed

- The release merge commit subject is now `version [release]: vX.Y.Z - PR #N`
  instead of GitHub's default `Merge pull request #N from <owner>/dev`.
- Local releases (`--local` or no remote) now always create a merge commit on
  the base branch, `version [release]: vX.Y.Z`, instead of fast-forwarding it,
  and fast-forward `dev` onto that merge before the next prerelease bump.

### Fixed

- An install with `--prefix=<dir>` could not find its own library and exited;
  `stanza` now looks for `lib/stanza/` next to its own `bin/` directory.
- `uninstall.sh` stopped after removing the binary, leaving the library and
  completions in place: a `((count++))` from zero exits non-zero under `set -e`.

## [1.0.0] - 2026-08-09

First public release.
