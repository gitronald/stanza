# Stanza - Version Management with Git + GitHub

Simple semantic versioning workflow with Git and GitHub. Supports Python projects (via uv) and plain version files.

Stanza handles two distinct workflows:

**Prerelease Workflow** (prerelease):
- Simple version bump and commit on current branch
- Can be run on any development branch (dev, feature/*, bugfix/*, etc.)
- Skips PR creation, merging, and tagging steps
- Useful for development iterations and testing

**Full Release Workflow** (patch/minor/major):
1. Bump version on dev branch and commit
2. Create PR from dev to main with formatted body
3. Merge PR to main branch (merge commit `version [release]: vX.Y.Z - PR #N`)
4. Tag release on main and push to remote
5. Return to dev and bump to next prerelease version

Step 5 can be skipped with `--no-dev-cycle`: the release stops after tagging,
leaving `dev` untouched (no merge-back, no next prerelease bump) and the working
tree on the base branch. Useful when you want to land the release but defer or
hand-manage the next dev cycle.

The full workflow can also run in two phases — `stanza release pr <type>` opens
the PR and stops, then `stanza release merge` merges it — so you can review the PR
before it lands. See [Phased releases](#phased-releases).

## Project Types

Stanza auto-detects how your project manages its version:

| Type | Version source | Detection | When `uv` is required |
|------|---------------|-----------|----------------------|
| uv/Python | `pyproject.toml` (`[project]` with `version =`) | Checked first | Yes |
| Bash/plain | `VERSION` file (single-line semver, e.g., `0.1.0`) | Checked second | No |
| LaTeX | `*.cls` or `*.sty` at project root with `\ProvidesClass{...}[YYYY/MM/DD vN.NN ...]` | Checked third | No |

If multiple sources exist, `pyproject.toml` takes precedence over `VERSION`; both take precedence over LaTeX detection. If none match, stanza exits with an error listing the files it checked.

**VERSION file format**: A single line containing a semver string with optional alpha prerelease. No `v` prefix, no trailing whitespace.

```
0.1.0
1.2.3a0
```

**LaTeX format**: `\ProvidesClass{name}[YYYY/MM/DD vN.NN description]` (or `\ProvidesPackage`). Stanza reads/writes the `vN.NN` portion (1-3 numeric components) and stamps today's date on bump. LaTeX projects don't support `prerelease` bumps — use `patch`/`minor`/`major` only. The full release workflow on LaTeX skips the post-release prerelease cycle step.

**Note**: Stanza must be run from the project root directory.

## Requirements

Before installing stanza, ensure you have these dependencies:

- **git** - Version control ([install](https://git-scm.com/downloads))
- **uv** - Python package and project manager, required for Python projects ([install](https://docs.astral.sh/uv/getting-started/installation/))
- **gh** - GitHub CLI ([install](https://github.com/cli/cli#installation))
- **bash** - Required for script execution (pre-installed on macOS and most Unix systems)

**Note for macOS users**: All scripts use `#!/usr/bin/env bash` to ensure bash execution regardless of your default shell (e.g., zsh). No additional configuration should be needed.

## Installation

### Quick Install (User)
Clone and install to ~/.local/bin (no sudo required):
```bash
git clone https://github.com/gitronald/stanza.git
cd stanza
./install.sh
```

When `~/.claude` exists, `install.sh` also installs the
[Claude Code rule](#claude-code-rule); pass `--no-rules` to skip it.

### System Install
Install system-wide to /usr/local/bin:
```bash
git clone https://github.com/gitronald/stanza.git
cd stanza
sudo ./install.sh --system
```

### Custom Location
```bash
./install.sh --prefix=/custom/path
```

### Uninstall
```bash
./uninstall.sh
# or for system install:
sudo ./uninstall.sh --system
```

## Quick Start

After installation, try these common workflows:

```bash
# Initialize a new GitHub repository
stanza init --public

# Bump to a prerelease version (dev/feature branches; 'pre' is an alias)
stanza release prerelease

# Create a patch release (from dev branch)
stanza release patch

# Or release in two phases: open the PR, review it, then merge
stanza release pr patch -y     # bump on dev, open PR, then stop
stanza release merge -y        # merge the open PR, tag, open the next cycle

# Print the agent-facing guide to driving releases
stanza guide

# Install the Claude Code rule that documents stanza's commits
stanza rules install

# Show all available commands
stanza help
```

## Usage

```bash
stanza [global-options] <command> [command-options]
```

Available commands:
- `release` - Create a release (patch, minor, major, or prerelease — also `pre`)
- `init` - Initialize a GitHub repository
- `guide` - Print the agent-facing guide to driving releases
- `rules` - Print, install, or check the generated Claude Code rule
- `help` - Show help message
- `version` - Show project version

### Global options

These flags can be passed before the subcommand (or, for back-compat, after):

| Flag | Effect |
|------|--------|
| `-q`, `--quiet` | Reduce output to a single line: the new version (release), repo URL (init). Errors still print. |
| `-v`, `--verbose` | Show step internals (pre-checks, remote-skip context). Stack as `-vv` to dump every git/gh command. |
| `--json` | Emit a single JSON document on stdout (`schema_version: 1`). Suppresses the human banner; errors still go to stderr. |
| `--no-color` | Disable ANSI color. Also honored: the `NO_COLOR` env var. |

`--quiet` and `--verbose` are mutually exclusive. `--json` takes over stdout regardless of verbosity.

### Output and verbosity

Default output uses a small table grammar — a header line and labelled rows:

```
stanza release patch  (dev -> main, uv)
  bump      0.6.2a0 -> 0.7.0  on dev
  commit    af3c91e  "version [patch]: 0.7.0"
  push      origin/dev
  pr        #42  https://github.com/user/repo/pull/42
  merge     #42 merged into main
  tag       v0.7.0  pushed
  cycle     0.7.1a0 on dev (merged main back, pushed)
  done      released v0.7.0; dev -> 0.7.1a0
```

In `--quiet` mode, the same release prints just `0.7.0`. In `--json` mode, the result is a structured document suitable for piping into `jq`.

### Release Command

```bash
stanza release <BUMP_TYPE>          # Full release (bump, PR, merge, tag, new cycle)
stanza release pr <BUMP_TYPE>       # Phase 1: bump on dev, open PR, then stop
stanza release merge [PR_NUMBER]    # Phase 2: merge the open PR, tag, open new cycle

Arguments:
  <BUMP_TYPE>  Type of version bump:
                 patch         Promote alpha to stable, or bump patch (0.1.1a0 -> 0.1.1)
                 minor         Bump minor, zero patch (0.1.1 -> 0.2.0)
                 major         Bump major, zero minor and patch (0.2.0 -> 1.0.0)
                 prerelease    Bump to next alpha (0.1.0 -> 0.1.1a0)  [alias: pre]
  [PR_NUMBER]  (merge only) pin a specific open PR when more than one exists

Options:
      --pr-note <TEXT>     Append a note to the PR body (full and pr phases)
      --no-dev-cycle  Skip the post-release dev cycle (full and merge phases)
      --no-changelog       Skip CHANGELOG [Unreleased] promotion and its check
  -y, --yes                Auto-confirm all prompts (useful for CI/CD)
      --local              Local-only mode (skip all remote operations)
  -h, --help               Show this help message

(Plus the global flags above: -q, -v, --json, --no-color)

Examples:
  stanza release prerelease           # 0.1.0 -> 0.1.1a0, no PR
  stanza release pre                  # Same as 'prerelease' (alias)
  stanza release patch                # 0.1.1a0 -> 0.1.1, PR from dev to main
  stanza release minor                # 0.1.1 -> 0.2.0, PR from dev to main
  stanza release major                # 0.2.0 -> 1.0.0, PR from dev to main
  stanza release patch -y             # Non-interactive release
  stanza release pr minor -y          # Phase 1: bump + open PR, then stop
  stanza release merge -y             # Phase 2: merge the open PR, tag, new cycle
  stanza release pr patch --pr-note "fixes #42"   # Open PR with a note in its body
  stanza release patch -y --no-dev-cycle     # Release, but leave dev untouched
  stanza -v release patch             # Show detailed git output
  stanza -q release prerelease -y     # Print just the new version
  stanza --json release patch -y      # Machine-readable JSON output
```

**Branch Requirements:**
- ✅ `prerelease` (or `pre`) — Any branch except main/master
- ❌ `patch` / `minor` / `major` — Must be on dev branch

#### Release-time docs sync

Alongside the version-source bump, a release keeps two pieces of documentation in
sync. Both ride in the same `version [type]:` commit, so they flow through the PR
and are present at tag time.

- **README title version (opt-in).** If your README's first H1 title carries a
  `v<version>` token — e.g. `# pbz2 v0.2.0` — stanza rewrites it to the new
  version on every bump so it can't drift from the version source. A title
  without such a token is left untouched (a repo never gets one it didn't
  already have).
- **CHANGELOG `[Unreleased]` promotion (stable releases).** If a `CHANGELOG.md`
  (Keep a Changelog convention) has a non-empty `## [Unreleased]` section, a
  stable release promotes it to `## [X.Y.Z] - YYYY-MM-DD` and opens a fresh empty
  `## [Unreleased]` above it. When the file uses compare-link references
  (`[Unreleased]: .../compare/vPREV...HEAD`), those are repointed and a
  `[X.Y.Z]: .../compare/vPREV...vX.Y.Z` link is inserted. Prereleases leave the
  changelog untouched. A release **aborts before any bump** if `[Unreleased]` is
  empty, so a version never ships without its changelog entries — pass
  `--no-changelog` to skip both the promotion and the check.

#### Phased releases

`patch`/`minor`/`major` releases can run in two phases so you can review the PR
before it merges:

```bash
stanza release pr <type> -y     # bump on dev, push, open the PR, then STOP
gh pr view                      # review the PR (diff, body, checks)
stanza release merge -y         # merge the PR, tag, open the next prerelease cycle
```

- Phase 2 re-derives everything from the open PR (the PR number and the tag from
  its title), so there is no state file between phases.
- If more than one open `dev -> base` PR exists, pin the target with
  `stanza release merge <pr-number>`.
- `merge` refuses to proceed if `dev` has advanced past the reviewed PR head, so
  new commits can't slip into the tagged release.
- `--pr-note <TEXT>` appends a note to the PR body (applies to `pr` and the full
  one-shot release; ignored by `merge`).
- `--no-dev-cycle` skips the post-release dev cycle (applies to the full
  one-shot release and to `merge`; ignored by `pr`, which stops before the cycle).
- Phases do not apply to `prerelease`, which opens no PR.

Run `stanza guide` for a compact, agent-facing version of this workflow.

### Init Command

Initialize a GitHub repository and link it to local git.

```bash
stanza init [OPTIONS]

Options:
  -n, --name NAME              Repository name (default: current directory name)
  -d, --description DESC       Repository description
  -t, --type TYPE              Scaffold a missing version file (bash | uv)
      --public                 Create public repository (default: private)
      --current-branch-only    Push only current branch (default: all branches)
  -y, --yes                    Auto-confirm all prompts (non-interactive mode)
  -h, --help                   Show this help message

(Plus the global flags above: -q, -v, --json, --no-color)

Examples:
  stanza init                                    # Private repo, current dir name
  stanza init -n my-project --public             # Public repo with custom name
  stanza init --current-branch-only              # Only push current branch
  stanza init -n tools -d "Utility scripts"      # With description
  stanza init --type bash                        # Also create a VERSION file (0.1.0)
  stanza init --type uv                          # Also create a minimal pyproject.toml
  stanza --json init -y -n my-tool               # Emit JSON for scripting
```

**Features:**
- Creates private GitHub repository by default (use `--public` for public)
- Automatically uses current directory name as repository name
- Checks for existing remote before proceeding
- Pushes all branches by default (or just current with `--current-branch-only`)
- Optional tag pushing with confirmation prompt
- With `--type bash` or `--type uv`, scaffolds a `VERSION` or `pyproject.toml` if missing (does not auto-commit)
- Requires `gh` CLI tool to be installed and authenticated

### Guide Command

Print a compact, agent-facing guide to driving releases (the two-stage flow,
`--pr-note`, prereleases, and the rules of the road) to stdout:

```bash
stanza guide
```

The guide ships inside the package (`lib/stanza-guide.md`), so it travels with
every install — any agent can run `stanza guide` from any project to learn the
workflow.

### Claude Code Rule

stanza writes its own commits: version bumps, the release merge, and the
back-merge into `dev`. Their subjects follow stanza's format, not hand-written
commit conventions. `stanza rules` prints a short rule that lists those
subjects and tells Claude Code to leave them alone, and `stanza rules install`
writes it where Claude Code loads it automatically:

```bash
stanza rules                    # print the rule text
stanza rules install            # write ~/.claude/rules/stanza.md
stanza rules install --local    # write <repo>/.claude/rules/stanza.md (commit it to share)
stanza rules check              # ok, drifted, or missing per location; non-zero unless current
stanza rules uninstall          # remove a rule file stanza generated
```

The rule text ships inside the package (`lib/stanza-rules.md`), and the
installed file carries a version stamp, so `stanza rules check` flags a copy
left over from an older stanza. `install` refuses to overwrite a file it did not
generate unless you pass `--force`, and `uninstall` never removes one.
`install.sh` runs `stanza rules install` for user installs when `~/.claude`
exists (`--no-rules` skips it), and `uninstall.sh` removes the generated file.

## Shell Completion

Shell completions for bash and zsh are installed automatically by `install.sh`.

### Zsh (macOS default)
If not auto-loaded, add to your `~/.zshrc`:
```zsh
# Add stanza completions to fpath
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit && compinit
```

### Bash
If not auto-loaded, add to your `~/.bashrc`:
```bash
# Load stanza completions
if [ -f ~/.bash_completion.d/stanza ]; then
    source ~/.bash_completion.d/stanza
fi
```

**Note**: The stanza scripts themselves run in bash (via shebang), so completions work regardless of your default shell.

## Project Structure

The stanza tool is organized as follows:

- `bin/stanza` - Main CLI dispatcher (uses `#!/usr/bin/env bash`)
- `lib/stanza-release` - Release workflow subcommand implementation
- `lib/stanza-init` - Repository initialization subcommand implementation
- `lib/stanza-common` - Common utility functions (not meant to be run directly)
- `lib/stanza-guide.md` - Agent-facing release guide printed by `stanza guide`
- `lib/stanza-rules` - Claude Code rule subcommand (print, install, check, uninstall)
- `lib/stanza-rules.md` - Rule text rendered by `stanza rules`
- `completions/` - Shell completion files for bash and zsh
- `tests/` - Version bump test suite
- `install.sh` / `uninstall.sh` - Installation scripts

### Compatibility Notes

All scripts use `#!/usr/bin/env bash` shebangs to ensure bash execution:
- **zsh compatibility**: Scripts automatically run in bash regardless of your default shell; uses `${BASH_SOURCE[0]:-$0}` for cross-shell path detection
- **macOS ready**: No GNU-specific tools required; works with macOS's built-in utilities
- **Bash features**: Scripts use bash-specific features (arrays, `[[`, regex, etc.) and require bash 3.2+

### Common Utilities (lib/stanza-common)

Shared functions used by all subcommands:

**Git Operations:**
- `get_current_branch()` - Get current git branch
- `check_uncommitted_changes()` - Check for uncommitted changes
- `require_branch(name)` - Validate current branch
- `get_branch_status(branch)` - Get ahead/behind commit counts vs remote
- `check_branch_up_to_date(branch)` - Check if branch is synced with remote
- `has_remote(name)` - Check if remote exists
- `git_quiet()` - Run git commands with verbose control
- `gh_quiet()` - Run gh commands with verbose control

**Version Management:**
- `detect_project_type()` - Detect project type (uv, bash, or none)
- `get_current_version()` - Get version (dispatches based on project type)
- `get_version_from_file()` - Read version from VERSION file
- `set_version_in_file(version)` - Write version to VERSION file
- `bump_version_string(version, type)` - Bump a semver string in pure bash
- `validate_version_string(version)` - Validate semver format

**Release-time Docs Sync:**
- `get_version_from_readme()` - Read the `v<version>` token from the README H1 title
- `set_version_in_readme(version)` - Sync the README title token (opt-in, no-op if absent)
- `changelog_unreleased_status()` - Classify `## [Unreleased]` (absent/missing/empty/nonempty)
- `promote_changelog(version)` - Promote `[Unreleased]` to a version section and update compare links

**User Interaction:**
- `confirm_step(message)` - Prompt user for confirmation (respects -y flag)
- `print_error(message)` - Print formatted error message
- `print_warning(message)` - Print formatted warning message

**Validation:**
- `check_command_availability()` - Check if command exists
- `check_required_commands()` - Check git, gh, and uv (if uv project)
- `should_skip_remote()` - Check if remote operations should be skipped

### Release Functions (lib/stanza-release)

Release-specific workflow functions:

**Version Operations:**
- `bump_version(type)` - Bump version and return new version
- `set_version(version)` - Set specific version (e.g., "1.2.3")

**Workflow Functions:**
- `bump_and_commit_version()` - Bump version, sync README/CHANGELOG, create commit
- `check_changelog_before_release()` - Pre-flight: block a release on an empty `[Unreleased]`
- `print_doc_sync_rows()` - Emit the readme/promote rows recorded by the last bump
- `git_tag_version()` - Create and push version tag
- `handle_prerelease_workflow()` - Execute prerelease workflow
- `create_version_bump_on_dev()` - Create version bump on dev branch
- `gh_create_pr()` - Open a PR from dev into the base branch (no merge)
- `gh_merge_pr()` - Merge the open dev to base PR, then sync the base branch
- `create_new_prerelease_cycle()` - Start new prerelease cycle
- `run_prerelease_cycle_or_skip()` - Run the cycle, or skip it under `--no-dev-cycle`
