<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Opening prompt — first sync and consumer cleanup

Paste this to open the session that takes repo-foundation from "pushed to GitHub" to "consumers aligned." It is the bridge between the W1 build-out and the rest of the master plan; the maintainer wants the sync and the consumer cleanups to land **before** other development (W3 and onward).

**Root the session in `~/devel/claude/desktop/toobuntu/repo-foundation`.** The engine (`.github/actions/sync/sync-files.rb`) and the manifest live here, and it takes a consumer's working tree as an argument. Local consumer clones are siblings under `~/devel/claude/desktop/toobuntu/`; a dry-run reads them (no writes), so it works from here. The *real* sync runs in GitHub Actions (`sync-to-consumers.yml`), which clones both sides itself.

## The first sync is NOT yet safe to run blind

Three gates stand between "pushed" and "trigger the sync." Do them in order.

### 1. File-by-file disposition review (the safety gate) — NOT DONE

`docs/reviews/` does not exist. Push-from-canonical **overwrites** each `mode: canonical` file in the consumer. Without a per-file review, the first sync can clobber a consumer's intentional divergence. Before any real sync, for every consumer, diff each canonical target against what the consumer ships today and record a verdict (`pick-now` / `pick-defer` / `have` / `drop`), grounded in the actual diff — the method from `~/devel/claude/desktop/toobuntu/zman-didan/docs/reviews/pr1-review.md`. Land the result under `repo-foundation/docs/reviews/` (per consumer or consolidated). This is the item `workspace/repo-foundation/w1-hooks-review-prompt.md` flagged and that Sessions 1–5 deferred.

### 2. Resolve the manifest `# CONFIRM` markers

`grep -n CONFIRM sync-manifest.yaml`. Open questions: `ruby_hook_tests` for zman-didan and homebrew-babble; `sandbox` for bob-book and cert-automation; `swift_plugin` (and the `ksh` question) for cert-automation; homebrew-babble's `swift_plugin` if W3 revives `quit_alert.swift`; dot-github's consumer set. Each decides what a consumer receives, so resolve them before syncing.

### 3. Dry-run the engine against every real consumer

The engine has unit coverage (`spec/integration/sync_files_spec.rb`) but has never run against a real consumer checkout. Per consumer:

```sh
.github/actions/sync/sync-files.rb toobuntu/<repo> ../<repo> --dry-run
```

Read every "would update" line against the disposition review. Investigate any surprise before it becomes a PR.

## Maintainer's manual prerequisites (GitHub side)

From `workspace/repo-foundation/bootstrap-actions.md`: re-sign the batch (`scripts/sign-push.sh`) and push repo-foundation; create the GitHub App (or reuse cask-tools'), set `SYNC_APP_CLIENT_ID` (var) and `SYNC_APP_PRIVATE_KEY` (secret) on repo-foundation, and install the App on every consumer. The agent cannot do these.

## Run the first sync

```sh
gh workflow run sync-to-consumers.yml --repo toobuntu/repo-foundation
```

Each consumer gets a `sync-from-foundation` pull request, one commit per file. Review and merge per consumer, cross-checking the disposition review.

## Consumer cleanups (after each consumer's first sync merges)

- **Drop local copies of the org-wide ADRs** now canonical in repo-foundation (blackoutd 0001/0004/0005/0006/0007/0008; hct 0001/0002; zman-didan 0001); keep only repo-specific ADRs and rely on repo-foundation + a pointer (ADR 0004).
- **homebrew-cask-tools:** delete `docs/shared-guidelines.md` (its org-wide content is now in the synced `docs/agent-principles.md`); repoint `AGENTS.md` / `CLAUDE.md`. Confirm it carries Homebrew/brew's `.editorconfig` + `.shellcheckrc` verbatim and lints via `brew style` (it is excluded from `shell_lint`). Cutover from its hand-rolled sync (see `docs/handoff/pr36-reconciliation-outcome.md`): disable the scheduled `Sync shared configuration` workflow before closing PR #41 (`gh workflow disable "Sync shared configuration" --repo toobuntu/homebrew-cask-tools`), otherwise its Wednesday run re-creates the PR; then delete `.github/workflows/sync-shared-config.yml` (the engine does not delete files), close its PR #41 unmerged, add the `adrs` MCP server and the `50-adrs` hook line to its `AGENTS.md`/`.mcp.json`, and prefer marking ADRs 0001/0002 `superseded` (pointing at RF 0012/0003) over deleting — deletion would leave the MADR sequence starting at 0003.
- **cert-automation:** its `.ksh` are covered by the dialect-aware `shell_lint` (`shellcheck --shell=ksh` + `ksh -n` where present, `shfmt` skipped), so drop the now-canonical `shellcheck` and `reuse` jobs from its `lint.yml`; keep a `ksh -n` job (installing ksh93) only for the authoritative CI syntax pass. Fix the real `shellcheck --shell=ksh` findings the sync surfaces in its own scripts.
- **zman-didan:** migrate off the local `Didan` Vale style to the synced `Toobuntu` (delete `.vale/styles/Didan/`; keep the Hebrew terms in a repo-local vocab). See `docs/handoff/vale-consumer-cleanup-prompt.md`.
- **homebrew-babble:** carries Homebrew/brew's shell config + `brew style`; confirm it runs `brew style` over its shell.
- After a cycle, delete `~/devel/claude/desktop/_claude-config-baseline.deprecated/`.

## Then resume the master plan

With the sync humming and consumers aligned, W3 (homebrew-babble) and the rest proceed. W6 (the `isolate` rename) is the next repo-foundation change and takes the next free ADR number (0018 went to the PR #36 ADR-tooling reconciliation).
