<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Docs & task workflow

**Status: PROPOSED** (2026-06-16) — pending maintainer confirmation of the
two open decisions at the bottom. Once confirmed, drop "PROPOSED" and this
becomes the single convention for where work and docs live across the org.

## The problem this fixes

Handoff / session / next / master-plan / tech-debt / scaffolding docs have
accumulated across four locations (`workspace/`, `workspace/<repo>/`, the
repo itself, `repo-foundation/`). Result: no clear "what's done / pending /
in what order," docs go stale as development outpaces them, some docs
"supersede parts of" others, and action items in chat scroll away and get
lost.

## The one rule that fixes most of it

**Separate volatile *status* from stable *design*.**

- **Status** (what's done, pending, next, who/when) is volatile → it lives
  in *one* task tracker, and *nowhere else*. Prose docs never restate it.
- **Design / intent / rationale** (why, how) is stable → it lives in docs
  that are *edited in place*, never snapshotted or "superseded by" a new
  file.

This single split kills staleness (docs stop trying to track progress) and
kills supersession (you edit the one living doc instead of writing a new one
that overrides the old).

## Where each thing lives (one home per type)

| Type | Home | Lifecycle | Status source |
|---|---|---|---|
| Task / action item | GitHub issue in the owning repo | open → closed | the issue (it *is* the status) |
| Cross-repo effort (a "W-phase") | a milestone + the org Project board | living | the board |
| Decision (ADR) | `<repo>/docs/decisions/`; org-wide → `repo-foundation/docs/decisions/` | immutable; replace only via ADR "Superseded by NNNN" | n/a |
| Reference (architecture, usage, runbook) | `<repo>/docs/` | edited in place | n/a |
| Roadmap (the old "master-plan") | `repo-foundation/docs/roadmap.md` — **one**, living | edited in place | links to the board |
| Session handoff | `<repo>/docs/handoff.md` — **one**, gitignored | **overwritten** each session | n/a (promote to issues) |
| Reusable prompt template | `repo-foundation/prompts/` | edited in place | n/a |
| Scratch / thinking | `workspace/` | ephemeral, delete freely | n/a |
| Dated snapshots | **banned** (use git history); `.../archive/` only if truly needed | — | — |

## Task tracking

Every actionable item is a **GitHub issue** in the repo that owns the work.
`tech-debt`, `scaffolding`, `meta`, and the `W#` effort become **labels**,
not separate files — that dissolves the tech-debt-vs-meta-file overlap. The
cross-repo "what's next, in what order" view is the **org Project board**
(or, lighter, a milestone per effort + a saved issue search). Claude reads
and updates these with `gh`, so action items it surfaces become issues
instead of chat lines that scroll away.

## `workspace/` is scratch only

Nothing durable lives in `workspace/` or `workspace/<repo>/`. As part of the
reorg, **drain it**: the master-plan → `repo-foundation/docs/roadmap.md`;
per-repo planning → that repo's issues/`docs/`; delete the dated snapshots
(git history is the archive). After draining, `workspace/` holds only
genuinely throwaway scratch.

## Session handoff protocol

One rolling `<repo>/docs/handoff.md` (gitignored), **overwritten** each
session — never a new dated file. At the **end** of every session:

1. Promote durable outcomes → issues (tasks), ADRs (decisions), or the
   roadmap (intent). 
2. Rewrite `handoff.md` to "where I am right now + the single next action."
3. Close/update the issues you advanced.

A "handoff prompt" that is generic and reusable is a **template**
(`repo-foundation/prompts/`). A handoff that is "kick off *this* effort" is
just **its issue/milestone + a pointer to context** — not a standalone file.

## Migration (incremental — do not big-bang)

1. Pick the two open decisions below.
2. Seed the tracker with the **already-known pending work** (e.g. the reorg
   PRs: babble, blackoutd, bob-book, homebrew-cask-tools, zman-didan) so
   nothing is lost in the transition.
3. Move master-plan → `repo-foundation/docs/roadmap.md`; strip its status
   prose down to links into the tracker.
4. Drain `workspace/` opportunistically (when you touch a doc, rehome it).
5. Collapse each repo's many handoff/next files into one rolling
   `handoff.md` + issues; delete the rest (history keeps them).

## Open decisions (please confirm)

1. **Task-tracker substrate** — GitHub Issues + an org Project board, vs.
   Issues + milestones (lighter), vs. a single file-based backlog in
   `repo-foundation/`. Everything above assumes GitHub Issues as the atom.
2. **Drain `workspace/`** into `repo-foundation/docs/roadmap.md` + per-repo
   issues, and retire the dated snapshots? (Recommended.)
