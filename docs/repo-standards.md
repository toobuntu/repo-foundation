<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Repository standards

What is expected of every toobuntu repository, each standard with the check that enforces it. This page doubles as the checklist `foundation-doctor` grows toward; it is linked from the onboarding runbook (`docs/adding-a-repo.md`) and the synced CONTRIBUTING baseline.

| Standard | What it means | Enforced by |
| --- | --- | --- |
| Signed commits | Every pushed commit is SSH-signed; sandboxed agents commit unsigned and the maintainer re-signs the batch (`scripts/sign-push.sh`) | the synced `pre-push` hook (rejects unsigned tips where signing is configured; warns otherwise) |
| REUSE compliance | Every file declares copyright and license; headers come from `scripts/annotate.sh`, never by hand | the pre-commit REUSE plugin; the `lint-reuse` CI job |
| ADR practice | Decisions are MADR 4.0 ADRs; org-wide ones live only in repo-foundation and are referenced by pointer (ADR 0004); per-repo ADRs start at 0001; numbering stays contiguous | the `50-adrs` pre-commit plugin (`adrs doctor`); the `lint-adrs` CI job |
| Hooks activated | `git config core.hooksPath .githooks`, once per clone | convention; CI backstops every hook check; a `foundation-doctor` probe is queued |
| Synced CI green | The canonical workflows (lint, actionlint, prose, spec where subscribed) pass; a consumer does not edit synced files to silence them | the workflows themselves; divergence is caught at the next sync (a PR-time guard is queued) |
| Prose style | Vale's Toobuntu style at error level on tracked Markdown; en_US spelling everywhere | the `15-prose` pre-commit plugin; the `prose.yml` CI job |
| Markdown structure | rumdl clean, org soft-wrap policy (ADR 0020) | the `10-markdown` pre-commit plugin; the markdownlint job in `lint.yml` |
| Shell discipline | POSIX `sh` or explicit bash/ksh shebangs; BSD-userland portable; dialect-aware linting (ADR 0017); Homebrew-aligned repos defer to `brew style` | the `10-shell` plugin and `shell-lint` CI where synced |
| Executable-bit policy | Scripts and hooks carry the executable bit; nothing else does | `scripts/lint-perms.sh` (hook and CI) |
| No invisible Unicode | Trojan-Source and invisible-character scanning | `scripts/lint-unicode.sh` (hook and CI) |
| Tests | New functionality ships tests in the org pattern for its language — RSpec for shell/Ruby hook-and-script suites (ADR 0011), Swift Testing for Swift | the repo's `spec.yml` / CI test jobs |
| Continuity layer | The `.ai/` directory (ADR 0022): committed `memory.md` and synced `org/memory.md` + `progress.template.md`; volatile files gitignored | the sync (`ai_continuity` set); `foundation-init` seeds |
| Registers | `docs/technical-debt.md` is a register of open, never-renumbered items; resolved entries move to `docs/technical-debt-resolved.md` with date and PR link | convention; the resolving PR moves the entry |
| Makefile vocabulary | Where a repo carries a Makefile front door, the target names are `help` / `check` / `lint` / `test` / `build`, each a thin call into `scripts/` | `checkmake` (synced config); convention for the names |
| Cross-repo references | Committed docs name other repos by `<org>/<repo>` slug, own-repo paths by `<repo-root>` placeholder | convention; review |
| Doc distribution | Decision records are referenced by pointer; operational how-tos a contributor needs *inside* a consumer sync as canonical; hub-internal docs stay in repo-foundation | `sync-manifest.yaml` membership; review |

**Which docs travel, and why they differ from ADRs.** ADR 0004 keeps org-wide decision records in repo-foundation and has consumers point at them, and the reason is specific rather than general: an ADR's identity is a *number in one sequence*, so copies would fork the numbering contract that `adrs doctor` enforces. Ordinary documentation has no such contract, and the other half of 0004's rationale — drift between copies — is exactly what the sync and the foundation guard already prevent. So three genres, decided 2026-07-28:

- **Decision records** — pointer, per ADR 0004. Unchanged.
- **Operational how-tos** — `mode: canonical`. The test is one question: *does someone working in the consumer repository need this during routine work?* `docs/testing-github-workflows-locally.md` is the worked example — it explains the very workflows `ci_core` delivers, so it rides that set. Anything the synced CONTRIBUTING baseline links to belongs here almost by definition: a CONTRIBUTING that sends a contributor to another repository for its own instructions fails offline and reads as an afterthought.
- **Hub-internal docs** — repo-foundation only. `architecture.md`, `adding-a-repo.md`, this page: they describe the hub, not the consumer's daily work.
- **Agent skills** — the same question, applied to `.claude/skills/*/SKILL.md` (ADR 0025). A skill whose body is org-wide procedure syncs as canonical in the `claude_skills` set and carries the `tb-` prefix that marks it as managed here; a skill naming one repository's toolchain stays in that repository. The extra consideration a doc does not have is *scope*: a skill loads by directory, so one placed above several repositories is offered inside all of them.

Where the enforcing column says "convention," the standard is real but the automated check does not exist yet; `foundation-doctor` is the intended home for those probes.
