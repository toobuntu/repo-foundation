---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 4
title: Keep org-wide ADRs only in repo-foundation; reference them by pointer
status: accepted
date: 2026-07-21
decision-makers:
  - toobuntu
---

# Keep org-wide ADRs only in repo-foundation; reference them by pointer

## Context and Problem Statement

Some decisions are org-wide: the Trojan-Source strategy, the REUSE-lint hook strategy, the merge strategy. The implementation each governs — a hook, a CI job, a script — is synced to every consumer (ADR 0003), and the synced file is byte-identical across consumers. Such a file often references its ADR ("rationale: see …"). That reference must resolve to one location for every consumer, since the file's bytes are the same everywhere.

Copying the ADR into each consumer's `docs/decisions/` breaks the moment a consumer writes its own first ADR: the org-wide copy and the consumer's local ADR collide on number 0001. The question is where org-wide ADRs live and how synced files and consumers point at them.

## Decision Drivers

- One canonical home per org-wide decision.
- No numbering collisions between org-wide and consumer-local ADRs.
- A synced, byte-identical file must reference one stable location.
- Consumers keep independent ADR numbering, free to start at their own 0001.

## Considered Options

- **Org ADRs live only in repo-foundation; synced files and consumers point to them by repo-qualified id or stable URL** (chosen).
- **Copy each org ADR into every consumer** under a reserved-number scheme (e.g. consumers must leave 0001–0010 free for org ADRs).
- **Propagate one per-repo pointer ADR** that occupies the consumer's 0001 and points at repo-foundation.

## Decision Outcome

Chosen: org-wide and cross-cutting ADRs are canonical in `toobuntu/repo-foundation/docs/decisions/` only, with repo-foundation's own clean numbering. The numbering policy has two phases, keyed on publication:

- **During the build-out (before the first sync)** nothing outside this repository references an ADR number, so numbering is not load-bearing — renumber freely when curating the sequence, including when a promoted consumer ADR merges into or reorders the set.
- **Once an ADR is published** — synced files or consumers reference it by number or URL, which the first sync makes true for the whole set — its number is immutable. A promoted or new ADR then takes the next unused number, appended sequentially, so the sequence stays contiguous and every existing pointer stays valid.

The rest of the decision:

- The **implementation** an ADR governs is synced; the **rationale is not**. A consumer carries the hook or CI job, not the ADR text.
- A synced file references the ADR by its repo-foundation location or a stable URL — e.g. `https://github.com/toobuntu/repo-foundation/blob/main/docs/decisions/0006-trojan-source-detection-strategy.md` — never a local `docs/decisions/…` path the consumer does not have.
- **Consumer ADR numbering is independent** and starts at the consumer's own
  0001. Repo-specific ADRs stay in the consumer's `docs/decisions/`.
- If discoverability needs it, sync a short **unnumbered** `docs/decisions/README.md` pointer ("project ADRs here; org-wide ADRs live in repo-foundation, see <url>") rather than burning a per-repo 0001 on an org pointer.

### Consequences

- Good, because there is no cross-repo numbering collision and one rationale to maintain per decision.
- Good, because a byte-identical synced file references a single unambiguous home, so the reference is correct in every consumer.
- Bad, because a reader in a consumer repository follows a pointer out to repo-foundation to read the rationale. Accepted: the implementation is local and self-explanatory; only the *why* is remote.
- Neutral, because the reserved-number scheme is rejected as brittle — it constrains every consumer's numbering forever to protect a copy that need not exist.

## More Information

This is why the canonical pre-commit hook cites the Trojan-Source ADR (0006) and the REUSE-lint ADR (0005) at their repo-foundation location rather than a local path. The sync architecture that distributes the implementations is ADR 0003.
