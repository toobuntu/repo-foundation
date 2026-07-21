<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# git-park RFC 001

## Title

git-park: Safe archival of merged pull request branches

## Status

Draft

## Version

0.1

## Abstract

`git-park` is a Git extension that safely archives local branches after their associated GitHub pull requests have been merged.

The command verifies the current branch's GitHub pull request state, determines the pull request number, and renames the branch into a predictable archival namespace.

Example:

```text
feature/login-flow

        |
        | PR #42 merged
        v

merged/pr42-feature/login-flow
```

The command is intentionally conservative. It prefers refusing an ambiguous operation with useful diagnostics over making a potentially destructive change.

`git-park` is designed as a native Git extension:

```sh
git park
```

implemented as:

```text
git-park
```

on the user's `PATH`.

---

## 1. Motivation

Long-lived repositories accumulate local branches after pull requests merge.

A typical workflow leaves developers with:

```text
main
feature/foo
feature/bar
feature/baz
```

where some branches are obsolete but contain valuable historical context.

Deleting them loses:

- the association between local history and the pull request,
- an easy way to inspect prior work,
- a record of the branch lifecycle.

Manually renaming branches is tedious:

```sh
git branch -m merged/pr123-feature/foo
```

The developer must know:

- whether the PR merged,
- which PR number applies,
- the desired naming convention.

`git-park` automates this safely.

---

## 2. Design Principles

### 2.1 Conservative behavior

The command must avoid surprising the user.

If it cannot confidently determine the correct action:

- do not mutate repository state,
- explain the reason,
- provide remediation guidance.

---

### 2.2 Explicit state transitions

The command performs a small number of well-defined operations.

Primary transition:

```text
unparked branch

        |

        v

parked branch
```

Optional follow-up transitions:

```text
parked branch

        |
        +--> update main

        |
        +--> remove associated remote-tracking ref
```

---

### 2.3 Idempotency

Running the command repeatedly must be safe.

Examples:

```sh
git park
git park
git park
```

must not create:

```text
merged/pr42-merged/pr42-feature/foo
```

or otherwise mutate the repository repeatedly.

---

### 2.4 Single responsibility

`git-park` is responsible for:

- validating the current branch,
- identifying the merged PR,
- renaming the branch.

It is not responsible for:

- repository cleanup,
- deleting branches,
- synchronizing all remotes,
- enforcing naming conventions.

---

## 3. Goals

### 3.1 Required goals

The initial release must:

- operate on the current branch,
- detect the associated GitHub pull request,
- require that the PR is merged,
- determine the PR number automatically,
- rename the branch using a predictable convention,
- provide useful diagnostics,
- support dry-run mode,
- support configuration,
- return meaningful exit codes.

---

### 3.2 Optional goals

The initial release may support:

- updating the main branch,
- removing the corresponding remote-tracking ref,
- shell completions,
- colorized output,
- Homebrew packaging.

---

## 4. Non-goals

The initial release must not:

- delete local branches,
- delete remote branches,
- perform `git fetch --prune`,
- rename arbitrary branches,
- operate on multiple branches at once,
- repair incorrect branch history,
- replace GitHub CLI.

---

## 5. Terminology

### Active branch

A local branch currently checked out.

Example:

```text
feature/login-flow
```

---

### Parked branch

A branch moved into an archival namespace.

Default:

```text
merged/pr<N>-<branch>
```

Example:

```text
merged/pr42-feature/login-flow
```

---

### Remote-tracking branch

A local reference representing a remote branch.

Example:

```text
origin/feature/login-flow
```

This is distinct from the local branch.

---

### Associated pull request

The GitHub pull request associated with the current branch according to GitHub CLI.

---

## 6. User Experience

The common workflow:

```sh
git checkout feature/login-flow

# GitHub PR is merged

git park
```

Expected output:

```text
Parked branch:

    feature/login-flow

New branch:

    merged/pr42-feature/login-flow
```

---

## 7. Dependencies

### Required

- Git
- GitHub CLI (`gh`)

The command intentionally delegates GitHub authentication and API access to `gh`.

---

### GitHub CLI requirements

The user must have authenticated:

```sh
gh auth status
```

or:

```sh
gh auth login
```

The command must not manage GitHub tokens directly.

---

### Missing dependency example

If `gh` is unavailable:

```text
Cannot park branch.

Required dependency not found:

    gh

Install GitHub CLI:

    https://cli.github.com/
```

Exit status:

```text
3
```

---

## 8. Installation Model

The preferred distribution artifact is a single executable:

```text
git-park
```

installed into a directory on `PATH`.

Examples:

```text
/usr/local/bin/git-park
~/.local/bin/git-park
```

Git automatically exposes:

```sh
git park
```

Additional distribution artifacts:

