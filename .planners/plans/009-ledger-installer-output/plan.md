---
id: 9
slug: ledger-installer-output
status: active
branch: feature/ledger-installer-output
created: 2026-10-10T13:53:07-07:00
concluded:
pr:
---

# Restyle installer output in the ledger row grammar

## Plan

### Motivation

`install.sh` and `uninstall.sh` print in a Homebrew-like `==>` style that no
other stanza command uses, and they have problems that show up on macOS:

- Color is never gated. Piped to a file or a CI log, every line carries raw
  escape codes. `lib/stanza-common` already gates on `NO_COLOR`, `--no-color`,
  and `[ -t fd ]`; the installers do not.
- The PATH warning, the one line a Mac user must act on (`~/.local/bin` is not
  on PATH by default), is bold yellow. With Terminal's "Use bright colors for
  bold text" on, that is bright yellow on the Basic profile's white: 1.3:1.
- The PATH hint names `~/.bashrc, ~/.zshrc, etc.` instead of the user's shell.
  macOS defaults to zsh, and login bash on macOS reads `~/.bash_profile`.
- The `━` rules print whatever the locale.
- A successful install prints 49 lines; each step has a start and a done line.
  A checksum mismatch does not say that nothing was installed or what to do.
- `uninstall.sh` uses `echo -e`, which differs between shells.

### Decision

Adopt direction B, "Ledger", from the mockups in
[artifacts/installer-styles.html](artifacts/installer-styles.html) (open it in
a browser; the bar at the top switches the Terminal profile, piped/NO_COLOR,
and a non-UTF-8 locale). The installer uses the same row grammar as
`stanza release`: a bold `stanza install  (v1.2.1, ~/.local)` header, then
two-space-indented rows with an 8-column dim label (`LABEL_WIDTH`) and the
content beside it. Color sits on the label only (`warn` yellow, `hint` cyan,
`error` red, `done` green), so the word carries the meaning and a weak hue on
one profile costs nothing.

Target output for a fresh install on macOS:

```
stanza install  (v1.2.1, ~/.local)
  source  github.com/gitronald/stanza, release v1.2.1
  bin     ~/.local/bin/stanza
  lib     ~/.local/lib/stanza
  bash    ~/.local/share/bash-completion/completions/stanza
  zsh     ~/.local/share/zsh/site-functions/_stanza
  rule    ~/.claude/rules/stanza.md

  Install stanza 1.2.1? [Y/n] y

  fetch   stanza-1.2.1.tar.gz
  verify  sha256 3f9a0c51d2e7b8a4
  files   ~/.local/bin/stanza, ~/.local/lib/stanza
  bash    ~/.local/share/bash-completion/completions/stanza
  zsh     ~/.local/share/zsh/site-functions/_stanza
  rule    ~/.claude/rules/stanza.md
  warn    ~/.local/bin is not on your PATH
  hint    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
  done    stanza 1.2.1. Open a new terminal, then run: stanza --help
```

And for a checksum mismatch (stderr):

```
  fetch   stanza-1.2.1.tar.gz
  error   sha256 mismatch for stanza-1.2.1.tar.gz; nothing was installed
          expected 3f9a...
          actual   b7d2...
  hint    retry; if it fails again: github.com/gitronald/stanza/issues
```

### macOS-safe constraints

- bash 3.2: no `declare -A`, `${x,,}`, `mapfile`, `&>>`, `|&`, `${a[-1]}`,
  `printf '%(...)T'`; no `"${arr[@]}"` on an empty array under `set -u`.
- 16 basic ANSI colors (SGR 30-37), bold and dim only. No 256-color or
  24-bit codes, no `tput` dependency, no cursor movement, spinners, `\r`
  redraws, or `tput cols`.
- `printf`, never `echo -e`/`echo -n`.
- Color gate per fd: off under `NO_COLOR`, `--no-color`, `TERM=dumb`, or a
  non-TTY fd; on under `CLICOLOR_FORCE` (non-zero). stdout rows check `-t 1`,
  `error`/`hint`/`warn` rows go to stderr and check `-t 2`. `curl | bash` pipes
  stdin only, so `-t 1` still sees the terminal.
- No non-ASCII glyphs in the output (drop the `━` rules), so no locale check
  is needed.
- Paths under `$HOME` print as `~` via a `case "$1" in "$HOME"/*)` helper,
  not `${1/#$HOME/~}`, whose tilde handling varies by bash version.
- Lines stay under about 76 columns where content allows.

### Approach

