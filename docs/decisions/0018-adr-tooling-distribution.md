---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 18
title: Distribute ADR tooling through existing sync carriers
status: accepted
date: 2026-07-03
decision-makers:
  - toobuntu
---

# Distribute ADR tooling through existing sync carriers

## Context and Problem Statement

The org standardized on MADR 4.0 ADRs authored and linted with `adrs`
(ADR 0004 settles where org-wide ADRs live; the synced `adrs.toml` in the
`repo_config` set already reaches every consumer). homebrew-cask-tools
PR #36 prototyped the tooling around that standard in one consumer: a
dedicated `adr-doctor.yml` CI workflow, an `adrs doctor` fragment in its
pre-commit hook, `adrs` added to the Copilot coding-agent install lists,
and the `adrs` MCP server in `.mcp.json` / `.vscode/mcp.json`. PR #36 was
closed in favor of reconciling those pieces here, so a change reaches every
consumer instead of one. For each piece: is it repo-foundation-canonical,
repo-local, or dropped — and on which carrier does the canonical version
ride?

Two of PR #36's supporting claims were re-verified rather than assumed,
against `adrs` 0.8.0:

* **"ADR status must be lowercase" is false.** `status: Accepted` passes
  `adrs doctor` with no issues; an unknown status value produces only a
  warning (exit 0). Lowercase is house style, not a tool requirement.
* **Availability**: `adrs` is now in homebrew/core, so PR #36's tap-name
  install references (`joshrotenberg/brew/adrs`) are stale. It runs
  cleanly in the local agent sandbox (`adrs doctor` reads only the
  working tree), and the `lint-adrs` CI job installs it from core. It is
  present in the Copilot coding-agent sandbox only if
  `copilot-setup-steps.yml` installs it — which this decision arranges.

## Decision Drivers

* One canonical implementation per check, synced everywhere (ADR 0003);
  no per-consumer forks of ADR tooling.
* Prefer existing carriers (the canonical `lint.yml`, the hook-plugin
  mechanism of ADR 0017, the `upstreams` mutation of ADR 0015) over new
  files that duplicate them.
* A check must be a no-op where it does not apply and run clean in the
  agent sandbox.
* Per-repo files (ADR 0015's `ci.yml` / `codeql.yml` reasoning) stay
  per-repo.

## Considered Options

* **CI**: a dedicated, path-gated `adr-doctor.yml` workflow per consumer
  vs the existing `lint-adrs` job in the canonical `lint.yml`.
* **Pre-commit**: a fragment inside the base hook vs a `pre-commit.d`
  plugin (ADR 0017), mastered under `provides/` vs at the natural path.
* **MCP config**: sync `.mcp.json` canonically vs leave it per-repo.
* **Install lists**: fold `adrs` into the existing Copilot install-list
  mutation and scaffold vs a separate install step.

## Decision Outcome

Every piece rides an existing carrier; the only new file is the hook
plugin.

* **CI: the `lint-adrs` job in the canonical `lint.yml` (`ci_core`) is
  the carrier; PR #36's dedicated `adr-doctor.yml` is dropped.** The job
  already syncs to every consumer, installs `adrs` from homebrew/core,
  and skips cleanly where `docs/decisions/` is absent. A second workflow
  would duplicate it for a path-gating benefit that does not justify a
  file in every consumer.
* **Pre-commit: a `50-adrs` plugin, mastered at the natural path
  `.githooks/pre-commit.d/50-adrs`, synced via the `adrs_plugin` set to
  every hook-carrying consumer.** It runs `adrs doctor` only when
  `docs/decisions/**` or `adrs.toml` is staged, warns-and-skips when the
  tool is absent, and runs clean in a sandbox. Unlike the language
  plugins (mastered under `provides/` because repo-foundation is not a
  Go/ObjC/Swift/tap repo), this master sits at the natural path:
  repo-foundation authors most org-wide ADRs and runs the plugin on its
  own commits — exactly ADR 0001's rule. It maps to all consumers except
  dot-github (which takes no `git_hooks`), because every consumer already
  receives `adrs.toml` and may keep repo-specific ADRs (ADR 0004); the
  staged-file gate makes it free elsewhere.
* **MCP config: `.mcp.json` is per-repo and not synced.** The server set
  is intrinsic to each repo — homebrew-cask-tools pairs `adrs` with the
  Homebrew MCP server; other repos will differ — the same reasoning that
  keeps `ci.yml` per-repo (ADR 0015). repo-foundation carries its own
  `.mcp.json` with the `adrs` server (`adrs mcp serve`); a consumer adds
  its own when it adopts AI-assisted ADR authoring. `.vscode/mcp.json`
  likewise stays repo-local.
* **Install lists: `adrs` (the homebrew/core name) is appended to the
  Copilot install-list mutation in `sync-manifest.yaml` (taps, via the
  `homebrew_tap` relay of ADR 0015) and to the non-tap scaffold
  `provides/github/workflows/copilot-setup-steps.template.yml`.**
  PR #36's parallel edit to cask-tools' `sync-shared-config.yml` is
  dropped; that workflow is decommissioned at the sync cutover (ADR
  0003 supersedes it, having absorbed cask-tools ADR 0002).
* **`adrs.toml` stays in its current canonical form** (`adr_dir` plus
  `[templates] format = "madr"`). PR #36's `mode = "ng"` and
  `variant = "minimal"` are not adopted: doctor passes the existing ADR
  set as-is, and the minimal template omits `decision-makers`, which the
  house frontmatter style carries.
* **PR #36's SPDX placement (an HTML comment above the frontmatter) is
  not adopted.** SPDX lives inside the YAML frontmatter, where
  `scripts/annotate.sh` puts it; `adrs doctor` accepts that form
  (maintainer-verified, exit 0). See the SPDX / REUSE section of
  `docs/agent-principles.md`.

### Consequences

* Good, because ADR health is enforced org-wide — pre-commit and CI —
  through two files that already sync, plus one new self-gating plugin.
* Good, because install references use the homebrew/core name; the stale
  tap name in PR #36 dies with the PR.
* Good, because the natural-path master keeps repo-foundation honest: it
  runs the same plugin it ships (the layout rule of ADR 0001, not an
  exception to ADR 0017's `provides/` placement — that placement was
  always conditional on repo-foundation not running the plugin).
* Bad, because `lint-adrs` runs on every push/PR rather than only on ADR
  paths; the job is seconds long and the uniformity of one `lint.yml` is
  worth more than the saved runner minutes.
* Neutral, because consumers gain the plugin before most of them author
  their first local ADR; it is inert until `docs/decisions/**` or
  `adrs.toml` is staged.

## More Information

Follows from the reconciliation of homebrew-cask-tools PR #36 (closed);
the outcome note is `docs/handoff/pr36-reconciliation-outcome.md`. The
hook-plugin mechanics are ADR 0017; the layout rule that places this
master at the natural path is ADR 0001; org-wide ADR location and
pointers are ADR 0004; copilot-setup-steps distribution is ADR 0015; the
sync that carries all of it is ADR 0003. The same natural-path rule
relocated the `05-shell` master out of `provides/` in the same change:
repo-foundation is itself a shell repository and now runs the plugin on
its own commits, so its earlier `provides/` placement (premised on
repo-foundation not running it) no longer applied; ADR 0017's master
list is amended accordingly.
