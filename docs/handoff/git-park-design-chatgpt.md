<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# git-park Design Document

**Status:** Draft v0.1  
**Author:** Todd Schulman (concept), ChatGPT (design assistance)

---

## Overview

`git-park` is a Git extension that archives local branches after their associated GitHub pull requests have been merged.

Its primary responsibility is intentionally narrow:

> Given the current branch, verify that its GitHub pull request has merged, then rename the branch into a predictable archival namespace.

The command should behave like a native Git subcommand:

```sh
git park
```

Git automatically discovers executables named `git-<command>` on the user's `PATH`.

---

## Design Philosophy

`git-park` is **not** a branch cleanup tool.

It is **not** a repository linter.

It is **not** a GitHub management tool.

It is a **conservative workflow command**.

Whenever there is ambiguity, the command should **refuse to act** and explain why.

The guiding principles are:

- correctness over convenience
- explicit over implicit
- safety over automation
- useful diagnostics over silent failure
- idempotency by design

---

## Goals

### Primary

- Safely archive merged feature branches.
- Eliminate manual branch renaming.
- Discover the associated PR automatically.
- Include the PR number in the parked branch name.
- Preserve the original branch name.
- Be idempotent.
- Produce high-quality diagnostics.
- Feel like a native Git command.

### Secondary

- Dry-run mode.
- Configurable behavior.
- Optional main branch update.
- Optional cleanup of the corresponding remote-tracking branch.
- Shell completions.
- Manual page.

### Non-goals

The command intentionally does **not**:

- perform repository-wide cleanup
- lint branch names
- delete local branches
- delete remote branches
- merge pull requests
- resolve merge conflicts
- replace GitHub CLI

---

## Dependencies

The command intentionally delegates to existing tools.

Required:

- Git
- GitHub CLI (`gh`)

Authentication is delegated to GitHub CLI.

The implementation should never communicate with the GitHub API directly.

Benefits:

- single authentication implementation
- respects existing `gh auth login`
- respects enterprise configuration
- avoids token management
- simpler implementation

---

## Installation

Preferred distribution:

```text
git-park
```

installed somewhere on `PATH`.

Examples:

```text
/usr/local/bin/git-park
/home/linuxbrew/.linuxbrew/bin/git-park
$HOME/.local/bin/git-park
```

Git automatically exposes it as:

```sh
git park
```

Documentation should include:

- README
- git-park(1)
- `git park --help`

Shell completions should be provided for:

- bash
- zsh
- fish

---

## Branch Naming

Default naming policy:

```text
merged/pr<N>-<original-branch>
```

Example:

```text
feature/login

↓

merged/pr42-feature/login
```

The original branch name is preserved verbatim.

The namespace is configurable.

Examples:

```text
merged/
archive/
retired/
```

---

## State Machine

The operation consists of one state transition.

```text
active branch
        │
        │ verify PR merged
        ▼
parked branch
```

Optional follow-up operations may occur afterwards.

```text
parked branch
      │
      ├── update main
      │
      └── cleanup remote-tracking ref
```

The rename is the primary operation.

Everything else is secondary.

---

## Validation Sequence

No repository mutation occurs until every validation succeeds.

Order:

1. Repository exists.
2. HEAD is attached.
3. Current branch exists.
4. Branch is not already parked.
5. GitHub CLI exists.
6. GitHub authentication is valid.
7. Branch has an associated PR.
8. PR is merged.
9. Destination branch does not already exist.

Only then may the rename occur.

---

## Idempotency

Running

```sh
git park
```

multiple times must be safe.

Already parked branches must never be renamed again.

Example:

```text
merged/pr42-feature/login
```

Output:

```text
Branch 'merged/pr42-feature/login' is already parked.
```

Exit status:

```text
0
```

---

## Legacy Parked Branches

Example:

```text
merged/feature/login
```

This branch is already parked.

The command should not rename it automatically.

Instead it may print a hint.

Example:

```text
Branch 'merged/feature/login' is already parked.

Hint:

The associated pull request appears to be #42.

To normalize the name:

    git branch -m \
        merged/feature/login \
        merged/pr42-feature/login
```

This is informational only.

`git-park` is not a naming linter.

---

## GitHub Integration

The implementation uses GitHub CLI.

Example:

```sh
gh pr view --json number,state,mergedAt
```

Information required:

- PR number
- state
- merged timestamp

