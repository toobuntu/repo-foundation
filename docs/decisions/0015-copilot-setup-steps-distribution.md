---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 15
title: Distribute copilot-setup-steps per-repo, except Homebrew taps
status: accepted
date: 2026-06-23
decision-makers:
  - toobuntu
---

# Distribute copilot-setup-steps per-repo, except Homebrew taps

## Context and Problem Statement

`.github/workflows/copilot-setup-steps.yml` pre-installs the toolchain the GitHub
Copilot coding agent (the Cloud agent, included in Copilot Pro; not Copilot Code
Review) needs to operate in a repository. repo-foundation syncs shared
configuration to consumer repos, so the question is how copilot-setup-steps should
be distributed: synced from one canonical base, or owned per repo?

The complication is that the file's content *is* a per-repo concern — the agent's
toolchain differs by repository. babble (a Homebrew / mas-cli / softwareupdate
wrapper) needs `brew` and `mas`; homebrew-cask-tools (a tap) needs brew's
bundler-gems and test environment; an Objective-C repo needs `llvm`; a Go repo
needs `go`. There is no single install list correct for all of them.

## Decision Drivers

* The agent toolchain is intrinsic to each repo, like `ci.yml` build/test steps
  and `codeql.yml` languages — both already treated as per-repo scaffolds.
* Keep the sync engine's mode set small and declarative (canonical / template /
  generate / baseline-merge); avoid per-consumer imperative tweaks.
* Syncing earns its keep for genuinely *uniform* files (hooks, scripts, lint
  configs); it is friction for files that vary per repo.
* One case genuinely benefits from syncing: Homebrew taps. Homebrew/brew's
  copilot-setup-steps fits a tap as-is (a tap's `brew tests` use brew's
  bundler-gems/test env), and the maintainer expects to add more taps over time.
* Per-repo files risk silent staleness; this must be mitigated.

## Considered Options

* Sync one base to every repo
* Sync one base + per-consumer yq mutations
* Per-repo scaffold for every repo, including taps
* Per-repo scaffold, except Homebrew taps (chosen)

### Pros and cons of the options

* **Sync one base to every repo.** Rejected: forces Homebrew/brew's
  brew-development base (`install-bundler-gems`, `gnu-tar`, `subversion`) onto
  non-tap repos, where it is wrong.
* **Sync one base + per-consumer yq mutations.** Implemented, then rejected (see
  More Information). A `homebrew_ecosystem` set carried copilot-setup-steps to
  taps and wrappers, with a per-consumer `mutations` map (babble appended `mas`)
  applied by a new engine helper. Rejected because it adds a fifth, imperative
  paradigm to the engine; the yq expressions couple to Homebrew's upstream YAML
  structure (an upstream refactor silently mis-targets); and it exists mainly to
  force babble onto a base that does not fit it.
* **Per-repo scaffold for every repo, including taps.** Clean and consistent, but
  discards the real convenience of tracking Homebrew/brew for taps and makes each
  new tap a hand-rolled file.
* **Per-repo scaffold, except Homebrew taps (chosen).** Non-tap repos copy a
  scaffold and own their copilot-setup-steps; Homebrew taps sync it from
  repo-foundation (tracked from Homebrew/brew via `upstreams`, distributed via the
  `homebrew_tap` set), so a new tap is a one-line manifest entry.

## Decision Outcome

Chosen: option 4. copilot-setup-steps is per-repo for everything except Homebrew
taps, which sync it from repo-foundation. This keeps the engine declarative (no
per-consumer mutations), treats the file consistently with `ci.yml` / `codeql.yml`
for the common case, and still centralizes the one case — taps — where a shared,
upstream-tracked base genuinely fits and where the maintainer wants
add-a-tap-by-manifest-entry simplicity. A staleness check mitigates per-repo
drift (see More Information).

### Consequences

* Good: the sync engine keeps its small, predictable mode set; non-tap repos own
  the toolchain that is genuinely theirs; new taps are trivial to onboard; the
  base that taps track is apt for taps.
* Good: action pins inside the per-repo files stay fresh via Dependabot
  (github-actions ecosystem), independent of any reconciliation.
* Bad: one filename has two distribution paths (tap-synced vs per-repo scaffold) —
  a documented split, not an accident.
* Bad: per-repo scaffolds can drift structurally from upstream best practice;
  addressed by the staleness check below.
* Neutral: homebrew-cask-tools' own per-repo copilot-setup-steps sync is
  superseded by repo-foundation's `homebrew_tap` distribution once RF lands.

## More Information

### Staleness check (the chosen mitigation)

Per-repo scaffolds (ci.yml, codeql.yml, copilot-setup-steps.yml) are customized,
so there is no clean canonical to diff them against; an age-based nudge is the
pragmatic signal. Plan: a `foundation doctor` check flags scaffolded workflows
untouched in roughly a year ("reconcile against current upstream guidance"), and
a scheduled workflow runs the same check and opens/updates an issue on drift —
one implementation, two triggers. Diff-reporting is reserved for genuinely-synced
files, which already self-heal (drift → sync PR). Implementation is a follow-up,
alongside foundation-init / foundation doctor (Phase E).

### How the rejected synced + mutations approach (option 2) was built

Recorded for reference, should it ever be reconsidered:

* Manifest: a `homebrew_ecosystem` component set held copilot-setup-steps, listed
  by cask-tools and babble; babble carried a consumer-level `mutations` map keyed
  by target path, with a yq expression appending `mas` to the
  cache-homebrew-prefix install list.
* Engine: `sync-files.rb` gained `apply_consumer_mutations(content, mutations)`,
  applied to a component's content after the copy via a tempfile + `yq eval
  --inplace`. It ran against the freshly-derived canonical content each sync, so a
  plain append stayed idempotent and change-detection compared the final result;
  yq preserved the synced header. `require "tempfile"` and a `consumer["mutations"]`
  lookup supported it.

### How to revert to fully per-repo (drop the tap exception too)

If taps should also be per-repo: remove the `homebrew_tap` set and cask-tools'
membership; remove copilot-setup-steps from `upstreams`; delete RF's own
`.github/workflows/copilot-setup-steps.yml`; every repo (taps included) then
copies `provides/github/workflows/copilot-setup-steps.template.yml`. The
staleness check then covers taps too.

### Related

This refines the cross-repo sync architecture decision (ADR 0003).
