<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Outcome — PR #36 ADR-tooling reconciliation

Result of the session opened by `archive/pr36-adr-tooling-reconciliation.md` (2026-07-03). The decisions are recorded in ADR 0018; this note carries the operational detail that feeds the disposition review in `first-sync-and-consumer-cleanup.md`.

## Verdicts

- **cask-tools PR #36: closure confirmed — nothing of value lost.** The PR was already closed 2026-07-03. Its brew-man half re-landed via cask-tools PR #46; its `adrs.toml` + MADR conversions landed via PR #45; every ADR-tooling piece is now reconciled here (ADR 0018) or deliberately dropped (the dedicated `adr-doctor.yml`, the `.mcp.json` sync, the SPDX-above-frontmatter placement, the stale `joshrotenberg/brew/adrs` tap name).
- **cask-tools PR #41: close unmerged.** Its whole content is upstream `actionlint.yaml` drift adding a `paths:` ignore block for Homebrew/brew's internal `tests.yml` — a block repo-foundation's `del(.paths)` mutation strips deliberately. The relayed `ci_core` copy supersedes it with a superset `config-variables` list. Closing before the cutover is fine, with one side effect: the scheduled `sync-shared-config.yml` run (Wednesdays 08:00 UTC) force-pushes the sync branch and re-creates the PR while the workflow still exists. To keep it closed in the interim, disable the workflow (`gh workflow disable "Sync shared configuration"`); the cutover then deletes the workflow outright.

## Part 1 dispositions (implemented here)

| PR #36 piece | Disposition | Carrier |
| --- | --- | --- |
| `.github/workflows/adr-doctor.yml` | Drop | `lint-adrs` job in canonical `lint.yml` (`ci_core`) already covers every consumer |
| pre-commit `adrs doctor` fragment | RF-canonical | new `.githooks/pre-commit.d/50-adrs` plugin, `adrs_plugin` set, all hook-carrying consumers |
| `adrs` in `copilot-setup-steps.yml` | RF-canonical | `upstreams` mutation (taps) + `provides/.../copilot-setup-steps.template.yml` (non-taps), homebrew/core name `adrs` |
| `adrs` in `sync-shared-config.yml` | Drop | workflow decommissioned at cutover |
| `.mcp.json` + `.vscode/mcp.json` | Repo-local | per-repo server sets; RF now carries its own `.mcp.json` (adrs only) |
| `adrs.toml` `mode = "ng"` / `variant = "minimal"` | Drop | canonical `adrs.toml` unchanged; doctor passes as-is |
| ADR-policy prose | RF-canonical | new "Architecture decision records" section in `docs/agent-principles.md` (`agent_docs`) |

Verified along the way (`adrs` 0.8.0): `status` case does not matter to `adrs doctor` (unknown values warn, exit 0) — lowercase is house style; SPDX inside the frontmatter passes doctor (exit 0 on this repo's 18-ADR set with the new plugin live).

## What each consumer receives from this work, via the first sync

On top of what the manifest already granted them:

- **All hook-carrying consumers** (blackoutd, zman-didan, homebrew-babble, bob-book, cert-automation, homebrew-cask-tools): `.githooks/pre-commit.d/50-adrs` (inert until `docs/decisions/**` or `adrs.toml` is staged), `.githooks/pre-commit.d/15-prose` (vale on staged Markdown, added as follow-on scope — ADR 0019; warns and skips until the repo seeds `.vale.ini`), and the updated `docs/agent-principles.md` with the ADR section. dot-github takes only the updated `agent-principles.md` (no `git_hooks`).
- **homebrew-cask-tools** additionally: `copilot-setup-steps.yml` whose install list now ends `… zizmor fzf adrs` (relayed from Homebrew/brew with the amended mutation).
- **Non-tap consumers** running the Copilot coding agent: nothing synced — their per-repo `copilot-setup-steps.yml` is seeded from the scaffold, which now includes `adrs`; existing per-repo copies add it during their cleanup pass if they want ADR tooling in the agent sandbox.

## Cutover: cask-tools' hand-rolled sync → RF pipeline

Coverage diff first: cask-tools' `sync-shared-config.yml` pulls exactly four files — `zizmor.yml` (Homebrew/.github), `actionlint-matcher.json`, `actionlint.yaml`, `copilot-setup-steps.yml` (Homebrew/brew). RF's `upstreams:` covers all four; RF's mutations are a superset (adds `del(.paths)` and the `SYNC_BOT_*` config-variables on `actionlint.yaml`, and now `adrs` on the install list). **No gap; no new manifest coverage was needed.**

Sequence:

1. RF's first sync opens the `sync-from-foundation` PR on cask-tools (`ci_core` + `homebrew_tap` deliver the four files, RF-headed).
2. In that PR (or its cleanup follow-up): delete `.github/workflows/sync-shared-config.yml` — the engine writes files and does not delete, so the removal is a cleanup-pass commit, not an engine feature.
3. Close PR #41 (see verdict above).
4. Maintainer (manual): the RF sync App must be installed on cask-tools with the Workflows permission (it pushes workflow files — already a first-sync prerequisite); after the cutover PR merges, remove the now-unused `SYNC_APP_CLIENT_ID` var / `SYNC_APP_PRIVATE_KEY` secret from cask-tools if RF's App replaces the repo-local one.
5. cask-tools ADRs 0001 (pipx) and 0002 (sync-branch-PR-strategy) are absorbed by RF ADRs 0012 and 0003 respectively — RF ADR 0003's "More Information" already records the 0002 absorption, so no further harvest was needed. Their local disposition (mark superseded vs delete; ADR 0003 brew-man stays regardless) belongs to the cleanup pass — deleting both would leave the MADR set starting at 0003, so prefer marking them `superseded` with a pointer, per the ADR 0004 pointer pattern.
6. cask-tools `AGENTS.md` gains repo-local prose during cleanup: the `50-adrs` hook line, the `adrs` MCP server rows PR #36 drafted (its `.mcp.json` already carries the Homebrew server; add `adrs`), and the `brew install adrs` (core, not tap) install hint.

## Loose ends for the maintainer

- `workspace/master-plan.md` still lists RF `.mcp.json` as "Pending" under the W1 MADR scope addition — it landed with this work (outside the agent sandbox's writable area, so not updated here).
- Observation, no action taken: `sync-to-consumers.yml` checks PR existence with `gh pr list --json number --jq length` while ADR 0003's text describes the REST `gh api` + `jq --exit-status` form. Same set-query semantics, different plumbing; align whichever way preferred, in its own change.
