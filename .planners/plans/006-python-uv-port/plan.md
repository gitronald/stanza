---
id: 6
slug: python-uv-port
status: draft
branch:
created: 2026-10-09T20:06:03-07:00
concluded:
pr:
---

# Research porting stanza to a Python uv tool

## Plan

This is a research plan: it records what a port of stanza from bash to a
Python CLI installed with `uv tool install` would involve, so a go/no-go
decision can be made with the costs in view. Nothing here is scheduled.

### Current shape (as of v1.1.3)

| Piece | Lines | Role |
|---|---|---|
| `bin/stanza` | 270 | global flags, lib-dir discovery, dispatch, `version`, `guide` |
| `lib/stanza-common` | 855 | output helpers (`print_*`, hand-rolled JSON), project detection, version read/write/bump for uv, VERSION, and LaTeX, README title sync, CHANGELOG promotion, git/gh wrappers, confirm prompts |
| `lib/stanza-release` | 1057 | arg parsing, prerelease flow, full / `pr` / `merge` phases, PR create and merge, local merge, tag, push retry, next dev cycle, JSON result |
| `lib/stanza-init` | 296 | `gh repo create`, `--type` scaffolding |
| `lib/stanza-rules` | 296 | render, install, uninstall, and drift-check the generated Claude Code rule |
| `install.sh` / `uninstall.sh` | 665 | copy bin, lib, and completions under a prefix; install the rule |
| `completions/` | 337 | hand-written bash and zsh completion |
| `tests/` | 2717 | six shell suites: three subprocess `bin/stanza` with a `gh` mock on `PATH`, three source `lib/` and call functions directly |

External programs it calls: `git` (everywhere), `gh` (PR and init paths
only), `uv` (`uv version`, `uv lock`, for uv projects only), and `awk`,
`sed`, `grep`, `date` for text edits (written to the BSD/macOS subset).
Runtime requirement today is bash 3.2+, so a plain VERSION or LaTeX
project needs nothing beyond bash, git, and (for PRs) gh.

### What the port would look like

**Package layout**, following the existing public uv tools by the same
author (`planners`: hatchling, typer, flat package dir, Python >= 3.11):

    pyproject.toml            # [project.scripts] stanza = "<pkg>.cli:app"
    <pkg>/
      cli.py                  # typer app: global flags, release/init/guide/rules/version
      output.py               # Reporter: verbosity tiers, --json doc, color, stdout/stderr split
      project.py              # detect_project_type, version sources (uv, VERSION, LaTeX)
      versions.py             # semver+alpha bump/validate, LaTeX vN.NN bump
      docsync.py              # README title token, CHANGELOG [Unreleased] promotion
      git.py / gh.py          # thin subprocess wrappers (quiet/verbose, timeout, capture)
      release.py              # phases: prerelease, full, pr, merge; steps as functions
      init.py, rules.py
      prompts/guide.md, prompts/rules.md   # package data (today lib/*.md)
    tests/                    # pytest

**Keep shelling out to `git`, `gh`, and `uv`.** No GitPython or PyGithub:
`gh` carries the user's auth and its JSON flags already do what stanza
needs, and staying on the same commands keeps behavior identical. `uv
version --bump` stays the version writer for uv projects; `tomllib` can
replace the grep/sed detection of `[project] version =` for reading.

**What gets simpler:**

- `json.dumps` replaces `json_escape` / `json_set_raw` / `json_emit`; the
  output contract (one JSON document on stdout, everything else on
  stderr, `-q` prints a single value) becomes one `Reporter` object
  instead of globals checked in every `print_*`.
- `re` replaces the awk programs that avoid `{n,m}` for macOS awk, and
  the BSD-sed caveats disappear.
- `subprocess.run(..., timeout=)` gives plan 003 its timeouts natively;
  exceptions with a step name give it the "name the failed step" half.
