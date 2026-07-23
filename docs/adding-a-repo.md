<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Adding a repository

The onboarding runbook: how a repository — brand new or pre-existing — comes under repo-foundation management. This is maintainer-internal process; the contributor-facing surface is each repo's own `AGENTS.md` / `CONTRIBUTING.md`. Day-to-day operation after onboarding is `docs/maintaining-a-repo.md`.

## The ordered path

1. **Create the repository** on GitHub (or pick the existing one).

2. **Bootstrap from a repo-foundation checkout:**

   ```sh
   scripts/foundation-init.sh [--license SPDX-ID] /path/to/new-repo
   ```

   It copies the copy-once scaffolds (the `ci` / `codeql` / `copilot-setup-steps` workflows, `.vale.ini`), seeds the baseline-merge targets (`AGENTS.md`, `CONTRIBUTING.md`, `.gitignore`) with an empty managed region for the first sync to fill, seeds `CLAUDE.md`, `.claude/settings.addenda.json`, and the `.ai/` continuity files (ADR 0022: the committed `.ai/memory.md`, plus a starting gitignored `.ai/progress.md`), and brings the tree into REUSE compliance under `--license` (default `GPL-3.0-or-later`; ADR 0016).

3. **Review, commit, push** in the new repo, and activate the hooks once per clone:

   ```sh
   git config core.hooksPath .githooks
   ```

4. **Add the consumer entry** to `sync-manifest.yaml`: the repo under `consumers:` with the `sets` matching its class (compare an existing consumer of the same kind — a Homebrew tap, a Go repo, an Objective-C daemon). Commit through the normal PR path; the manifest is a contract, so reason about the sets rather than copying blindly.

5. **Install the sync App** (`toobuntu-token-app`) on the repository: GitHub → Settings → Installations → Repository access. Each sync matrix leg mints a token scoped to its one consumer, so a repo the App does not cover is simply unreachable — installation is the enable switch.

6. **Run the sync**: dispatch `sync-to-consumers.yml` (`gh workflow run "Sync to consumers"`). Today a dispatch renders every consumer — legs without App access fail at token minting and do not block the others; a `consumer=<slug>` filter input is queued with the sync-mechanics work.

7. **Merge the sync pull request** in the consumer. The managed regions fill, the canonical files arrive with their "do not modify it directly" headers, and the repo is aligned from then on.

## Pre-existing content

A repository with real history needs a reconciliation pass before its first sync: compare what it carries against what the sync will impose, and disposition each divergence (adopt the canonical, record an exclusion with a reason, or promote the local improvement into repo-foundation). The pre-sync freshness audit (`docs/handoff/rf-upstream-notes.md` § 15, whose `--audit` engine mode is queued) is that pass; sweep the repo's own `docs/handoff/` for reconcile notes first — each consumer's notes are dispositions waiting to be consumed.

## Dormant repositories

A dormant repo that will eventually come under management is listed in `sync-manifest.yaml` as a commented, deferred consumer entry and onboarded with this same runbook at revival.
