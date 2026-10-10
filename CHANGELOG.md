# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- `install.sh` and `uninstall.sh` print in the same row grammar as
  `stanza release`: a `stanza install` header, then one labelled row per file
  or step, with every installed file named by its path before the prompt and
  as it lands. A fresh install prints about 20 lines instead of about 50.
- Their color follows `NO_COLOR`, `--no-color` (new on both scripts),
  `TERM=dumb`, and `CLICOLOR_FORCE`, and is off when the output is not a
  terminal, so a piped or logged install carries no escape codes.
- The PATH hint names the user's own startup file (`~/.zshrc`; for bash,
  `~/.bash_profile` on macOS and `~/.bashrc` elsewhere; `fish_add_path` for
  fish), and so do the completion hints when the fallback directories are used.
- Every installer error says whether anything was installed and is followed by
  a `hint` row with the next step.

## [1.2.1] - 2026-10-10

### Changed

- `install.sh` refuses to download from a repository URL that is not HTTPS
  (`STANZA_REPO_URL=http://...`), and its `curl` downloads require HTTPS and
  TLS 1.2 for the request as well as the redirect.
- The `release-asset` workflow no longer leaves the job token in the
  checkout's git config while the release script runs.

## [1.2.0] - 2026-10-10

### Added

- One-line install without a clone: `curl --proto '=https' --tlsv1.2 -fsSL
  https://raw.githubusercontent.com/gitronald/stanza/main/install.sh | bash`.
  Run outside a checkout, `install.sh` downloads the latest release (or the
  tag given by `--version` / `STANZA_VERSION`) and installs from it.
- Each stable release publishes `stanza-<version>.tar.gz` and its `.sha256` on
  its GitHub release, built by `scripts/release-asset.sh` from a tag-triggered
  workflow. The one-line installer downloads that asset and refuses to install
  it unless it matches the checksum; tags without an asset (v1.1.3 and
  earlier) are refused, with a pointer to the clone path.
- `install.sh --yes` skips the confirmation prompt. A piped install reads the
  answer from the terminal, and fails with a hint to pass `--yes` when there
  is none.
- `stanza release merge` resumes a release that is already merged and tagged:
  it pushes the tag if only the local clone has it, then runs the dev cycle. A
  re-run after the cycle has finished is a no-op.
- `STANZA_NET_STALL_SECONDS` (default 30) sets how long a git transfer may stay
  below 1000 bytes/s before it is abandoned; `0` turns the limit off.

### Changed

- A release that stops partway prints a row naming the failed step (`bump`,
  `push`, `pr`, `merge`, `tag`, `cycle`), what it left behind, and the command
  that resumes it.
- With `--json`, a failed release prints a JSON document with `"ok": false`,
  `failed_step`, `completed_steps`, `error`, `resume`, and `hint`. Successful
  release documents carry `"ok": true`, and `merge` adds `resumed`.
- The dev cycle skips the prerelease bump when `dev` is already past the
  release, and skips the push when `origin/dev` already matches.
- For SSH remotes, git calls add `ServerAlive` keepalives unless an ssh command
  is already configured.

### Fixed

- A stalled HTTPS fetch or push could hang a release indefinitely. Git calls
  that reach the remote now give up after `STANZA_NET_STALL_SECONDS` without
  progress, unless the user's own `http.lowSpeed*` config says otherwise.
- A failed git or gh call ended the run with no message, because its output
  was discarded. The error it printed is now shown, with the command that
  failed.
- Error details from the branch, clean-tree, and gh login checks went to
  stdout, ahead of any `--json` document; they now go to stderr.

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
