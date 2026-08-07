---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 26
title: Enforce the close ritual with hooks and a one-way vault
status: accepted
date: 2026-08-06
decision-makers:
  - toobuntu
---

# Enforce the close ritual with hooks and a one-way vault

## Context and Problem Statement

The end-of-session ritual — rewrite `.ai/progress.md`, account for removed lines, print a runnable closing recipe — is stated in `docs/agent-principles.md` and mechanized by the `tb-session-close` skill, and prose did not hold. The 2026-08-04 close named a deleted draft in its recipe, left `progress.md` un-rewritten under turn-final recipes that read as current, listed already-done steps as pending, and had to be ASKED for the recipe. Separately, the volatile continuity files (`.ai/progress.md`, `.ai/scratchpad/`) are gitignored by design (ADR 0022), so a destructive rewrite or deletion was final: branches do not version untracked files, and the main-branch edit guard that appeared to protect them protected zero bytes while forcing a ceremonial branch at every close on `main`.

## Decision Drivers

- Every 2026-08-04 failure is mechanically checkable from the agent's final message plus repository state; a `Stop` hook receives both (`last_assistant_message`, measured on Claude Code 2.1.220) and its exit-2/`decision:block` feedback is the only channel that can change behavior before the turn ends.
- A hook that misfires is worse than no hook, and this one syncs org-wide: every blocking path needs a spec that proves it fires and a loop story that provably terminates.
- Recovery for untracked files can only come from copies: no ceremony, no branch, and no report protects bytes.
- The maintainer must stay the only deleter of anything without checkable landing evidence.

## Considered Options

- **A `Stop` hook (close-check) plus a one-way vault, logic in `ai-session.sh`** (chosen).
- **Advisory-only output at turn end.** Rejected: exit-0 stdout of a `Stop` hook is not shown and not fed to the agent, so "advisory" means invisible — the failure the hook exists to fix would continue.
- **Track the volatile files in git.** Rejected: reopens ADR 0022's contract (per-developer, freely rewritten, no history), adds a commit per session on whatever branch is checked out, and collides with the clean-tree discipline.
- **Wider guards (block shell writes to continuity paths on `main`).** Rejected: the writing forms (`>`, heredocs, interpreters) are used constantly for read-only work, so the guard that prevents anything real also refuses legitimate commands — the same trade `guard-main.sh`'s header already declines.

## Decision Outcome

Chosen: enforcement in `scripts/ai/ai-session.sh` subcommands wired as thin `[ -x ]`-gated hook shims in the settings baseline, with recovery in a vault outside the agent's writable area.

- **`close-check` (Stop hook).** Four checks: recipe-truth over fenced blocks only (session-artifact paths must exist; a `cp` whose endpoints compare equal is an already-done step; an `rm` of an absent path is a stale step); a close claim over a `progress.md` not newer than the session-start snapshot; spent drafts (full-message match against `git log` — a subject-only match is a note, never a block, because an `--amend` keeps the subject; a parked `merged/prNN/*` branch proves a PR draft spent); and a close-shaped turn (commits ahead, clean tree) with no recipe, satisfied by either the recipe or an explicit `Closing recipe: none — <reason>`. Loop safety is layered: the harness's `stop_hook_active` always downgrades, and a per-session finding-set hash means a distinct finding set blocks at most once, then surfaces as a visible `systemMessage`.
- **The vault.** `${XDG_STATE_HOME:-~/.local/state}/ai-history/<org>/<repo>/` receives the pre-write state of every continuity file before hooks let an overwrite or deletion proceed (Edit/Write shim, Bash-rm shim, SessionStart, PreCompact), deduped, announced with both paths. Hooks run outside the agent sandbox and can write there; the sandboxed agent cannot (measured: `Operation not permitted`), and the Edit/Write tool routes carry explicit denies — one-way by construction. Pruning is evidence-first: `progress.md` keeps the newest ten copies; a gone draft auto-prunes only on landing evidence; everything else is only ever REPORTED after 30 noticed days, and `vault-gc`, the sole deleter for that class, is maintainer-run and wired into no hook — a spec asserts the settings never wire it.
- **Unclean-close detection.** `end` writes a marker (session id, UTC, progress checksum); the next `start` verifies it and, on a mismatch, prints the previous session's id with a copy-pasteable `claude --resume <id>` + `/tb-session-close` remedy before anything overwrites the snapshot. A `start` re-fired by the same session keeps the snapshot.
- **The guard exemption.** `guard-main.sh pre` refuses tracked-file edits on `main` as before, exempts exactly the two continuity paths on every branch, and logs each exempted `main` write to `.git/claude-exempt-writes` for close-check to report — visibility by report instead of by ceremony.

