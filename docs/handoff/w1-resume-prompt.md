<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# W1 build-out — resume prompt

Paste or reference this to resume the repo-foundation (RF) full build-out. Session is rooted in `~/devel/claude/desktop/toobuntu/repo-foundation`, branch `feature/reorg-reference-fixup` (pre-initial-commit).

**STATUS (end of Session 2, revised after maintainer review):** Sessions 1 + 2 complete. Phase A (`.github/` derivation) is DONE; the sync engine + composite action + both sync workflows are built and verified. Per review: `zizmor.yml` and `actionlint.yaml` are **upstream-coupled** (mirroring homebrew-cask-tools' sync, which RF supersedes), not RF-authored — the engine strips the upstream relay header and writes a repo-foundation one. **copilot-setup-steps is per-repo (scaffold) EXCEPT Homebrew taps**, which sync it via the `homebrew_tap` set from a Homebrew/brew-tracked base — decided in ADR 0015 (which also records the rejected synced + per-consumer-yq-mutations approach with revert pointers, and the planned age-based staleness check via `foundation doctor` + a scheduled job). cask-tools is reconciled into the canonical hooks (`git_hooks` + new `30-brew` plugin). Bot commit signing is opt-in (`SYNC_BOT_SIGN` + `SYNC_BOT_NAME`/`SYNC_BOT_EMAIL` + `SYNC_APP_SSH_SIGNING_KEY`; a "Verified" badge needs a machine-user account). The engine has its own spec (`spec/integration/sync_files_spec.rb`). Verified: actionlint, zizmor (0 findings), reuse, `ruby -c` (2.6 + 4.0.5), rspec (only the flaky pre-push gpg/web-flow test fails in-sandbox; it passes on the maintainer's machine). `20-objc`, `30-brew`, `adrs.toml`, and the copilot-setup-steps ADR landed (now 0015).

**STATUS (end of Session 3):** ADR curation DONE. `docs/decisions/` is one clean MADR 4.0 sequence of 15 ADRs (0001–0015, no gaps); `adrs doctor` exit 0, `reuse lint` compliant, `lint-unicode` clean, full `rspec` green except the known in-sandbox pre-push web-flow flake. The canonical hook + `scripts/lint-unicode.sh`

- `precommit_unicode_spec.rb` now point at RF's ADR 0006 (trojan) / 0005
(reuse-lint) by stable URL; the `annotate.sh` / no-hand-write-SPDX rule was consolidated into `docs/agent-principles.md`. Provenance, the consumer-cleanup follow-up, the legacy stale-ADR-ref list, and the W6 → 0016 numbering note are in plan doc §7 "Curation outcome". **Next: Session 4 — Phase D.** All on disk uncommitted; the initial commit series is Session 5 / Phase F.

**STATUS (end of Session 4):** Phase D DONE. The `provides/` tree (`claude-user/`, `objc/`, `repo/` baselines), the multi-way-re-derived LCD `.claude/settings.json`, and baseline-merge for all three target types are built and verified (`reuse lint` 95/95, `adrs doctor` exit 0, `rspec` green bar the known in-sandbox gpg-agent pre-push flake). `sync-files.rb` now renders baseline-merge sentinels in the TARGET's comment syntax (`#` / `<!-- -->`) and deep-merges a JSON `.claude/settings.json` with a consumer `<stem>.addenda.json` (arrays union so a consumer can only ADD to the deny rail; idempotent). The `.baseline` infix is settled (ADR 0002 amended; 0001 updated); the manifest set `claude_merged` → `repo_baseline`. Synced-file licensing is decided in **ADR 0016** (license follows ownership: mirrors keep RF's GPL, merges carry the consumer's; region sources are license-neutral via `provides/repo/REUSE.toml`; counter-argument for a future per-repo-license switch recorded). `annotate.sh` gained a clang-config category. Detail in plan doc §6 "Phase D outcome". **Next: Session 5 — Phases E + F.** All on disk uncommitted; the initial commit series is Session 5 / Phase F.

**Authoritative design doc:** [`docs/handoff/w1-buildout-plan.md`](./w1-buildout-plan.md) — read it first. It holds the inventory, the per-file canonical map, the locked organization + sync design, the ADR policy, and the phased roadmap.

## Decisions already locked (do not re-litigate)

