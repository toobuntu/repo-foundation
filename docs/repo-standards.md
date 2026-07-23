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

Where the enforcing column says "convention," the standard is real but the automated check does not exist yet; `foundation-doctor` is the intended home for those probes.
