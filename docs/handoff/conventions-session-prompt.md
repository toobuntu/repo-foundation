<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Conventions + continuity session — opening prompt

The next repo-foundation session implements the in-repo `.ai/` continuity layer (ADR 0022) and reconciles the org-continuity docs into repo-foundation. This is the `<workspace-root>/dispatch.md` "Conventions + continuity" row, scoped to the `.ai/` half.

## Setup

- Root the session in `repo-foundation`, on a new branch `feature/ai-continuity` off `main`.
- Settled decisions — do not re-litigate: ADR 0022 (adopt `.ai/`), ADR 0016 (the class-fragment tier), ADR 0003 (sync architecture). The one OPEN question the session must resolve is the org-tier location (see the prompt).

## Opening prompt

Paste the block below to open the session.

```text
Implement the in-repo .ai/ continuity layer org-wide (ADR 0022) and reconcile
the org-continuity docs into repo-foundation. Root: repo-foundation; work on a
new branch feature/ai-continuity off main.

Read first, before proposing anything:
- docs/decisions/0022-ai-continuity-directory.md (the decision; note the OPEN
  org-tier-location question in its Decision Outcome) and
  docs/decisions/0016-synced-file-licensing.md (the class-fragment tier added
  2026-07-22 — the precedent for syncing shared config with per-consumer merge).
- The design source: <workspace-root>/.ai/memory.md and
  progress.md; <workspace-root>/reference-eval-recommendations.md sections 1-2;
  <workspace-root>/reference-eval-next-steps.md.
- The org-continuity docs to reconcile: <workspace-root>/dispatch.md,
  <workspace-root>/conversation-management.md, and repo-foundation docs/workflow.md.
- docs/handoff/rf-upstream-notes.md sections 18.6 and 18d-18j (the continuity-system design record).

Scope:
1. Per-repo .ai/ (ADR 0022): commit .ai/progress.template.md; add .ai/progress.md
   and .ai/scratchpad.md to provides/repo/gitignore.baseline; have
   scripts/foundation-init.sh seed .ai/memory.md from the template.
2. RESOLVE ADR 0022's open org-tier question: home org-wide knowledge in
   repo-foundation (a subdir of RF's own .ai/, e.g. .ai/org/, kept distinct from
   RF-specific .ai/ state) and sync it to each consumer's .ai/org/ so every clone
   carries it — decide the sync mode (canonical copy vs the generate/class-
   fragment pattern) and record the resolution as an ADR 0022 amendment or a new
   superseding ADR. <workspace-root>/.ai/ was the bootstrap; it does not survive a fork
   or a second machine, which is why the home moves into RF.
3. Wire the sync: manifest component_set(s) + consumer mappings for the .ai/
   pieces; mirror the ownership tiers (ADR 0003/0016).
4. Reconcile the dispatch rituals and conversation-management guidance into RF's
   agent-principles.md / workflow.md where they are genuinely org-wide (not
   maintainer-machine-specific); leave machine-specific bits in workspace.
5. Tests: extend sync_manifest_spec.rb / sync_files_spec.rb to cover the new
   .ai/ sync (sources exist, mapped to the right consumers, gitignore carries the
   volatile files).

Confirm the org-tier design (the RF subdir + the chosen sync mode) with me
BEFORE large implementation — this is the confirm-before-churn case, and it
touches the sync contract (reason about every consumer). Gates before each
commit: adrs doctor, rumdl check ., the tracked-vale one-liner, reuse lint,
bundle exec rspec. Commit unsigned; sign-push at the end.

Adjacent but SEPARATE (do not fold in unless I say so): the broader docs split
in the dispatch "Conventions + continuity" row (adding-a-repo, maintaining-a-
repo, architecture, repo-standards) — flag it, don't build it here.
```