1. **Helper.** `install.sh` cannot source `lib/stanza-common` in fetch mode
   (it runs before the download), so it carries its own small copy: a color
   gate and `row label content [fd] [sgr]`, plus `header` and `tilde`. Keep
   the label width and colors identical to `print_row`, `print_hint`, and
   `print_done`, and note in both files that they must stay in step. Step 7
   adds a test that enforces it.
   `uninstall.sh` runs from an installed or checked-out tree, so check whether
   it can source `lib/stanza-common` instead of copying.
2. **install.sh.** Replace `info`/`success`/`warn`/`error` call sites with
   rows: one row per step, no start/done pairs. Collapse the configuration
   block into `source`/`bin`/`lib`/`bash`/`zsh`/`rule`. Every installed file
   is spelled out by its full path, both in the pre-prompt block and in the
   step rows, never summarized as "completions" or "Claude Code rule". The
   pre-prompt block resolves the same destination the install step will use:
   the `$PREFIX/share/...` completion directories when writable, otherwise
   `~/.bash_completion.d/stanza` and `~/.zsh/completions/_stanza`. A row is
   omitted when its file will not be installed (`--no-completions`,
   `--no-rules`, `~/.claude` missing, a system install), and the `rule` row
   is followed by a `hint` naming `stanza rules install` when skipped for a
   reason the user can change. Rewrite the end: drop the banner,
   "Installation details", and "Next steps" in favor of the `warn`/`hint`
   PATH rows (only when needed) and one `done` row.
3. **Shell-aware PATH hint.** Pick the startup file from `${SHELL##*/}` and
   `uname -s`: zsh -> `~/.zshrc`; bash -> `~/.bash_profile` on Darwin,
   `~/.bashrc` elsewhere; fish -> `fish_add_path ~/.local/bin`; anything else
   falls back to naming the export line. Same treatment for the completion
   hints when the fallback paths are used: a `hint` row after the `zsh` row
   gives `fpath=(~/.zsh/completions $fpath)` for `~/.zshrc`, and one after the
   `bash` row gives the `~/.bash_completion.d` source loop for the bash
   startup file.
4. **Errors.** Every `error` row says whether anything was installed and is
   followed by a `hint` row with the next step, matching `print_hint`.
5. **`--no-color`.** Add the flag to `install.sh` and `uninstall.sh` for
   parity with the CLI.
6. **uninstall.sh.** Same grammar: `stanza uninstall  (~/.local)` header,
   rows for each removed path, a `done` row.
7. **Tests.** Update `tests/test-install.sh` assertions that match old
   strings (`Source:`, `Downloading stanza v...`, `Checksum mismatch for`,
   `Verified`, `Could not download ...`). Add cases: piped output contains no
   ESC byte; `NO_COLOR=1` under a pseudo-TTY contains none either (if a PTY is
   available in the test harness; otherwise test the gate function directly);
   the PATH hint names `~/.zshrc` for `SHELL=/bin/zsh` and `~/.bash_profile`
   for bash on Darwin (stub `uname`). Add a drift test that sources
   `lib/stanza-common` and the installer's helper (or extracts it) and
   asserts the same label width and the same SGR codes for the dim label,
   `warn`, `hint`, `error`, and `done`, so the two copies cannot diverge
   unnoticed.
8. **Docs.** Add a CHANGELOG `[Unreleased]` entry. The README, CHANGELOG,
   and `lib/stanza-guide.md` show no installer output today, so there are no
   examples to update.

### Verification

- `tests/test-install.sh` and the rest of `tests/` pass.
- Run the installer from a checkout and in fetch mode (local repo URL) and
  compare against the mockup, in a TTY and piped through `cat -v`.
- On macOS, run under `/bin/bash` 3.2 in Terminal's Basic and Pro profiles.
  This needs a Mac and is carried by plan 010, which reviews this plan's
  outcome on a Mac after it merges.

### Accepted trade-offs

- **Yellow `warn` label on Terminal's Basic profile (2.4:1 on white).** Kept
  yellow for consistency with `print_warning` and the CLI's other output.
  The label word carries the meaning and the content beside it is the
  default foreground, so the low-contrast hue is a second cue, not the only
  one. The label is never bold, which would turn it bright yellow (1.3:1)
  when Terminal brightens bold text. Revisit in plan 010 if it reads poorly
  on a real Mac.

### Out of scope

- Changing what the installer does (sources, checksums, prompts, flags other
  than `--no-color`).
- Restyling `stanza release`/`init`/`rules` output; the installer conforms to
  it, not the reverse.
- Directions A (Homebrew, tidied) and C (checklist) from the mockups, kept in
  the artifact for reference.

## Log

- **2026-10-10T14:04:05-07:00** — Activated.
  - Branch: `feature/ledger-installer-output`
  - Base: `dev` at `3ef5fc1`
  - Worktree: `.worktrees/ledger-installer-output`
  - PR: pending
