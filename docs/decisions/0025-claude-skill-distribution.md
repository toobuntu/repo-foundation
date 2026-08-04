---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 25
title: Distribute org-generic Claude Code skills as canonical files
status: accepted
date: 2026-08-03
decision-makers:
  - toobuntu
---

# Distribute org-generic Claude Code skills as canonical files

## Context and Problem Statement

A Claude Code skill is a `SKILL.md` under `.claude/skills/<name>/` whose frontmatter description decides when an agent loads it, and whose body is then instructions that agent follows. Three of them — `tb-issue-draft`, `tb-review-triage`, `tb-session-close` — were written in repo-foundation and set out org-wide procedure: the house style for an upstream bug report, review-bot triage and where a settled ruling gets recorded, and the end-of-session ritual with its runnable closing recipe. Each procedure is already org canon in `docs/agent-principles.md` and in the files `scripts_core`, `ai_continuity` and `repo_config` deliver — but the skills that mechanize them exist in one repository.

Four more skills sat at the *bucket* scope: the `.claude/skills/` of the directory that holds every toobuntu clone on a maintainer's machine. All four (`dev-cycle`, `release-check`, `test`, `review-pr`) duplicate blackoutd's own copies, and three name blackoutd explicitly ("run blackoutd's edit/build/reload cycle", "blackoutd's pre-commit hook"). A skill at that scope loads in *every* repository under the directory, so an agent working in homebrew-cask-tools is offered blackoutd's build cycle.

So: which skills are org canon and travel with the sync, which stay local to one repository, and what happens to the bucket-scope copies?

## Decision Drivers

- A skill's body is instructions a later session follows, so drift between repositories is drift in how agents behave — the argument that already makes `docs/agent-principles.md` canonical.
- The criterion should be the one `docs/repo-standards.md` uses for docs: does someone working *in the consumer repository* need this during routine work?
- A synced skill must not name anything the consumer does not receive.
- Scope must match audience. Loading one repository's skill in another is a correctness problem, not clutter.

## Considered Options

- **A canonical `claude_skills` set for the org-generic skills** (chosen).
- **Leave every skill local.** Rejected: the three carry org procedure, so copies would drift exactly as the `annotate.sh` copies did — eight of them across three generations (`.ai/memory.md`, 2026-08-03).
- **Promote them to the bucket scope instead of syncing.** Rejected: that directory is maintainer-machine state. It reaches no contributor, no fork, and no other machine — the reason ADR 0022 moved org knowledge out of the private workspace and into the repository.

## Decision Outcome

Chosen: a **`claude_skills` component set** carrying the three `tb-*` skills as `mode: canonical`, mapped to every `repo_baseline` consumer.

- **What syncs, and why each.** `tb-session-close` mechanizes the `.ai/` end-of-session ritual and the closing recipe, both `docs/agent-principles.md` rules; `tb-review-triage` covers review-bot triage and pins the "record it in `.coderabbit.yaml`" step that is otherwise the one most often skipped; `tb-issue-draft` is the house style for an upstream report. None names a repository, a build system, or a path the sync does not deliver.
- **What does not.** A skill naming one repository's toolchain stays in that repository, unsynced: blackoutd's `dev-cycle`, `release-check` and `test`; bob-book's `bob-book-transcription`.
- **The bucket-scope copies are removed.** Each duplicates blackoutd's own, so nothing is lost by deleting them there, and three mis-fire everywhere else. A maintainer step: that directory sits outside every repository tree and outside the agent sandbox.
- **`review-pr` is superseded rather than promoted.** Its content is "fetch a pull request's review state, including the inline comments `gh pr view` omits" — which is step 0 of `tb-review-triage`, carrying the same warning about the separate REST endpoint. Consumers get the behavior through the synced skill; blackoutd may retire its local copy.
- **`toobuntu/.github` is not mapped.** It takes neither `repo_baseline` nor `ai_continuity` (it hosts served community-health files, not development work), so a session-ritual skill there would document machinery it does not have.
- **The `tb-` prefix marks the org set.** A contributor reading a consumer's `.claude/skills/` can tell which entries are managed here and which are the repository's own without opening them.

### Consequences

- Good, because one edit to a procedure reaches every repository's agents, and the foundation guard rejects a consumer-side edit to a managed skill exactly as it does for any other canonical file.
- Good, because it forced a latent engine defect into the open: these are the first canonical Markdown sources carrying YAML frontmatter, and the synced header landed between the closing fence and its blank line, rendering a file that fails MD071 and MD012 in every consumer running the Markdown gate. Fixed alongside the set.
- Bad, because a consumer wanting to vary one of the three must exclude the target with a cited reason rather than edit in place — the standard canonical-file trade.
- Bad, because the SPDX block sits *inside* the YAML frontmatter (`.ai/org/memory.md`, 2026-07-30, measured both directions). That is correct and non-obvious, and a contributor hand-adding a skill will reach for the header form used everywhere else. Run `scripts/annotate.sh` and let `reuse` place it, per the standing rule.
- Neutral, because the agent sandbox denies Bash writes under a repository's own `.claude/skills/`. Authoring a skill still needs the Write tool and the two excluded formatters; receiving one does not, since the sync engine writes through the GitHub API.

## More Information

The distribution criterion is `docs/repo-standards.md`; the manifest mechanics are ADR 0001 (natural-path mastering) and the component-set model in `docs/architecture.md`. SPDX-inside-frontmatter is recorded in `.ai/org/memory.md`, 2026-07-30, together with the verification method — a clean `scripts/annotate.sh` run does not confirm placement, because `reuse lint` accepts the strings wherever they sit.
