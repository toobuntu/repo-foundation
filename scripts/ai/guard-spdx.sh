#!/bin/sh

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# guard-spdx.sh — PreToolUse Write guard: refuse creating a NEW file whose
# head carries a hand-written SPDX header.
#
# Org rule (docs/agent-principles.md, SPDX / REUSE headers): headers are
# written by scripts/annotate.sh, never by hand — a hand-placed header
# drifts from reuse's output (position, spacing, prefix) and passes
# `reuse lint` anyway, which is satisfied by the strings appearing
# ANYWHERE. Three hand-written headers landed in one 2026-08-04 session
# against a rule stated in three places; this is the executable form.
#
# The sharp edge that keeps it from false-positives: it fires only when the
# target does NOT yet exist (a creation) AND an SPDX tag sits in the first
# ten lines of the content. Editing an existing annotated file never
# matches (the file exists); a prose MENTION of a tag never matches (it is
# mid-file, and the Edit tool is not on this matcher at all). It matches
# the tag names, never a comment syntax, so every --style/--single-line/
# --copyright-prefix variant is caught without enumerating any. `.license`
# sidecars are refused too: annotate.sh writes those (--force-dot-license),
# and the sandbox exclusion for the bare `scripts/annotate.sh` reaches
# every tree, .claude/skills/ included.
#
# jq missing fails OPEN: this gates a policy, not a sandbox escape, and a
# guard that refuses every Write on a missing tool would be the defect.

set -eu

command -v jq > /dev/null 2>&1 || exit 0
in=$(cat)
[ -n "$in" ] || exit 0

fp=$(printf '%s' "$in" | jq -r '.tool_input.file_path // empty')
[ -n "$fp" ] || exit 0
case "$fp" in
/*) ;;
*) fp="${CLAUDE_PROJECT_DIR:-$PWD}/$fp" ;;
esac
# Overwrite of an existing file: not a creation, not this guard's business.
[ -e "$fp" ] && exit 0

printf '%s' "$in" | jq -r '.tool_input.content // empty' | head -n 10 |
  grep -q -E 'SPDX-(File|Snippet)CopyrightText|SPDX-License-Identifier' || exit 0

{
  printf 'Hand-written SPDX header refused (new file: %s).\n' "$fp"
  printf 'Headers are written by the annotation script, never by hand — a\n'
  printf 'hand-placed header drifts from its output and still passes reuse lint.\n'
  printf 'Create the file with NO header, then run the bare command\n'
  # The backticks are markdown quoting for the reader, not expansion.
  # shellcheck disable=SC2016
  printf '`scripts/annotate.sh` (the bare form is the sandbox-excluded one, so\n'
  printf 'it runs unsandboxed and reaches every tree, .claude/skills/ included).\n'
} >&2
exit 2
