---
status: active
branch:
needs: [a]
---

# Verify the installer's download with a checksummed release asset

Part of [Add a one-line install path that does not require a clone](../plan.md).

## Plan

### Motivation

Plan 001 added a one-line install (`curl ... install.sh | bash`). In fetch mode,
`install.sh` downloads GitHub's on-the-fly source archive,
`archive/refs/tags/v<version>.tar.gz`, and nothing but TLS checks it. Plan 001
chose that deliberately (its option B) and deferred option C to this plan:
publish a release asset with a checksum, and have the installer verify it.

GitHub generates the archive on demand, so its bytes (and its SHA-256) are not
guaranteed stable across GitHub infrastructure changes. A hard-coded or
published checksum of that archive can therefore break without any change on
our side. A release asset is a file we upload once, so its checksum stays
fixed.

### What it defends against, and what it does not

- Defends against a corrupted or truncated archive, and against tampering
  with the asset alone (a replaced file on a CDN or mirror).
- An unsigned checksum fetched from the same host does **not** defend against
  a compromised GitHub account: whoever can replace the asset can replace the
  checksum. Only a signature, checked against a public key committed to the
  repo and printed in the README, closes that gap. See the umbrella's
  [security comparison](../plan.md#security-comparison).
- So: checksum first (cheap, removes the corruption class), and signing as a
  separate decision (step 4), not bundled in.

### Steps

1. **Build the asset in `stanza release`.** On a stable release, after the
   tag is pushed, build `stanza-<version>.tar.gz` from the tagged tree
   (`git archive --prefix=stanza-<version>/ v<version>`, which is deterministic
   for a given tree), write `stanza-<version>.tar.gz.sha256`, and upload both
   with `gh release create v<version> ... --verify-tag`. Today `stanza release`
   creates no GitHub releases at all, only tags, so this is a new step.
   Decide whether it is on by default for every repo stanza releases, or
   opt-in (a config flag or the presence of an `install.sh`). Most repos using
   stanza do not need a release asset.
2. **Make the release step resumable.** It runs after the tag push, so it must
   fit plan 007's resume model: a re-run with the release already present
   skips it, and a release missing its assets uploads them.
3. **Switch the installer's fetch mode.** Download
   `releases/download/v<version>/stanza-<version>.tar.gz` and its `.sha256`,
   verify with `sha256sum -c` (or `shasum -a 256 -c` on macOS), and refuse to
   continue on a mismatch or a missing checksum. The install line does not
   change.
   - Older tags (v1.1.3 and earlier) have no release asset. Either backfill
     assets for them with a one-off script, or keep the archive endpoint as a
     fallback for tags older than the first release with assets, with a
     warning that the download is unverified. Pick one; backfilling is
     simpler to reason about.
4. **Signing (separate decision).** If wanted: sign the `.sha256` with
   minisign or `ssh-keygen -Y sign`, commit the public key, print its
   fingerprint in the README, and have the installer verify the signature
   when the tool is available (and say so when it is not). Weigh this against
   the cost of keeping a signing key for a single-maintainer project.

### Tests

- `tests/test-install.sh` already runs fetch mode against a local
  `file://` stand-in. Extend the stand-in to lay out
  `releases/download/v<version>/` with an asset and checksum, and add cases:
  good checksum installs, a flipped byte refuses, a missing `.sha256` refuses.
- A release-workflow test that the asset and checksum are built and that a
  re-run does not duplicate the upload (mock `gh`, as the existing release
  tests do).

### Out of scope

- Package managers (plan 001's option D). They need a stable asset, which
  this plan provides, but each is its own plan.
- Changing the install line or the install layout.

## Log

- **2026-10-10T12:42:56-07:00** — Moved here verbatim from plan 008 (retired into plan 001),
  with the link to the security comparison repointed at the umbrella.
  Decision from the umbrella: no stable release of the one-line installer
  without checksum verification, so this is no longer optional follow-up
  work. Open questions 1-3 are in the umbrella's Handoff.
