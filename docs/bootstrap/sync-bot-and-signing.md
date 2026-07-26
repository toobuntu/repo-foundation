<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Sync bot and verified commits

Maintainer reference for the GitHub App that repo-foundation's sync workflows use, and how the bot's commits come out **Verified** with no signing key at all. All of this is GitHub-side configuration the agent cannot do for you.

## 1. The sync GitHub App (required)

`sync-to-consumers.yml` pushes a branch and opens a PR on each consumer; `sync-from-upstreams.yml` does the same on repo-foundation itself. `GITHUB_TOKEN` cannot push workflow files (`.github/workflows/*`) or act across repos, so the workflows mint a short-lived, per-repo-scoped installation token from a GitHub App via `actions/create-github-app-token`.

### Create (or reuse) the App

Reusing homebrew-cask-tools' existing sync App is fine — same credentials, one App to manage. To create a fresh one (<https://github.com/settings/apps>):

- **Repository permissions:** Contents = Read and write; Pull requests = Read and write; Workflows = Read and write; Metadata = Read-only.
- Generate a **private key** (PEM download).
- **Install** the App on `toobuntu/repo-foundation` and on **every** consumer repo it will sync to.

### Credentials (set on `toobuntu/repo-foundation`)

| Kind | Name | Value |
| ------ | ------ | ------- |
| Variable | `SYNC_APP_CLIENT_ID` | the App's Client ID |
| Secret | `SYNC_APP_PRIVATE_KEY` | the App's private key (PEM contents) |

The workflows scope each issued token with `permission-*` inputs, so the token carries only what that run needs.

## 2. Verified bot commits (the Git Data path)

Sync commits to consumers are created through the GitHub **Git Data API** (blob → tree → commit → ref update) under the App installation token, by `.github/actions/sync/git-data-commit.rb`. GitHub signs API-created commits with its web-flow key when they are minted with an App installation token, so every sync commit arrives **Verified** with:

- **no machine user** and **no SSH signing key** — there is nothing to create, register, or rotate;
- a clean `toobuntu-token-app[bot]` author identity, with `GitHub <noreply@github.com>` as the signing committer;
- **real file modes** on new *and* modified files (the tree API carries `mode:`), so executable scripts stay executable through a sync.

This is token-type-dependent, verified by test on 2026-07-15 (`docs/handoff/rf-upstream-notes.md` § 18i): the same Git Data calls under a **user** token produce *unsigned* commits. Nothing beyond section 1 needs configuring — the Verified badge is a property of the App-token API path itself.

Two alternatives were evaluated and retired unimplemented (§§ 18b–18i): a **machine-user account with SSH commit signing** (Homebrew's BrewTestBot model — a real account, a registered signing key, and a rotatable secret, all custody the API path does not need), and GraphQL **`createCommitOnBranch`** (also auto-Verified, but it cannot set file modes on new files, which the tree API can).

## 3. Where these names are consumed

- `.github/workflows/sync-to-consumers.yml` — per-consumer App token; drives `git-data-commit.rb` for the Verified per-file commits.
- `.github/workflows/sync-from-upstreams.yml` — RF-scoped App token.
- `.github/actionlint.yaml` — declares `SYNC_APP_CLIENT_ID` as an allowed `config-variable`, so actionlint does not flag the `vars.*` reference.
