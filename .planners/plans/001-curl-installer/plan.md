---
id: 1
slug: curl-installer
status: done
branch: feature/curl-installer
created: 2026-10-08T17:47:56-07:00
concluded: 2026-10-10T13:16:25-07:00
pr: https://github.com/gitronald/stanza/pull/9
---

# Add a one-line install path that does not require a clone

## Plan

### Motivation

Installing stanza today means cloning the repository and running `./install.sh`
from inside the checkout. The installer copies `bin/stanza`, `lib/`,
`completions/`, and `VERSION` relative to its own location, so it cannot run
from anywhere else. That is three steps and a leftover checkout for a tool that
is a handful of bash files, and it is more than peers ask: uv, rustup, nvm, and
the GitHub CLI's own installers are each one line.

A provisioning script that installs stanza alongside those tools has to special
case it: pick a clone location, decide whether to `git clone` or `git pull` on a
rerun, and keep the checkout around (or delete it and lose the upgrade path).
A one-line installer removes that whole branch of logic, and makes upgrades a
rerun of the same line.

The clone path should stay. It is the right one for development, and for anyone
who wants to read what they are about to run.

### Subplans

<!-- planners:subplans:start -->
| Subplan | Scope | Status | Note |
|---|---|---|---|
| [a](subplans/a-fetch-mode.md) | Install from the tag archive when piped | done |  |
| [b](subplans/b-verified-release-download.md) | Verify the installer's download with a checksummed release asset | done |  |
<!-- planners:subplans:end -->

### Options

Four ways to get the files onto a machine without a persistent checkout, in
rough order of how much they change.

#### A. Document a throwaway clone

No code change. The README gains:

```bash
git clone --depth 1 https://github.com/gitronald/stanza /tmp/stanza && /tmp/stanza/install.sh && rm -rf /tmp/stanza
```

- Pro: zero new surface area; the installer is unchanged and still reviewable.
- Pro: `git` verifies object integrity, and over HTTPS the transport is
  authenticated by GitHub's certificate.
- Con: still a long line, still needs `git`, and `rm -rf` in a copy-paste
  command is unfriendly. It is a workaround, not an install path.
- Con: no way to pin a version short of adding `--branch vX.Y.Z`.

#### B. Make `install.sh` fetch its own payload (`curl | bash`)

Teach `install.sh` to notice when it is not inside a checkout (no `bin/stanza`
next to it, which is already checked in `install_files`) and, in that case,
download a tarball of the repo to a temp dir, extract it, and continue with the
existing copy logic from there. Then the install line is:

```bash
curl -fsSL https://raw.githubusercontent.com/gitronald/stanza/main/install.sh | bash
```

The tarball comes from GitHub's archive endpoint,
`https://github.com/gitronald/stanza/archive/refs/tags/v<version>.tar.gz`, with
the version taken from a `--version` flag or `STANZA_VERSION`, defaulting to the
latest tag (resolved with one API call to `releases/latest` or `tags`, or by
pinning the default in the script at release time).

- Pro: the one-line install people expect; same script handles both modes, so
  the clone path and the curl path cannot drift apart.
- Pro: version pinning falls out naturally (`--version 1.1.1`), which the clone
  path does not offer today.
- Con: `curl | bash` is the pattern security reviewers dislike, for concrete
  reasons covered below. Mitigations exist but are the bulk of the work.
- Con: the installer runs with stdin consumed by the pipe, so the interactive
  `Continue? [Y/n]` prompt reads EOF. The script needs a `--yes` flag (useful
  regardless) and must detect the piped case and either default to yes or read
  from `/dev/tty`.
- Con: two network round trips (script, then archive), and the archive endpoint
  is GitHub generating a tarball on the fly, so its checksum is not stable
  across GitHub infrastructure changes. That rules out hard-coding a tarball
  checksum unless the archive is published as a release asset (see C).

#### C. Publish a release asset and verify it

Add a `release` step that builds `stanza-<version>.tar.gz` from the tagged
tree, computes a SHA-256, and uploads both as GitHub release assets (`gh release
create`). `install.sh` in curl mode then downloads the asset and its checksum
and refuses to continue on mismatch. Optionally sign the checksum file (minisign
or ssh-keygen -Y) with a key whose public half is committed in the repo and
printed in the README.

- Pro: the only option where the installer can verify what it downloaded
  against something other than the download itself. A stable artifact also
  means `install.sh` can be pinned to a version and reproduced.
- Pro: fits stanza's own domain. The tool already owns the tag and the release
  merge; building and uploading an asset at that moment is one more step in
  `stanza release`, and would be a feature other repos using stanza could opt
  into.
