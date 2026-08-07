#!/bin/sh

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# hook-run.sh — run a scripts/ai/ hook script, but only if it is runnable.
#
# WHY THIS EXISTS, from the incident that produced it (2026-08-07): an editing
# session introduced a shell syntax error into ai-session.sh while that script
# was wired into the PreToolUse Edit, Write, MultiEdit, and Bash hooks and the
# Stop hook. A syntax error exits 2, and exit 2 from those events BLOCKS — so
# every writing tool and every turn end refused at once, including the edit
# that would have fixed the file. The session could not repair itself and had
# to be rescued from outside.
#
# The old shim tested `[ -x "$s" ]`, which asks whether the file is executable
# and not whether it is parseable. This adds the missing half: `sh -n` first,
# and on failure exit 0 (silently allow) rather than propagating the parse
# error. A guard whose own code is broken must fail OPEN — a broken guard
# stops being a guard either way, and the version that also stops the session
# from being repaired is strictly worse.
#
# This script is deliberately tiny and dependency-free, because it is the one
# link in the chain that nothing else validates. The inline shim in
# settings.json runs `sh -n` on THIS file before exec'ing it, which closes the
# chicken-and-egg: one inline check guards the validator, and the validator
# guards everything else.
#
# Usage (from a settings.json hook command):
#   hook-run.sh <script-name-under-scripts/ai> [args...]
#
# Hook JSON on stdin is passed through untouched.

set -eu

d="${CLAUDE_PROJECT_DIR:-$PWD}/scripts/ai"
s="$d/${1:-}"
[ -n "${1:-}" ] || exit 0
shift

[ -f "$s" ] && [ -x "$s" ] || exit 0

# Parse-check before running. Any diagnostic is swallowed: it would otherwise
# reach the agent as hook stderr on a path where this script has decided to
# stay out of the way entirely.
sh -n "$s" 2> /dev/null || exit 0

exec "$s" "$@"