- **Full build-out**, not a reconciliation pass. A reconciliation pass would 2-way diff RF against one sibling and merge the deltas; the full build-out instead constructs RF from the ground up as the org-wide canonical source — inventory every active repo, derive canonical content multi-way, and design the layout, sync, and ADRs anew — which then syncs to the active `toobuntu/*` repos. (Plan doc §1 spells out the steps.)
- **Canonical derivation is multi-way** across all active repos (not 2-way).
- **Layout:** mirror Homebrew/.github — files RF uses itself at natural paths; `.template` is an **infix** (`name.template.ext`); minimal `provides/` only for files with no natural RF path (user-global `~/.claude/`, objc configs).
- **Sync:** declarative `sync-manifest.yaml` + Ruby `.github/actions/sync/sync-files.rb` + `action.yml` + `sync-to-consumers.yml` / `sync-from-upstreams.yml`. Names are settled.
- **ADRs:** org-wide ADRs canonical in RF only; implementation syncs, rationale is pointed-to (no per-repo ADR copies, no reserved numbers).
- **pre-commit** canonical = zman-didan (classicalre `pre-commit.d` rule).
- Write **literal prose** (no jargon like "dogfood"). Agent commits unsigned in-sandbox; maintainer re-signs the batch.

## Done this session (on disk, uncommitted)

- Multi-way canonical map for **scripts, hooks, docs, specs, shared repo configs** (plan doc). The `.github/` **workflows/CI configs were NOT read/derived** — only md5-grouped; the manifest `ci_*` modes are provisional. Outstanding Phase-A work, for Session 2.
- Canonical content placed + reconciled at natural paths, verified (`sh -n`/`bash -n` + shellcheck clean):
  - `.githooks/pre-commit` ← zman-didan + working-tree review comment.
  - `scripts/lint-perms.sh` ← zman-didan + RF `LINT_PERMS_FORMAT` up-front validation.
  - `scripts/lint-unicode.sh` ← blackoutd. `scripts/annotate.sh` ← blackoutd (consumer "synced from" header removed — the sync re-adds it).
  - `docs/agent-principles.md` ← blackoutd.
  - `spec/integration/precommit_unicode_spec.rb` — `BLACKOUTD_SKIP_REUSE_LINT` → `REUSE_LINT_SKIP` (matches the reconciled hook).
- `sync-manifest.yaml` (validated) + `.github/actions/sync/dependabot.template.yml`.
- **rspec verified:** 46 examples, 0 failures (`GIT_CONFIG_GLOBAL=/dev/null`; `bundle config set --local path vendor/bundle`).
- **Licensing/compliance progress:** `.bundle/config` is the canonical bundler config (now annotated); the misplaced root `config` is removed (maintainer did it — the seatbelt protects repo-root `config`/`HEAD`/`objects`/`refs` as git internals, so the agent's `rm` was denied). Created `.gitignore` (`/vendor/`) and root `COPYING` (GPL text for GitHub's license UI; its own REUSE declaration — via `REUSE.toml` — comes at Phase F). `annotate.sh` headered legit RF files but also walked `vendor/` before `.gitignore` existed (303 gems got bogus headers — harmless: gitignored + reinstallable; `rm -rf vendor/bundle` to wipe). `LICENSES/GPL-3.0-or-later.txt` exists (maintainer ran `reuse download`).

## Must-read workspace planning docs

Read the master plan first — it is the top-level coordination across all in-flight workstreams (W1 is this build-out), and the per-session opening prompt should reference it:

- `~/devel/claude/desktop/workspace/master-plan.md`

Then, in `~/devel/claude/desktop/workspace/repo-foundation/`:

- `w1-hooks-review-prompt.md` — **supersedes `bootstrap-prompt.md`** where they conflict; the authoritative hooks / plugins / ADR-relocation / Vale spec.
- `bootstrap-actions.md` — the maintainer's manual runbook (GitHub repo + App, push, first sync). Reference, not agent work.
- `vale-styles-evaluation.md` — Vale rule survey, for Session 5.
- `bootstrap-prompt.md` — original broad runbook (superseded in parts).

Session-1 gaps these surfaced (detail in plan doc "Inputs from the workspace planning docs"): language-plugin architecture (manifest fixed), `20-objc` extraction, the `docs/reviews/` disposition audit, hook ADR-ref repointing, the `Toobuntu` Vale consolidation, the `lint-perms` CI job.

## Session 2 (next) — finish Phase A, then the sync engine

**Part 1 — finish Phase A (the outstanding `.github/` derivation).** Multi-way read/analyze the workflows + CI configs (`ci.yml`, `codeql.yml`, `actionlint.yml`, `copilot-setup-steps.yml`, `dependabot.yml`, `zizmor.yml`, `copilot-instructions.md`, `licenses.instructions.md`) across blackoutd / cert-automation / homebrew-cask-tools / zman-didan; classify each as canonical / template / baseline-merge; finalize the manifest `ci_core` / `ci_templates` modes; place the derived canonical/template files in RF at their natural paths.

