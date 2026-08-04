---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

name: tb-review-triage
description: >-
  Work through code-review findings from review bots (CodeRabbit, Greptile, Qodo, Copilot) or
  human reviewers, treating each as INPUT to assess rather than a directive to apply. Use
  whenever the maintainer pastes review comments, says "treat as input, make your own
  assessment", asks to address a PR review, or asks whether a specific finding is valid. Also
  use when a bot's suggestion conflicts with a project convention. Produces a per-finding
  disposition (fixed / declined with reason), applies only the valid fixes, and records
  settled rulings so the same finding does not return on the next pull request. Also use when
  asked what the state of a pull request is, or whether the bots have finished — step 0 fetches
  the review state read-only.
---

# Review triage

Review-bot output is a set of claims to verify, not a task list to execute. Bots optimize for plausible-looking gating; they do not know this organization's policies, and they are frequently right about a symptom while wrong about its cause. Both failure directions are real, so neither blanket acceptance nor blanket dismissal is acceptable.

## Procedure

0. **Fetch the findings, if they were not handed to you.** Skip this when the maintainer pasted them. The trap here is worth knowing: `gh pr view --json reviews,comments` returns review summaries and issue-style comments but **not** the inline review-thread comments carrying `file:line` references, which come from a separate REST endpoint — so a picture built from `gh pr view` alone silently omits most of what a bot said.

   ```sh
   gh pr view <N> --json number,state,mergeable,reviews,comments,statusCheckRollup
   gh api "/repos/$(gh repo view --json nameWithOwner --jq .nameWithOwner)/pulls/<N>/comments" --paginate
   ```

   **Those two are commands the maintainer runs, not the agent.** Every org repository's settings put `~/.config/gh` in `sandbox.filesystem.denyRead`, so inside the agent sandbox `gh` dies at config load before it parses an argument — a sandbox denial, which no permission entry can grant. The agent's own read-only fallback for a PUBLIC repository is unauthenticated `curl` against `api.github.com`, which is on the network allowlist and needs no credentials; anything private or authenticated is a maintainer step.

   ```sh
   curl -sS -D - "https://api.github.com/repos/<owner>/<repo>/pulls/<N>/comments?per_page=100"
   ```

   Both flags are load-bearing. `per_page` because the API returns 30 by default and there is no `--paginate` here to hide it; `-D -` because the only way to know whether more remain is the `Link` header, which a bare body request never shows. Past 100, follow `rel="next"` until no next link remains — a silently truncated list is the failure this step exists to prevent.

   Where a check is failing, read the log rather than the check name (`gh run view <id> --log-failed`); a check name rarely says what broke. Treat a comment whose `in_reply_to_id` is set as possibly already answered, and report "the bots have not posted yet" rather than presenting an empty list as a clean review. Stopping after this step is a legitimate outcome when the maintainer only asked for the state.
1. **Enumerate** every finding with its source (which bot, or which reviewer) and the file and line it names. Include findings the maintainer forwarded without comment.
2. **Verify each against the current code.** Read the file at that line. Do not trust the quoted snippet: bots review a commit that may already have moved, and a finding can be stale rather than wrong. A claim about behavior gets tested, not reasoned about — if the finding says a guard fires, make it fire.
3. **Classify** each as valid, invalid, or valid-with-a-different-cause. That third category is the one worth slowing down for; see the traps below.
4. **Fix the valid ones minimally.** One concern per commit where they are unrelated. If a finding reveals a policy question rather than a defect, state the policy and confirm it before writing code — that is `docs/agent-principles.md` § Confirm policy intent before coding.
5. **Decline the rest in one sentence each**, naming the reason. "Declined: this is deliberate, see ADR N" is a disposition. Silence is not.
6. **Record anything settled** in `.coderabbit.yaml` `path_instructions`, with the *reason* written out rather than the ruling alone. A finding argued down in a pull-request thread and not recorded there returns on the next pull request. This is the step most often skipped.
7. **Validate, then report the dispositions** as a compact list. Run the repository's own gates — the "Build, test, and lint" block in `AGENTS.md` — and state the result.

## Traps that have actually bitten

- **A finding declined twice on "it works on this machine" grounds is a signal to re-read, not to decline again.** The stated claim can be false while the defect underneath is real.
- **A bot may not know a file is append-only or generated.** `.ai/memory.md` is append-only and hook-enforced; the correction to a stale entry is a new dated entry, never an edit. Check for a governing convention before editing what a bot points at.
- **Two bots agreeing raises the prior but proves nothing**, and two bots can both be wrong in the same direction. Verify anyway.
- **A suggestion that is right in general can be wrong here.** Cite the ADR or the measurement when declining, so the next reviewer inherits the reasoning.
- **Check whether a finding's premise is something this project asserted.** A wrong rationale in a comment or a config file will be quoted back as authority; verify a structural-sounding claim against sibling code before repeating it.

## Reporting

Lead with what changed and why, then the declines with their reasons. Where a finding was valid but for a different reason than the bot gave, say so — that difference is usually the most useful thing in the review.
