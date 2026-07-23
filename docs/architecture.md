<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Architecture

How repo-foundation is built: the two sync directions, the engine and its modes, the ownership tiers, and the trust boundaries. What a consumer experiences day to day is `docs/maintaining-a-repo.md`; the why behind each choice is the ADRs under `docs/decisions/`.

## The shape

repo-foundation is a push-from-canonical hub (ADR 0003). Each shared file lives here at the same path it occupies in a consumer, is run on repo-foundation's own commits (a breaking change fails this repo's CI before any consumer sees it), and is pushed outward as pull requests. Files with no natural path here — per-consumer baselines, seed templates, plugin masters this repo does not run — live under `provides/` (ADR 0001).

Two workflows are the two directions:

- **`sync-from-upstreams.yml`** pulls the files repo-foundation relays from external upstreams (Homebrew), applies the `yq` mutations declared in the manifest, prepends the synced header and SPDX, and opens a pull request on drift.
- **`sync-to-consumers.yml`** runs on a schedule and on dispatch. It builds a matrix from the manifest's `consumers:`, mints a GitHub App installation token scoped to each single consumer, clones it, runs the engine, and opens a `sync-from-foundation` pull request when anything changed — one commit per file.

## The manifest

`sync-manifest.yaml` is the declarative catalog: `upstreams` (files pulled in, with mutations), `component_sets` (named, reusable file groups), and `consumers` (which repo subscribes to which sets, with `exclude` and `extra` for per-repo variance). It is a contract: a change to a set changes every subscriber, so reason about every consumer before editing.

## The engine and its modes

`.github/actions/sync/sync-files.rb` — stdlib-only Ruby, runnable locally against a sibling clone (`--dry-run`). One mode per component (ADR 0002, ADR 0016):

| Mode | Ownership | Behavior |
| --- | --- | --- |
| `canonical` | repo-foundation | Byte copy plus a "synced from repo-foundation — do not modify it directly" header in the target's comment syntax. |
| `template` | consumer after copy | Copied with the `.template` infix stripped; the consumer owns it from then on (realignment is the age-based scaffold-drift nudge, ADR 0015). |
| `generate` | repo-foundation | Built per consumer (`dependabot.yml` filtered to the ecosystems the target actually uses). |
| `baseline-merge` | consumer file, repo-foundation region | Text targets keep a sentinel-delimited managed region; the JSON target (`.claude/settings.json`) is regenerated as baseline → class fragments → consumer addenda, later layer wins scalars, arrays union. |
| `fragment` | repo-foundation | A class-shared merge input (ADR 0016): folded into the same consumer's baseline-merge JSON target, never written as a file of its own. |

Licensing follows ownership (ADR 0016): mirrors carry repo-foundation's GPL header; merged files carry the consumer's license, with the region sources declared license-neutral in `provides/repo/REUSE.toml`.

## Trust boundaries

- The manifest is hub-side only; a consumer carries no sync configuration a pull request could quietly weaken.
- Each matrix leg's token is scoped to its one consumer; a repo the App is not installed on is unreachable, and one failing leg does not block the others.
- Consumers audit their own effective surface: synced workflows arrive as complete files, so actionlint and zizmor run against exactly what executes there — no cross-repo `uses:` indirection.

## Queued mechanics

Recorded in `docs/handoff/rf-upstream-notes.md` § 18 and queued for the sync-mechanics session, so they are design intent, not yet behavior: the engine `--guard` mode with a consumer-side required check; the sentinel history-split (self-heal only when marker history proves bootstrap); exclude-with-reason manifest entries; the App-token Git Data commit loop (Verified commits, real file modes — verified by test 2026-07-15); ephemeral per-run sync branches; the `--audit` freshness mode; a `consumer=` dispatch filter.