- Con: more moving parts: a build step, release assets that must exist for
  every tag the installer can request (no releases exist today, only tags), a
  signing key to keep somewhere, and a bootstrap problem for the checksum file
  itself (it is fetched from the same host as the tarball, so it only defends
  against a corrupted or tampered artifact, not a compromised GitHub account,
  unless signed).
- Con: a checksum published next to the artifact adds little against the main
  threat for a single-maintainer project (the maintainer's GitHub account),
  since whoever can replace the tarball can replace the checksum.

#### D. Package manager

A Homebrew tap (`brew install gitronald/tap/stanza`), or a `.deb` via a PPA.

- Pro: the manager handles download, verification, PATH, completions, and
  upgrades. Brew formulas carry a SHA-256 of the tarball, so verification comes
  for free.
- Con: Homebrew is a large dependency to assume on Linux and WSL; a PPA is
  Ubuntu-only and heavyweight for a few bash files. Each is another repo to
  maintain, and each still needs a stable tarball (C) to point at.
- Con: the formula or package must be updated for every release, so this
  depends on C being automated first.

### Security comparison

The threat that matters is someone other than the maintainer getting code onto
a user's machine via the install path. Compared on who they have to compromise.

| Option | Transport integrity | Content verified against | Partial-download risk | What an attacker needs |
|---|---|---|---|---|
| Clone (today) and A | TLS plus git object hashes | the repo itself | none (git is atomic) | the GitHub account or GitHub |
| B | TLS only | nothing beyond TLS | yes, unless mitigated | the GitHub account, GitHub, or a TLS MITM with a trusted cert |
| C, unsigned | TLS plus SHA-256 | a file on the same host | no | the GitHub account or GitHub (checksum is replaceable too) |
| C, signed | TLS plus signature | a key committed in the repo and in the README | no | the signing key, or the account plus a README rewrite nobody notices |
| D (brew) | TLS plus formula SHA-256 | the tap repo | no | the tap repo or the account |

Observations:

- Nothing here is worse than the status quo in what it trusts. Every option
  ultimately trusts the GitHub account that owns the repo. The clone path trusts
  it too; it just does so with one fewer failure mode.
- The specific failure mode `curl | bash` adds is **partial execution**: if the
  connection drops mid-stream, bash executes whatever prefix arrived. A script
  that ends with `rm -rf "$TMP"` and gets cut off after `rm -rf "` is the
  canonical horror story. The standard mitigation is to wrap the whole body in
  a function and call it on the last line, so a truncated download defines a
  partial function and never runs it. uv and rustup both do this.
- The second added failure mode is **server-side content sniffing**: a
  malicious or compromised server can detect `curl`'s request pattern and serve
  different bytes to the pipe than to a browser. The mitigation is for users to
  download first and read, which is what the README should recommend as the
  alternative. Hosting the script on `raw.githubusercontent.com` means GitHub
  would have to do the sniffing, which is the same trust as the clone.
- The piped script should never `sudo` on the user's behalf. `install.sh`
  already refuses `--system` without root; keep that and never escalate.
- `--version` pinning is a security feature as well as a convenience: a user
  can install exactly what they reviewed, and a provisioning script becomes
  reproducible.
- Unsigned checksums (C without signing) are mostly a defense against
  corruption, not attack. Say so in the README rather than implying more.

### Recommendation

Do B now, built so that C can be layered on later without changing the install
line:

The steps are in [subplan a](subplans/a-fetch-mode.md).

Defer C to a follow-up plan, gated on whether `stanza release` grows a release
asset step in general. If it does, the installer's fetch mode switches from the
archive endpoint to the release asset and gains checksum verification, with the
install line unchanged. Skip D unless there is demand from users who already
have Homebrew.

**Revised 2026-10-10:** C is not deferred. No stable release ships the
one-line installer without checksum verification: the release asset and
the installer's check are part of this plan, as
[subplan b](subplans/b-verified-release-download.md). Order: `a -> b`.
Plan 008, written as the follow-up, is retired into this plan.

### Out of scope

- Windows outside WSL. stanza requires bash.
- Changing where files land (`~/.local/bin`, `~/.local/lib/stanza`) or how
  `bin/stanza` finds its library directory.
- Auto-update at runtime. Upgrades stay an explicit rerun of the installer.

## Log

- **2026-10-10T11:32:23-07:00** — Activated.
  - Branch: `feature/curl-installer`
  - Base: `dev` at `6716cbd`
  - Worktree: `.worktrees/curl-installer`
  - PR: pending
- **2026-10-10T11:38:17-07:00** — PR opened: https://github.com/gitronald/stanza/pull/9
- **2026-10-10T11:38:17-07:00** — Implemented option B (commits `c2941fd`,
  `d5b4419`). Detail in [subplan a](subplans/a-fetch-mode.md)'s Log.
- **2026-10-10T11:38:38-07:00** — Implemented: 4 commits ahead of `dev`.
- **2026-10-10T12:32:48-07:00** — Review fixes (commit `1f85050`). Detail in
  [subplan a](subplans/a-fetch-mode.md)'s Log.
- **2026-10-10T12:41:58-07:00** — Reactivated: back to active after review.
- **2026-10-10T12:42:56-07:00** — Split into nested subplans.
  - [a](subplans/a-fetch-mode.md) takes the initial implementation (option
    B): the Recommendation's steps 1-6, the Verification section, and the
    two detailed Log entries (implementation and review fixes), moved
    verbatim. a is done.
  - [b](subplans/b-verified-release-download.md) takes plan 008's body
    verbatim (merged in from `dev`); 008 is retired into this plan.
  - The Recommendation keeps its intro and its deferral of C, with the
    revision appended below it.

- **2026-10-10T12:55:16-07:00** — Subplan b implemented and done (commits
  `5e16f74`, `d321f2f`, `c71a34d`, `a421a09`). Questions 1-3 answered: the
  asset is built by `scripts/release-asset.sh` from a tag-triggered workflow,
  so `stanza release` is unchanged and needs no opt-in; old tags are refused;
  no signing. Detail in [subplan b](subplans/b-verified-release-download.md)'s
  Log.
- **2026-10-10T12:55:42-07:00** — Implemented: 20 commits ahead of `dev`.
- **2026-10-10T13:16:44-07:00** — Close review of PR #9 (`/code-review`,
  medium), posted to the PR.
  - Review follow-up: 4 findings, 3 fixed, 1 skipped.
    - Fixed (`bba6201`): the latest-tag lookup ran before the dependency
      check, so a piped install without git blamed the connection. It moved
      to `find_latest_release`, after `check_dependencies`. Regression case
      "Piped without git" in `tests/test-install.sh`, which fails on the old
      installer.
    - Fixed (`53d2f6d`): the two truncation loops shared one body (now
      `cut_runs_main`), and an `out` capture was never read.
    - Skipped: `fetch-depth: 0` in the release-asset workflow. A shallow
      checkout would likely work, but nothing can test it before the first
      real release run.
    - Rejected in verification: the newest tag without an asset (documented,
      fails closed with a retry hint), a dispatch for a tag older than the
      script (refused by design), and the re-checks in `install_files`
      (already on `dev`).
  - All 9 suites pass locally (`test-install.sh` 53/53).

