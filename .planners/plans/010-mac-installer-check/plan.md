---
id: 10
slug: mac-installer-check
status: active
branch: feature/mac-installer-check
created: 2026-10-10T13:59:48-07:00
concluded:
pr: https://github.com/gitronald/stanza/pull/13
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

## Log

### 2026-10-10: review of 009

- Mockup comparison: the fresh-install and checksum-mismatch runs match
  the ledger panes (bold header, dim labels, cyan `hint`, yellow `warn`,
  red `error`, green `done`, continuation rows indented under the label).
  See `artifacts/rendered-terminal-basic.png` and `-pro.png`.
- Constraints: grepped `install.sh` and `uninstall.sh` for `echo -e`,
  `tput`, cursor movement, 256-color SGRs, non-ASCII bytes, and bash 4
  constructs (`declare -A`, `${x,,}`, `mapfile`, `|&`). None found. Color
  is gated per fd by `use_color`, and `tilde` folds `$HOME`.
- Drift test: changing `LABEL_WIDTH` in `uninstall.sh` fails 4 assertions;
  changing `SGR_HINT` in `install.sh` fails 2. Both restored.
- `tests/test-install.sh` under `/bin/bash` 3.2.57: 104 passed, 1 skip
  (the pty color cases, which only knew util-linux `script`).

### 2026-10-10: runs on a Mac

macOS 26.6.2, Apple silicon, `/bin/bash` 3.2.57(1)-release, Terminal 2.15,
`SHELL=/bin/zsh`. Each case ran with `HOME` at an empty directory, under a
pty from BSD `script`, installing release v1.2.1 through the checkout's
`install.sh --version=1.2.1`; raw captures are in `artifacts/macos-runs.txt`.

| Case | Result |
|---|---|
| Terminal, Basic profile | Rendered from the capture with Terminal's default palette (no Screen Recording grant for the shell, so no real screenshot). `warn` is ANSI yellow `#999900` on white: legible, not bright yellow |
| Terminal, Pro profile | Same rendering on black; dim labels, `done`, and `hint` readable |
| Bright colors for bold | Header is bold with no color, and no label is bold (`SGR_WARN='0;33'`, test `warn: not bold`); nothing for the setting to change |
| iTerm2 | Not installed on this Mac; not run |
| Piped, `cat -v` | No `^[[` sequences; 20 rows, exit 0 |
| `NO_COLOR=1` in a tty | No color |
| `CLICOLOR_FORCE=1` piped | Color present |
| `TERM=dumb` | No color, no `tput` errors on stderr |
| `LANG=C` | Byte-identical to the default run |
| `SHELL=/bin/zsh` | `hint    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc` |
| `SHELL=/bin/bash` | Same hint ending in `~/.bash_profile` |
| `~/.local/share` missing | `~/.bash_completion.d/stanza` and `~/.zsh/completions/_stanza` named before the prompt and in the rows, each followed by its `hint` (the zsh one with a continuation row) |
| No `~/.claude` | No `rule` row; `hint    no ~/.claude, so no rule; to add it later: stanza rules install` |
| `~/.local/share` and `~/.claude` present | Completions under `~/.local/share`, `rule    ~/.claude/rules/stanza.md`, no hints |
| Checksum mismatch (`STANZA_REPO_URL` at a `file://` copy with a zeroed `.sha256`) | `error`, expected/actual continuation rows, and `hint` on stderr; stdout stops after `fetch`; exit 1; `HOME` still empty |
| `uninstall.sh` | Header `stanza uninstall  (~/.local)`, a row per path before and after, `done    stanza uninstalled; 5 items removed`; a second run reports `error   no stanza installation found` on stderr, exit 1 |
| Intel | Not available |

After the clean install, the installed binary ran (`stanza 1.2.1`) and
`_stanza` autoloaded in `zsh -f` with the hinted `fpath` line. The
`curl | bash` line from `main` was not used: `main` still serves 009's
predecessor until the next release, so the piped case fed the checkout's
`install.sh` on stdin instead, which takes the same download path.

The real reinstall on this machine, from the checkout with
`--version=1.2.1`, went from stanza 1.1.0 to 1.2.1 and regenerated
`~/.claude/rules/stanza.md`.

### Decisions

- `warn` stays yellow: Terminal's non-bold ANSI yellow is dark enough on
  the Basic profile's white, so 009's trade-off holds.
- One small fix on this branch: `tests/test-install.sh` now runs its
  three pty color cases under BSD `script` on Darwin, so the suite passes
  107 on macOS instead of skipping them.
- Real Terminal screenshots need a Screen Recording grant for the shell
  that runs `screencapture`; the renderings stand in until then.
