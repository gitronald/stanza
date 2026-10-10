---
id: 1
slug: curl-installer
status: active
branch: feature/curl-installer
created: 2026-10-08T17:47:56-07:00
concluded:
pr:
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

Defer C to a follow-up plan, gated on whether `stanza release` grows a release
asset step in general. If it does, the installer's fetch mode switches from the
archive endpoint to the release asset and gains checksum verification, with the
install line unchanged. Skip D unless there is demand from users who already
have Homebrew.

### Out of scope

- Windows outside WSL. stanza requires bash.
- Changing where files land (`~/.local/bin`, `~/.local/lib/stanza`) or how
  `bin/stanza` finds its library directory.
- Auto-update at runtime. Upgrades stay an explicit rerun of the installer.

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

- **2026-10-10T11:32:23-07:00** — Activated.
  - Branch: `feature/curl-installer`
  - Base: `dev` at `6716cbd`
  - Worktree: `.worktrees/curl-installer`
  - PR: pending
