<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Architecture decision records

This directory holds **this repository's own** decision records, numbered from `0001` in its own sequence. They are MADR 4.0 documents, authored and checked with [`adrs`](https://joshrotenberg.com/adrs/) (`brew install adrs`); `adrs doctor` is the health gate, run by the `50-adrs` pre-commit plugin and by the `lint-adrs` CI job.

**Organization-wide decisions are not copied here.** They live once, in
[toobuntu/repo-foundation](https://github.com/toobuntu/repo-foundation/tree/main/docs/decisions),
and the files they govern reference them by that URL. An ADR's identity is its number in a single sequence, so a per-repository copy would fork the numbering contract `adrs doctor` enforces — the reasoning is ADR 0004 there.

In short: this directory explains why *this* repository is built the way it is; repo-foundation's explains why *every* repository is.
