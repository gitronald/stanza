---
id: 2
slug: release-without-pr
status: draft
branch:
created: 2026-10-09T14:47:27-07:00
concluded:
pr:
---

# Add a no-PR option to stanza release

## Plan

### Problem

`stanza release <type>` always routes the release through a `dev -> main` pull
request, even in the one-shot form that opens and merges it in the same run.
For a quick patch bump that nobody will review, the PR is overkill: it adds an
API round trip and a PR to the history that carries no review. `--local` is
not a substitute, since it skips every remote step, so the tag and branches
never reach the remote.

### Goal

Investigate adding an option (working name `--no-pr`) that keeps the remote
steps but merges `dev` into the base branch directly, without a PR.

### Questions to resolve

1. Flag shape: a `--no-pr` flag on the full release, or a config default per
   repo? Should it be refused for `minor`/`major`, or only warned on?
2. Merge commit subject: the no-PR form already exists for `--local`
   (`version [release]: v<version>`); reuse it.
3. Branch protection: a protected base branch rejects a direct push. Detect
   this up front and fail with a hint to drop the flag, rather than failing
   after the bump is pushed.
4. Interaction with `--pr-note` (reject the combination) and with the `pr` and
   `merge` phases (the flag does not apply to them).
5. JSON output: what replaces the PR number/URL fields.

### Approach

- Reuse the `--local` merge path for the merge and tag, then push the base
  branch and tag as the remote mode does today.
- Keep the post-release dev cycle and the changelog promotion unchanged.
- Tests: a no-PR release against a local bare remote, and the
  branch-protection refusal.
- Docs: `stanza release --help`, `stanza guide`, and the generated rules text.
