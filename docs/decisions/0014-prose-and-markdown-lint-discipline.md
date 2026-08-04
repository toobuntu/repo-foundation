---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 14
title: Adopt one canonical Vale prose style, run via Homebrew in CI
status: accepted
date: 2026-06-23
decision-makers:
  - toobuntu
---

# Adopt one canonical Vale prose style, run via Homebrew in CI

## Context and Problem Statement

Markdown prose across the repositories needs a consistent house style: en_US, terse, impersonal, technical. Two questions follow. Which linter and style? And how does CI run it as a deterministic gate?

One repository (zman-didan) built a local `Didan` Vale style and ran Vale in CI. Left there, every repository would grow its own style with its own term swaps, and a consumer that received two styles could get conflicting substitutions. The org-wide decision is whether to standardize one style, and how CI executes it.

## Decision Drivers

- Deterministic CI gate: fail the build on any error-level alert (for example an en_GB spelling), reliably.
- One canonical style org-wide — not per-repo styles that ship conflicting term swaps to a consumer.
- Least privilege in CI: no `GITHUB_TOKEN` write scopes unless genuinely required.
- One source of truth for the linted file set.
- Parity between the local install and CI, to avoid drift.
- Supply-chain hygiene: pinned, auditable dependencies; nothing extra inside the trust boundary.

## Considered Options

For the style:

- **One canonical `Toobuntu` style, synced from repo-foundation** (chosen).
- **Per-repo styles**, each maintained locally.

For CI execution (carried from zman-didan's evaluation):

- **`vale-cli/vale-action`** (formerly `errata-ai/vale-action`).
- **Pinned release tarball plus the repo's `vale` lint target.**
- **Install Vale via the runner's pre-installed Homebrew, then run the `vale` lint target** (chosen).

## Decision Outcome

Chosen: one canonical `Toobuntu` style, run via Homebrew in CI.

- **One style, synced.** The `Toobuntu` style lives in repo-foundation and syncs to consumers (ADR 0003), behind a single `accept.txt` vocabulary. (Amended 2026-08-03: two vocabularies, not one. `Vocab` takes a comma-separated list, so every consumer seeds `Vocab = Toobuntu, Local` and keeps its own domain terms in an unsynced `Local` list — a product name or a daemon should not need a repo-foundation round trip to stop failing that repository's gate. repo-foundation carries only `Toobuntu`, since it owns the canonical list. A named vocabulary that does not exist is a runtime error that lints nothing, and git does not track an empty directory, so `foundation-init` seeds `Local/accept.txt` as a real tracked file.) It absorbs the former `Didan.*` rules (American-spelling, impersonal-voice, abbreviation-plurals) plus adopted rules from the Homebrew, GitLab, and Elastic style sets. A consumer consumes the synced style instead of maintaining its own, so no consumer ever receives two styles with conflicting swaps.
- **Run via Homebrew, not the action.** CI installs Vale with the runner's pre-installed Homebrew (`brew install vale`) and invokes the repo's `vale` lint target. `vale-cli/vale-action` is rejected: its `fail_on_error` has repeatedly failed to fail the build even with error-level alerts present; its reviewdog reporters need a `GITHUB_TOKEN` with `checks` / `pull-requests` write; its default `filter_mode: added` lints only diff-added lines, not the whole tree; and the publishing org was renamed. A bare `vale` exits non-zero on error-level alerts under `MinAlertLevel = error`, so the job needs no reporter and no token.
- **Policy split.** The dialect rule (en_US American spelling) is enforced **everywhere** — it is correctness, not voice. The dictionary spelling check and the impersonal-voice rule are relaxed per-glob for handoff/working-note and snippet-heavy design docs.
- **Levels.** Only `error` gates under `MinAlertLevel = error`. A new rule lands at `warning`, runs over the real corpus, and is promoted to `error` after a clean pass. The tiered rule roster (high-value, near-zero false-positive rules at error; heuristic or tagger-noisy rules at warning; product-specific or voice-clashing rules skipped) is curated separately and not enumerated here. (Amended 2026-08-03, on the evidence of the first two reviews this path actually produced. **Promotion is per-repo**: levels live in `.vale.ini`, which is deliberately not synced because its scope-block relaxations vary, so a rule's level is six independent decisions taken against six corpora — never one org-wide switch. And **a clean pass is a precondition, not a verdict**: `Vale.Spelling` reached one here and was promoted, while `Toobuntu.Acronyms` cannot reach one at all, because 69% of its findings are emphasis capitals and file names its `[A-Z]{3,}` pattern cannot distinguish from acronyms. A rule whose false positives are structural stays at warning permanently, or is redesigned; growing the exception list until the corpus is clean would only stop it firing on the case it exists for. Measurements in `docs/prose-linting.md`.)

Markdown *structure* — a README's section set and order — is a separate concern, governed by ADR 0008 (standard-readme via remark). This ADR is about prose.

### Consequences

- Good, because a bare `vale` exit code is a sufficient gate: no reviewdog, no reporter, no `GITHUB_TOKEN`.
- Good, because the linted file set lives only in the repo's `vale` target; CI runs that target, so the two cannot drift.
- Good, because CI and local both obtain Vale from Homebrew, sidestepping the brew-versus-release-artifact vocabulary-handling discrepancy class.
- Good, because one org style means a consumer never receives two styles with conflicting term swaps.
- Bad, because CI tracks whatever version Homebrew's index has rather than a pinned version. Acceptable for a prose linter; pin a version later if exact parity ever matters.
- Neutral, because Homebrew is pre-installed on the runner but not on `PATH`, so the job invokes `brew` by absolute path and prepends its bin to `GITHUB_PATH`.

### Confirmation

A single en_GB spelling in a linted file fails the `vale` job. `MinAlertLevel = error` in `.vale.ini` is what makes the bare `vale` exit code a sufficient gate.

## More Information

This supersedes zman-didan's local `Didan` style and its initial tarball-based Vale job (zman-didan ADR 0001, absorbed here). The canonical `Toobuntu` style and its vocabulary are landed in a later build-out phase and synced via the manifest (ADR 0003); this ADR records the discipline ahead of that work. Runner Homebrew location and the "not on PATH" caveat are documented in the actions/runner-images Ubuntu readme.
