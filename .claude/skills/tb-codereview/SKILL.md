---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

name: tb-codereview
description: >-
  Work through code-review findings from review bots (CodeRabbit, Greptile, Qodo, Copilot) or
  human reviewers, treating each as INPUT to assess rather than a directive to apply. Use
  whenever the maintainer pastes review comments, says "treat as input, make your own
  assessment", asks to address a PR review, or asks whether a specific finding is valid. Also
  use when a bot's suggestion conflicts with a project convention. Produces a per-finding
  disposition (fixed / declined with reason), applies only the valid fixes, and records
  settled rulings so the same finding does not return on the next pull request.
---

# Code review as input

Review-bot output is a set of claims to verify, not a task list to execute. Bots optimize for plausible-looking gating; they do not know this organization's policies, and they are frequently right about a symptom while wrong about its cause. Both failure directions are real, so neither blanket acceptance nor blanket dismissal is acceptable.

## Procedure

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
