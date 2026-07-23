<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Sync bot and verified commits

Maintainer reference for the GitHub App that repo-foundation's sync workflows use, and the optional setup that makes the bot's commits show as **Verified**. All of this is GitHub-side configuration the agent cannot do for you.

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

## 2. Verified bot commits (optional)

By default the sync bot commits **unsigned**. To get the green "Verified" badge, use a dedicated machine-user account plus SSH commit signing — Homebrew's BrewTestBot model. (A GitHub App's `…[bot]` identity cannot hold SSH signing keys, which is why a real user account is needed.)

### One-time setup

1. Create a dedicated GitHub **user account** (a "machine user"), e.g. `toobuntu-bot`.
2. Generate an SSH signing key: `ssh-keygen -t ed25519 -C toobuntu-bot-signing -f ./toobuntu-bot-signing`
3. Add the **public** key to that account: Settings → SSH and GPG keys → New SSH key → **Key type = Signing Key** (not Authentication).
4. Set on `toobuntu/repo-foundation`:

   | Kind | Name | Value |
   | ------ | ------ | ------- |
   | Variable | `SYNC_BOT_SIGN` | `true` |
   | Variable | `SYNC_BOT_NAME` | the machine user's name |
   | Variable | `SYNC_BOT_EMAIL` | a **verified** email on that account (or its `<id>+<user>@users.noreply.github.com`) |
   | Secret | `SYNC_APP_SSH_SIGNING_KEY` | the **private** signing key |

5. Ensure the App (or the machine user) can push to the consumers.

### How it works

`sync-to-consumers.yml` sets the committer identity from `SYNC_BOT_NAME` / `SYNC_BOT_EMAIL`, then `Homebrew/actions/setup-commit-signing@main` configures git to SSH-sign with the key; the engine's per-file commits are then signed. GitHub shows **Verified** only when all three hold: the commit is SSH-signed, the public key is a registered *signing* key on an account, and the committer email matches a verified email on that account — hence the machine user.

### Alternative: the GitHub Git Data API

Creating commits through the API (blob → tree → commit → ref update) with the App token makes GitHub auto-sign them with its web-flow key — auto-Verified, no key to manage. It is a **larger** change: the engine makes local `git` commits today, so API mode means roughly N×(blob+tree+commit)+ref-update calls per sync, an HTTP/auth surface inside the engine, and harder testing. Reserve it for if Verified is required *without* a machine user. (See the cross-repo sync architecture ADR, authored in Session 3.)

## 3. Where these names are consumed

- `.github/workflows/sync-to-consumers.yml` — per-consumer App token; the `SYNC_BOT_*` identity and the opt-in signing step.
- `.github/workflows/sync-from-upstreams.yml` — RF-scoped App token.
- `.github/actionlint.yaml` — declares `SYNC_APP_CLIENT_ID`, `SYNC_BOT_SIGN`, `SYNC_BOT_NAME`, `SYNC_BOT_EMAIL` as allowed `config-variables`, so actionlint does not flag the `vars.*` references.