### Consequences

- Good: the four measured close failures become one blocked turn each, with the fix named; a defective recipe cannot end a session silently.
- Good: deletion and destructive rewrite of the volatile files stop being final, with recovery copies the agent can read but not touch.
- Good: closing on `main` no longer requires a ceremonial branch, and the writes that made it tempting are reported instead of invisible.
- Bad: a wrong blocking finding costs one retry turn before it downgrades; the spec suite is the guard against shipping one.
- Bad: the vault is per-machine state; it does not travel between machines, and multi-machine continuity remains out of scope (ADR 0022's contract stands).
- Neutral: `Stop` fires only when a turn's final act is text, so a turn ending in a question or permission prompt is not gated — closes are the covered shape, and the hook does not claim to be a universal enforcer.

## Amendment (2026-08-07)

Four changes from the first review round and from two incidents in which the enforcement caught its own building session.

- **The auto-compaction narrowing is reversed.** The original decision shipped only a vault copy at `PreCompact`, on the theory that auto-compaction fires too near context-full to leave room for writing. That does not survive the arithmetic (maintainer): the trigger leaves a substantial fraction of the window free, ample for a progress rewrite and a memory entry — and a `PostCompact` alternative is strictly worse, because after compaction the agent no longer holds the detail it would need to write. `compact-check` now blocks manual and auto compaction alike until `.ai/progress.md` is current, with the vault copy taken first (a block never costs a snapshot) and a two-block cap so a session that cannot write still compacts. "Current" is measured against activity, not against session start — a `progress.md` rewritten in hour one of a five-hour session is stale — by comparing its mtime to the session-start snapshot, the last-compact marker, `.git/logs/HEAD`, modified tracked files, and the scratchpad.
- **Every hygiene shim runs through `hook-run.sh`, which parse-checks before exec and fails OPEN.** A syntax error introduced into `ai-session.sh` while it was wired into four PreToolUse matchers and `Stop` refused every writing tool and every turn end at once — including the edit that would have fixed it. A guard whose own code is broken has stopped guarding either way; the version that also blocks its own repair is strictly worse.
- **The `annotate.sh` guard moved from inline JSON into `scripts/ai/guard-annotate.sh` and is the one deliberate exception: its shim fails CLOSED**, because it gates a sandbox escape (`excludedCommands`), where silently ceasing to guard is the worse failure. Two scope rules keep the closed failure recoverable: the shim refuses only commands that name the protected script (its first version refused every Bash call while the guard file was non-executable — caught live, within a minute of wiring), and the guard sits only on the Bash matcher, so the Edit tool can always repair it.
- **Landing evidence may use the network, degrading to silence.** `net_get` prefers `gh` — hooks run outside the sandbox, so the credentials the sandboxed agent cannot read are available to them — falls back to unauthenticated `api.github.com` with a three-second timeout, caches per API path, and treats every failure as no-evidence, never as unlanded and never as a user-visible error. It serves a merged-upstream check for PR drafts (after the free local parked-branch test) and a filed-issue check for issue drafts, which shrinks the report-only class to genuinely ad-hoc files; the orphan report itself now fires at 14 days rather than 30, since it only reports and a late report costs the memory of what the file was.
