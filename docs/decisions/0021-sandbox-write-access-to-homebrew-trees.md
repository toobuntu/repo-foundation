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

Only Homebrew-aligned repositories need this — the taps and `brew style`/`brew tests` repos (homebrew-cask-tools, babble). repo-foundation itself does **not**: it is the sync hub, runs no brew developer command, and its RSpec suite reads project-local gems (`.bundle/config` sets `BUNDLE_PATH: vendor/bundle`) without writing anywhere under `Library/Homebrew`. So the grant is a per-consumer concern, not an org-wide default. An automated reviewer separately flagged the grants as broad — the trees include installed toolchain source. The questions are whether the grants stay, with what boundary, and **where they are declared**.

## Considered Options

Boundary:

- **Allow writes to exactly `vendor/`, `cmd/`, and `test/` under `Library/Homebrew`** (chosen).
- **Allow all of `Library/Homebrew`** — simpler but lets a session rewrite `brew.rb`, the DSL, and brew's git metadata.
- **No grant** — the maintainer runs all brew dev-commands on request (the babble Tier 3 position before 2026-07-15).
- **An isolated Homebrew checkout for agent work** — cleanest isolation, but a second brew to keep current, and `brew` on `PATH` still resolves to the live one.

Placement:

- **In each Homebrew-aligned consumer's `.claude/settings.addenda.json`** (chosen): the baseline-merge deep-merges it into that consumer's generated `.claude/settings.json`, so only the repos that need it carry it.
- **In the synced baseline `provides/repo/settings.baseline.json`** — rejected: it would grant every consumer, including the non-Homebrew ones (zman-didan, cert-automation, bob-book), write access they never use.
- **In repo-foundation's own `.claude/settings.json`** — rejected: RF does not need it (above), so it would be dead config, and it is not the template consumers inherit anyway.

## Decision Outcome

Chosen: allow writes to exactly the three directories, declared **only** in each Homebrew-aligned consumer's `.claude/settings.addenda.json` (the array unions into that consumer's generated settings under ADR 0016's baseline-merge). The synced baseline (`provides/repo/settings.baseline.json`) deliberately carries no `allowWrite`, so non-Homebrew consumers stay unaffected; repo-foundation's own settings carry none either. The boundary was validated in the babble-w3 session (2026-07-15; `docs/handoff/rf-upstream-notes.md` § 3). Everything else under `Library/Homebrew` — `brew.rb`, the DSL, git metadata — stays read-only, which is the boundary that matters: the three writable trees are exactly where brew's own developer workflow writes (vendored gems, external-command hardlinks, spec fixtures). Cache traffic needs no grant at all — `HOMEBREW_CACHE` and `HOMEBREW_TEMP` pointed at `$TMPDIR` keep `brew style` and plain `brew typecheck` fully sandboxed once gems are current.

### Consequences

- Good, because the grant reaches only the repos that use it: non-Homebrew consumers and the hub itself never widen their sandbox.
- Good, because sandboxed sessions in a Homebrew-aligned repo run the brew dev-commands self-serve instead of queueing on the maintainer.
- Good, because the boundary is enforced structurally: toolchain source and git metadata remain unwritable, so a misbehaving session can dirty caches and vendored gems but not brew's code.
- Bad, because `vendor/` includes the portable Ruby the RSpec suite runs on, so a bad write can break the local toolchain until `brew vendor-install` restores it. Accepted at Tier 3, where the remoteless clone is the containment and the damage is local and recoverable.
- Neutral, because two fallbacks remain for sessions without the grant: the `excludedCommands` + ask entries for interactive runs, and `brew mcp-server` (`.mcp.json`), which covers style/typecheck/tests with no filesystem widening.

## More Information

Origin: commit `d6de362` (2026-07-15) and `docs/handoff/rf-upstream-notes.md` § 3, which records the session that verified both unlocks. The three entries were briefly kept in repo-foundation's own `.claude/settings.json` and are being moved to the consumer addenda per this decision. The baseline-merge/addenda model is ADR 0016; the sandbox model and writable-area default are in `docs/agent-principles.md`; the Ruby toolchain the grant serves is ADR 0011.
