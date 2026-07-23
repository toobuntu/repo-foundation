<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Repo memory — repo-foundation

> Durable per-repo knowledge (ADR 0022). Append dated entries (`## YYYY-MM-DD — Topic`); never rewrite history — a correction is a new entry naming what it supersedes. Decisions graduate to ADRs; org-wide knowledge belongs in `.ai/org/memory.md` (edited only in repo-foundation); volatile status belongs in the gitignored `.ai/progress.md`.

## 2026-07-23 — Continuity layer landed; notes migration pending

The `.ai/` layer (ADR 0022) is implemented in this repository. The durable findings accumulated in `docs/handoff/rf-upstream-notes.md` (shfmt heredoc corruption, ShellCheck directive facts, sandbox placement, and the rest) migrate into this file at the canonical repairs session, which dispositions that document section by section; until then rf-upstream-notes remains the older record.
