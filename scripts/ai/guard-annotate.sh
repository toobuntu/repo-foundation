#!/bin/sh

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# guard-annotate.sh — PreToolUse Bash guard on the sandbox-excluded
# annotation script.
#
# scripts/annotate.sh is in sandbox.excludedCommands: the bare invocation
# runs OUTSIDE the sandbox, which is what lets it annotate trees the
# sandboxed shell cannot write (.claude/skills/). An unguarded exclusion for
# a repo script would let a session modify that script and then execute its
# own code unsandboxed — so this refuses any Bash call naming the script
# while the working copy differs from origin/main, or when there is no
# origin/main to compare against.
#
# FAIL CLOSED, unlike the hygiene guards behind hook-run.sh. Those gate
# politeness, and a broken guard that blocks everything is worse than no
# guard; this gates a sandbox escape, where a guard that silently stops
# guarding is the worse failure. The closed failure is recoverable by
# construction: this guard sits only on the Bash matcher, so even when it
# refuses every shell call, the Edit tool still reaches the file that needs
# repairing — the 2026-08-07 lockout shape (a broken script wired into the
# Edit/Write matchers too) cannot recur through this one.
#
# Known, documented over-match: the PATH is matched anywhere in the command
# string, so `git diff -- scripts/annotate.sh` is refused too. The refusal
# text carries the workarounds; letting git through was considered and
# declined (2026-08-03) as complexity on a security gate.

set -eu

command -v jq > /dev/null 2>&1 || {
  echo 'jq is required to inspect the command this guard protects; refusing rather than leaving scripts/annotate.sh ungated.' >&2
  exit 2
}
cmd=$(jq -r '.tool_input.command // empty') || {
  echo 'could not parse the tool input; refusing rather than leaving scripts/annotate.sh ungated.' >&2
  exit 2
}

case "$cmd" in
*scripts/annotate.sh*) ;;
*) exit 0 ;;
esac

d="${CLAUDE_PROJECT_DIR:-$PWD}"
if ! git -C "$d" rev-parse --verify --quiet origin/main > /dev/null 2>&1; then
  echo 'scripts/annotate.sh runs OUTSIDE the sandbox. Refusing: there is no origin/main to verify it against. Run it yourself.' >&2
  exit 2
fi
if ! git -C "$d" diff --quiet origin/main -- scripts/annotate.sh; then
  {
    echo 'scripts/annotate.sh differs from origin/main and runs OUTSIDE the sandbox. Refusing.'
    echo 'This guard matches the PATH anywhere in a command string, so git diff/restore naming that file are refused too.'
    # The backtick spans below quote commands for the reader; nothing expands.
    # shellcheck disable=SC2016
    echo 'Diffstat below. Revert with the Edit tool, or with a pathspec that does not spell the path: git restore scripts/annot*.sh — `git restore scripts/` works too but discards every other change under scripts/. Or review this and run the script yourself.'
    git -C "$d" --no-pager diff --stat origin/main -- scripts/annotate.sh
  } >&2
  exit 2
fi
exit 0
