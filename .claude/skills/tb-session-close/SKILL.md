---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

name: tb-session-close
description: >-
  Run the end-of-session ritual and produce the runnable closing recipe — continuity files
  updated, learnings appended, then the exact commands to finish this session and start the
  next one. Use when the maintainer says to wrap up, close out, hand off, is done for now, or
  asks for the closing recipe or next-session setup. Also use before a long pause. Covers
  every step a session must not ship incomplete: the removed-line accounting, annotations the
  sandbox blocked, sign-push, the PR body, branch parking, and the next opening prompt with
  its model.
---

# Session close

The last thing a session prints is not a summary but a sequence the maintainer can execute without reconstructing anything. A report that says "then open a PR" has moved work back onto the maintainer that the session was supposed to finish.

This skill exists because the prose version of it in `docs/agent-principles.md` has repeatedly been shipped incomplete — most expensively when a pull request merged without three commits that were never sign-pushed.

## First, the continuity files

1. **`scripts/ai-session.sh end`**, then **account in the report for every line it lists as removed from `.ai/progress.md`.** Most removals are correct: finished status should go away. The one that is not is a line recording a COMMITMENT rather than a status, which had to graduate somewhere durable — a dispatch row, an issue, an ADR, `.ai/memory.md` — before it left the file. Stating each removal is what makes that case visible; a rewrite with no diff hides it.
2. **Append durable learnings to `.ai/memory.md`** as a dated entry. Append-only, hook-enforced: a correction is a new entry naming what it supersedes, never an edit. Graduate what belongs elsewhere — a decision to an ADR, a fact the code can carry into code, an org-wide rule of conduct to `docs/agent-principles.md`, an org-wide fact to `.ai/org/memory.md` (or `.ai/org/relay.md` outside repo-foundation). Per-session "what shipped" does not go in at all; git history owns that.
3. **Rewrite `.ai/progress.md`** to the current state and the next action.

## Then close the loop on what the sandbox blocked

State these explicitly rather than leaving them implied:

- **`scripts/annotate.sh`** whenever a file was created that the session could not annotate. Writes under `<repo-root>/.claude/skills/` are denied to every Bash tool while the Write tool reaches them, so a session that adds a skill cannot annotate or format it. Put `annotate.sh` in the recipe; it is a no-op on already-compliant files, which doubles as the verification.
- **Any `rumdl fmt` or formatter run** the same denial swallowed. `rumdl fmt` reports success while changing nothing there, so never treat its exit status as proof.
- **Anything unverified**, named as such: an untested CI path, a claim read from source rather than run. Say which run would prove it.
- **Leftover drafts** under `.ai/scratchpad/`. A spent draft is deleted; a surviving one is the signal of an unfinished commit.

## Then the recipe, written out in full

Every applicable command, in order, each in its own fenced `bash` block so it is one click to run. No prose stand-ins.

- `scripts/sign-push.sh` — and check `git log @{u}..HEAD` first. Unsigned commits sitting on a parked branch after its PR merged is a real failure that has happened; "sign-push, then merge" is ordered.
- The `gh pr create --body-file …` invocation, with the body already written to `.ai/scratchpad/pr-body-<slug>.md`, chained to `rm -f` on success. For a PR that already exists and has grown, `gh pr edit <N> --body-file …` instead — a stale description is what review bots read, and they will report findings against it.
- `cp -p` for any file mirrored under `.ai/scratchpad/workspace/`, plus the `git -C … commit` that lands it.
- `git branch --move <branch> merged/pr<N>/<branch>` — park, never delete; remote deletion is separate.
- Realigning local `main` after a re-signed branch lands: `git switch main && git fetch origin && git reset --hard origin/main`, since the re-signed SHAs and the local copies diverge by construction.
- Any expected-red CI, named as expected: a manifest or engine change re-stales the foundation guard pin, and that run prints the exact replacement `ref:`.
- **The next session's opening prompt, by path, with the model to run it under.** This is the step whose absence makes a session incomplete no matter how good the work was.

## Report shape

Lead with what landed and what is verified. Then the accounting for removed progress lines. Then the recipe. Do not bury an unverified claim or a blocked annotation inside a paragraph of accomplishments.
