<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Reconciliation audit — what the multi-way derivation missed

A comprehensive pass over every active `toobuntu/*` repository (plus the
Homebrew/brew fork and the dormant tree where relevant), checking each
agent-config, shared-config, hook, CI, and convention file for org-wide content
or configuration the repo-foundation canonical was missing. Prompted by the
discovery that `homebrew-cask-tools/docs/shared-guidelines.md` had been missed.

## Method

Inventoried, per repo: root dotfiles/configs; `.github/workflows/`; `.githooks/`
(+ `pre-commit.d/`); `.github/copilot-instructions.md`; `docs/decisions/`;
`scripts/`; and the guidance docs (`AGENTS.md`, `CLAUDE.md`,
`shared-guidelines.md`). For each, asked: does it hold something org-wide that
the canonical (agent-principles.md, the hooks, the lint configs, the ADRs) does
not already carry?

## Findings and disposition

| Miss | Where found | Disposition |
|---|---|---|
| **macOS/BSD-compatibility rules** (no GNU-only flags, portable shell + shebang, no Linux paths, the BSD-date gotcha) | `homebrew-cask-tools/docs/shared-guidelines.md`; `cert-automation/.github/copilot-instructions.md` | **Reconciled** into agent-principles.md as the "Platform: macOS and the BSD userland" section. |
| **shfmt + shellcheck enforcement** in pre-commit + CI | shared-guidelines.md (stated as `brew style` for the tap); cert-automation `lint.yml` (a standalone `shellcheck` job) | **Reconciled** as the canonical `shell_lint` set: `.editorconfig` (2-space), `.shellcheckrc`, `scripts/lint-shell.sh`, `05-shell` plugin, `shell-lint.yml`. Synced to non-Homebrew consumers (ADR 0017). |
| **`.shellcheckrc`** (5 curated `enable=` optional checks) | `babble/.shellcheckrc` | **Adopted verbatim** as RF's canonical `.shellcheckrc`. |
| **`.editorconfig`** | absent everywhere | **Created** canonical (2-space shell; the missing config shfmt needs). |
| **`ksh -n` / ksh93 handling** | `cert-automation/lint.yml`; old (ksh-era) babble CI | **Reconciled** — `scripts/lint-shell.sh` is dialect-aware. ksh93 files (`.ksh` or a ksh shebang, `/bin/ksh` or `/usr/bin/env ksh`) get `ksh -n` (where ksh is present) plus `shellcheck --shell=ksh` — shellcheck's own ksh dialect, no ksh binary needed, so they are analyzed even on the Ubuntu runner — and **skip `shfmt`** (no ksh93 dialect; it mangles/rejects ksh93, mvdan/sh#614). So cert-automation stays a `shell_lint` consumer and the synced CI need not install ksh93; a ksh-heavy repo may still add its own ksh93 `ksh -n` job for the authoritative syntax pass. |
| **`post-merge` / `post-rewrite` hooks** | `homebrew-cask-tools/.githooks/` | **Repo-specific** (regenerate cask completions/man). Not org-wide; left in cask-tools. |
| org-wide ADRs (trojan, merge, reuse-lint, ruby-toolchain, analytics, pre-push-signing, pipx, vale) | blackoutd, hct, zman-didan `docs/decisions/` | **Already reconciled** in Session 3 (RF ADRs 0005–0014). No new miss. |
| `copilot-instructions.md` | blackoutd, cert-automation, hct | **Repo-specific** by design (ADR-era decision); the one shared rule (annotate SPDX) is already in agent-principles.md. |
| shared scripts (`annotate.sh`, `lint-perms.sh`) | most repos | **Already canonical** in RF `scripts_core`. Other scripts (`bump.sh`, `maslist*.sh`, ksh cert scripts) are repo-specific. |

## Follow-ups (post first sync)

- **homebrew-cask-tools drops `docs/shared-guidelines.md`.** Its org-wide content
  now lives in the synced `docs/agent-principles.md`; its `brew style` line is a
  repo fact for cask-tools' `AGENTS.md`. Remove the file and repoint `AGENTS.md`
  / `CLAUDE.md` at agent-principles.md once the sync lands.
- **cert-automation's `.ksh` are covered by the dialect-aware `shell_lint`**
  (`shellcheck --shell=ksh` + `ksh -n` where present, `shfmt` skipped), and its
  `reuse` is in the canonical `lint.yml`. So its own `lint.yml` can drop the
  `shellcheck` and `reuse` jobs; keep a `ksh -n` job (installing ksh93) only if
  it wants the authoritative syntax pass in CI (the synced workflow runs `ksh -n`
  opportunistically). Its own scripts also carry real `shellcheck --shell=ksh`
  findings (install/pki/ssh-key-check) to fix during cleanup.
- **babble + homebrew-cask-tools** carry Homebrew/brew's `.editorconfig` +
  `.shellcheckrc` verbatim and rely on `brew style`; confirm babble runs
  `brew style` over its shell (it has a `.shellcheckrc` today but no hooks).
- **cert-automation's `.swift` helpers** (`swift_plugin`) and the `ksh` question
  are the two remaining CONFIRMs in `sync-manifest.yaml`.
