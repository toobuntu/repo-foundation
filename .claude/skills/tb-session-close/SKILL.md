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

## When this runs: every recipe-bearing turn

A session cannot know in advance which turn is its last, but it always knows when it *might* end: **any turn that ends with a closing recipe is a potential session end, so the ritual below runs before printing the recipe — not only when the maintainer says wrap up.** Waiting for an explicit close is how a session prints a current-looking recipe over a `progress.md` three days stale, which happened on 2026-08-02 and added this section.

Running early is safe by construction, so err toward running: `ai-session.sh end` is read-only and idempotent (it diffs the start snapshot against the current file, exits 0, and never consumes the snapshot); `progress.md` is rewritten freely by design; memory entries are dated and append-only, so an early entry is legal and the periodic consolidation pass absorbs any fragmentation. Only append to memory when the turn produced a durable learning not yet recorded — the idempotence license covers re-running the ritual, not re-stating the same lesson.

1. **`scripts/ai-session.sh end`**, then **account in the report for every line it lists as removed from `.ai/progress.md`.** Most removals are correct: finished status should go away. The one that is not is a line recording a COMMITMENT rather than a status, which had to graduate somewhere durable — a dispatch row, an issue, an ADR, `.ai/memory.md` — before it left the file. Stating each removal is what makes that case visible; a rewrite with no diff hides it.
2. **Append durable learnings to `.ai/memory.md`** as a dated entry. Append-only, hook-enforced: a correction is a new entry naming what it supersedes, never an edit. Graduate what belongs elsewhere — a decision to an ADR, a fact the code can carry into code, an org-wide rule of conduct to `docs/agent-principles.md`, an org-wide fact to `.ai/org/memory.md` (or `.ai/org/relay.md` outside repo-foundation). Per-session "what shipped" does not go in at all; git history owns that.
3. **Rewrite `.ai/progress.md`** to the current state and the next action.

## Then close the loop on what the sandbox blocked

State these explicitly rather than leaving them implied:

- **`scripts/annotate.sh`** whenever a file was created that the session could not annotate. Writes under `<repo-root>/.claude/skills/` are historically denied to Bash tools while the Write tool reaches them, so a session that adds a skill may be unable to annotate or format it. Put `annotate.sh` in the recipe — but do **not** claim its silence verifies a hand-placed SPDX block. `annotate.sh` acts only on files `reuse lint` reports as non-compliant, and `reuse lint` passes wherever in a file the SPDX strings sit, so a no-op says nothing about placement. The test that does: copy the file, strip its SPDX block, run `reuse annotate` on the copy with the same arguments `annotate.sh` uses (including `--copyright-prefix=spdx-string`), and diff against the original.
- **Any `rumdl fmt` or formatter run** the same denial swallowed. `rumdl fmt` reports success while changing nothing there, so never treat its exit status as proof.
- **Anything unverified**, named as such: an untested CI path, a claim read from source rather than run. Say which run would prove it.
- **Leftover drafts** under `.ai/scratchpad/`. A spent draft is deleted; a surviving one is the signal of an unfinished commit.

## Then the recipe, written out in full

Every applicable command, in order, each in its own fenced `bash` block so it is one click to run. No prose stand-ins.

**Validate the recipe before printing it.** Every path it names must exist *now*: `ls` the draft files, check the branch name against `git branch --show-current`, confirm the PR number. This is not pedantry — a recipe that chains `rm -f` on success consumes its own inputs, so repeating a previous turn's recipe verbatim hands the maintainer a command whose file was deleted by the last one. That has happened. Re-derive the recipe each time from current state rather than copying the last one forward, and if a draft is genuinely gone, write a fresh one rather than naming the missing path.

- `scripts/sign-push.sh` — and check `git log @{u}..HEAD` first. Unsigned commits sitting on a parked branch after its PR merged is a real failure that has happened; "sign-push, then merge" is ordered.
- The `gh pr create --body-file …` invocation, with the body already written to `.ai/scratchpad/pr-body-<slug>.md`, chained to `rm -f` on success. For a PR that already exists and has grown, `scripts/pr-body-update.sh <N> .ai/scratchpad/pr-body-<slug>.md` instead — a stale description is what review bots read, and they will report findings against it. Never a bare `gh pr edit --body-file`: it replaces the whole body, deleting the summary CodeRabbit writes into the description. The script rewrites only the region between the `pr-body:begin` / `pr-body:end` markers (see `docs/agent-principles.md`), and refuses a body that has none rather than guessing where the bot's text starts.
- `cp -p` for any file mirrored under `.ai/scratchpad/tb-coordination/`, plus the `git -C … commit` that lands it. A mirror that carries *edits* rather than a whole replacement file cannot be a `cp -p`, and "apply the edits" is exactly the prose stand-in this section forbids — write the step out: open `<edits-file>`, apply every replacement it describes to `<target-file>`, then the commit and the `rm -f` of the spent edits file. Name both paths.
- **Diffs you are asking the maintainer to review go through `git diff`, not `diff`** — its output is what they read, and their `diff.algorithm`, `diff.colorMoved`, and textconv settings only apply there. For two files neither of which is in the index, that is `git diff --no-index`; add `-R` when the natural reading order is target-then-source, as when piping a proposed new version against the current one.
- `git branch --move <branch> merged/pr<N>/<branch>` — park, never delete; remote deletion is separate.
- Realigning local `main` after a branch lands: **`git switch main && git pull --ff-only`**. That is the routine case and the only one to put in a recipe. `git reset --hard origin/main` belongs *solely* to the documented divergence in `docs/agent-principles.md` — where commits were made on local `main`, re-signed onto a branch, and the same trees now exist at two SHAs so no fast-forward is possible. Do not reach for it merely because `--ff-only` might fail; find out why it failed first. It is in the org's own `permissions.deny`, which is the standing signal that it is never a routine step, and agent-principles gates it on `git status` clean plus `git log origin/main..main` showing only the superseded copies.
- Any expected-red CI, named as expected: a manifest or engine change re-stales the foundation guard pin, and that run prints the exact replacement `ref:`.
- **The next session's opening prompt, by path, with the model to run it under.** This is the step whose absence makes a session incomplete no matter how good the work was.

## Report shape

Lead with what landed and what is verified. Then the accounting for removed progress lines. Then the recipe. Do not bury an unverified claim or a blocked annotation inside a paragraph of accomplishments.
