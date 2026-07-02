---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 1
title: Mirror the Homebrew/.github layout with a small provides/ area
status: accepted
date: 2026-06-24
decision-makers:
  - toobuntu
---

# Mirror the Homebrew/.github layout with a small provides/ area

## Context and Problem Statement

repo-foundation is the org-wide canonical source that syncs shared
configuration to the active `toobuntu/*` repositories. It needs a directory
layout that decides, for every shared artifact, where the canonical copy
lives in this repository — and how a consumer can tell which files it edits
from which it receives verbatim.

Two properties are in tension. The canonical files should sit where
repo-foundation itself uses them, so its own CI exercises them on every push
rather than storing them in a parallel tree that never runs. At the same time
a handful of artifacts have no natural home here (a user-global `~/.claude/`
config, an Objective-C toolchain for one consumer) or are meant to be edited
by the consumer, and those must be marked, not mixed in with the
sync-verbatim set.

## Decision Drivers

* repo-foundation should run the canonical files it ships, so a breaking
  change fails its own CI before any consumer sees it.
* A consumer must be able to tell at a glance which files it owns and edits
  versus which arrive byte-for-byte from the sync.
* Prefer a proven layout over an invented one.
* The consumer set is heterogeneous — an Objective-C daemon, Ruby gems,
  Homebrew taps, documentation repos — unlike Homebrew's uniform consumers,
  so a pure mirror does not cover every case.

## Considered Options

* **Mirror Homebrew/.github, plus a small `provides/` for the exceptions**
  (chosen).
* **A `global/` + `project/` split** (the pre-existing repo-foundation tree):
  every shipped file filed under a category directory, with repo-foundation
  not using its own configs.
* **Everything under `provides/`**: no file sits at a natural path.

## Decision Outcome

Chosen: mirror Homebrew/.github. Files repo-foundation uses itself live at
their natural paths with no marker — `.githooks/`, `scripts/`,
`.github/{workflows,zizmor.yml,actionlint.yaml,…}`, `docs/` and the org-wide
ADRs, `adrs.toml`, `spec/`, `.pinact.yaml`, `checkmake.ini`, `.rspec`,
`Gemfile`, `LICENSES/`, and repo-foundation's own
`AGENTS.md` / `CLAUDE.md` / `.claude/settings.json` (which double as the
project-scope baseline). Files a consumer receives non-verbatim carry a
filename infix (see ADR 0002).

`provides/` holds only the artifacts with no natural repo-foundation path:

* `provides/claude-user/{CLAUDE.md,settings.json}` — the version-controlled
  `~/.claude/` user-global config, applied to the maintainer's home, not
  consumer-synced. Claude Code auto-loads `CLAUDE.md` at the user-global level
  and no other tool reads `~/.claude/`, so there is no user-global `AGENTS.md`.
* `provides/objc/{.clang-format,.clang-tidy}` — the Objective-C toolchain
  for objc consumers, a per-consumer opt-in.
* `provides/githooks/pre-commit.d/{05-shell,10-go,20-objc,30-brew,40-swift}` —
  the `pre-commit.d` plugin masters (shell lint plus the per-language checks).
  repo-foundation runs the base hook at its natural `.githooks/` path but not
  these plugins, so they live under `provides/`; the directory mirrors the
  consumer's `.githooks/` exactly as `provides/github/workflows/` mirrors
  `.github/workflows/`. The hook base/plugin model is ADR 0017.
* `provides/repo/` — the per-repo baselines for the merge sync
  (`AGENTS.baseline.md`, `CONTRIBUTING.baseline.md`, `gitignore.baseline`,
  `settings.baseline.json`), plus a thin canonical `CLAUDE.md` pointer.

### Consequences

* Good, because repo-foundation exercises every canonical file it ships;
  a regression surfaces in its own CI before reaching a consumer.
* Good, because the mirror is Homebrew's proven model, so the layout is
  familiar and the sync engine has a reference implementation to follow.
* Good, because the natural-path / `.template` / `provides/` split makes a
  file's role legible: sync-verbatim, consumer-transformed, or
  no-natural-home.
* Bad, because the `provides/` area is a departure from a pure mirror. It is
  the minimum needed because the consumer set is heterogeneous; Homebrew's
  uniform consumers do not need it.
* Neutral, because the pre-existing `global/` + `project/` tree is retired;
  the reorganization into this layout is a later build-out phase.

## More Information

This layout models
[Homebrew/.github](https://github.com/Homebrew/.github). The `.template`
infix convention is ADR 0002; the sync architecture that distributes these
files is ADR 0003; the policy for where org-wide ADRs live is ADR 0004.
