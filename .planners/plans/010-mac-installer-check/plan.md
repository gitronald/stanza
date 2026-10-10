---
id: 10
slug: mac-installer-check
status: active
branch: feature/mac-installer-check
created: 2026-10-10T13:59:48-07:00
concluded:
pr:
---

# Check the ledger installer output on macOS

## Plan

### Goal

Plan 009 restyles `install.sh` and `uninstall.sh` in the ledger row grammar
and sets macOS-safe constraints, but its checks run on Linux. This plan
reviews what 009 shipped against its mockup and its constraints, and runs the
installer on a real Mac. Start it after 009 merges; it needs someone with a
Mac.

### Review the outcome of 009

- Compare the installer's output with the ledger panes in
  [009's mockup](../009-ledger-installer-output/artifacts/installer-styles.html),
  for a fresh install and a checksum mismatch.
- Read the diff of 009 against its constraint list: bash 3.2 syntax, 16
  colors only, `printf` not `echo -e`, no glyphs, no cursor movement, the
  color gate per fd, and the `~` helper.
- Confirm the drift test from 009 step 7 exists and fails when one copy of
  the label width or a color code changes.

### Run on a Mac

Run each case with `/bin/bash` (check `bash --version` reports 3.2) from a
fresh user account or with `HOME` pointed at an empty directory, so
`~/.local` and `~/.claude` start clean. Use the one-line `curl | bash`
install against the released tag, and a checkout's `./install.sh`.

| Case | What to check |
|---|---|
| Terminal, Basic profile | All rows readable; `warn` label legible; no bright yellow |
| Terminal, Pro profile | Dim labels and `done`/`hint` readable on black |
| "Use bright colors for bold text" on and off | Bold header unaffected; no bold colored labels |
| iTerm2, default theme | Same output as Terminal |
| Piped: `... \| bash > log; cat -v log` | No `^[[` sequences |
| `NO_COLOR=1` in a TTY | No color |
| `CLICOLOR_FORCE=1` piped | Color present |
| `TERM=dumb` | No color, no `tput` errors |
| `LANG=C` | Output unchanged, no mojibake |
| `SHELL=/bin/zsh` (default) | PATH hint names `~/.zshrc` |
| `SHELL=/bin/bash` | PATH hint names `~/.bash_profile` |
| `~/.local/share` missing | Fallback completion paths shown before the prompt and in rows, with `hint` rows |
| No `~/.claude` | No `rule` row; hint names `stanza rules install` |
| Checksum mismatch (point `STANZA_REPO_URL` at a copy with a bad `.sha256`) | `error` and `hint` on stderr; nothing installed |
| `uninstall.sh` | Same grammar; every removed path named |
| Apple silicon and Intel, if both are available | No difference expected |

Then follow the PATH hint as printed, open a new terminal, and confirm
`stanza --help` runs and tab completion works in zsh.

### Record

Log each case's result in this plan with the macOS version, the terminal
and its version, and `bash --version`. Save screenshots of the Basic and Pro
runs under `artifacts/` (drop the user name and machine name from window
titles first; this repo is public).

### Decide

- If the yellow `warn` label (009's accepted trade-off) reads poorly on
  Basic, pick another treatment and change it in the installer and in
  `lib/stanza-common` together, so the drift test stays green.
- Fix small defects on a branch from this plan. Anything larger becomes its
  own plan.

### Out of scope

- Linux and WSL checks, which 009's tests already cover.
- Restyling other stanza commands.