Failure cases:

### gh missing

```text
GitHub CLI (gh) was not found.

Hint:

Install GitHub CLI:

    https://cli.github.com/
```

---

### Not authenticated

```text
GitHub CLI is not authenticated.

Hint:

Run:

    gh auth login
```

---

### No associated PR

```text
Cannot park branch 'feature/login'.

No associated pull request exists.
```

---

### PR still open

```text
Cannot park branch 'feature/login'.

Pull request #42 is OPEN.

Hint:

Merge the pull request first,
then run:

    git park
```

---

## Main Branch Update

Updating `main` is optional.

Default:

```text
disabled
```

Command line:

```sh
git park --update-main
```

Behavior:

```sh
git switch main
git pull --ff-only
```

Failure must not undo parking.

Example:

```text
Branch successfully parked.

Unable to update main.

Reason:

git pull --ff-only failed.
```

---

## Remote Tracking Cleanup

Repository-wide pruning is intentionally avoided.

The command must never run

```sh
git fetch --prune
```

by default.

Instead it may optionally remove **only** the remote-tracking reference associated with the parked branch.

Example:

Before:

```text
origin/feature/login
```

After:

```text
(no origin/feature/login)
```

This cleanup is optional.

Suggested option:

```sh
git park --cleanup-remote
```

Configuration:

```ini
park.cleanupRemote = true
```

---

## Configuration

Configuration uses Git configuration.

Example:

```ini
[park]
    prefix = merged
    updateMain = false
    cleanupRemote = false
    mainBranch = main
```

Precedence:

1. command line
2. repository config
3. global config
4. defaults

---

## Command Line

```text
git park
```

Options:

```text
--dry-run
--verbose
--quiet

--update-main
--no-update-main

--cleanup-remote
--no-cleanup-remote

--help
--version
```

---

## Output Philosophy

Messages should be categorized.

### Informational

Shown by default.

Example:

```text
Parked:

    feature/login

Renamed to:

    merged/pr42-feature/login
```

---

### Verbose

Shown only with:

```text
--verbose
```

Example:

```text
Checking repository...
Checking GitHub authentication...
Finding pull request...
Verifying merged state...
```

---

### Warning

Always shown.

Example:

```text
Branch parked successfully.

Unable to update main.
```

---

### Error

Errors should always explain:

- what happened
- why it happened
- how to fix it

---

## Dry Run

Dry run performs every validation.

It performs no mutations.

Example:

```text
Current branch:

    feature/login

Associated PR:

    #42

State:

    MERGED

Would rename:

    feature/login

to

    merged/pr42-feature/login

Would update main:

    no

Would clean remote tracking ref:

    no
```

---

## Portability

The first implementation should target POSIX shell compatibility where practical.

Desired supported shells:

- dash
- bash
- ksh93
- zsh (sh mode)

Avoid shell-specific features unless they provide compelling value.

All shell behavior should be validated under:

- macOS
- GNU/Linux

---

## Logging API

The implementation should avoid scattered `printf` calls.

Instead it should centralize output.

Conceptually:

```text
fatal()
warn()
info()
verbose()
hint()
success()
```

Benefits:

- consistent formatting
- centralized verbosity handling
- easy testing
- future color support

---

## External Command Wrappers

All Git and GitHub CLI invocations should pass through wrapper functions.

Benefits:

- consistent diagnostics
- dry-run support
- easier testing
- centralized subprocess handling

No raw `git` or `gh` invocations should appear in business logic.

---

## Testing

### Unit

- naming
- configuration
- validation
- messaging

### Integration

Temporary repositories.

Scenarios:

- merged PR
- open PR
- missing PR
- detached HEAD
- already parked
- dirty worktree
- update-main failure
- cleanup failure

GitHub CLI should be mocked where practical.

---

## Future Enhancements

Potential future additions:

- `git unpark`
- `git park --all`
- configurable naming templates
- additional hosting providers
- lifecycle reporting
- parked branch summaries

These are intentionally out of scope for the initial release.

---

## Summary

`git-park` is intentionally small in scope but high in polish.

Its responsibility is singular:

> Verify that the current branch's GitHub pull request has merged, then archive that branch safely using a predictable naming convention.

The command should earn the user's trust by being:

- conservative
- predictable
- idempotent
- well documented
- informative
- difficult to misuse

If there is any uncertainty, it should refuse to proceed and tell the user why.