```text
git-park(1)
bash completion
zsh completion
fish completion
```

---

## 9. Implementation Language

The reference implementation should be written in Go.

Rationale:

- single binary distribution,
- strong subprocess support,
- structured JSON handling,
- excellent testing tools,
- cross-platform support,
- easier maintenance than a growing shell implementation.

The implementation still delegates Git operations to Git and GitHub operations to `gh`.

## 10. Configuration Specification

Configuration is stored using Git's configuration mechanism.

Example:

```ini
[park]
    prefix = merged
    mainBranch = main
    updateMain = false
    cleanupRemote = false
```

Configuration lookup follows Git conventions.

Precedence:

1. Command-line options.
2. Repository configuration.
3. Global configuration.
4. Built-in defaults.

---

### 10.1 Configuration keys

#### `park.prefix`

Controls the namespace for parked branches.

Default:

```text
merged
```

Example:

```ini
[park]
    prefix = archived
```

Result:

```text
archived/pr42-feature/foo
```

---

#### `park.mainBranch`

The branch updated by `--update-main`.

Default:

```text
main
```

---

#### `park.updateMain`

Whether to update the main branch after parking.

Default:

```text
false
```

Equivalent command-line override:

```sh
git park --update-main
```

---

#### `park.cleanupRemote`

Whether to remove the remote-tracking reference corresponding to the parked branch.

Default:

```text
false
```

Equivalent command-line override:

```sh
git park --cleanup-remote
```

---

#### `park.remote`

Optional override for the remote name.

Default:

```text
auto-detect
```

If unspecified, the implementation should determine the remote from the branch upstream.

---

## 11. Command Line Interface

### 11.1 Basic invocation

```sh
git park
```

The command operates on the currently checked out branch.

---

## 11.2 Options

### `--dry-run`

Validate and display intended actions without mutation.

Example:

```sh
git park --dry-run
```

---

### `--quiet`

Suppress informational messages.

Errors and warnings remain visible.

---

### `--verbose`

Display detailed progress.

Example:

```text
Checking repository...
Checking current branch...
Finding pull request...
Checking merge state...
```

---

### `--update-main`

Update the main branch after parking.

Equivalent:

```ini
park.updateMain=true
```

---

### `--no-update-main`

Disable main branch update.

Overrides configuration.

---

### `--cleanup-remote`

Remove the associated remote-tracking reference.

Equivalent:

```ini
park.cleanupRemote=true
```

---

### `--no-cleanup-remote`

Disable remote cleanup.

---

### `--help`

Display usage information.

---

### `--version`

Display version information.

---

## 12. Validation Sequence

Validation must complete before the primary mutation.

The order is:

```text
1. Validate invocation
2. Validate dependencies
3. Validate repository state
4. Validate current branch
5. Detect parked state
6. Resolve GitHub PR
7. Verify PR merged
8. Validate destination name
9. Rename branch
10. Perform optional actions
```

---

## 13. Repository Validation

### 13.1 Repository unavailable

Failure:

```text
Cannot park branch.

Not inside a Git repository.
```

Exit:

```text
1
```

---

### 13.2 Detached HEAD

Failure:

```text
Cannot park branch.

HEAD is detached.

Checkout a branch first.
```

Exit:

```text
5
```

---

### 13.3 Dirty working tree

Default behavior:

```text
refuse
```

Reason:

Although `git branch -m` can succeed with modifications, later operations such as switching branches may fail.

Example:

```text
Cannot park branch 'feature/foo'.

Working tree contains uncommitted changes.

Commit, stash, or clean the working tree first.
```

Exit:

```text
5
```

Future versions may provide:

```sh
git park --allow-dirty
```

---

## 14. Already Parked Behavior

If the current branch already matches the configured parking namespace:

Example:

```text
merged/pr42-feature/foo
```

the command exits successfully.

Output:

```text
Branch is already parked:

    merged/pr42-feature/foo
```

Exit:

```text
0
```

---

## 15. GitHub CLI Contract

The implementation uses:

```sh
gh pr view
```

The command must request structured output.

Example:

```sh
gh pr view \
    --json number,state,mergedAt,headRefName
```

Expected fields:

```json
{
  "number": 42,
  "state": "MERGED",
  "mergedAt": "2026-07-20T12:34:56Z",
  "headRefName": "feature/foo"
}
```

---

## 16. GitHub Failure Cases

### 16.1 No pull request

Example:

```text
Cannot park branch 'feature/foo'.

No associated pull request was found.

Create a pull request first.
```

Exit:

```text
5
```

---

### 16.2 Pull request not merged

Example:

```text
Cannot park branch 'feature/foo'.

Pull request #42 is OPEN.

Merge the pull request before parking.
```

Exit:

```text
5
```

---

