---
id: 5
slug: ci-output-contract
status: implemented
branch: feature/ci-output-contract
created: 2026-10-09T18:49:08-07:00
concluded:
pr: https://github.com/gitronald/stanza/pull/20
---

# Add CI with an output-mode matrix and a bash 3.2 job

## Plan

### Problem

stanza has 300+ shell tests and no CI: they run only when someone runs them,
on whatever bash that machine has (5.x here). Two gaps follow.

1. **Output modes are tested on the happy path only.** The review on
   `feature/review-simplify` found a successful `--json -q` release exiting 1
   and `--json -vv` printing prompts and git output ahead of the JSON. Both
   are fixed there, with one regression test each, but there is no systematic
   coverage of verbosity x output mode x outcome.
2. **The bash 3.2 floor is a claim, not a check.** macOS ships bash 3.2 and
   the README promises it works, but nothing runs the code on 3.2, and the
   zsh completion file is never loaded by any test.

### Changes

1. **Output-mode matrix test** (`tests/test-output-contract.sh`). For each
   command that has a JSON shape (`release` full/pr/merge/prerelease with
   `--local`, `init` with the gh mock, `rules install`), run the product of
   verbosity `{-q, default, -v, -vv}` x `{text, --json}` x
   `{success, a forced failure}` and assert:
   - exit code is 0 on success, non-zero on failure;
   - in `--json` mode stdout parses as exactly one JSON document
     (`uv run --no-project python -c 'import json,sys; json.load(sys.stdin)'`,
     or `jq -e .` if jq is a test dependency) and every other line went to
     stderr;
   - in `-q` text mode stdout is the single documented value (version or URL).
   Keep it table-driven so a new command adds a row, not a block.
2. **A shared test runner** (`tests/run.sh`) that runs every `test-*.sh`,
   sums the `Results:` lines, and exits non-zero on any failure. CI and
   humans call the same entry point.
3. **GitHub Actions workflow** (`.github/workflows/test.yml`), on push and
   PR to `dev` and `main`:
   - `ubuntu-latest`: `tests/run.sh` and ShellCheck (fail on new findings;
     start from the current baseline with a checked-in exclusion list rather
     than fixing all at once);
   - `macos-latest` with `/bin/bash` (3.2) explicitly: `tests/run.sh` run as
     `/bin/bash tests/run.sh`, and each test invoking stanza through
     `/bin/bash`, so the floor is the shell under test;
   - a zsh step that sources `completions/stanza.zsh` under `compinit` and
     checks it loads without error.
4. **README:** a status badge and a line on running `tests/run.sh`.

### Open questions

1. Is `jq` acceptable as a test-only dependency, or use `uv run` for JSON
   validation? (uv is already assumed by the uv project tests.)
   **Answered 2026-10-09: yes, `jq` is fine as a test dependency.** Use
   `jq -e .` for JSON validation in the matrix.
2. Should ShellCheck gate CI from day one, or report only until the
   remaining findings are triaged?
   **Answered 2026-10-09: gate from day one, after a cleanup commit.** A trial
   cleared all 27 findings in about 30 lines with no behavior change and all
   tests passing: `# shellcheck source-path=`/`source=` directives (clears the
   7 SC1091 and the 9 cross-file SC2034), a disable comment on `PURPLE`, a
   `VERBOSE="${VERBOSE:-false}"` default (SC2153), a `while read` loop in the
   bash completion (SC2207, no `mapfile` on bash 3.2), and split
   `local`/assign for the 8 SC2155. Six of those splits change nothing (four
   run inside `$(...)`, where bash drops `set -e`; two wrap `echo | awk`, so
   use `read -r ahead behind <<<`). The two `current_branch=$(get_current_branch)`
   splits must be written `... || current_branch=""`, or `require_branch`
   outside a repo dies with exit 128 instead of printing its error. Make this
   the first step, then gate CI on zero findings.

### Order

2 -> 1 -> 3 -> 4. The runner first, since both the matrix and CI call it.

## Log

- **2026-10-11T02:00:46-07:00** — Activated.
  - Branch: `feature/ci-output-contract`
  - Base: `dev` at `decba7b`
  - Worktree: `.worktrees/ci-output-contract`
  - PR: pending