**Part 2 — the sync engine.**

1. **`.github/actions/sync/sync-files.rb`** — the engine. Model on Homebrew's `shared-config.rb` (saved at `/tmp/claude/hb-shared-config.rb`; also `hb-sync-workflow.yml`, `hb-dependabot.template.yml`). It must:
   - Parse `sync-manifest.yaml`; for a given consumer, resolve `sets` + `extra` − `exclude` into a component list.
   - Per component `mode`:
     - `canonical`: copy source→target byte-for-byte, then **prepend** the `defaults.synced_header` rendered in the target's comment syntax (chosen by extension: `#` for sh/rb/yaml/toml, `<!-- -->` for md/html, `//` for c/m/h). The source carries no such header.
     - `template`: copy verbatim; strip the `.template` infix from the target.
     - `generate`: build `.github/dependabot.yml` from `dependabot.template.yml`, keeping only ecosystems whose manifest file exists in the target (`bundler`→`Gemfile.lock`, `github-actions`→ `.github/workflows`, `pip`→`requirements.txt`/`pyproject.toml`). Mirror Homebrew's `dependabot_config_yaml["updates"].filter_map`.
     - `baseline-merge`: replace only the region between `defaults.merge_begin` / `merge_end` sentinels in the target; preserve everything outside.
   - Commit one file per change; set `pull_request=true` for the workflow.
   - Invocation: `sync-files.rb <consumer_repo_slug> <target_path> [--dry-run]`.
   Use Ruby stdlib only (yaml, fileutils, find, open3) so it runs without bundler in CI.
2. **`.github/actions/sync/action.yml`** — composite action wrapping the engine (inputs `repo`, `manifest_path`, `dry_run`).
3. **`sync-to-consumers.yml`** — matrix over `consumers`; clone source+target, run the action, branch `sync-from-foundation` + `gh pr create`. Top-level `permissions: {contents: read}`; GitHub App token. Decide whether the bot signs its commits (Homebrew does; our ADR 0008 forbids only a signing *gate*, not a bot signing its own work).
4. **`sync-from-upstreams.yml`** — iterate `upstreams`; fetch, apply `yq` mutations, PR on drift.

## Later sessions (≈3 after the engine)

W1 needs roughly **four more sessions** after this one:

- **Session 3 — ADR curation. DONE.** `docs/decisions/` is a clean 15-ADR MADR 4.0 sequence (0001–0015); `adrs doctor` exit 0. Outcome, provenance, and follow-ups recorded in plan doc §7 "Curation outcome".
- **Session 4 — Phase D. DONE.** `provides/` tree created, LCD `.claude/settings.json` re-derived multi-way, baseline-merge implemented for text (style-aware sentinels) and JSON (deep-merge with consumer addenda), `.baseline` infix settled, synced-file licensing decided (ADR 0016). See plan doc §6 "Phase D outcome".
- **Session 5 — Phases E + F.** `policies/`, RF `README.md` + `CONTRIBUTING.md`, `examples/minimal-repo/`, confirm dot-github's org-fallback set; `scripts/foundation-init.sh` + a `foundation doctor` mode and a scheduled "scaffold drift" workflow implementing the per-repo staleness check (age-based nudge per ADR 0015); reorganize the legacy tree into the locked layout; then `scripts/annotate.sh` + `reuse lint`, `actionlint`, `shellcheck`, full `rspec`; initial commit series (unsigned; maintainer re-signs via `scripts/re-sign-unpushed.sh`).

Fold into the relevant session: `last_review_date` on standalone docs (not `agent-principles.md`); de-leak spec temp-dir prefixes (`blackoutd-*`); move bundler config root `config` → `.bundle/config`; gitignore `vendor/bundle` + `.bundle/`.

## How to open the next session

Root a Tier-3 session in `~/devel/claude/desktop/toobuntu/repo-foundation` (`./scripts/sandbox-enter.sh --mode=no-remote`) and open with:

