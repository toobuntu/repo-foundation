#!/bin/sh

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# scripts/main-guard.sh — report a working tree dirtied on the main branch.
#
# The PreToolUse guard in .claude/settings.json refuses Edit/Write/MultiEdit on
# `main`, but it matches TOOL NAMES, so anything that writes through a shell
# bypasses it: `sed -i`, `tee`, `>` redirection, a python or ruby heredoc. That
# happened on 2026-07-31 — edits landed on `main` through Bash and only a later
# Write was refused. The pre-commit hook still blocks the COMMIT, so nothing
# reaches history; what gets dirtied is the working tree, on the wrong branch,
# and the recovery is `git switch -c` after the fact instead of before.
#
# So this checks the EFFECT rather than the tool: one `git status --porcelain`
# after each Bash call, against a record seeded at session start so a tree that
# was already dirty does not trip it. Wired in .claude/settings.json as:
#
#   SessionStart                 main-guard.sh seed
#   PostToolUse (matcher: Bash)  main-guard.sh check
#
# `check` exits 2 on a finding, which is how a PostToolUse hook feeds its
# stderr back to the agent. The tool has already run, so this reports and asks
# for recovery rather than preventing.
#
# A PreToolUse pattern check on the command string was evaluated and NOT added.
# The forms with no read-only use (`sed -i`) are not the forms that caused the
# incident (a `python3 - <<'PY'` heredoc), and the forms that would have caught
# it (`>`, a heredoc, an interpreter reading stdin) are used constantly for
# read-only work — so the version that prevents anything real also refuses
# legitimate commands. Detection is complete; prevention would be partial and
# noisy, which is the trade a guard should not make.
#
# The record lives in .git/: per-clone by construction, never reported by
# `git status`, and needing no .gitignore entry. A plain file there is writable
# under the agent sandbox — unlike .git/config or .git/hooks/, which are not.
#
# Usage:
#   scripts/ai/guard-main.sh seed    # record the current dirty set
#   scripts/ai/guard-main.sh check   # report paths dirtied since; exit 2 if any
#   scripts/ai/guard-main.sh pre     # PreToolUse half: refuse Edit/Write on
#                                    # main — EXCEPT the volatile continuity
#                                    # files, which are exempt, logged, and
#                                    # reported at the close (hook JSON stdin)
#
# The exemption is a category fix, not a loosening: branches do not version
# untracked files, so requiring a branch to edit .ai/progress.md protected
# zero bytes of it while forcing a ceremonial branch at every close-on-main.
# Tracked work stays refused. Each exempted write is appended to
# .git/claude-exempt-writes; ai-session.sh close-check reports the list, so
# the visibility the ceremony appeared to give becomes an explicit report.
#
# A no-op outside a git repository, so it is safe to wire into hooks that fire
# everywhere.

set -eu

BRANCH=main

usage() {
  printf 'Usage: %s seed|check|pre\n' "${0##*/}" >&2
}

# Resolve against the PROJECT directory, not the hook process's working
# directory: a hook that fires from elsewhere would otherwise read one
# repository's branch and write another's exempt-writes log.
proj="${CLAUDE_PROJECT_DIR:-$PWD}"

