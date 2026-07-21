---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 17
title: Track Git hooks in .githooks/ as a base plus per-language plugins
status: accepted
date: 2026-06-25
decision-makers:
  - toobuntu
---

# Track Git hooks in .githooks/ as a base plus per-language plugins

## Context and Problem Statement

Every repository in the family runs the same client-side Git hooks: a `pre-commit` that enforces the executable-bit policy, the Trojan-Source / invisible-Unicode scan, and REUSE compliance, and a `pre-push` that checks commit signatures. repo-foundation is the canonical source that syncs these hooks to consumers (ADR 0003). Three questions follow, and the answers interlock:

1. **Where do the hooks live, and how does a clone activate them?** Git's own `.git/hooks/` is per-clone and untracked, so a hook placed there is invisible to version control and absent on a fresh clone.
2. **How do per-language checks attach?** A Go repo wants `gofmt` / `go vet`; an Objective-C repo wants `clang-format` / `clang-tidy`; a Homebrew tap wants `brew style`; a Swift tool wants `swiftformat` / `swiftlint`. None of these belongs in a hook that every repo receives byte-for-byte.
3. **Where in repo-foundation do the per-language masters sit**, given that repo-foundation runs the base hook on its own commits but is not itself a Go, Objective-C, Swift, or tap repository?

An earlier arrangement answered these badly: blackoutd's `pre-commit` embedded its Objective-C checks directly in the base. The base could not then be synced verbatim — every consumer would inherit blackoutd's `clang-tidy` invocation — and a fix to the shared logic could not propagate without hand-editing each copy.

## Decision Drivers

- A single base hook must sync byte-for-byte to every consumer, so one fix propagates through the sync rather than being re-applied per repo.
- The hooks must be tracked and present on a fresh clone, activated by one documented command.
- Per-language checks must reach only the repositories of that language.
- The plugin mechanism must behave identically under macOS `/bin/sh` (bash 3.2), dash, and ksh — no reliance on a shell-specific glob or bracket quirk.
- repo-foundation's own layout (ADR 0001) places a file at its natural path when repo-foundation uses it, and under `provides/` when it does not; the hook artifacts must follow that rule legibly.

## Considered Options

### Activation and location

- **A tracked `.githooks/` directory plus `git config core.hooksPath .githooks`** (chosen).
- **`.git/hooks/` populated by an install script** — untracked; needs a bootstrap step that can silently not run.
- **A third-party hook manager** (pre-commit.com, husky, lefthook) — adds a runtime dependency and a config language for what a 40-line POSIX `sh` script already does.

### Per-language checks

- **A repo-agnostic base plus per-language `pre-commit.d/` plugin masters owned by repo-foundation** (chosen).
- **Language checks inline in the base** — the rejected status quo; the base can no longer be synced verbatim.
- **Each repo owns its own complete hook** — a shared fix cannot propagate.

### Plugin naming

- **Debian `run-parts` `classicalre` names — `^[A-Za-z0-9_-]+$`, no dot, no extension** (chosen): a dot disables a plugin (`20-go.off`, `*.disabled`).
- **`NN-name.sh`** — the extension collides with `run-parts`' disable-by-dot convention and with the exec-bit lint pattern.

### Where the masters live in repo-foundation

- **`provides/githooks/pre-commit.d/`** (chosen) — mirrors the consumer's `.githooks/` exactly as `provides/github/workflows/` mirrors `.github/workflows/`.
- **`.githooks/pre-commit.d/` at the natural path** — wrong, because repo-foundation does not run these language plugins; a master there would be a non-running file in repo-foundation's own hook directory.
- **`provides/git/hooks/pre-commit.d/`** — rejected: the `git/hooks/` spelling reads as `.git/hooks/`, the untracked git-internal directory this whole decision routes around.

## Decision Outcome

Hooks are tracked in a top-level **`.githooks/`** directory and activated with `git config core.hooksPath .githooks` (run once per clone; the foundation-init bootstrap and CONTRIBUTING document it). The directory holds a **repo-agnostic base**: `pre-commit` and `pre-push`, synced byte-for-byte to every consumer (`mode: canonical`).

