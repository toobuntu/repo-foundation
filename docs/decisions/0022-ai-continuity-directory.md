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
- **`.ai/scratchpad/`** (optional; amended 2026-07-24 from a single `scratchpad.md`) — gitignored ephemeral notes and named commit/PR message drafts (`commit-msg-<slug>.md`, `pr-body-<slug>.md`); per-message files survive interrupted commits and never clobber each other.

The system is two-tier. **Per-repo** state lives in each repo's `.ai/`. **Org-wide** state (amended 2026-07-23, resolving the location question this ADR originally left open): the durable org tier is homed in **repo-foundation**, at `.ai/org/memory.md` — a subdirectory of repo-foundation's own `.ai/`, distinct from its repo-specific state — and synced `mode: canonical` to `.ai/org/memory.md` in every repo-baseline consumer (the `.github` community-health repo, which hosts served defaults rather than development work, is the deliberate exception), so every clone and fork carries the org knowledge. Canonical is the right mode because org knowledge is by definition byte-identical across consumers: there is no per-consumer variation, so the merge machinery (`baseline-merge`, the ADR 0016 class fragments) buys nothing, and the standard "synced from repo-foundation — do not modify it directly" header states the ownership contract. The file is edited only in repo-foundation; a consumer-rooted session that learns an org-wide fact relays it through a gitignored `<repo>/.ai/org/relay.md` drop (renamed from the pre-amendment `progress-relay.md` — what it carries is mostly memory in transit, plus coordination updates) that the maintainer, or the next repo-foundation-rooted session, promotes and deletes. The **volatile** org tier — session dispatch and org-level progress — is maintainer coordination state, full of machine-specific paths, and stays in the maintainer's private workspace outside the sync; it was the bootstrap home (2026-07-15) for the whole org tier, but it does not survive a fork or a second machine, which is why the durable half moved here.

The boundary with Claude Code memory is explicit: **`.ai/` holds project knowledge** (versioned, contributor-visible, portable across machines); **Claude's per-machine memory holds only agent-workflow preferences.** A durable *decision* still graduates to an ADR; `.ai/memory.md` holds the operational facts and gotchas that are not themselves decisions.

Distribution follows the ownership tiers (ADR 0003, ADR 0016), implemented 2026-07-23 as the `ai_continuity` component set: `.ai/progress.template.md` and `.ai/org/memory.md` sync as canonical mirrors at their natural paths (repo-foundation runs the files it ships); `gitignore.baseline` carries the `.ai/progress.md`, `.ai/scratchpad/`, and `.ai/org/relay.md` ignore lines; `foundation-init` seeds the consumer-owned `.ai/memory.md` from `provides/ai/memory.template.md` and copies the progress template to the developer's gitignored `.ai/progress.md`.

### Consequences

- Good, because session-spanning context is versioned, contributor-visible, and survives clone retirement — unlike per-machine agent memory.
- Good, because the durable/volatile split keeps append-only decisions (`memory.md`) from being churned by fast-moving status (`progress.md`).
- Good, because one convention serves every repo and both tiers: durable org knowledge rides the sync into every clone, and a single dispatch front door remains the maintainer-side arrangement.
- Bad, because a gitignored per-repo `progress.md` is absent on a fresh clone until seeded from the template; `foundation-init` and the relay drop mitigate.
- Bad, because org-memory additions from consumer-rooted sessions take a relay hop and a sync cycle to reach every clone; acceptable, since the file's genre is durable knowledge, not fast-moving status.
- Neutral, because `memory.md` overlaps in spirit with ADRs and `docs/`; the rule above (decisions become ADRs; facts and gotchas stay in `memory.md`) draws the line.

## Amendment (2026-07-26): the tier rules are enforced, not merely stated

Both halves of this decision rested on prose, and prose is what gets dropped. A queued first-sync cleanup item was lost on 2026-07-25 in a wholesale rewrite of `.ai/progress.md` and surfaced a day later only by accident. The append-only rule for the memory files had the same shape of exposure and a worse blast radius, since `.ai/org/memory.md` syncs to every consumer.

Three mechanisms, matched to how each file is stored:

- **Tracked, append-only (`.ai/memory.md`, `.ai/org/memory.md`).** Git already keeps the history; what was missing was a gate. The canonical `40-memory` pre-commit plugin rejects any commit removing a line from either file. `AI_MEMORY_ALLOW_REWRITE=1` overrides. The check is deliberately blunt — a reflow or an in-place typo fix trips it too — because loosening a gate later is easier than discovering it was lax.
- **Gitignored, rewritten freely (`.ai/progress.md`).** No history is possible, so the answer is accountability rather than recovery: `scripts/ai-session.sh start` snapshots the file, `… end` lists what the session removed, and the handoff report must account for each line. A backup alone would not have caught the 2026-07-25 loss, because nobody diffs a backup they have no reason to suspect — the maintainer's own dated snapshots under `workspace/.ai/` are the proof.
- **Gitignored, consumed once (`.ai/org/relay.md`).** Retired by rename to a dated `.ai/org/relay.consumed-*.md` rather than deleted, so an over-eager consumption is recoverable. Deletion is by hand and gated on a CONDITION, never on age: every entry has landed somewhere tracked or been declined in writing. A time-based sweep was considered and rejected — a maintainer away for a month through holiday or illness would return to find unpromoted org knowledge tidied away, which is the exact loss this amendment exists to prevent. Instead `ai-session.sh start` names any lingering consumed relay every session; the nag is the mechanism.

Consequence to plan for: append-only plus enforcement means the memory files only grow. A periodic **consolidation pass** — merging entries, pruning superseded ones, graduating durable material to an ADR, to `agent-principles.md`, or into code — is the intended use of the override, and is expected to run as its own reviewable pull request whose diff is mostly removals.

## More Information

Adopted from BrewUI's `.ai/` pattern (reference evaluation in `workspace/reference-eval-recommendations.md` §§ 1–2 and `reference-eval-next-steps.md`). The org tier was bootstrapped 2026-07-15 (`workspace/.ai/`, `workspace/dispatch.md`) and its durable half moved into repo-foundation by the 2026-07-23 amendment above (the conventions session), sourced from rf-upstream-notes §§ 18.6 and 18d–18j. The session rituals live in `docs/agent-principles.md` ("Session continuity") with a reminder in the `AGENTS.baseline.md` managed region; the surrounding docs-and-status conventions are `docs/workflow.md`. The distinction between this layer and Claude Code memory is the maintainer's ruling recorded in the reference evaluation.
