---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 3
title: Sync shared configuration by pushing from a canonical source
status: accepted
date: 2026-06-23
decision-makers:
  - toobuntu
---

# Sync shared configuration by pushing from a canonical source

## Context and Problem Statement

A family of repositories shares configuration: git hooks, helper scripts,
lint configs, CI workflows, agent docs. Kept by hand, these copies drift —
a fix applied to one repository's pre-commit hook does not reach the others.
The repositories need an automated way to stay consistent with one canonical
version.

Two models are possible. In **pull-from-consumer**, every repository carries
a workflow that fetches the shared files from the canonical source. In
**push-from-canonical**, one source repository holds the canonical files and
pushes updates outward. The first spreads the sync logic across every
repository and couples each to the source's layout; the second keeps the
logic in one place. This ADR also settles how the sync interacts with pull
requests on the consumer side (absorbing homebrew-cask-tools' earlier
sync-branch-PR-strategy decision).

## Decision Drivers

* One obvious source of truth; a fix lands once and propagates.
* Consumers carry no sync machinery of their own.
* Changes arrive as reviewable pull requests, not silent commits.
* Deterministic behavior; minimal dependency surface.
* The bot needs no broad standing access; least privilege.

## Considered Options

* **Push-from-canonical, manifest-driven**, modeled on Homebrew/.github's
  `sync-shared-config` (chosen).
* **Pull-from-consumer** — each repository fetches from repo-foundation on a
  schedule.
* **Manual copy** — the maintainer copies files between repositories by hand.

## Decision Outcome

Chosen: push-from-canonical, driven by a declarative manifest and a Ruby
engine, modeled on
[Homebrew/.github](https://github.com/Homebrew/.github/blob/main/.github/workflows/sync-shared-config.yml).

* **`sync-manifest.yaml`** (repository root) lists `consumers` (pushed to),
  `upstreams` (pulled into repo-foundation), and `sources` (community-health
  files served from dot-github). Each consumer resolves to a component list
  with a per-component `mode`.
* **`.github/actions/sync/sync-files.rb`** is the engine, Ruby stdlib only so
  it runs without bundler in CI. Per component `mode`:
  * `canonical` — copy the source byte-for-byte, then prepend a "synced from
    repo-foundation — do not edit here" header in the target's comment syntax
    (chosen by extension). The source carries no such header; the sync adds
    it.
  * `template` — copy verbatim and strip the `.template` infix from the
    target (see ADR 0002).
  * `generate` — build the target per consumer; `dependabot.yml` is generated
    from `dependabot.template.yml`, keeping only the ecosystems whose manifest
    files exist in the target.
  * `baseline-merge` — replace only the region between sentinel markers in the
    target, preserving everything the consumer added outside it.
* **`.github/actions/sync/action.yml`** wraps the engine as a composite
  action. **`.github/workflows/sync-to-consumers.yml`** runs a matrix over the
  consumers; **`.github/workflows/sync-from-upstreams.yml`** pulls
  upstream-tracked files (zizmor, actionlint) into repo-foundation, applying
  `yq` mutations and the relay-header rewrite so consumers see repo-foundation
  as their single source.

The sync opens a pull request rather than committing to the consumer's default
branch. The branch (`sync-from-foundation`) is bot-managed, regenerated and
force-pushed each run; the pull request is a view of the current branch state,
not a long-lived development artifact. Workflow `concurrency` serializes runs
so only one mutates a repository at a time.

**Pull-request existence is a set query, not an object lookup** (absorbing
homebrew-cask-tools ADR 0002). The workflow asks the REST API
`/repos/{owner}/{repo}/pulls`, filters by `head` and `state=open`, and
evaluates the result with `jq --exit-status 'length == 0'` for a direct
shell exit code — opening a PR only when none matches. `gh pr view`
(object-resolution, ambiguous on multi-match) and `gh pr list` (needs output
parsing) are rejected for control flow; the REST-plus-`jq` query is correct
even if several PRs exist for the branch.

The bot signs its commits only when opted in (`SYNC_BOT_SIGN` plus an SSH
signing key in secrets); signing the bot's own work is distinct from the
rejected CI signing *gate* (ADR 0007). The token is a GitHub App token scoped
to contents, pull-requests, and workflows (workflow files are pushed).

### Consequences

* Good, because a shared file has one canonical home and consumers carry no
  sync logic; drift self-heals as a sync PR.
* Good, because the engine's mode set is small and declarative
  (canonical / template / generate / baseline-merge), so adding a consumer is
  a manifest entry, not code.
* Good, because PR-existence detection is set-based and deterministic under
  serialized execution, correct even with multiple open PRs.
* Bad, because the sync needs a GitHub App token with write and workflows
  scope, and the PR-existence query couples to the REST response shape.
* Neutral, because the rolling force-pushed branch means the PR always
  reflects the latest computed state; PRs are opportunistic, not durable.

## More Information

Models Homebrew/.github's `sync-shared-config` engine and workflow. Absorbs
homebrew-cask-tools' prior sync-branch-PR-strategy ADR (the REST-plus-`jq`
existence check and the rolling-branch rationale). The `.template` infix the
`template` mode strips is ADR 0002; how copilot-setup-steps is distributed
through this sync is ADR 0015; the analytics and signing policies the bot
honors are ADRs 0013 and 0007.