> Continue the W1 build-out — Session 5 (Phases E + F), the final W1 session. We are continuing W1 from `~/devel/claude/desktop/workspace/master-plan.md` — read that first. Root: `~/devel/claude/desktop/toobuntu/repo-foundation` (Tier 3). Read `docs/handoff/w1-resume-prompt.md` then `docs/handoff/w1-buildout-plan.md` first (note the end-of-Session-4 banner: Phase D done — the `provides/` tree [renamed from `templates/` this session], the LCD `.claude/settings.json`, and baseline-merge for text + JSON are built and verified; `adrs doctor` exit 0 over 16 ADRs, `reuse lint` clean, `rspec` green bar the known in-sandbox gpg-agent pre-push flake). ADRs 0001 layout, 0002 `.template`/`.baseline` infixes, 0003 sync architecture, and 0016 synced-file licensing govern this work; do not re-litigate them. Also read the workspace planning docs in `~/devel/claude/desktop/workspace/repo-foundation/` (`w1-hooks-review-prompt.md` supersedes `bootstrap-prompt.md`; `bootstrap-actions.md`; `vale-styles-evaluation.md`) — they still say `templates/` for the now-`provides/` directory; read past that. This session does Phases E + F per plan doc §8.
>
> Phase E: (1) RF's own `README.md` (standard-readme, ADR 0008) and `CONTRIBUTING.md` (the org-wide baseline `provides/repo/CONTRIBUTING.baseline.md` plus sync-hub specifics); `policies/` if warranted. (2) `examples/minimal-repo/` — a worked consumer showing the layout, including a sample `.claude/settings.addenda.json` that demonstrates the JSON baseline-merge deep-merge (the engine reads `<stem>.addenda.json` beside the target). (3) `scripts/foundation-init.sh` — bootstrap a consumer: copy the copy-once `.template` scaffolds (`provides/github/workflows/*`), seed AGENTS.md / CONTRIBUTING.md / .gitignore with the baseline-merge sentinels in the desired spot, seed `.claude/settings.addenda.json`, and run `reuse download --all` plus `ANNOTATE_LICENSE=<id> scripts/annotate.sh` so a non-GPL consumer is compliant under its own license (ADR 0016). (4) the scaffold-staleness check per ADR 0015 — a `foundation doctor` mode plus a scheduled "scaffold drift" workflow (age nudge, not a diff). (5) confirm dot-github's org-fallback set and wire `community_health_source`.
>
> Reorg (Phase E): retire the legacy tree now superseded by `provides/` — `global/` (→ `provides/claude-user/`), `project/` (→ `provides/repo/` + `provides/objc/`), `project/scaffolding-adrs.md` — and rewrite the stale root `README.md` and `docs/usage.md` (both still describe the pre-build-out `scaffolding`/`project/` model). Reconcile the stale ADR-number references in plan doc §7 and this doc's "Reorganization still pending". Fold in `last_review_date` on standalone canonical docs (not `agent-principles.md`, which is `@import`-ed raw).
>
> Phase F: root license `COPYING` (GPL) with a `REUSE.toml` entry (§9); then the full gate — `scripts/annotate.sh`, `reuse lint`, `actionlint`, `shellcheck`, `shfmt`, full `rspec` — and the initial commit series, committed UNSIGNED in the sandbox; tell the maintainer to re-sign the batch before pushing via `scripts/re-sign-unpushed.sh`. Org rules: write file bodies WITHOUT SPDX, then run `scripts/annotate.sh` (never hand-write SPDX; special cases → amend annotate.sh or add a `REUSE.toml`, never direct `reuse annotate`); multi-way canonical derivation; literal prose (no "dogfood"). Everything is on disk uncommitted until the Phase F commit series.

## Reorganization — DONE (Session 5)

The pre-existing RF tree was reorganized into the locked layout in Session 5. `global/` and `project/` (including `project/scaffolding-adrs.md` and `project/objc/`) are retired — superseded by `provides/claude-user/`, `provides/repo/`, `provides/objc/`, and ADR 0004. Root `README.md` was rewritten to standard-readme (titled `repo-foundation`); `docs/usage.md` was rewritten to the sync/foundation-init model.

**Stale ADR-number references — all reconciled.** The legacy files that cited an old/aspirational scheme are gone or rewritten: `project/scaffolding-adrs.md` (deleted), root `README.md` and `docs/usage.md` (rewritten, no longer cite the old 0005/0006/0007 meanings), and `scripts/sandbox-vm-enter.sh` (the dangling `0007-layered-isolation-strategy.md` reference now points to the forthcoming W6 isolate-cli ADR). W6's isolate-cli ADR takes **0018** (Session 4 took 0016 for synced-file licensing, Session 5 took 0017 for the git-hooks base/plugins ADR). `docs/newsyslog-log-rotation.md` ("see ADR 0009") was already correct — 0009 is the logging ADR.
