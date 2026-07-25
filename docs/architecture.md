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
- **`sync-to-consumers.yml`** runs on a schedule and on dispatch (`consumer=<slug>` optionally filters the matrix to one repo). It builds a matrix from the manifest's `consumers:`, mints a GitHub App installation token scoped to each single consumer, clones it with full history, runs the engine, and opens a sync pull request when anything changed — one commit per file (see Commit mechanics below).

## The manifest

`sync-manifest.yaml` is the declarative catalog: `upstreams` (files pulled in, with mutations), `component_sets` (named, reusable file groups), and `consumers` (which repo subscribes to which sets, with `exclude` and `extra` for per-repo variance). It is a contract: a change to a set changes every subscriber, so reason about every consumer before editing.

## The engine and its modes

`.github/actions/sync/sync-files.rb` — stdlib-only Ruby, runnable locally against a sibling clone. Besides the default render-and-write (which also emits the change list and pull-request body for the commit loop), it has three read-only modes of operation:

- **`--dry-run`** reports what would change and writes nothing.
- **`--audit`** is the pre-sync freshness report: one row per manifest (source → target) pair — same/differs/missing status, consumer and repo-foundation mtimes (a review signal; the rendered-content comparison decides), a diffstat on mismatch — plus the consumer's exclusions with their reasons. It always exits 0; the disposition pass (adopt-into-RF / keep-RF / record an exclude with a reason) is human.
- **`--guard <base>`** is the foundation guard (below): render every component in memory and flag only the files a pull request touched that diverge from the canon.

One mode per component (ADR 0002, ADR 0016):

| Mode | Ownership | Behavior |
| --- | --- | --- |
| `canonical` | repo-foundation | Byte copy plus a "synced from repo-foundation — do not modify it directly" header in the target's comment syntax. |
| `template` | consumer after copy | Copied with the `.template` infix stripped; the consumer owns it from then on (realignment is the age-based scaffold-drift nudge, ADR 0015). |
| `generate` | repo-foundation | Built per consumer (`dependabot.yml` filtered to the ecosystems the target actually uses). |
| `baseline-merge` | consumer file, repo-foundation region | Text targets keep a sentinel-delimited managed region (Markdown regions padded with a blank line inside each sentinel); the JSON target (`.claude/settings.json`) is regenerated as baseline → class fragments → consumer addenda, later layer wins scalars, arrays union. |
| `fragment` | repo-foundation | A class-shared merge input (ADR 0016): folded into the same consumer's baseline-merge JSON target, never written as a file of its own. |

Licensing follows ownership (ADR 0016): mirrors carry repo-foundation's GPL header; merged files carry the consumer's license, with the region sources declared license-neutral in `provides/repo/REUSE.toml`.

Managed-region markers are handled statefully and loudly. An inverted or duplicated marker pair aborts the run. A target that exists without markers splits on marker history (`git log -S<begin marker> -- <path>`, which is why consumer checkouts fetch full history): markers never present means bootstrap — the region is prepended, after the H1 in Markdown or after the leading comment block in hash-comment targets, and the position is consumer-owned afterward — while markers that WERE in history mean intent the engine cannot read, so it aborts with ready-to-run recovery: the exact `git restore --source=<short-sha> -- <path>` command and a paste-ready `{target: ..., reason: "..."}` exclude entry. Exclusions themselves are mappings with a required reason, printed by the audit report and every sync pull-request body, so per-repo variance self-documents.

## Commit mechanics

The engine makes no git commits. It writes the rendered files and emits `changes.json` (path, status, git file mode) plus `pr-body.md`; `git-data-commit.rb` turns that list into per-file chained commits through the GitHub Git Data API — blob → one-entry tree built on the previous commit's tree → commit — with deletions as `sha: null` tree entries and one ref create at the end. Minted under the App installation token, these commits arrive GitHub-signed (web-flow, **Verified**) with real file modes on new and modified files; no machine user and no signing key exist (`docs/bootstrap/sync-bot-and-signing.md`).

Sync branches are ephemeral: one `sync/<run-id>-<attempt>` branch per run. A run whose rendered tree equals an open sync pull request's head tree skips instead of duplicating it; any other open sync pull request is closed with a superseded comment and its branch deleted, so a human fix-up commit on an old sync branch is never force-push-clobbered. The pull-request body lists the converged surfaces and the exclusions with reasons — a quiet scheduled run means the consumers are converged.

## The foundation guard

Every consumer receives `.github/workflows/foundation-guard.yml` (ci_core), a required pull-request check that runs the engine's `--guard` mode. It is self-contained — no cross-repo reusable-workflow callers, so actionlint and zizmor audit the complete effective surface consumer-side — and checks out repo-foundation at a pinned commit, reading the manifest from that checkout, never from consumer-writable content. Only files the pull request itself touched can fail it (merge-base filter: drift that predates the branch belongs to the sync, not the author); baseline-merge targets compare regenerated output, so consumer-owned edits pass while edits inside a managed region — or direct edits to the generated `.claude/settings.json` bypassing the addenda file — fail. The sync App's own pull requests are exempt. Tamper backstop: an in-tree `pull_request` workflow cannot defend its own caller, so branch protection requires the check by name — a pull request that deletes or breaks the workflow leaves the required check missing and stays blocked.

## Trust boundaries

- The manifest is hub-side only; a consumer carries no sync configuration a pull request could quietly weaken.
- Each matrix leg's token is scoped to its one consumer; a repo the App is not installed on is unreachable, and one failing leg does not block the others.
- Consumers audit their own effective surface: synced workflows arrive as complete files, so actionlint and zizmor run against exactly what executes there — no cross-repo `uses:` indirection.
- The foundation guard rejects consumer edits to managed surfaces at pull-request time, and required-by-name branch protection backstops the guard's own caller.
