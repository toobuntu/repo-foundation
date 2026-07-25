<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Repo memory — repo-foundation

> Durable per-repo knowledge (ADR 0022). Append dated entries (`## YYYY-MM-DD — Topic`); never rewrite history — a correction is a new entry naming what it supersedes. Decisions graduate to ADRs; org-wide knowledge belongs in `.ai/org/memory.md` (edited only in repo-foundation); volatile status belongs in the gitignored `.ai/progress.md`.

## 2026-07-23 — Continuity layer landed; notes migration pending

The `.ai/` layer (ADR 0022) is implemented in this repository. The durable findings accumulated in `docs/handoff/rf-upstream-notes.md` (shfmt heredoc corruption, ShellCheck directive facts, sandbox placement, and the rest) migrate into this file at the canonical repairs session, which dispositions that document section by section; until then rf-upstream-notes remains the older record.

## 2026-07-24 — Sync-mechanics constraints worth keeping in view

- **Guard pin bootstrap:** `provides/github/workflows/foundation-guard.yml` pins repo-foundation by commit (`ref:`). The pin must be bumped to a main commit that carries the `--guard` engine after the sync-mechanics branch merges and BEFORE the first sync ships the guard to consumers; at a pre-guard pin the check fails on the unknown option. Ongoing rule: a manifest or engine change the guard must see requires a pin bump, delivered by the next sync (the sync is the pin's writer).
- **Dependabot vs the guard (maintainer ruling, 2026-07-24):** Dependabot PRs are exempt from the foundation guard — a consumer may merge a pinned-action bump (security fixes especially) ahead of the canonical sync. Consequence to expect: until repo-foundation bumps the same pin, a sync run renders the older canon and would open a converge-PR proposing the revert — so bump promptly in RF when a consumer takes a Dependabot bump on a canonical workflow.
- **Exec-bit drift never self-heals:** the engine compares content only, so a consumer `chmod -x` on a canonical script with unchanged content is not corrected by the next sync (and the guard passes it: mode-only changes render no content diff). The synced lint-perms CI is the net that catches it.
- **Engine child processes in specs:** spawn `RbConfig.ruby`, never bare `ruby` — a bare name resolves through PATH to the frozen macOS system Ruby 2.6. BSD `env -P` locates only the utility and does not export the modified PATH to children; `brew exec` does provide portable Ruby but strips `TMPDIR`, which in the Claude Code sandbox pushes `Dir.mktmpdir` into the repo root where `git init` trips the `.git/hooks` write denial — so in-sandbox suite runs use `env -P… PATH=… bundle exec rspec`.
