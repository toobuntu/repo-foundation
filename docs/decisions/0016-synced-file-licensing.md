---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 16
title: License a synced file by which repository owns it
status: accepted
date: 2026-07-22
decision-makers:
  - toobuntu
---

# License a synced file by which repository owns it

## Context and Problem Statement

The sync pushes files from repo-foundation to consumers (ADR 0003). repo-foundation is licensed `GPL-3.0-or-later`, but consumers are not uniform: homebrew-cask-tools is `GPL-3.0-or-later OR BSD-2-Clause`, and a future consumer could be permissive-only. Every synced file must declare a license under SPDX/REUSE in the consumer, and `reuse lint` must stay green there. So whose license does a synced file carry in the consumer — repo-foundation's, or the consumer's?

The synced files fall into two classes that answer this differently. Some are **mirrors**: repo-foundation owns them, the consumer receives them byte-for-byte under a "synced from repo-foundation — do not modify it directly" header, and never edits them (the hooks, `annotate.sh`, the lint and CI configs — the `canonical`, `template`, and `generate` modes). Others are **merges**: the consumer owns the file and repo-foundation manages only a sentinel-delimited region inside it (`AGENTS.md`, `CONTRIBUTING.md`, `.gitignore`, `.claude/settings.json` — the `baseline-merge` mode). A single rule for both is wrong: a mirror is repo-foundation's work, a merge is the consumer's.

## Decision Drivers

- Honest provenance: a file's declared license should match who owns it.
- `reuse lint` passes in every consumer (every referenced license has its text in `LICENSES/`).
- Compliant on arrival: the sync pull request should pass the consumer's `lint-reuse` job without a separate fix-up step.
- Minimal moving parts: the sync should not need to know each consumer's license.
- Per-repo autonomy where the consumer genuinely owns the file.

## Considered Options

- **License by ownership** (chosen): mirrors keep repo-foundation's license; a merge's managed region is license-neutral and the consumer's own file supplies the license; a per-file override covers exceptions.
- **Uniform consumer license on every synced file**: re-stamp every mirror to the consumer's license, by stripping repo-foundation's header on sync and re-annotating from a per-consumer license, or by having each consumer's `REUSE.toml` glob the synced paths.
- **Uniform repo-foundation license everywhere**: stamp `GPL-3.0-or-later` on the merged files too — rejected, because it relabels files the consumer owns.

## Decision Outcome

Chosen: **license by ownership.**

- **Mirrors (`canonical` / `template` / `generate`)** keep repo-foundation's inline SPDX header. The file is repo-foundation's GPL work, mirrored under a "do not modify it directly" header; declaring repo-foundation's license is the honest statement of provenance, and the consumer's sync pull request is compliant on arrival.
- **Merges (`baseline-merge`)** carry the consumer's license. The managed-region source in repo-foundation is therefore license-neutral: its SPDX is declared in `provides/repo/REUSE.toml` so no header is wrapped into the consumer's file, and the consumer's own header (or its own `REUSE.toml`/sidecar) supplies the license. The one exception is `provides/repo/settings.baseline.json`, whose `.license` sidecar IS synced, because the generated `.claude/settings.json` is a whole generated file rather than a region inside a consumer-owned one.
- **Class fragments (`fragment`; added 2026-07-22)** extend the merge tier with a middle layer. A settings delta that starts life in one consumer's `settings.addenda.json` promotes to RF management once a second consumer needs it (the rule-of-three instinct applied at n = 2): it becomes an RF-owned fragment (e.g. `provides/repo/settings.homebrew.json`), mapped only to the consumers of that class, and the engine folds it into the baseline-merge JSON target **between** the baseline and the consumer's own addenda — baseline → class fragments → addenda, later layer wins scalars, arrays union. Ownership per layer stays single: baseline = org LCD (RF), fragment = shared class delta (RF), addenda = consumer-unique (consumer). Licensing follows the merge rule above: a fragment is a merge input, never synced as a file, so it rides `provides/repo/REUSE.toml` and the generated target's sidecar still comes from `settings.baseline.json.license`.
- **Exception for a single mirror**: a consumer that genuinely needs a different license for one mirrored file adds a `precedence = "override"` entry for that path in its own `REUSE.toml`. The exception is explicit, auditable, and local to the consumer — not the default.

A non-`GPL-3.0-or-later` consumer is served without re-stamping: `reuse lint` requires only that each referenced license's text be present in `LICENSES/`, not that the repo be single-license. The consumer carries `GPL-3.0-or-later.txt` (for the mirrors) alongside its own license text; `reuse download --all` — run post-sync by `foundation-init` or in the consumer's `lint-reuse` job — fetches any referenced-but-missing license text idempotently; and the consumer annotates its *own* files with its own license via `ANNOTATE_LICENSE=<spdx-id> scripts/annotate.sh`. The result is an honest mixed-license repository, each file labeled by its owner.

### Consequences

- Good, because each file's license states who owns it: repo-foundation's GPL on the mirrors it ships, the consumer's license on the files the consumer edits.
- Good, because the sync needs no per-consumer license and writes no header-free file in transit; the consumer's pull request is compliant on arrival.
- Good, because repo-foundation keeps real inline headers on the files it uses itself, rather than emptying them to serve consumers.
- Bad, and this is the counter-argument that may reopen the decision: a consumer that must be **license-pure** — zero GPL files, for example to be absorbed wholesale into a permissive upstream, or a firm rule that every file physically in homebrew-cask-tools must read `GPL-3.0-or-later OR BSD-2-Clause` — cannot use this model for mirrors. Per-file overrides on every mirror would defeat the simplicity. If that becomes the firm intent, switch to the uniform-consumer-license option: strip repo-foundation's header on sync and re-annotate from a per-consumer `license` field in the manifest, or have each consumer's `REUSE.toml` glob the synced paths. That is a larger change to the sync engine and to this ADR, deliberately deferred until the need is real.
- Neutral, because license-text completeness in a consumer is maintained by `reuse download`, not by hand, so adding a differently-licensed consumer is a one-time `download` plus its own annotation pass.

## More Information

The sync architecture and its modes are ADR 0003; the `.template` and `.baseline` infixes that mark the two file classes are ADR 0002; the policy of referencing org-wide ADRs by pointer rather than copy is ADR 0004. REUSE's `precedence` semantics (the per-file override) are specified at
[reuse.software](https://reuse.software/spec/).
