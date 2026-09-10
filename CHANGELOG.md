# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

- `uninstall.sh` stopped after removing the binary, leaving the library and
  completions in place: a `((count++))` from zero exits non-zero under `set -e`.

## [1.0.0] - 2026-08-09

First public release.
