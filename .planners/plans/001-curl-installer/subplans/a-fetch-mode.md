---
status: done
branch:
---

# Install from the tag archive when piped

Part of [Add a one-line install path that does not require a clone](../plan.md).

## Plan

Option B from the umbrella, as the umbrella's Recommendation laid it out:

1. Refactor `install.sh` so all code is inside functions and the last line is
   `main "$@"`. This is the partial-download guard and costs nothing. Most of
   the script is already structured this way.
2. Add `--yes` (skip the confirmation) and `--version <tag>` flags.
3. Add a fetch mode: when `bin/stanza` is not next to the script, download
   `archive/refs/tags/<tag>.tar.gz` to `mktemp -d`, extract, and set
   `SCRIPT_DIR` to the extracted root so `install_files` and
   `install_completions` work unchanged. Clean the temp dir in an `EXIT` trap.
   Resolve the default tag from the GitHub API, with the `VERSION` file as a
   fallback when the API call fails.
4. When stdin is not a terminal and `--yes` was not given, read the
   confirmation from `/dev/tty` if it exists, else fail with a message that
   names `--yes`. Do not default to yes silently.
5. README: lead with the one-liner, show the pinned form, and give the
   "download, read, then run" alternative right next to it.
6. Keep the clone instructions as the development path.

### Verification

- Fresh container with only `curl`, `bash`, `git`, `gh`, and `uv`: the
  one-liner installs, `stanza --version` matches the latest tag, completions
  land, and the temp dir is gone afterwards.
- `--version v1.1.1` installs that version's `VERSION` file.
- Simulate truncation: `head -c 2000 install.sh | bash` must do nothing.
- Piped with no `--yes` and no tty: exits non-zero with the hint; with
  `--yes`: installs.
- The clone path (`./install.sh` inside a checkout) behaves exactly as before.

## Log

- **2026-10-10T11:38:17-07:00** — Implemented option B (commits `c2941fd`, `d5b4419`).
  - `install.sh`: fetch mode, `-y/--yes`, `--version[=]TAG` (also
    `STANZA_VERSION`), and `STANZA_REPO_URL` (defaults to the GitHub repo;
    exists so tests can point at a local stand-in). Fetch mode runs when the
    script is not a file inside a checkout, or when a version is given (so
    `./install.sh --version 1.0.0` from a checkout downloads that tag). The
    archive goes to `mktemp -d` and is removed by an `EXIT` trap.
  - Deviation: the default tag comes from `git ls-remote --tags` (highest
    `vX.Y.Z` with no prerelease suffix, compared numerically), not the GitHub
    API. The repo has tags but no GitHub releases, so `releases/latest` 404s,
    and git is already a required dependency with no API rate limit. There is
    no `VERSION` fallback: a piped script has no local `VERSION`, and when
    ls-remote cannot reach GitHub the archive download would fail too. The
    error names `--version` instead.
  - Confirmation reads the terminal (`/dev/tty`) only when the script itself
    arrived on stdin. Run from a file, it reads stdin as before, so
    `printf y | ./install.sh` (used by `tests/test-rules.sh`) keeps working.
    The first cut used `/dev/tty` whenever stdin was not a terminal, and it
    broke that suite.
  - Found while testing: inside a function, a piped script's
    `BASH_SOURCE[0]` is `bash`, not empty. The script path is now read once at
    top level (`SCRIPT_PATH`), so a file named `bash` in the working
    directory cannot pass for a checkout.
  - README leads with the one-liner, the pinned and `--yes` forms, and the
    download-read-run alternative. It says that only TLS checks the download.
    The clone path is kept as "From a Clone". Also added: uninstall without a
    clone (download `uninstall.sh`, run it; checked to work outside a checkout).
  - Verification: the new `tests/test-install.sh` (29 checks, offline, uses
    a `file://` stand-in remote) covers the clone path, piped latest
    (prerelease ignored, `1.10.0` > `1.9.0`), pins by flag and env, temp-dir
    cleanup, a missing tag, an invalid tag, an unreachable remote, piping
    with no terminal and no `--yes`, `printf y|n` from a file, and
    truncation at every 97th byte up to the last line. A scratch mutant with
    a mid-file call confirmed that the truncation check can fail. All 8
    suites pass. By hand: piped against the real GitHub repo installed
    v1.1.3 with completions; under a pty, a piped run without `--yes`
    prompted on the terminal and installed.
  - Not verified: the fresh-container run from the plan's Verification
    section. The checks ran in temp `HOME`/`TMPDIR` directories on a
    machine that already had git, gh, and uv.
- **2026-10-10T12:32:48-07:00** — Review fixes (commit `1f85050`). Codex
  drafted a code and security review of the PR; the main session checked
  each finding and made the fixes.
  - `--version=` with an empty value now errors. Before, it read as "no
    version" and installed latest (or the checkout), overriding
    `STANZA_VERSION`.
  - The last line is `{ main "$@"; }`. A cut inside the braces is a syntax
    error, which closes the gap the Handoff listed (a cut after `main` ran it
    with the arguments dropped).
  - curl gets `--proto-redir '=https'`, so a redirect off HTTPS is refused.
    The wget fallback is unchanged: BusyBox wget has no `--https-only`.
  - Tests: an empty-pin case, and truncation now cuts at every byte of the
    last line and checks for main's banner, not only for an install. A copy
    with the old code fails 4 checks (the 3 empty-pin checks and the
    truncation check at the cut after `main`); the real tree passes 32/32,
    and `tests/test-rules.sh` 115/115.
  - Not changed, by judgment: archive symlinks (a payload with them can
    already run code via `bin/stanza`), and stale `lib/` files on upgrade
    (predates the PR; `bin/stanza` sources its libraries by name).
- **2026-10-10T12:38:36-07:00** — One-liner hardening (commit `1dd1178`).
  Every curl line that fetches the installer or uninstaller (README,
  `install.sh --help`, CHANGELOG) now starts `curl --proto '=https'
  --tlsv1.2 -fsSL`, and the README says what the flags do. Checked that
  curl refuses a non-HTTPS URL with them; not run against GitHub.
