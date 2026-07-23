---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

last_review_date: 2026-07-23
---

# Maintaining a repository

Operating a repository already under repo-foundation management: what a consumer receives, how syncs arrive, and how scaffolds stay fresh. Bringing a repository under management is `docs/adding-a-repo.md`; how the hub itself is built is `docs/architecture.md`; what every repo is expected to uphold is `docs/repo-standards.md`.

## What a consumer receives

The consumer's entry in `sync-manifest.yaml` lists the `component_sets` it subscribes to. A file arrives in one of these modes (ADR 0002, ADR 0003, ADR 0016):

- **canonical** — byte-for-byte, with a "synced from repo-foundation" header prepended. The hooks, scripts, lint configs, the prose style, and the org memory (`.ai/org/memory.md`, ADR 0022) come this way. Do not edit a canonical file in a consumer; edit it in repo-foundation.
- **template** — copied once with the `.template` infix stripped, then owned by the consumer (the workflow scaffolds, `.vale.ini`).
- **generate** — built per consumer (`dependabot.yml`, filtered to the ecosystems the consumer actually uses).
- **baseline-merge** — a managed region inside a consumer-owned file. For `AGENTS.md` / `CONTRIBUTING.md` / `.gitignore` the region sits between sentinel comments; edit outside it. For `.claude/settings.json` there is no comment syntax, so the file is regenerated from repo-foundation's baseline deep-merged with any class fragments and the consumer's `.claude/settings.addenda.json` — arrays union (a consumer can only add to the permission rails, never silently drop one).

## Receiving a sync

`sync-to-consumers.yml` runs on a schedule and on dispatch. For each consumer it clones the target, runs the engine, and — when a managed file has changed — opens a `sync-from-foundation` pull request, one commit per file. Review and merge it like any other pull request. A consumer never has to pull; the foundation pushes. Scheduled silence is the health signal: a quiet sync day means the consumers are converged, not that the sync is broken.

## Keep scaffolds fresh

The copy-once scaffolds (`ci.yml`, `codeql.yml`, `copilot-setup-steps.yml`) are owned per repo, so the sync cannot realign them. Instead, `foundation-doctor.sh` flags a scaffold that has not been touched in about a year, and the scheduled `scaffold-drift.yml` workflow runs the same check and files an issue (ADR 0015). The nudge is age-based, not a diff — a customized scaffold has no clean canonical to diff against.

## A worked example

`examples/minimal-repo/` is a consumer reduced to the essentials — the hook activation, an `AGENTS.md` with a managed region, and a `.claude/settings.addenda.json` that demonstrates the deep-merge. Read it alongside this guide.