Per-language checks are **`pre-commit.d/` plugins**. The base runs each entry of `.githooks/pre-commit.d/` in a subprocess, in sorted order — the `/etc/cron.d`/`run-parts` convention — and gates each name by the `run-parts` **`classicalre`** rule: it runs only if the name matches `^[A-Za-z0-9_-]+$` (letters, digits, underscore, hyphen — no dot, hence no extension). A dot suffix therefore disables a plugin (`20-go.off`, `*.disabled`, `*.sample`). The base applies that rule with `grep -E` under `LC_ALL=C`, not a `case` glob, because macOS `/bin/sh` (bash 3.2) mis-handles the POSIX negated bracket `[!…]` and `[^…]` is not dash-portable; `grep -E` is the same regex `run-parts` compiles and behaves identically everywhere. `scripts/lint-perms.sh` enforces the executable bit on the same `[A-Za-z0-9_-]+` name set, so a plugin committed `100644` (which would silently never run) fails the perms lint instead.

repo-foundation owns the plugin masters; placement follows ADR 0001. The language plugins it does not run — it is not a Go, Objective-C, Swift, or tap repository — live under `provides/`, at **`provides/githooks/pre-commit.d/`**: `20-go`, `20-objc`, `20-brew`, `20-swift`. A plugin repo-foundation runs on its own commits is mastered at the natural path `.githooks/pre-commit.d/` instead: `10-shell` (repo-foundation is itself a shell repository) and later `10-prose`, `10-markdown`, and `50-adrs` (ADRs 0019, 0020, and 0018). The numeric prefix marks a category — `10-` format checks, `20-` language toolchains, `50-` policy/health — that share a prefix and sort lexicographically within, so a new plugin joins a tier without renumbering the rest. The manifest maps each to a consumer **only** where it applies (`go_plugin` → zman-didan, `objc_plugin` → blackoutd, `brew_plugin` → the tap, `swift_plugin` → Swift consumers), so one master is the single source for every consumer of its language. A plugin is **self-contained**: it runs as a subprocess and does not inherit the base's shell functions, so it defines its own `staged_z` / `has_files` helpers.

`10-shell` is the near-universal plugin: every repository has shell scripts, so it (with `.editorconfig`, `.shellcheckrc`, `scripts/lint-shell.sh`, and the `shell-lint` CI job — the `shell_lint` set) syncs to every consumer **except** the Homebrew-aligned ones. homebrew-cask-tools and babble instead defer to `brew style`, which runs `shfmt` + `shellcheck` (and RuboCop) with Homebrew/brew's own config carried verbatim, so they take `brew_plugin`, not `shell_lint`, and never receive the toobuntu two-space shell config. Its `10-` prefix places it in the format-check tier (with `10-prose` and `10-markdown`), which runs before the `20-` language toolchains, so the cheap style checks surface first.

The `provides/githooks/` spelling is deliberate. The sync target is the consumer's `.githooks/pre-commit.d/`; dropping the leading dot for the `provides/` copy mirrors that path the same way `provides/github/workflows/` mirrors `.github/workflows/`. The rejected `provides/git/hooks/` spelling read as `.git/hooks/` — the untracked, git-internal hooks directory that `core.hooksPath` exists to bypass — and so misnamed the very thing the layout is built to avoid.

### Consequences

- Good, because the base hook is genuinely uniform: it syncs byte-for-byte, and a fix to the shared logic reaches every consumer through one sync.
- Good, because `core.hooksPath` keeps the hooks tracked and reviewable, with a single activation command and no per-clone install script that can be skipped.
- Good, because a language fix is made once in the one master and propagates to every consumer of that language; a repo of another language never receives it.
- Good, because the `classicalre` rule gives a uniform enable/disable convention (dot to disable) that the perms lint and the base hook share, with identical behavior across shells.
- Bad, because `pre-commit.d` plugins re-declare the base's `staged_z` / `has_files` helpers; the duplication is the price of subprocess isolation and is small.
- Neutral, because the masters sit under `provides/` rather than at a natural path; that is exactly ADR 0001's rule for a file repo-foundation ships but does not run.

## More Information

The `run-parts` `classicalre` rule is the default regex compiled by `regex_compile_pattern` in `run-parts.c` (mirrored at `toobuntu/bob-book/docs/src/run-parts.c`). The base hook and `scripts/lint-perms.sh` are the implementation; ADR 0005 (REUSE lint-file with `--no-multiprocessing`) and ADR 0006 (Trojan-Source detection) govern two checks *inside* the base hook, and are distinct from this decision about how the hook suite is structured, located, and distributed. The layout rule is ADR 0001, the filename infixes are ADR 0002, and the sync that carries all of this is ADR 0003.
