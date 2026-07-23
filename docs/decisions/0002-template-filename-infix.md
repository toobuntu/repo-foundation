---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 2
title: Mark non-verbatim files with a filename infix, not a suffix
status: accepted
date: 2026-06-24
decision-makers:
  - toobuntu
---

# Mark non-verbatim files with a filename infix, not a suffix

## Context and Problem Statement

Some files repo-foundation ships are not copied verbatim, and they come in two roles. A **transform** is delivered once and then owned by the consumer or the sync engine: `dependabot.yml` is generated per target; the `ci` / `codeql` / `copilot-setup-steps` workflow scaffolds are copied once and then edited freely. A **baseline** is a region repo-foundation manages in perpetuity inside a file the consumer otherwise owns: the org-wide slice of `AGENTS.md`, `CONTRIBUTING.md`, `.gitignore`, and `.claude/settings.json`. Both need a visible marker distinguishing them from the sync-verbatim set (see ADR 0001), and the two roles want distinct markers so a glance at the source name says which it is.

A marker that hides the file's real extension is worse than no marker. A trailing `dependabot.yml.template` stops editors, linters, formatters, and Markdown viewers from recognizing the file by extension, so the very tools that would validate it go quiet. The marker must be visible to a human and inert to tooling.

## Decision Drivers

- Keep filetype recognition: `*.yml` stays YAML to every tool, `*.md` still renders as Markdown.
- Mark non-verbatim files unambiguously, and say which kind each is.
- Map the marker to the sync mode, so the source name predicts the engine's behavior.

## Considered Options

- **Infix: `name.<role>.ext`** (chosen) — e.g. `dependabot.template.yml`, `AGENTS.baseline.md`.
- **Suffix: `name.ext.template`** — e.g. `dependabot.yml.template`.
- **One infix for both roles** — mark every non-verbatim file `.template`, ignoring the transform-versus-baseline distinction.
- **No filename marker; rely on directory placement alone.**

## Decision Outcome

Chosen: the marker is an **infix**, placed before the final extension, and there are two, one per role:

- **`.template`** marks a transform — a file delivered once and then owned by the consumer or the sync engine: `dependabot.template.yml`, `provides/github/workflows/ci.template.yml`. The engine strips the infix when it writes the target (`dependabot.yml`, `ci.yml`).
- **`.baseline`** marks a managed region merged into a consumer-owned file: `provides/repo/AGENTS.baseline.md`, `CONTRIBUTING.baseline.md`, `gitignore.baseline`, `settings.baseline.json`. The `baseline-merge` mode consumes these (ADR 0003); the infix matches the maintainer's existing `settings.baseline.json` naming.

Splitting the two infixes makes the source name state the engine mode: a `.template` source is copied or generated whole, a `.baseline` source is merged into a region. A file repo-foundation copies verbatim and fully owns keeps its natural name with no infix (`provides/objc/.clang-format`, `provides/repo/CLAUDE.md`).

A transform that pairs with a repo-foundation-own file lives beside the sync engine rather than at the natural path, to avoid two files claiming the same slot: `.github/actions/sync/dependabot.template.yml` sits next to the engine while `.github/dependabot.yml` is repo-foundation's own generated copy. This mirrors Homebrew/.github's exact choice.

### Consequences

- Good, because `*.template.yml` and `*.baseline.json` are still valid YAML and JSON and `*.baseline.md` still renders, so editors, linters, and viewers keep working on the source.
- Good, because the infix names the engine mode: `.template` is copied or generated whole, `.baseline` is merged into a region, no infix is a verbatim copy.
- Bad, because two infixes are marginally less conventional than a trailing suffix or a single marker; mitigated by mapping each one-to-one to a sync mode and documenting it here.
- Neutral, because directory placement (`provides/`) and the infix are complementary: `provides/` says "no natural repo-foundation path," the infix says how the file reaches the consumer.

## More Information

The layout this convention serves is ADR 0001; the sync engine that strips the `.template` infix and merges the `.baseline` region is ADR 0003. Models [Homebrew/.github](https://github.com/Homebrew/.github)'s `dependabot.template.yml`.

The infix vocabulary was settled in Phase D: `.template` (transform) and `.baseline` (managed region) are the two infixes, each mapped to a sync mode. The directory that holds them was renamed `templates/` → `provides/`: it carries the files repo-foundation manages on behalf of consumers or the maintainer's home and does not use at its own natural paths (transforms, baselines, the plugin masters, the user-global config), so "templates" undersold it — only the workflow scaffolds are literal templates. `provides/` also matches the manifest's existing `provides:` vocabulary for the dot-github-sourced files.
