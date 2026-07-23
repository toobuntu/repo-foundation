---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 22
title: In-repo .ai/ continuity directory for agent session state
status: accepted
date: 2026-07-22
decision-makers:
  - toobuntu
---

# In-repo .ai/ continuity directory for agent session state

## Context and Problem Statement

Agent sessions (Claude Code and others) accumulate two kinds of context that must outlive one session: durable knowledge (decisions already made, hard-won facts, gotchas) and volatile working state (what was just done, what is next, what is blocked). Claude Code's built-in memory is per-machine, per-path, invisible to contributors, and is lost when a Tier-3 sandbox clone is retired — so it cannot be the home for project knowledge that a teammate, or a future session on another machine, needs to see. Where does session-spanning project context live so that it is versioned, contributor-visible, and portable?

## Considered Options

- **An in-repo `.ai/` directory** (chosen), adopting the *pattern* — not the exact layout — from BrewUI's `.ai/` system.
- **A `docs/` pair** (`docs/log.md` + `docs/progress.md`) — the earlier idea; rejected because the content serves agents first and would clutter human-facing `docs/`, while `.ai/` is still tracked and contributor-visible.
- **Claude Code per-project memory only** — rejected: per-machine, per-path, invisible to contributors, and lost when a clone is retired. It holds only agent-workflow preferences, not project knowledge.

## Decision Outcome

Every toobuntu repository carries a top-level `.ai/` directory:

- **`.ai/memory.md` — durable knowledge.** Append-only, dated entries (`## YYYY-MM-DD — Topic`); history is never rewritten — a correction is a new entry naming what it supersedes. Committed; seeded by `foundation-init`.
- **`.ai/progress.md` — volatile session state** (Last touched / Done recently / In flight / Blocked / Handoff). This is per-developer working state, so it is **gitignored**; the committed **`.ai/progress.template.md`** is its seed.
- **`.ai/scratchpad.md`** (optional) — gitignored ephemeral notes.

The system is two-tier. **Per-repo** state lives in each repo's `.ai/`. **Org-wide** state has a location question that is **still open** (flagged 2026-07-23): it currently lives in `workspace/.ai/` (bootstrapped 2026-07-15; `progress.md` committed there as shared coordination state, sessions dispatching from `workspace/dispatch.md`), but `workspace/` is a private local repository — invisible to anyone forking or cloning a toobuntu repo, and to the maintainer on a second machine. The refinement under consideration homes org-wide knowledge in **repo-foundation** instead (a subdirectory of RF's own `.ai/`, distinct from RF-specific state) and syncs it to a subdirectory of each consumer's `.ai/`, so every clone carries the org knowledge. The two-tier split stands; only the org tier's home is being reconsidered, in the conventions session. A session rooted in a sandbox clone that cannot write the org tier relays through a gitignored `<repo>/.ai/org/progress-relay.md` drop that the maintainer, or the next desktop-rooted session, merges upward.

The boundary with Claude Code memory is explicit: **`.ai/` holds project knowledge** (versioned, contributor-visible, portable across machines); **Claude's per-machine memory holds only agent-workflow preferences.** A durable *decision* still graduates to an ADR; `.ai/memory.md` holds the operational facts and gotchas that are not themselves decisions.

Distribution follows the ownership tiers (ADR 0003, ADR 0016): `gitignore.baseline` carries the `.ai/progress.md` and `.ai/scratchpad.md` ignore lines; `.ai/progress.template.md` syncs as a seed; `foundation-init` seeds `.ai/memory.md`. Wiring those into the baselines is the conventions session's implementation task — this ADR records the decision to adopt the layout org-wide.

### Consequences

- Good, because session-spanning context is versioned, contributor-visible, and survives clone retirement — unlike per-machine agent memory.
- Good, because the durable/volatile split keeps append-only decisions (`memory.md`) from being churned by fast-moving status (`progress.md`).
- Good, because one convention serves every repo and both tiers, with a single dispatch front door.
- Bad, because a gitignored per-repo `progress.md` is absent on a fresh clone until seeded from the template; `foundation-init` and the relay drop mitigate.
- Neutral, because `memory.md` overlaps in spirit with ADRs and `docs/`; the rule above (decisions become ADRs; facts and gotchas stay in `memory.md`) draws the line.

## More Information

Adopted from BrewUI's `.ai/` pattern (reference evaluation in `workspace/reference-eval-recommendations.md` §§ 1–2 and `reference-eval-next-steps.md`). The org tier was bootstrapped 2026-07-15 (`workspace/.ai/`, `workspace/dispatch.md`). The distribution mechanics and the surrounding docs split are the conventions session (the `workspace/dispatch.md` "Conventions + continuity" row), sourced from rf-upstream-notes §§ 18.6 and 18d–18j. The distinction between this layer and Claude Code memory is the maintainer's ruling recorded in the reference evaluation.
