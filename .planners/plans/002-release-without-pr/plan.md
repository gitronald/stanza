---
id: 2
slug: release-without-pr
status: implemented
branch: feature/release-without-pr
created: 2026-10-09T14:47:27-07:00
concluded:
pr: https://github.com/gitronald/stanza/pull/4
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

### Answers (2026-10-09)

1. A `--no-pr` flag on the full release. Allowed for every bump type, with no
   refusal and no warning for `minor`/`major`. Not a config default.
2. Yes: reuse `version [release]: v<version>` from `git_merge_dev_into_main`.
3. No up-front detection. The push to a protected base branch is refused by
   the remote, and that refusal is the error. Two consequences to handle:
   - By then the bump commit is already on `origin/dev`. The error hint names
     the recovery: reset the local base branch to its remote, then open the PR
     and run `stanza release merge`.
   - `git_tag_version` pushes with `git push origin <base> --tags`, which is
     not atomic, so the tag can land even when the branch is refused. Use
     `git push --atomic` for the `--no-pr` push (worth checking for the PR
     path too). `--atomic` is a standard `git push` option: the remote
     updates every ref in the push or none of them, so a refused base branch
     also leaves the tag unpushed. It changes nothing else about the push.
4. `--no-pr` does not change any other option. `--pr-note` with `--no-pr` has
   nothing to attach to: print a warning that the note is ignored, and carry
   on. Every step except the merge is unchanged: the bump, changelog
   promotion, tag, merge-back, and dev cycle run as they do today. For the
   phases, `release merge --no-pr` merges `dev` directly instead of looking for
   an open PR. `release pr --no-pr` contradicts itself, since that phase exists
   to open a PR: warn that the flag is ignored there, the same way as
   `--pr-note`.
5. `pr: null`, as `json_set_pr_field` already emits when no PR was opened.

The code mostly exists already. `--no-pr` is the `--local` merge path
(`git_merge_dev_into_main`) with remote operations left on, since
`git_tag_version` already pushes the base branch with the tag. The flag
replaces `gh_merge_pr` with that function and leaves `should_skip_remote`
alone. The branch-protection test in the Approach becomes a test that a
rejected push leaves no tag on the remote.

### Approach

- Reuse the `--local` merge path for the merge and tag, then push the base
  branch and tag as the remote mode does today.
- Keep the post-release dev cycle and the changelog promotion unchanged.
- Tests: a no-PR release against a local bare remote, and the
  branch-protection refusal.
- Docs: `stanza release --help`, `stanza guide`, and the generated rules text.

## Log

- **2026-10-09T17:19:48-07:00** — Activated.
  - Branch: `feature/release-without-pr`
  - Base: `dev` at `0f6d5ef`
  - Worktree: `.worktrees/release-without-pr`
  - PR: pending
- **2026-10-09T17:22:39-07:00** — PR opened: https://github.com/gitronald/stanza/pull/4
- **2026-10-09T17:22:40-07:00** — Implemented: 3 commits ahead of `dev`.
