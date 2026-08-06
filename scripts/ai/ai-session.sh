#!/bin/sh

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# ai-session.sh — bookend the volatile .ai/ files so a session cannot drop
# work silently.
#
# `.ai/progress.md` and `.ai/org/relay.md` are gitignored by design (ADR 0022):
# per-developer, rewritten freely, no history. That is right for status and
# wrong for anything that turns out to be a commitment — and a rewrite has no
# diff, so a dropped line leaves no trace anywhere. This happened: a queued
# cleanup item vanished in a wholesale rewrite on 2026-07-25 and surfaced a
# day later only by accident (incident record: repo-foundation ADR 0022).
#
# `start` snapshots progress.md; `end` reports what the session removed from
# it. The point of `end` is NOT to forbid removals — most are correct, since
# finished status should go away — but to make each one STATED in the handoff,
# where a commitment that should have graduated is obvious. Backups alone do
# not do this: nobody diffs a backup they have no reason to suspect.
#
# Usage:
#   scripts/ai-session.sh start   # snapshot; safe to run repeatedly
#   scripts/ai-session.sh end     # report removed lines (always exits 0)
#   scripts/ai-session.sh relay-consume  # retire a promoted relay safely
#
# Every subcommand is a no-op in a repository with no .ai/ layer, so it is safe
# to wire into a SessionStart hook that fires everywhere.

set -eu

usage() {
  printf 'Usage: %s start|end|relay-consume\n' "${0##*/}" >&2
}

repo_root() {
  git rev-parse --show-toplevel 2> /dev/null || return 1
}

root=$(repo_root) || {
  # Not a git repository: nothing to bookend. Silent, so a SessionStart hook
  # firing in an arbitrary directory stays quiet.
  exit 0
}

progress="$root/.ai/progress.md"
snapshot="$root/.ai/.progress.session-start"
relay="$root/.ai/org/relay.md"

case "${1:-}" in
start)
  # Surface any relay retired but never dispositioned. This is a CUE, never a
  # cleanup: a consumed relay is not deleted on a timer, because the content
  # that justifies deleting it is the promotion, not the passage of time. A
  # maintainer away for a month must come back to the same prompt, not to a
  # tidied-away file.
  for _c in "$root"/.ai/org/relay.consumed-*.md; do
    [ -e "$_c" ] || continue
    printf 'ai-session: %s is still here — confirm every entry landed somewhere\n' \
      "${_c#"$root"/}"
    printf '  tracked (.ai/org/memory.md, an ADR, a dispatch row) or was declined\n'
    printf '  in writing, then delete it by hand.\n'
  done

  [ -f "$progress" ] || exit 0
  cp "$progress" "$snapshot"
  printf 'ai-session: snapshotted .ai/progress.md for end-of-session comparison\n'
  ;;

end)
  [ -f "$progress" ] || exit 0
  if [ ! -f "$snapshot" ]; then
    printf 'ai-session: no session-start snapshot; run "%s start" at session start\n' \
      "${0##*/}" >&2
    exit 0
  fi

  # The snapshot's mtime is the session start (cp sets it; reading the
  # original does not touch the original's). Progress not newer than that
  # means the end ritual's rewrite never happened.
  if [ ! "$progress" -nt "$snapshot" ]; then
    printf 'ai-session: .ai/progress.md was NOT updated this session.\n'
    printf 'Rewrite it to the current state and next action before closing,\n'
    printf 'or state in the handoff why it stands unchanged.\n'
  fi
  # Lines present at session start and absent now. `comm` needs sorted input,
  # and sorting is right here: this reports WHAT was removed, not where.
  # Blank lines are dropped — their coming and going is formatting, not
  # content.
  _a=$(mktemp "${TMPDIR:-/tmp}/ai-session.XXXXXX")
  _b=$(mktemp "${TMPDIR:-/tmp}/ai-session.XXXXXX")
  trap 'rm -f "$_a" "$_b"' EXIT INT TERM
  grep -v '^[[:space:]]*$' "$snapshot" | sort > "$_a"
  grep -v '^[[:space:]]*$' "$progress" | sort > "$_b"
  removed=$(comm -23 "$_a" "$_b")

  if [ -z "$removed" ]; then
    printf 'ai-session: nothing removed from .ai/progress.md this session\n'
    exit 0
  fi

  printf 'ai-session: %s line(s) removed from .ai/progress.md this session.\n' \
    "$(printf '%s\n' "$removed" | wc -l | tr -d ' ')"
  printf 'Account for each in the handoff report. A line that recorded a\n'
  printf 'COMMITMENT rather than status should have graduated (dispatch row,\n'
  printf 'issue, ADR, or .ai/memory.md) before it left this file:\n\n'
  printf '%s\n' "$removed" | sed -e 's/\(.\{110\}\).*/\1…/' -e 's/^/  - /'
  ;;

relay-consume)
  [ -f "$relay" ] || {
    printf 'ai-session: no .ai/org/relay.md to consume\n'
    exit 0
  }
  # A holding copy must never clobber an earlier holding copy, and a
  # one-second timestamp alone cannot guarantee that (a relay recreated and
  # consumed twice quickly, or two concurrent invocations). Counter-suffix
  # until the name is free; the bound only guards against a pathological
  # filesystem loop.
  _base="$root/.ai/org/relay.consumed-$(date +%Y-%m-%d-%H%M%S)"
  consumed="$_base.md"
  _n=1
  while [ -e "$consumed" ]; do
    _n=$((_n + 1))
    if [ "$_n" -gt 100 ]; then
      printf 'ai-session: could not reserve a free consumed-relay name near %s\n' \
        "$_base.md" >&2
      exit 1
    fi
    consumed="$_base.$_n.md"
  done
  mv "$relay" "$consumed"
  printf 'ai-session: relay retired to %s\n' "${consumed#"$root"/}"
  printf 'The relay is tracked: commit its deletion together with the promotion,\n'
  printf 'so the consumption is reviewable.\n'
  printf 'This is a holding copy, not the record. Delete it by hand once every\n'
  printf 'entry has landed somewhere TRACKED (.ai/org/memory.md, an ADR, a\n'
  printf 'dispatch row) or been declined in writing — that condition, never an\n'
  printf 'age. Nothing deletes it on a timer: "ai-session.sh start" will keep\n'
  printf 'reminding you it is here, which is the intended nag.\n'
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