### 16.3 GitHub authentication failure

Example:

```text
Cannot query GitHub.

GitHub CLI authentication failed.

Run:

    gh auth login
```

Exit:

```text
4
```

---

## 17. Destination Validation

Before renaming:

```text
merged/pr42-feature/foo
```

must not already exist.

Failure:

```text
Cannot park branch.

Destination branch already exists:

    merged/pr42-feature/foo
```

Exit:

```text
6
```

---

## 18. Mutation Ordering

The primary mutation:

```sh
git branch --move
```

occurs only after validation.

After rename succeeds:

```text
parking succeeded
```

The remaining operations are optional.

---

### 18.1 Update main

Sequence:

```sh
git switch main
git pull --ff-only
```

Failure does not undo parking.

Example:

```text
Branch parked successfully:

    merged/pr42-feature/foo

Unable to update main:

    git pull --ff-only failed
```

Exit:

```text
6
```

---

### 18.2 Remote cleanup

Remote cleanup happens last.

The command removes only:

```text
refs/remotes/<remote>/<original-branch>
```

It must not run:

```sh
git fetch --prune
```

because unrelated stale refs are outside scope.

---

## 19. Error Taxonomy

Errors are grouped.

### Dependency errors

Examples:

- Git missing
- GitHub CLI missing

Exit:

```text
3
```

---

### Authentication errors

Examples:

- `gh auth` failure

Exit:

```text
4
```

---

### Validation errors

Examples:

- no PR
- PR not merged
- dirty worktree
- detached HEAD

Exit:

```text
5
```

---

### Mutation errors

Examples:

- rename failure
- branch switch failure
- pull failure
- cleanup failure

Exit:

```text
6
```

---

## 20. Exit Status Contract

| Exit | Meaning |
| --- | --- |
| 0 | Success or already parked |
| 1 | General failure |
| 2 | Invalid command usage |
| 3 | Missing dependency |
| 4 | Authentication failure |
| 5 | Validation failure |
| 6 | Mutation failure |

Scripts may rely on these values.

## 21. Output and Messaging Guidelines

A primary design goal of `git-park` is to make users confident in what the command did or did not do.

Messages must be:

- concise,
- specific,
- actionable,
- written for humans first.

The command should avoid generic messages such as:

```text
Error occurred.
Operation failed.
Invalid state.
```

Instead, messages should describe:

1. What the command attempted.
2. What prevented completion.
3. What the user can do next.

---

## 21.1 Output channels

### stdout

Used for:

- successful results,
- machine-readable output in future versions,
- normal command output.

### stderr

Used for:

- errors,
- warnings,
- diagnostic messages.

This allows normal Unix composition.

---

## 21.2 Message levels

The implementation should internally classify messages.

### Fatal

Always shown.

Examples:

```text
Cannot park branch.

No GitHub pull request was found for:

    feature/login
```

---

### Warning

Always shown.

Examples:

```text
Branch was parked successfully.

The requested main branch update did not complete.
```

---

### Informational

Shown unless `--quiet`.

Examples:

```text
Parked branch:

    feature/login

New branch:

    merged/pr42-feature/login
```

---

### Verbose

Shown only with:

```sh
git park --verbose
```

Examples:

```text
Repository:

    /Users/todd/src/project

Current branch:

    feature/login

Querying GitHub pull request...
```

---

## 21.3 Hints

Hints should be used when the user can take an obvious next step.

Example:

```text
Cannot park branch.

Pull request #42 is still OPEN.

Hint:

Merge the pull request, then run:

    git park
```

Hints should not be emitted for routine success.

---

## 21.4 Dry-run output

Dry-run should resemble a planned execution.

Example:

```text
Validation successful.

Current branch:

    feature/login

Associated pull request:

    #42

State:

    MERGED


Planned actions:

    Rename:
        feature/login
        ->
        merged/pr42-feature/login

    Update main:
        no

    Cleanup remote tracking:
        no
```

---

## 22. Security Considerations

Although `git-park` primarily orchestrates Git commands, it must treat repository metadata and external command output as untrusted input.

---

## 22.1 Command execution

The implementation must never construct shell commands by concatenating user input.

Unsafe:

```text
sh -c "git branch -m $branch"
```

Preferred:

```text
exec.Command(
    "git",
    "branch",
    "--move",
    destination,
)
```

---

## 22.2 Branch names

Branch names originate from Git and potentially from remote systems.

The implementation must:

- avoid shell interpolation,
- avoid assuming branch names contain safe characters,
- pass arguments directly to subprocesses.

---

## 22.3 GitHub CLI output

`gh` output should be treated as external data.

The implementation must:

- validate JSON fields,
- handle missing fields,
- handle unexpected states.

Example:

Unexpected:

```json
{
    "state": null
}
```

