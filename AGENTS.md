<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# AGENTS.md — repo-foundation

Authoritative reference for any agent (Claude Code, Codex, Copilot, …) or new human contributor working on repo-foundation. `CLAUDE.md` is a one-line pointer to this file (the Homebrew pattern); read this first.

@docs/agent-principles.md

The import above pulls in the operating principles that apply to every toobuntu repository — pre-action discipline, modern Git verbs, the sandbox model, the universal denied operations, the agent commit-and-signing procedure, and the SPDX/REUSE rule. In repo-foundation those principles are **canonical**: this is the repository that defines them and syncs them to every consumer. Edit them in `docs/agent-principles.md`; do not fork the rules here.

This file adds repo-foundation-specific context.

## What this repository is

repo-foundation is the org-wide canonical source for the toobuntu repositories (see `README.md`). It holds each shared file at its natural path, runs that file on its own commits, and pushes it to consumers with a declarative manifest and a Ruby sync engine. A change here reaches every consumer through a sync pull request, so a change here is a change to every repository.

## Build, test, and lint

```sh
# RSpec hook/engine suite under Homebrew's portable Ruby (ADR 0011):
env -P"$(brew --repository)/Library/Homebrew/vendor/portable-ruby/current/bin:$PATH" \
  bundle exec rspec
# Whole-tree gates (each also a CI job):
reuse lint            # REUSE/SPDX compliance
scripts/lint-unicode.sh .   # Trojan-Source / invisible-Unicode scan
scripts/lint-perms.sh --tracked   # executable-bit policy
adrs doctor           # ADR sequence and structure
rumdl check .         # Markdown structure + soft-wrap (ADR 0020)
git ls-files -z '*.md' | xargs -0 vale   # prose (Toobuntu style)
actionlint && zizmor .      # workflow syntax and security
```

Vale has no `.gitignore` support (upstream, by design), so a bare `vale .` also scans vendored gem docs under `vendor/bundle/`. Run it over the tracked files instead — `git ls-files` lists only tracked files (so untracked vendored docs are excluded), which is the primary form. Because `git ls-files` reports a tracked path even when it has been deleted on disk without staging the deletion, filter to readable paths before the single vale run (`read -d ''` is not dash-portable, so use `xargs`+`sh`):

```sh
git ls-files -z '*.md' |
  xargs -0 -r sh -c 'for f in "$@"; do [ -r "$f" ] && printf "%s\0" "$f"; done' sh |
  xargs -0 -r vale
```

`vale --glob='!vendor/**' .` is an alternate but excludes only the one named tree. CI's `prose.yml` and the `15-prose` hook use the same filtered form; neither sees `vendor/`.

Add SPDX headers by running `scripts/annotate.sh` — never hand-write them; this includes ADRs (see the SPDX/REUSE section of `docs/agent-principles.md`).

## Architecture

- `sync-manifest.yaml` — the declarative catalog: `upstreams` (pulled in), `component_sets` (reusable file groups), `consumers` (who gets which sets).
- `.github/actions/sync/sync-files.rb` — the engine. Stdlib-only Ruby. Modes: `canonical` (byte copy + synced header), `template` (copy, strip `.template`), `generate` (build per consumer, e.g. dependabot), `baseline-merge` (a sentinel region for text, a deep-merge for `.claude/settings.json`).
- `.github/workflows/sync-to-consumers.yml` / `sync-from-upstreams.yml` — the two directions of the sync.
- `docs/decisions/` — the org-wide ADRs (MADR 4.0). The numbering is the contract `adrs doctor` checks; keep it contiguous.

## Safety invariants

- The sync engine and `sync-manifest.yaml` are a contract. A change to a mode, the header logic, or the sentinel format can rewrite a file in every consumer. Run `spec/integration/sync_files_spec.rb` and reason about every consumer.
- Canonical files are byte-identical across consumers. Never put a consumer-specific name or path in a `mode: canonical` file (it would sync that leak everywhere) — keep them org-neutral.
- Org-wide ADRs live only here and are referenced by pointer (ADR 0004). Do not add per-repo copies, and do not renumber a published ADR.
- The pre-push hook rejects unsigned commits in the pushed range where commit signing is configured (maintainer machines, including this repo); without signing configured it warns and lets the push proceed, so contributors are informed but never blocked. A sandboxed agent commits unsigned and the maintainer re-signs the batch (`scripts/sign-push.sh`) before pushing — see `docs/agent-principles.md`.

## Repository-specific tools

- `scripts/foundation-init.sh` — bootstrap a new consumer from this checkout.
- `scripts/foundation-doctor.sh` — flag stale per-repo scaffolds (ADR 0015).
- `scripts/annotate.sh` — REUSE/SPDX annotation, per-filetype rules.
- `examples/minimal-repo/` — a worked consumer; mirror it when reasoning about what a consumer ends up with.

## Documents to read first

1. `docs/agent-principles.md` — operating principles (imported above).
2. `README.md` — what repo-foundation is and how the sync works.
3. `docs/decisions/` — the accepted ADRs that govern the layout, infixes, sync, ADR policy, and the rest.
4. `CONTRIBUTING.md` — encoding policy, commits, signed pushes.