## Handoff

- State: subplans a and b are done. The plan is closed and PR #9 is merged
  into `dev`. Nothing is uncommitted.
- Release gate: the first stable release after this merges is the one that
  turns the one-liner on (it fetches `install.sh` from `main`). Its tag push
  runs the `release-asset` workflow, which must succeed. Check the release
  has `stanza-<version>.tar.gz` and `.sha256`, then run the one-liner against
  it. If the workflow fails, re-run it from the Actions tab with the tag, or
  run `scripts/release-asset.sh v<version>` locally.
- Questions (all settled 2026-10-10, see subplan b's Log):
  1. Opt-in for the release-asset step: avoided. A workflow in this repo
     builds it, and `stanza release` is unchanged.
  2. Tags without an asset (v1.1.3 and earlier): refused, with a pointer to
     the clone path.
  3. Signing: no, checksum only; the README says what that does not cover.
- Not verified: the workflow and `gh release` calls on GitHub (first run is
  the next stable tag); the installer against a real release download; the
  fresh-container run from subplan a's Verification; a real HTTPS redirect
  against `--proto-redir '=https'`.
  These all wait on the next stable release and are checked by the release
  gate above; no follow-up plan holds them.

## Retrospective

- The plan's recommendation (B now, C later) did not survive contact: C
  (a checksummed release asset) landed in the same PR as subplan b, once it
  turned out a tag-triggered workflow could build the asset without
  touching `stanza release`.
- Splitting into nested subplans after the first review worked well. Plan
  008 folded in as subplan b, and the umbrella kept only decisions.
- The truncation guard needed more than `main "$@"` on the last line. A cut
  before `"$@"` runs main with its arguments dropped, and the brace group
  is what makes bash read the whole line first. A byte-by-byte test of the
  last line caught it.
- The one-liner cannot be tested end to end before the first release with
  an asset. The release gate in Handoff is the real verification, so the
  next stable release should be treated as part of this work.
- The close review found an ordering bug (a network lookup before the
  dependency check) that no test exercised. A "missing tool" case per
  dependency is cheap with `path_without`.
