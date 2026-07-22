---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 21
title: Sandbox write access to Homebrew's vendor, cmd, and test trees
status: accepted
date: 2026-07-21
decision-makers:
  - toobuntu
---

# Sandbox write access to Homebrew's vendor, cmd, and test trees

## Context and Problem Statement

Sandboxed agent sessions on Homebrew-aligned repositories need to run brew developer commands — `brew style`, `brew typecheck`, `brew tests` — and the Ruby toolchain they ride on. Two mechanics force writes into Homebrew's own tree at `/opt/homebrew/Library/Homebrew/`: gem reconciliation (`bundle install` writes `vendor/bundle` gems and `vendor/portable-ruby` updates), and the hardlink test harnesses, which `brew tests` only discovers *inside* brew's tree — they create entries like `cmd/babble.rb`, `cmd/babble/…`, `test/cmd/babble_spec.rb`, and `test/fixtures/…`, so the parent directories `cmd/` and `test/` need write permission for `ln -f`/`mkdir`/`rm -f` (scoping to `cmd/<repo>` alone is not sufficient). The default sandbox writable area is the project tree, so without a grant every such session dead-ends on "ask the maintainer to run it."

An automated reviewer flagged the grants as broad — the trees include installed toolchain source. The question is whether the grants stay, and with what boundary.

## Considered Options

- **Allow writes to exactly `vendor/`, `cmd/`, and `test/` under `Library/Homebrew`** (chosen).
- **No grant** — the maintainer runs all brew dev-commands on request (the babble Tier 3 position before 2026-07-15).
- **Allow all of `Library/Homebrew`** — simpler but lets a session rewrite `brew.rb`, the DSL, and brew's git metadata.
- **An isolated Homebrew checkout for agent work** — cleanest isolation, but a second brew to keep current, and `brew` on `PATH` still resolves to the live one.

## Decision Outcome

Chosen: allow writes to exactly the three directories, recorded in `.claude/settings.json` (`sandbox.filesystem.allowWrite`) and validated in the babble-w3 session (2026-07-15; `docs/handoff/rf-upstream-notes.md` § 3). Everything else under `Library/Homebrew` — `brew.rb`, the DSL, git metadata — stays read-only, which is the boundary that matters: the three writable trees are exactly where brew's own developer workflow writes (vendored gems, external-command hardlinks, spec fixtures). Cache traffic needs no grant at all — `HOMEBREW_CACHE` and `HOMEBREW_TEMP` pointed at `$TMPDIR` keep `brew style` and plain `brew typecheck` fully sandboxed once gems are current.

### Consequences

- Good, because sandboxed sessions run the brew dev-commands self-serve instead of queueing on the maintainer.
- Good, because the boundary is enforced structurally: toolchain source and git metadata remain unwritable, so a misbehaving session can dirty caches and vendored gems but not brew's code.
- Bad, because `vendor/` includes the portable Ruby the RSpec suite runs on, so a bad write can break the local toolchain until `brew vendor-install` restores it. Accepted at Tier 3, where the remoteless clone is the containment and the damage is local and recoverable.
- Neutral, because two fallbacks remain for sessions without the grant: the `excludedCommands` + ask entries for interactive runs, and `brew mcp-server` (`.mcp.json`), which covers style/typecheck/tests with no filesystem widening.

## More Information

Origin: commit `d6de362` (2026-07-15) and `docs/handoff/rf-upstream-notes.md` § 3, which records the session that verified both unlocks. The sandbox model and the writable-area default are described in `docs/agent-principles.md`; the Ruby toolchain the grant serves is ADR 0011.
