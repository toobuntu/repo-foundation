<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# repo-foundation

> Org-wide canonical configuration — agent context, Git hooks, CI, and sync infrastructure — for the toobuntu repositories.

repo-foundation is the single source of the shared files every `toobuntu/*` repository runs: the operating principles agents read, the `.githooks/` pre-commit and pre-push hooks, the lint and CI workflows, the sandbox scripts, the prose style, and the Architectural Decision Records that govern them. It holds these at their natural paths, runs them on its own commits, and pushes them to each consumer with a declarative manifest and a Ruby sync engine — the push-from-canonical model, after Homebrew's `Homebrew/.github`.

## Table of Contents

- [Background](#background)
- [Layout](#layout)
- [Install](#install)
- [Usage](#usage)
- [Maintainers](#maintainers)
- [Contributing](#contributing)
- [License](#license)

## Background

The toobuntu repositories share a large amount of configuration: how a commit is checked, how CI lints, what an agent may and may not do, how prose reads. Maintaining a copy of each shared file in every repository drifts; nothing keeps the copies aligned. repo-foundation fixes that by being the one place a shared file is defined, with the alignment enforced by a sync rather than by discipline.

Two properties drive the design (ADR 0001). A canonical file lives where repo-foundation itself uses it, so a breaking change fails repo-foundation's own CI before any consumer sees it. A file a consumer transforms or owns is marked with a filename infix (ADR 0002) — `.template` for a copy-once scaffold, `.baseline` for a region the sync manages inside a consumer-owned file — and the few artifacts with no natural path here live under `provides/`.

The cross-repo distribution is push-from-canonical (ADR 0003): a declarative `sync-manifest.yaml` plus the engine at `.github/actions/sync/sync-files.rb` resolve each consumer's file set and open a pull request on drift. Cross-cutting decisions are recorded once, here, in `docs/decisions/`, and referenced by pointer from the consumers rather than copied (ADR 0004).

## Layout

```text
.githooks/                     pre-commit / pre-push base hooks (run here, synced)
scripts/                       annotate, lint-perms, lint-unicode, sandbox, foundation-*
docs/decisions/                org-wide ADRs (MADR 4.0; the canonical home)
docs/agent-principles.md       operating principles, imported into AGENTS.md
.github/workflows/             lint, spec, prose, actionlint, and the two sync workflows
.github/actions/sync/          the sync engine and the dependabot template
.vale/styles/Toobuntu/         the canonical prose style and its accept vocabulary
.rumdl.toml                    Markdown structure + soft-wrap config (rumdl)
sync-manifest.yaml             the declarative catalog the engine reads
provides/                      files with no natural path here:
  claude-user/                   the version-controlled ~/.claude/ user config
  githooks/pre-commit.d/         per-language hook plugin masters (the 20-* plugins)
  objc/                          the Objective-C toolchain config
  github/workflows/              ci / codeql / copilot-setup-steps scaffolds
  vale/                          the per-repo .vale.ini scaffold
  repo/                          the per-repo baselines (AGENTS, CONTRIBUTING, …)
examples/minimal-repo/         a worked consumer showing the layout
```

## Install

repo-foundation is not installed; consumers receive its files. To bootstrap a new consumer from a checkout of this repository:

```sh
scripts/foundation-init.sh /path/to/new-repo
```

That copies the copy-once scaffolds, seeds the baseline-merge regions in `AGENTS.md` / `CONTRIBUTING.md` / `.gitignore`, seeds `.claude/settings.addenda.json`, and runs REUSE annotation so the new repo is license-compliant under its own license (ADR 0016). The ongoing alignment then arrives as sync pull requests.

To run the hooks in any repository that has them:

```sh
git config core.hooksPath .githooks
```

## Usage

- **Sync to consumers.** `.github/workflows/sync-to-consumers.yml` runs the engine for each consumer in `sync-manifest.yaml` and opens a `sync-from-foundation` pull request when a canonical file has changed.
- **Sync from upstreams.** `.github/workflows/sync-from-upstreams.yml` pulls the files repo-foundation relays from external upstreams (Homebrew), applies the declared `yq` mutations, and opens a pull request on drift.
- **Check scaffold freshness.** `scripts/foundation-doctor.sh` flags per-repo scaffold workflows that have gone stale; the scheduled `.github/workflows/scaffold-drift.yml` runs the same check and files an issue (ADR 0015).
- **Add a consumer or a file.** Edit `sync-manifest.yaml`: list the consumer under `consumers`, or add a component to a `component_sets` group. The set a consumer subscribes to determines which files it receives.

The decision records under `docs/decisions/` explain why each piece is shaped the way it is; read them before changing the layout, the infixes, or the sync.

## Maintainers

[@toobuntu](https://github.com/toobuntu).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). READMEs in these repositories follow the [standard-readme](https://github.com/RichardLitt/standard-readme) specification (ADR 0008); a change to this file should keep it conforming.

## License

[GPL-3.0-or-later](COPYING) © Todd Schulman.
