---
id: 10
slug: mac-installer-check
status: done
branch: feature/mac-installer-check
created: 2026-10-10T13:59:48-07:00
concluded: 2026-10-10T17:29:47-07:00
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
`SHELL=/bin/zsh`. The tty cases ran with `HOME` at an empty directory, under a
pty from BSD `script`, installing release v1.2.1 through the checkout's
`install.sh --version=1.2.1`; raw captures are in `artifacts/macos-runs.txt`.

| Case | Result |
|---|---|
| Terminal, Basic profile | Rendered from the capture with Terminal's default palette (no Screen Recording grant for the shell, so no real screenshot). `warn` is ANSI yellow `#999900` on white: legible, not bright yellow |
| Terminal, Pro profile | Same rendering on black; dim labels, `done`, and `hint` readable |
| Bright colors for bold | Header is bold with no color, and no label is bold (`SGR_WARN='0;33'`, test `warn: not bold`); nothing for the setting to change |
| iTerm2 | Not installed on this Mac; not run |
| Piped, `cat -v` | No `^[[` sequences; 18 rows, exit 0 |
| `NO_COLOR=1` in a tty | No color |
| `CLICOLOR_FORCE=1` piped | Color present |
| `TERM=dumb` | No color, no `tput` errors on stderr |
| `LANG=C` | Byte-identical to the default run |
| `SHELL=/bin/zsh` | `hint    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc` |
| `SHELL=/bin/bash` | Same hint ending in `~/.bash_profile` |
| `~/.local/share` missing | `~/.bash_completion.d/stanza` and `~/.zsh/completions/_stanza` named before the prompt and in the rows, each followed by its `hint` (the zsh one with a continuation row) |
| No `~/.claude` | No `rule` row; `hint    no ~/.claude, so no rule; to add it later: stanza rules install` |
| `~/.local/share` and `~/.claude` present | Completions under `~/.local/share`, `rule    ~/.claude/rules/stanza.md`, no completion or rule hints |
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
- One small fix on this branch: the installer test suite now runs its
  three pty color cases under BSD `script` on Darwin, so the suite passes
  107 on macOS instead of skipping them.
- Real Terminal screenshots need a Screen Recording grant for the shell
  that runs `screencapture`; the renderings stand in until then.

### 2026-10-10: review follow-up

Reviewed PR #13 before merging. Raised and actioned:

- The BSD `script` fallback had landed in `tests/test-install.sh` only,
  while `tests/test-output-modes.sh` kept the util-linux-only gate, so its
  four `stanza release` pty color cases still skipped on a Mac. Both suites
  now source `tests/pty.sh`, which defines `in_pty` once, probes the
  `script` dialect by running it instead of checking `uname -s`, and strips
  the CR and echoed EOF bytes BSD `script` adds so both dialects return the
  same bytes for the color assertions. On this Mac the output-modes suite
  passes 50 with those four cases running, and the installer suite 107.
- The comment on the `/dev/null` redirect gave the wrong reason. BSD
  `script` opens a pty regardless of stdin; the redirect keeps it from
  raw-moding the suite's own terminal. Comment rewritten in the helper.
- The piped-case row said 20 rows; the capture has 18. Corrected.

Conscious no-ops:

- The two PNG renderings stay committed. The plan asks for images of the
  Basic and Pro runs, and the HTML mockup from 009 already shows the
  palette-free version.
- The raw capture file keeps its byte-identical duplicate blocks and the
  `file:///tmp/badrepo` URL. It is a verbatim capture, and `/tmp` names no
  user or machine.

### Remaining

Not done here, and not blocking the close. Pick up on a Mac with the
grants or hardware available:

- Real Terminal screenshots of the Basic and Pro profiles, with the
  "Use bright colors for bold text" setting toggled live, once the shell
  has a Screen Recording grant or by capturing by hand.
- iTerm2 (not installed here) and an Intel Mac (not available).
- The `curl | bash` one-liner from `main`, once the next release puts the
  ledger installer on `main`.

## Retrospective

- Nearly everything 009 constrained held on a real Mac without change:
  bash 3.2, the color gate, the PATH hint by shell, the fallback completion
  paths, and the checksum failure path all matched the mockup.
- The one real gap was test coverage, not the installer: the pty color
  cases had only ever run on Linux. Fixing that in one suite and not the
  other is exactly the drift the review caught, and a shared helper was
  the right altitude for the fix.
- Probing a tool's dialect by running it beat keying on the OS name. It
  covers FreeBSD for free and does not lie when a different `script` is
  first on `PATH`.
- Captures through `cat -v` were enough evidence for every case but the
  visual ones. For those, renderings stand in, and the plan should have
  said up front what to do when a screenshot cannot be taken from the
  shell.
- The 009 trade-off on the yellow `warn` label survived contact with the
  Basic profile, so no palette change was needed.

### 2026-10-10: post-merge review addendum

The review's late findings landed after PR #13 merged and were fixed on
`dev`:

- The shared `in_pty` piped `script` into `tr`, so the child's exit
  status was lost on macOS, and its `tr -d '\004'` never matched the
  echoed EOF, which the pty prints as the two characters `^D`. The BSD
  wrapper now runs under `pipefail` and strips the literal `^D` prefix.
- The capture file's header claimed raw captures with an empty `HOME` in
  every case. It now says the CRs and echoed EOF were removed, that the
  piped blocks are file redirections, and which cases seeded `HOME`. A
  stray `exit 0` line was dropped, and the method sentence and the
  seeded-`HOME` row above were corrected to match.
