---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 24
title: A main-branch CI check enforces guard-pin freshness
status: accepted
date: 2026-07-26
decision-makers:
  - toobuntu
---

# A main-branch CI check enforces guard-pin freshness

## Context and Problem Statement

The foundation guard (ADR 0003's superseding amendment; `provides/github/workflows/foundation-guard.yml`) checks out repo-foundation at a pinned commit — `ref:` — and runs the sync engine's `--guard` mode reading the manifest **from that checkout**. The pin is deliberate: a consumer's required check must not move when repo-foundation's `main` does. Its cost is an invariant nothing enforced: whenever a `main` commit changes the manifest or the engine, the pin must be bumped to a commit carrying that change, or every consumer guard keeps enforcing the older contract — new managed files it does not know about, or an engine too old for its own options.

The invariant broke twice in two consecutive pull requests. PR #11 landed the `--guard` engine while the pin predated it (the guard would have failed on an unknown option); a session bumped the pin as its first task, and the same session's PR #12 changed the manifest — invalidating the bump it had just made. "A thing sessions remember" is demonstrably not a mechanism.

## Decision Drivers

- The correct pin value is a `main` commit containing the change — normally the merge commit — which **does not exist until the merge happens**. No pre-merge artifact can name it.
- Enforcement must not depend on session memory, opening prompts, or the maintainer's checklist: those are the mechanisms that just failed twice.
- The org's trust posture: workflows with write access to the repository are a large surface to add for a one-line edit a few times a year.
- The failure must be legible: whoever sees it should be handed the exact fix, not a symptom.

## Considered Options

- **A `main`-branch CI check that detects staleness** (chosen).
- **A git hook (or `sign-push.sh` step) that writes the bump branch-side**, using the SHA known at commit time.
- **A post-merge workflow that opens the bump PR itself.**
- **Session memory and opening prompts** — the status quo.
- **Un-pinning: the consumer guard tracks `main`.**
- **Deriving the pin instead of storing it**, the way starhaven-io's fleet does (see below).

## Decision Outcome

Chosen: **the detector on `main`** — `.github/workflows/guard-pin.yml`, repo-foundation-only (not in the manifest), running on every push to `main`. It extracts the pin, requires it to be a `main`-reachable commit, and fails if any commit in `pin..HEAD` touches `sync-manifest.yaml` or `.github/actions/sync/` — printing the exact `ref:` value to set and noting the fix lands through a pull request like any change. It is read-only (`permissions: contents: read`), so it adds detection without adding a write surface.

### Why the branch-side hook cannot do this reliably

The hook idea is attractive — at commit time the SHA of the pin-relevant commit is known, and under the org's merge-commit policy branch commits do land on `main` unchanged. It fails on four independent grounds:

1. **A commit cannot contain its own hash.** The bump is therefore always a *trailing* commit pinning its predecessor: the pin can name the last pin-relevant commit `T`, never "this change as merged." That is workable in the simple case, but it is what makes every case below fatal, because the recorded SHA is fixed before the events that decide whether it survives.
2. **Agent batches are re-signed, and re-signing rewrites every SHA.** The sandbox workflow commits unsigned; `scripts/sign-push.sh` rebases with `--gpg-sign`, so `T` becomes `T′` and the pushed branch contains only `T′`. A pin written by a commit-time hook still names `T` — an orphan that never reaches any remote. The consumer guard would try to fetch a commit that does not exist upstream. Running the bump inside `sign-push.sh` instead would couple the pin to one script and still miss directly-signed maintainer commits.
3. **Concurrent branches have no correct branch-side answer.** Two open PRs each touching the manifest would each pin their own tip; neither tip contains the other's change, and only the second merge commit on `main` contains both. The two bumps also edit the same `ref:` line, so the second merge conflicts — and the human resolving it has no valid branch-side SHA to resolve *to*. The post-merge `main` commit is the only value that is always right, and it is exactly the one no branch can know.
4. **Merge mechanics are a policy, not a law.** Org policy is merge commits, but a squash or rebase merge — tooling defaults, an emergency, a slip — leaves branch SHAs off `main`, reachable only through GitHub's `refs/pull/*/head` retention. A pin that works only by that grace is not a pin.

A branch-side mechanism can at most *predict* the obligation; it cannot discharge it. Prediction without enforcement is the status quo that failed. (A warn-only pre-push notice — "this push touches pin-relevant paths; expect the pin check to require a bump after merge" — was considered and skipped: the detector's failure message arrives at the moment the fix is actually possible, which is the only moment the information is actionable.)

### The prior art: fleet derives its pin, so it has nothing to detect

starhaven-io's fleet — the reference this org evaluated in `docs/handoff/rf-upstream-notes.md` § 18 — faces the same "the correct SHA does not exist until the merge" problem and never has a stale pin, because **no human ever writes a SHA**. Its chain, read from source:

1. `fleet/VERSION` holds a CalVer string (`v2026.07.08.1`). A human bumps that *string*, never a hash.
2. `fleet-release.yml` tags `main` after the version bump merges — the tag is created post-merge by automation, at the commit that only then exists.
3. `sync.rb`'s `reusable_pin` resolves `refs/tags/<version>` to a SHA **at render time** and templates it into every consumer's caller (`uses: …@<sha> # <version>`), with `git_hub_sha` as fallback.

Its own comment states the invariant: "The sync is the only writer for fleet pins: every render seeds every caller at the current release." The pin is a *derived artifact*, so it cannot drift from its source — the freshness question is answered by construction rather than by detection.

That is a stronger design than the one chosen here, and it is worth being plain about why the detector is chosen anyway: repo-foundation stores a hand-edited SHA in the hub (`provides/github/workflows/foundation-guard.yml`), which is what creates the staleness this ADR detects. Adopting the derived model would require making that file templated rather than byte-canonical, adding a version-and-tag discipline, and an engine mutation — a design change, not a fix. It also carries a correctness argument in its favor: under a derived pin each consumer's guard compares against **the canon it actually received**, whereas one hand-maintained hub pin can point at canon a given consumer has not been synced to yet.

The detector is therefore correct-and-cheap under the *current* design, and independent of it: if the derived model is later adopted, this check either becomes trivially always-green or is replaced by a tag-existence check. Evaluating that switch is queued, and pre-first-sync is its cheapest moment.

### Why not the bump-PR bot

A post-merge workflow with `contents: write` and PR-creation rights that edits a file whose content decides what every consumer guard enforces is a meaningful trust surface, and a self-modifying one (its own merge triggers the next run). The bump cadence — a few times a year, one line — does not justify it. Revisit if the cadence grows; the detector's log message is already the bot's specification.

### Why the detector is shaped the way it is

- **On every `main` push, deliberately not `paths:`-filtered.** The bump commit touches only `foundation-guard.yml`; under a paths filter its merge would not re-run the workflow, leaving the previous failing run as the branch's standing status. An unfiltered run costs seconds and turns green the moment the bump lands.
- **Not a required PR check.** The invariant is about `main`, and a PR cannot satisfy it — it cannot know its own merge SHA. Red `main` is the signal, and the failure carries the instruction.
- **The failure reports on three surfaces, because a log line is the one nobody reads.** A GitHub `::error` annotation carrying the replacement SHA attaches to the `ref:` line itself, so it appears on the commit and in the run summary without opening the log; the run summary repeats it as a fenced `ref:` line to copy; and the log holds the detail the other two cannot — the actual commits the pin fails to cover. The annotation's line number is located at runtime rather than hardcoded, so it survives edits to the guard workflow above it.
- **Watched paths are the manifest and the engine only.** These are the two surfaces the guard reads from the pinned checkout (the standing rule recorded in `.ai/memory.md`, 2026-07-24). Drift in other canonical *sources* is deliberately tolerated: the guard's merge-base filter means such staleness only shifts which canon an already-flagged consumer edit is compared against, and the scheduled sync converges any copy that slipped through. Watching all canonical sources would demand a bump on nearly every merge for no enforcement gain. This scoping is also what terminates the recursion — the bump commit touches neither watched path, so it cannot re-trigger the requirement it satisfies.

### Consequences

- Good, because the invariant is now held by CI rather than by memory; the two-failure pattern cannot recur silently.
- Good, because the fix is embedded in the failure: the run prints the exact `ref:` to set.
- Bad, because `main` is legitimately red between a pin-relevant merge and the bump PR — including immediately after the PR that introduces this workflow, whose own manifest changes the current pin does not cover. That first red run is the check working.
- Neutral, because the pin's self-reference remains: the canonical `foundation-guard.yml` at pin `P` necessarily records an older pin inside itself. This predates the check and is bounded by the guard's merge-base filter; the check neither worsens nor fixes it.

## More Information

Fleet's release and pin-resolution chain, read at the local reference clone: `.github/workflows/fleet-release.yml` (the `tag` job) and `fleet/sync.rb` (`reusable_pin`, `version_commit`). The org's earlier adopt/adapt/skip pass over fleet is `docs/handoff/rf-upstream-notes.md` § 18.8, which skipped the CalVer sole-pin-writer along with the reusable-workflow layer it was bundled with — this ADR separates the two, because the pin mechanism does not depend on thin callers.

The guard's design and the pinned-checkout trust argument: `docs/architecture.md` (Foundation guard) and ADR 0003's dated amendment. The pin-bump standing rule and both staleness incidents: `.ai/memory.md` (2026-07-24, 2026-07-26). The re-sign SHA-rewrite mechanics that defeat the hook option: `docs/agent-principles.md`, "Agent commit + signing procedure under sandbox isolation."
