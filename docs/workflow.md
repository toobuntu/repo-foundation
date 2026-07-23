<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Docs & task workflow

Confirmed 2026-07-23 (previously PROPOSED 2026-06-16), reconciled with the `.ai/` continuity layer (ADR 0022). This is the single convention for where work and docs live across the org; the session-level rituals it relies on are the "Session continuity" section of `docs/agent-principles.md`.

## The problem this fixes

Handoff / session / next / master-plan / tech-debt / scaffolding docs accumulated across four locations with no clear "what's done / pending / in what order"; docs went stale as development outpaced them, and action items in chat scrolled away.

## The one rule that fixes most of it

**Separate volatile *status* from stable *design*.**

- **Status** (what's done, pending, next, who/when) is volatile → it lives in the status homes below, and *nowhere else*. Prose docs never restate it.
- **Design / intent / rationale** (why, how) is stable → it lives in docs that are *edited in place*, never snapshotted or "superseded by" a new file.

This split kills staleness (docs stop trying to track progress) and kills supersession (edit the one living doc instead of writing a new one that overrides the old).

## Where each thing lives (one home per type)

| Type | Home | Lifecycle |
| --- | --- | --- |
| Session state (per developer) | `<repo>/.ai/progress.md` — gitignored; seeded from the committed `.ai/progress.template.md` | rewritten each session; git history is not the archive (it is untracked) |
| Durable per-repo knowledge (gotchas, constraints, queued intents) | `<repo>/.ai/memory.md` | dated append-only entries; corrections are new entries |
| Durable org-wide knowledge | repo-foundation `.ai/org/memory.md`, synced read-only to `.ai/org/memory.md` in every consumer that carries the repo baseline (the org's `.github` community-health repo is the deliberate exception: it hosts served defaults, not development work) | edited only in repo-foundation; consumer sessions relay via the gitignored `.ai/org/relay.md` |
| Decision (ADR) | `<repo>/docs/decisions/`; org-wide → repo-foundation `docs/decisions/` | immutable; replaced only via "Superseded by NNNN" |
| Reference (architecture, usage, runbook) | `<repo>/docs/` | edited in place |
| Technical-debt backlog | `<repo>/docs/technical-debt.md` — a register of OPEN items with never-reused item numbers | resolved entries move to a resolved sidecar, never silently deleted |
| Roadmap | repo-foundation `docs/roadmap.md` — **one**, living (migration from the maintainer's master-plan is queued) | edited in place |
| Live opening prompts and plans | `<repo>/docs/handoff/` | live items only; executed prompts move to `docs/handoff/completed/` or are deleted once `.ai/memory.md` records the outcome |
| Reusable prompt template | repo-foundation `prompts/` | edited in place |
| Maintainer coordination (dispatch, org progress) | the maintainer's private workspace — outside the sync, machine-specific by design | per-machine; the durable half of the old workspace org tier now lives in `.ai/org/memory.md` |
| Scratch / thinking | workspace, or a session scratchpad (`.ai/scratchpad.md`, gitignored) | ephemeral, delete freely |
| Dated snapshots | **banned** (use git history) | — |

## Task tracking: three tiers, files as the local atoms

1. **`.ai/progress.md`** (gitignored) — this developer's session state: last touched, in flight, blocked, handoff.
2. **Committed registers** — `docs/technical-debt.md` (the per-repo backlog, P-numbered) and `.ai/memory.md` (durable knowledge and queued intents). Local-first, greppable, agent-readable without network.
3. **GitHub Issues as the promotion tier, not the atom**: an item graduates to an issue when it needs PR cross-references, changes state across sessions, or invites outside contribution; its register entry shrinks to one line with the issue link. Agents read and write issues via `gh`, so surfaced action items stop scrolling away in chat.

The roadmap links registers and issues; an org Project board stays out until a second maintainer exists.

## Session protocol

The start/end rituals — read `.ai/org/memory.md`, `.ai/memory.md`, `.ai/progress.md` at session start; write back at session end; graduation rules; the relay for org-wide facts — are normative in `docs/agent-principles.md` ("Session continuity") and summarized in every repo's `AGENTS.md` managed region. At the end of every session, additionally:

1. Promote durable outcomes → ADRs (decisions), `.ai/memory.md` (knowledge), issues (tasks that graduated).
2. Rewrite `.ai/progress.md` to "where I am right now + the single next action."
3. Close or update the issues the session advanced.

A generic, reusable kick-off prompt is a **template** (repo-foundation `prompts/`). A "kick off *this* effort" handoff is a live prompt in `docs/handoff/` — pointing at `.ai/` files and registers for context rather than restating it.

## Conversations: when to start a new session

Org-wide signals that a fresh session (chat or agent) beats continuing the current one:

1. **Topic shift to a different workstream or repo** — each has its own context; mixing invites drift.
2. **Two or more compaction events** — the summary that replaces detail is lossy; after a compaction, be *more* eager to suggest a fresh start, because operating on an inaccurate summary costs more than re-reading files.
3. **Accumulated stale assumptions** — repeated corrections on basics mean the context has degraded.
4. **Tool switch** — planning chat handing off to an execution session.
5. **A substantial deliverable just landed** and the next work is logically distinct.

Do not suggest a new session mid-task, for minor refinements, or when the maintainer has said to continue here. When suggesting one, write the opening prompt at suggestion time.

**Opening prompts stay short**: role and repo, the goal, what is locked (don't relitigate), and a first action — pointing at `.ai/progress.md`, `.ai/memory.md`, and the relevant registers by path instead of restating their content. Precision after context loss comes from files the session can read, not from prose in the prompt.

## Migration (incremental — do not big-bang)

- Rehome docs opportunistically: when you touch one, move it to its home above.
- Collapse per-repo handoff/next sprawl into `.ai/progress.md` + registers; executed prompts to `docs/handoff/completed/` or deletion (history keeps them).
- The roadmap migration and the maintainer-workspace drain proceed at the maintainer's pace.
