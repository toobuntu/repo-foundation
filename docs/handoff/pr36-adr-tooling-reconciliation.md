<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Opening prompt — PR #36 ADR-tooling reconciliation

Paste this to open the session that folds the ADR-tooling half of
`toobuntu/homebrew-cask-tools` PR #36 into repo-foundation, so that PR can be
closed, and that reconciles cask-tools' hand-rolled upstream sync with RF's
pipeline. It is later-added W1 scope: the build-out (Phases A–F) is complete;
this and the first sync are what remain.

**Root the session in `<repo-root>`** (repo-foundation). The canonical templates
land under `provides/` and the manifest entries in `sync-manifest.yaml`; both are
here. Consumer clones are siblings under `toobuntu/` for reference diffs.

## Do not re-plan what already landed

- cask-tools `main` **already** carries `adrs.toml` plus the MADR conversions of
  its ADRs 0001 and 0002 (merged as PR #45). Treat that as done; this task is
  about the *tooling* around ADRs, not re-converting them.
- The brew-man half of PR #36 (`cmd/man.rb` and its ADR 0003) is a separate,
  cask-tools-local concern. It is out of scope here.

## Corrections to carry in (verified, not assumptions)

- **SPDX inside ADR YAML frontmatter passes `adrs doctor`** (maintainer-verified
  2026-07-02, exit 0). RF's `scripts/annotate.sh` places the SPDX block as `#`
  comment lines *inside* the `---` fence, above `number:` — the form every RF ADR
  carries. PR #36 moved SPDX to an HTML comment above the frontmatter; that is
  unnecessary and diverges from the RF house pattern. **Do not adopt #36's SPDX
  placement.**
- Re-verify, do not assume, PR #36's two supporting claims before acting on them:
  its "ADR status must be lowercase" assertion, and its "`adrs` is/ isn't
  available in the agent sandbox / CI" assertion. Both drove #36 design choices;
  confirm each against the current `adrs` tool and RF's own passing ADR set.

## Part 1 — ADR-tooling reconciliation

For each item, decide **RF-canonical** (a `provides/` template + a manifest
entry, so every consumer receives it) vs **repo-local** (stays in cask-tools) vs
**drop**. RF already governs org-wide ADR policy (ADR 0004: ADRs live here and
are referenced by pointer), so the bias is RF-canonical for anything org-wide.

1. **`.github/workflows/adr-doctor.yml`** (CI running `adrs doctor`). RF already
   runs `adrs doctor` as a `lint-adrs` job — decide whether that job covers this
   or whether a dedicated workflow is warranted, and whether consumers (which
   reference org ADRs by pointer, ADR 0004) need it at all.
2. **`.mcp.json` + `.vscode/mcp.json`** (the `adrs` MCP server). The master plan
   lists an RF `.mcp.json` as pending. Decide the canonical form and whether it
   is RF-only or synced.
3. **`copilot-setup-steps.yml` + `sync-shared-config.yml` fragments** that
   install `adrs` in agent sandboxes. `copilot-setup-steps.yml` is already an
   RF upstream (ADR 0015); fold any `adrs`-install step into that canonical.
4. **`.githooks/pre-commit` fragment running `adrs doctor`.** Consider a
   `provides/githooks/pre-commit.d/50-adrs` plugin (mirrors the language-plugin
   pattern of ADR 0017), synced to consumers that keep local ADRs. Gate it on
   staged `docs/decisions/**` so it is a no-op elsewhere and runs clean in the
   sandbox.
5. **ADR-policy prose** in cask-tools `AGENTS.md` / `docs/shared-guidelines.md`.
   Reconcile any org-wide rule into `docs/agent-principles.md` or the relevant
   ADR; leave cask-tools-specific facts local. (`shared-guidelines.md` is already
   slated for deletion once the synced `agent-principles.md` lands — see
   `docs/handoff/reconciliation-audit.md`.)

## Part 2 — reconcile cask-tools' hand-rolled upstream sync with RF's pipeline

RF already implements **both** sync directions — `upstreams:` pull-in and the
consumer relay. So this is manifest coverage plus a cutover plan, not new engine
work.

1. **Coverage diff.** Compare the file list cask-tools' `sync-shared-config.yml`
   pulls against RF's `upstreams:` set. Note every gap and decide whether RF
   should carry it. `copilot-setup-steps.yml` is the known
   workflows-write-permission case.
2. **Cutover.** Define the switch: RF's sync removes the redundant cask-tools
   workflow; decommissioning the cask-tools sync App is a manual maintainer step;
   RF's App needs the Workflows permission on every consumer (it pushes workflow
   files).
3. **Prior art.** Harvest cask-tools ADR 0002 (`sync-branch-pr-strategy`) as
   input to RF's sync ADRs; mark it superseded at cutover.
4. **cask-tools PR #41** (`actionlint.yaml`): merge it if the hand-rolled sync
   survives to cutover; close it if RF's first sync delivers the same file.

## Deliverables

- The chosen RF `provides/` templates and `sync-manifest.yaml` entries.
- A note listing exactly what each consumer receives via the first sync from
  this work (feeds the disposition review in
  `docs/handoff/first-sync-and-consumer-cleanup.md`).
- A one-line go/no-go on closing cask-tools PR #36.

## References

- `toobuntu/homebrew-cask-tools` PR #36 (the source), PR #45 (the MADR
  conversion already merged), PR #41 (`actionlint.yaml`).
- The `adrs` tool's own ADRs and authoring notes, in the archived `adrs-formula`
  reference checkout under `_archived/` (no live remote):
  `docs/decisions/0001-*` and `docs/notes/adr-authoring-workflow.md`.
- RF ADR 0004 (org-wide ADR location), ADR 0015 (copilot-setup-steps
  distribution), ADR 0017 (git-hooks base + plugins).
