---
id: 5
slug: ci-output-contract
status: draft
branch:
created: 2026-10-09T18:49:08-07:00
concluded:
pr:
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

### Order

2 -> 1 -> 3 -> 4. The runner first, since both the matrix and CI call it.