- Arg parsing: the hand-written `while/case` loops in `bin/stanza` and
  each subcommand (including the back-compat re-parse of global flags
  after the subcommand) become typer options. Accepting `-vv` counting
  and global flags in either position needs a small custom callback;
  typer's `count=True` covers `-v`/`-vv`.
- Plan 004's preflight is easier as a list of check functions run before
  the first mutating call.

**What does not get simpler:** the release flow itself (branch dance,
PR head check, atomic tag push, recovery hints) is the same logic in a
different language. Most of `stanza-release` ports line for line.

### Naming and distribution

- **`stanza` is taken on PyPI** by the Stanford NLP package (HTTP 200,
  other author, checked 2026-10-09). `uv tool install stanza` would
  install that, a real trap for anyone following the obvious command.
  Free as of the same date: `stanza-release`, `stanza-cli`,
  `stanza-tool`, `stanzas`.
- The import package should not be `stanza` either, or it shadows the
  NLP package in any environment that has both; e.g. dist
  `stanza-release`, import `stanza_release`, console script `stanza`.
- **Leading candidate: `releaseflow`** (dist and import name). It
  describes the dev -> main -> dev cycle and was free on PyPI's
  simple index on 2026-10-09. Also free that day: `releasectl`,
  `versionctl`, `tercet`. Taken (registered, with or without
  releases): `versioning`, `versioner`, `versionflow`, `semverctl`,
  `releaser`, among others. A free index entry does not guarantee
  PyPI accepts the name; confirm by registering early.
- PyPI is optional: `uv tool install git+https://github.com/gitronald/stanza`
  works without publishing. If publishing, the proj-template publish
  workflow is gated on the `PUBLISH_ENABLED` repo variable.
- `uv tool install` / `uv tool upgrade` / `uv tool uninstall` replace
  `install.sh` and `uninstall.sh`, and make plan 001 (curl installer)
  moot. The lib-dir discovery in `bin/stanza` goes away;
  `importlib.metadata.version()` replaces reading `VERSION`.

### Rules, skills, and completions

- `stanza rules install|uninstall|check` could move onto `pkgskills`
  (public), as `planners` does: it already provides version-stamped
  rule copies, a drift check, and `<cli> skill <name>`, which is what
  `lib/stanza-rules` implements by hand. The repo-local
  `bump-version` skill could ship the same way. Cost: the stamp line
  format changes, so existing installed rule files read as foreign
  until reinstalled (needs a migration note or a one-time
  recognize-old-marker path).
- `stanza guide` becomes printing package data.
- Completions: typer can generate them (`--install-completion`), but
  the output differs from the hand-written files and covers bash, zsh,
  and fish. Either accept typer's, or keep the hand-written files and
  install them some other way (uv tool installs do not place
  completion files).

### Tests

- The three subprocess suites (`test-release-workflow.sh`,
  `test-output-modes.sh`, `test-rules.sh`) are a ready parity oracle:
  point `STANZA` at the Python entry point and they check the port
  against today's behavior, `gh` mock and all. Run them against both
  implementations until the bash one is deleted.
- The three function-level suites (`test-version-bumps.sh`,
  `test-version-file-detection.sh`, `test-latex-versioning.sh`) source
  `lib/` and must be rewritten as pytest; they are pure functions, so
  they port cleanly to parametrized tests (and hypothesis for the bump
  rules).
- Plan 005's output-mode matrix becomes a `pytest.mark.parametrize`
  over verbosity x mode x outcome; its bash 3.2 job is moot.

### Costs and risks

1. **New runtime requirement.** Every user needs uv (and a Python uv
   can fetch). Today a VERSION-file or LaTeX project needs only bash.
   For an author whose projects are mostly uv already this is small;
   for a bash-only user it is a real regression.
2. **Output parity is a contract.** Agents and the generated rule rely
   on exact commit subjects (`version [patch]: X`, `version [release]:
   vX - PR #N`), the JSON keys, and `-q` single-value output. The
   subprocess suites guard most of it; the human text rows will drift
   unless pinned.
