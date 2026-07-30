---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

name: tb-review-status
description: >-
  Fetch a pull request's current review state from GitHub and summarize the action items —
  mergeability, reviewer decisions, inline review comments grouped by file and line, general
  comments, and failing CI checks. Pure read, changes nothing. Use when the maintainer asks
  what the state of a PR is, wants a triage snapshot before addressing reviews, or asks
  whether the bots have finished. Acting on the findings is tb-review-triage; this skill only
  reports.
---

# Pull request review status

A status snapshot the maintainer uses to decide what to address. Read-only: propose no code changes, modify no files, push nothing. Adapted from `toobuntu/blackoutd`'s `review-pr` skill.

**The trap this skill exists to avoid:** `gh pr view --json reviews,comments` returns review-summary objects and issue-style PR comments, but **not** the inline review-thread comments that carry `file:line` references. Those come from a separate REST endpoint. A summary built from `gh pr view` alone silently omits most of what a bot actually said.

## Steps

1. Determine the PR number. With no argument, `gh pr view --json number --jq .number`; with an argument, use it directly. A bare number in the request is the PR number.
2. High-level state and reviewer decisions:

   ```sh
   gh pr view <N> --json number,state,mergeable,reviews,comments,statusCheckRollup
   ```

3. Inline review comments, with their file and line references:

   ```sh
   gh api "/repos/$(gh repo view --json nameWithOwner --jq .nameWithOwner)/pulls/<N>/comments" --paginate
   ```

4. Where CI is failing, read the actual log rather than the check name — `gh run view <id> --log-failed` — because a check name rarely says what broke.

## Report

- One line of PR state: open/merged/closed, mergeable, CI rollup.
- Reviewers and their overall decisions (`APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`) from step 2's `reviews`.
- Inline comments from step 3, grouped by reviewer (`user.login`), each with `path`, `line` (or `original_line`), and enough of `body` to be actionable. Mark a comment whose `in_reply_to_id` is null as top-of-thread, since replies are usually the bot conceding.
- Issue-style comments from step 2's `comments`, listed separately as general comments — these have no file or line.
- Failing checks from `statusCheckRollup`, each with what actually failed.

Distinguish a finding that is still open from one already answered in a reply. Note when a bot has posted nothing yet, rather than reporting an empty list as a clean review.
