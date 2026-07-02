---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

last_review_date: 2026-06-25
---

# Using repo-foundation

This guide is procedural: how to bootstrap a consumer, what the synced files
are, and how the ongoing sync reaches a repository. For the why, read the
decision records under `docs/decisions/`; for the overview, read `README.md`.

## Bootstrap a new consumer

From a checkout of repo-foundation, point `foundation-init` at the new
repository's working tree:

```sh
scripts/foundation-init.sh /path/to/new-repo
```

It does four things (ADR 0016 covers the licensing step):

1. Copies the copy-once scaffolds — the `ci` / `codeql` / `copilot-setup-steps`
   workflows from `provides/github/workflows/`, the `.vale.ini` from
   `provides/vale/`, the `adrs.toml`, and the lint configs — stripping the
   `.template` infix as it writes each target.
2. Seeds the baseline-merge files. `AGENTS.md`, `CONTRIBUTING.md`, and
   `.gitignore` get a sentinel-delimited region the sync manages; everything
   outside the region is the consumer's to edit. `.claude/settings.json` gets a
   starter plus a `.claude/settings.addenda.json` for the consumer's additions.
3. Seeds `CLAUDE.md` (the one-line `@AGENTS.md` pointer).
4. Runs `reuse download --all` and `ANNOTATE_LICENSE=<spdx> scripts/annotate.sh`,
   so a consumer under a non-GPL license is REUSE-compliant under its own
   license rather than inheriting repo-foundation's.

Then activate the hooks once per clone:

```sh
git config core.hooksPath .githooks
```

## What a consumer receives

The consumer's entry in `sync-manifest.yaml` lists the `component_sets` it
subscribes to. A file arrives in one of four modes (ADR 0002, ADR 0003):

- **canonical** — byte-for-byte, with a "synced from repo-foundation" header
  prepended. The hooks, scripts, lint configs, and the prose style come this
  way. Do not edit a canonical file in a consumer; edit it here.
- **template** — copied once with the `.template` infix stripped, then owned by
  the consumer (the workflow scaffolds, `.vale.ini`).
- **generate** — built per consumer (`dependabot.yml`, filtered to the
  ecosystems the consumer actually uses).
- **baseline-merge** — a managed region inside a consumer-owned file. For
  `AGENTS.md` / `CONTRIBUTING.md` / `.gitignore` the region sits between
  sentinel comments; edit outside it. For `.claude/settings.json` there is no
  comment syntax, so the file is regenerated from repo-foundation's baseline
  deep-merged with the consumer's `.claude/settings.addenda.json` — arrays union
  (a consumer can only add to the permission rails, never silently drop one).

## Receiving a sync

`sync-to-consumers.yml` runs on a schedule and on dispatch. For each consumer it
clones the target, runs the engine, and — when a canonical file has changed —
opens a `sync-from-foundation` pull request, one commit per file. Review and
merge it like any other pull request. A consumer never has to pull; the
foundation pushes.

## Keep scaffolds fresh

The copy-once scaffolds (`ci.yml`, `codeql.yml`, `copilot-setup-steps.yml`) are
owned per repo, so the sync cannot realign them. Instead, `foundation-doctor.sh`
flags a scaffold that has not been touched in about a year, and the scheduled
`scaffold-drift.yml` workflow runs the same check and files an issue (ADR 0015).
The nudge is age-based, not a diff — a customized scaffold has no clean
canonical to diff against.

## The user-global config

`provides/claude-user/` holds the version-controlled `~/.claude/` user config
(the `CLAUDE.md` and `settings.json` Claude Code loads for every project). It is
applied to the maintainer's home, not synced to consumers:

```sh
cp provides/claude-user/CLAUDE.md     ~/.claude/CLAUDE.md
cp provides/claude-user/settings.json ~/.claude/settings.json
```

## A worked example

`examples/minimal-repo/` is a consumer reduced to the essentials — the hook
activation, an `AGENTS.md` with a managed region, and a
`.claude/settings.addenda.json` that demonstrates the deep-merge. Read it
alongside this guide.