must result in a controlled failure.

---

## 22.4 Credentials

`git-park` must never:

- store GitHub tokens,
- print tokens,
- modify GitHub authentication,
- log authorization headers.

Authentication belongs entirely to:

```text
gh auth
```

---

## 22.5 Repository trust

The command should avoid executing repository-provided scripts.

It should not:

- source files from the repository,
- execute hooks,
- load arbitrary configuration files.

---

## 23. Implementation Architecture

The reference implementation should use Go.

Suggested layout:

```text
git-park/

cmd/
    git-park/
        main.go

internal/

    cli/
        args.go
        help.go

    config/
        config.go

    git/
        command.go
        branch.go
        repository.go

    github/
        gh.go
        pull_request.go

    park/
        workflow.go
        validation.go
        mutation.go

    output/
        printer.go
```

---

## 23.1 Command flow

High-level:

```text
main

 |
 |
 +--> parse command line

 |
 |
 +--> load configuration

 |
 |
 +--> validate environment

 |
 |
 +--> inspect repository

 |
 |
 +--> inspect GitHub PR

 |
 |
 +--> perform parking

 |
 |
 +--> perform optional operations

 |
 |
 +--> report result
```

---

## 23.2 Git abstraction

All Git operations should be isolated.

Examples:

```go
CurrentBranch()
HasChanges()
RenameBranch()
SwitchBranch()
PullFastForward()
RemoteForBranch()
DeleteRemoteTrackingRef()
```

Benefits:

- easier testing,
- consistent error handling,
- easier future changes.

---

## 23.3 GitHub abstraction

All GitHub CLI operations should be isolated.

Examples:

```go
FindPullRequest()
VerifyAuthentication()
```

The rest of the application should not know that GitHub CLI is used.

---

## 23.4 Dry-run implementation

Dry-run should not be implemented by duplicating logic.

Instead, mutation functions should receive an execution mode.

Example:

```text
validate()

performRename()

    if dry-run:
        report planned action

    else:
        execute action
```

---

## 24. Testing Strategy

The command should have multiple test layers.

---

## 24.1 Unit tests

Test:

- branch name generation,
- configuration precedence,
- option parsing,
- output formatting,
- state transitions.

---

## 24.2 Git integration tests

Use temporary repositories.

Test:

- normal parking,
- already parked branches,
- destination exists,
- detached HEAD,
- dirty worktree,
- missing upstream.

---

## 24.3 GitHub integration tests

Mock `gh`.

Test:

- merged PR,
- open PR,
- closed unmerged PR,
- missing PR,
- authentication failure,
- malformed output.

---

## 24.4 End-to-end tests

Run against:

- real Git repository,
- real `gh` executable,
- controlled GitHub test repository.

---

## 25. Packaging and Distribution

Preferred release artifacts:

```text
git-park
```

single binary.

---

## 25.1 Homebrew

Provide:

- formula,
- versioned releases,
- checksums.

Example:

```sh
brew install git-park
```

---

## 25.2 Manual installation

Provide:

```text
download binary
chmod +x git-park
move into PATH
```

---

## 25.3 Documentation

Ship:

```text
README.md
docs/git-park.1
```

The manual page should document:

- synopsis,
- options,
- configuration,
- dependencies,
- exit statuses,
- examples.

---

## 26. Open Questions

### 26.1 Should dirty worktrees be configurable?

Current recommendation:

Default:

```text
refuse
```

Future:

```sh
git park --allow-dirty
```

---

### 26.2 Should the command update the current branch after parking?

Current recommendation:

No.

The user is still on the renamed branch unless:

```sh
git park --update-main
```

is used.

Alternative future behavior:

Automatically switch away after parking.

---

### 26.3 Should cleanup happen by default?

Current recommendation:

No.

Reason:

Parking should have one primary effect.

Future:

Allow:

```ini
park.cleanupRemote=true
```

---

## 27. Future Work

Possible future commands:

### git unpark

Restore a parked branch.

Example:

```sh
git unpark merged/pr42-feature/foo
```

---

### Bulk parking

Example:

```sh
git park --merged
```

would discover all merged branches.

Explicitly deferred because it changes the safety model.

---

### Other providers

Potential support:

- GitLab
- Bitbucket
- custom GitHub Enterprise

The abstraction should keep GitHub-specific logic isolated.

---

## 28. Final Design Summary

`git-park` is a small, conservative Git extension.

Its core promise:

> If the current branch has a merged GitHub pull request, safely archive it under a predictable name.

The command should be trusted because it:

- validates before mutating,
- avoids destructive cleanup,
- uses existing authentication mechanisms,
- explains failures,
- is idempotent,
- behaves like a native Git command.

The implementation should optimize for correctness and user confidence over maximum automation.