- **2026-10-11T02:07:06-07:00** — PR opened: https://github.com/gitronald/stanza/pull/20
- **2026-10-11T02:22:45-07:00** — Implemented, CI green on all three jobs
  (run 38127818430 at `a76f189`): Linux bash 5.2 and macOS `/bin/bash`
  3.2.57 each ran 1471 checks with 0 failed, and ShellCheck 0.11.0 reported
  no findings.
  - **ShellCheck cleanup first.** The code had moved since the trial: 31
    findings, not 27 (no `PURPLE`; four SC2155, all inside `$(...)` call
    sites, so the splits change nothing; new SC1010, SC2088, and SC2206). A
    `.shellcheckrc` (`external-sources`, `source-path=SCRIPTDIR`) plus
    `# shellcheck source=` directives cleared the SC1091 and the cross-file
    SC2034. `version_lt` splits with `read -r -a`; the bash completion uses a
    `while read` loop. The checked set is the shipped scripts plus
    `tests/run.sh`; the `tests/test-*.sh` files are not checked.
  - **Runner.** `tests/run.sh` runs each file under its own bash and puts a
    `bash` shim for that bash first on PATH, so `/bin/bash tests/run.sh`
    runs stanza's `#!/usr/bin/env bash` on 3.2 too, with no test edits. It
    sets `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`, so local
    runs see what a fresh CI machine sees.
  - **Matrix.** `tests/test-output-contract.sh`: six rows (release
    full/pr/merge/prerelease, init, rules install) x 4 verbosities x text and
    `--json` x success and each forced failure (a failing pre-commit hook and
    a dirty tree for release, a failing `gh` for init, a hand-written rule
    file for rules install): 366 checks in about 15s. Validated with `jq`.
    Three mutations on a scratch copy were each caught: the header printed
    to stdout under `--json` (48 failures), `rules install -q` printing
    nothing (1), and a failed release exiting 0 (64).
  - **Found: `init` and `rules install` print nothing on stdout under
    `--json` when they fail**, where a release prints an `ok:false`
    document. The matrix records today's behavior (empty stdout) per row;
    see Handoff question 1.
  - **zsh** is a test file (`tests/test-completion-zsh.sh`) rather than a
    workflow step, so humans run it through the same runner. It installs the
    file as `_stanza` on `fpath`, runs `compinit`, and checks the mapping and
    `autoload +X`. Sourcing the file directly is not the check: its last line
    calls `_stanza`, which needs a completion context. It skips without zsh
    (Linux CI) and ran 3 checks on macOS.
  - **CI caught two test bugs**, both fixed in the tests:
    `test-version-bumps.sh` and `test-version-file-detection.sh` relied on a
    global git identity, and `test-rules.sh` expected the unresolved temp
    path where git reports the physical one (`/var` -> `/private/var`).
- **2026-10-11T02:23:07-07:00** — Implemented: 9 commits ahead of `dev`.

- **2026-10-11T02:35:03-07:00** — Review follow-up (code review at
  medium: 12 candidates, 5 findings kept, all fixed in `a44140a` and `c72a286`;
  CI run 38128579721 green, 1495 checks on Linux and on macOS bash 3.2.57).
  - Fixed: failure cases now assert the release's `failed_step` (hook:
    `bump`, or `cycle` for merge; dirty tree: `preflight`). A mutation that
    reports every failure as `preflight` gives 16 failures.
  - Fixed: `--json` success documents are checked for the `-q` value through
    a per-row jq filter (`.to_version`, `.tag.name[1:]`, `.repo_url`,
    `.path`). A wrong `repo_url` gives 4 failures.
  - Fixed: an early return skipped `cleanup` and leaked the case's temp dir.
  - Fixed: `eval` for `$T` was replaced by an `@T@` placeholder.
  - Fixed: README and CHANGELOG now scope the zero-findings claim to the
    shipped scripts and `tests/run.sh`. `tests/*.sh` carry 35 findings and
    are not checked.
  - No-op: per-file git identity blocks stay, since each test runs
    standalone. The overlap with `test-output-modes.sh` is partial (values
    there, shape and failures here). The per-case repo rebuild stays (about
    10s).

## Handoff

- **State.** All work is committed and pushed on
  `feature/ci-output-contract` (PR #20); CI is green; the review gate ran and its findings are fixed.
- **Open questions.**
  1. Should `init` and `rules` emit a failure document (`ok:false`, `error`,
     `hint`) on stdout under `--json`, as `release` does? Today they print
     nothing on stdout and the error on stderr. The matrix pins the current
     behavior (`gh:empty`, `handwritten:empty`); changing it is a schema
     addition and a two-cell edit in the table.
- **Not verified.** The badge renders only once `test.yml` runs on `main`,
  so it shows no status until the next release merges.