git_dir=$(git -C "$proj" rev-parse --git-dir 2> /dev/null) || {
  # Not a git repository: nothing to guard. Silent, so a SessionStart hook
  # firing in an arbitrary directory stays quiet.
  exit 0
}
# `--git-dir` answers relative to the queried directory; the record path has
# to work regardless of where this process is standing.
case "$git_dir" in
/*) ;;
*) git_dir="$proj/$git_dir" ;;
esac

# Physical path of a directory, for prefix comparison. macOS reaches one tree
# as both /var/... and /private/var/..., and a hook may supply either form,
# so an uncanonicalized prefix test lets a project file read as "outside the
# project tree" — the guard would then fail OPEN. Falls back to the input
# when the directory does not exist.
canon_dir() {
  (cd "$1" 2> /dev/null && pwd -P) || printf '%s\n' "$1"
}
record="$git_dir/claude-main-guard"

# The dirty set as one stable key per path. `git status --porcelain` quotes any
# path holding a special character (only `-z` turns quoting off), so one line
# is one path and `cut` cannot be fooled by an embedded newline. Dropping the
# two status columns is deliberate: a path that merely moves from unstaged to
# staged is the same finding, not a new one.
# `--untracked-files=normal` is passed explicitly rather than relied on as the
# default: `status.showUntrackedFiles=no` in any config would hide new files,
# and a new file written through a shell is the exact bypass this guard exists
# to catch. `normal` rather than `all` because a directory's first new file
# already fires the report, and `all` walks every untracked tree.
dirty_paths() {
  git -C "$proj" status --porcelain --untracked-files=normal | cut -c4-
}

case "${1:-}" in
seed)
  dirty_paths | LC_ALL=C sort > "$record"
  ;;

pre)
  fp=""
  if command -v jq > /dev/null 2>&1; then
    fp=$(jq -r '.tool_input.file_path // empty' 2> /dev/null || true)
  fi
  proj=$(canon_dir "$proj")
  on_main=0
  [ "$(git -C "$proj" branch --show-current 2> /dev/null)" = "$BRANCH" ] && on_main=1

  # An unparseable target fails CLOSED on main: with no file_path (no jq, or
  # malformed input) the guard cannot tell what is being written, and
  # refusing is what the pre-existing inline guard did. Handled before any
  # path arithmetic — routing it through a sentinel path is how a
  # canonicalization step silently turned the refusal into an allow.
  if [ -z "$fp" ]; then
    [ "$on_main" -eq 0 ] && exit 0
    printf 'Direct edits to main are not allowed. Create a feature branch (git switch -c feature/<topic>) before editing.\n' >&2
    exit 2
  fi

  case "$fp" in
  /*) ;;
  *) fp="$proj/$fp" ;;
  esac
  # Canonicalize the target too. The file may not exist yet (a Write creating
  # it), so its DIRECTORY is what gets resolved.
  fp="$(canon_dir "$(dirname -- "$fp")")/$(basename -- "$fp")"
  case "$fp" in
  "$proj/.ai/progress.md" | "$proj/.ai/scratchpad/"*)
    # Volatile continuity files: exempt on every branch. On main the write
    # is logged so close-check can report it — visibility by report, not by
    # ceremony. The vault shim (a sibling hook on the same matcher) has
    # already copied the pre-state.
    if [ "$on_main" -eq 1 ]; then
      printf '%s\n' "${fp#"$proj"/}" >> "$git_dir/claude-exempt-writes"
    fi
    exit 0
    ;;
  "$proj"/*)
    if [ "$on_main" -eq 1 ]; then
      printf 'Direct edits to main are not allowed. Create a feature branch (git switch -c feature/<topic>) before editing.\n' >&2
      exit 2
    fi
    ;;
  *) ;; # outside the project tree: not this guard's business
  esac
  exit 0
  ;;

check)
  [ "$(git -C "$proj" branch --show-current 2> /dev/null)" = "$BRANCH" ] || exit 0

  now=$(mktemp "${TMPDIR:-/tmp}/main-guard.XXXXXX")
  trap 'rm -f "$now"' EXIT INT TERM
  dirty_paths | LC_ALL=C sort > "$now"

  if [ ! -f "$record" ]; then
    # No seed: SessionStart never fired, or the repository appeared mid-session.
    # Adopt the current state and stay silent — reporting a tree never seen
    # clean would blame this call for whatever was already there.
    cp "$now" "$record"
    exit 0
  fi

  new=$(LC_ALL=C comm -13 "$record" "$now")
  [ -n "$new" ] || exit 0

  # Fold the finding into the record so the next Bash call does not repeat a
  # report the agent already has. This is a notification, not a gate — the
  # write has happened — and repeating it after every later call would drown
  # the recovery it is asking for.
  cp "$now" "$record"

  {
    printf 'The working tree on %s has changes that were not there at session start:\n\n' \
      "$BRANCH"
    printf '%s\n' "$new" | sed 's/^/  /'
    printf '\nDirect work on %s is not allowed; the pre-commit hook refuses the commit.\n' \
      "$BRANCH"
    # The backticks quote the recovery command for the reader; nothing here is
    # a substitution. Keep the literal hint rather than rewording it away.
    # shellcheck disable=SC2016
    printf 'Carry these onto a branch now — `git switch -c feature/<topic>` keeps the\n'
    printf 'changes and leaves %s clean. Reported once per path.\n' "$BRANCH"
  } >&2
  exit 2
  ;;

-h | --help)
  usage
  exit 0
  ;;
*)
  usage
  exit 2
  ;;
esac