3. **Interactive prompts** (`read -p`, `confirm_step`) and `set -e`
   semantics must be reproduced deliberately: every step that bash
   lets fail with `|| true` needs an explicit choice in Python.
4. **Startup time:** a typer CLI imports in roughly 100-200 ms versus
   near-zero for bash. Irrelevant for a release tool.
5. **Self-hosting transition.** stanza releases itself from a VERSION
   file. The port switches it to a pyproject version, so the release
   that lands the port is cut by the installed bash stanza (its uv
   path already handles that), and the version is continued rather
   than reset.
6. **Parallel maintenance** while both exist; keep the window short.

### Migrating existing installs and consumers

- **Executable collision.** `install.sh` puts a plain `stanza` script
  in `~/.local/bin`, which is also where `uv tool install` puts tool
  executables. If the console script stays `stanza`, uv is expected
  to refuse to overwrite an executable it did not install (needs
  `--force`; not verified here). The upgrade path is `./uninstall.sh`
  first, then `uv tool install`; the README and release notes should
  say so, and the last bash release could print a notice.
- **Downstream references.** Other repos document `stanza release ...`
  commands and stanza's commit subjects: proj-template's README,
  CLAUDE.md, and skills mention it, and the generated rule
  (`~/.claude/rules/stanza.md`) is read by agents in every repo. A
  renamed console script means updating those sources and
  reinstalling the rule; keeping `stanza` as the command avoids all
  of it. Either way the commit-subject formats must not change.

### Rough sequence if it goes ahead

1. Scaffold the uv project beside the bash code (pyproject, package,
   pytest, ruff, pyrefly); pick the dist and import names.
2. Port pure logic first: `versions.py`, `project.py`, `docsync.py`,
   with the function-level suites rewritten as pytest.
3. Port `output.py`, `git.py`, `gh.py`, then `version`, `guide`,
   `rules`, `init`, and `release`; run the subprocess shell suites
   against the Python entry point until they pass.
4. Switch the repo's own version source to pyproject, update README
   install docs to `uv tool install`, delete `bin/`, `lib/`,
   `install.sh`, `uninstall.sh`; retire or rewrite plans 001 and 005.
5. Release as a major version (install method and requirements change).

Size estimate: about 2,900 lines of bash should land near 1,500-2,000
lines of Python plus tests; a few focused sessions, dominated by the
release flow and by chasing parity in the shell suites.

### Open questions

1. Is requiring uv for VERSION-file and LaTeX projects acceptable?
   This is the deciding question; everything else is mechanics.
2. Distribution name (leading candidate `releaseflow`; see Naming)
   and whether to publish to PyPI at all or install from git. If the
   dist is `releaseflow`, does the console script stay `stanza` (keeps
   muscle memory, rule text, and commit-format docs) or become
   `releaseflow`?
3. Adopt `pkgskills` for rules and the bump-version skill, or keep the
   hand-written rules logic?
4. Typer-generated completions, or keep the hand-written ones?
5. Pursue plans 001, 003, 004, and 005 in bash first, or hold them for
   the port (003 and 004 get cheaper in Python; 001 and 005's bash 3.2
   job become moot)?

### Recommendation

The port is feasible and mostly mechanical; the gains are maintainability
(real JSON, no awk/sed portability, typed steps, timeouts) and a standard
install path. Decide question 1 first. If uv-for-everyone is fine, hold
plans 001 and 005 and do the port before them, since both are partly
undone by it.

## Log

- **2026-10-09T20:06:03-07:00** — Research pass. Read `bin/`, `lib/`,
  `install.sh`, and the test harnesses; compared against the layout of
  `planners` and `pkgskills`. Checked PyPI names against the simple
  index (the JSON API returns 404 for a registered name with no
  releases, so it is not a reliable availability check): `stanza`,
  `versioning`, and `versioner` are taken; `releaseflow` chosen as the
  leading candidate. Plan left uncommitted as a draft.
