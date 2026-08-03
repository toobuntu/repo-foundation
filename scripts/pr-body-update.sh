#!/bin/sh

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# pr-body-update.sh — rewrite only the maintained region of a pull-request body.
#
# `gh pr edit --body-file` replaces the WHOLE description, and the GitHub API
# offers nothing narrower, so a routine "refresh the PR body" wipes whatever a
# review bot appended to it -- the summary CodeRabbit writes into the
# description, not into a comment. Recovering that by hand, every time, is the
# problem this script exists to remove.
#
# The mechanism is read-modify-write around two HTML-comment markers. Text
# before the begin marker and after the end marker is carried through
# untouched; only what sits between them is replaced.
#
#   pr-body-update.sh <pr-number> <replacement-file>
#   pr-body-update.sh --dry-run <pr-number> <replacement-file>   # print, do not write
#
# The markers to put in the body (gh pr create writes them; see
# docs/agent-principles.md):
#
#   <!-- pr-body:begin - managed by pr-body-update.sh; text outside is preserved -->
#   <!-- pr-body:end -->
#
# A body with no markers is REFUSED rather than wrapped. Only the author knows
# where their own text ends and a bot's begins; guessing would pull the bot's
# section inside the managed region, and the next run would delete it -- the
# exact failure this script prevents.

set -eu

BEGIN_MARK='<!-- pr-body:begin'
END_MARK='<!-- pr-body:end'

usage() {
  printf 'Usage: %s [--dry-run] <pr-number> <replacement-file>\n' "${0##*/}" >&2
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}

# Absent tooling is a hard abort, not a skip: this script's whole purpose is
# the gh round trip (ADR 0017 records the two tool-check patterns). 127 is the
# shell's own "command not found", so a caller can tell a missing dependency
# from a refused edit.
command -v gh > /dev/null 2>&1 ||
  die 'gh not found; required by pr-body-update.sh (brew install gh)' 127

dry_run=""
case "${1:-}" in
--dry-run)
  dry_run=1
  shift
  ;;
-h | --help)
  usage
  exit 0
  ;;
-*)
  usage
  die "unknown option: $1" 2
  ;;
*) ;;
esac

[ "$#" -eq 2 ] || {
  usage
  exit 2
}

pr=$1
replacement=$2

case "$pr" in
'' | *[!0-9]*) die "pull-request number must be digits, got: $pr" 2 ;;
*) ;;
esac
[ -r "$replacement" ] || die "cannot read replacement file: $replacement" 2

current=$(mktemp "${TMPDIR:-/tmp}/pr-body-cur.XXXXXX")
merged=$(mktemp "${TMPDIR:-/tmp}/pr-body-new.XXXXXX")
trap 'rm -f "$current" "$merged"' EXIT INT TERM

# Its own command, so a failed fetch is not mistaken for an empty body.
gh pr view "$pr" --json body --jq .body > "$current" ||
  die "could not read the body of pull request #$pr"

# ONE definition of "this line IS a marker", shared by the validation below and
# the splice further down. A marker must STAND ALONE on its line: a body that
# merely mentions the token in prose or inside a fenced example is not carrying
# a second marker pair, and counting substring hits would refuse it. That case
# is not hypothetical here -- this repository documents these markers, so a
# pull request describing them would break its own tool. Leading whitespace is
# tolerated and a trailing CR is stripped, because GitHub returns CRLF for a
# description edited in the web UI.
IS_MARK='function ismark(s, m,  t) { t = s; sub(/\r$/, "", t); sub(/^[ \t]+/, "", t); return index(t, m) == 1 }'

# One pass reports both counts and both line numbers, so the file is read once
# and the two answers cannot disagree.
marks=$(PB_BEGIN="$BEGIN_MARK" PB_END="$END_MARK" awk "$IS_MARK"' BEGIN{b=ENVIRON["PB_BEGIN"];e=ENVIRON["PB_END"]} ismark($0,b){nb++; if(!lb)lb=NR} ismark($0,e){ne++; if(!le)le=NR} END{printf "%d %d %d %d\n", nb, ne, lb, le}' "$current")

# Word splitting is the point: four integers, no whitespace inside any of them.
# shellcheck disable=SC2086  # deliberate word splitting of a known 4-field line
set -- $marks
n_begin=$1
n_end=$2
line_begin=$3
line_end=$4

if [ "$n_begin" -ne 1 ] || [ "$n_end" -ne 1 ]; then
  printf 'error: pull request #%s needs exactly one marker pair (found %s begin, %s end).\n' \
    "$pr" "$n_begin" "$n_end" >&2
  printf 'Edit the description once, putting these two lines around YOUR text and\n' >&2
  printf 'leaving anything a bot added outside them:\n\n' >&2
  printf '  %s - managed by pr-body-update.sh; text outside is preserved -->\n' \
    "$BEGIN_MARK" >&2
  printf '  %s -->\n' "$END_MARK" >&2
  exit 3
fi

[ "$line_begin" -lt "$line_end" ] ||
  die "the end marker precedes the begin marker in pull request #$pr" 3

# Splice, using the same standalone-marker predicate. The markers themselves
# are reprinted verbatim, so the maintainer's exact wording survives. The
# replacement is READ AS DATA (getline from a file), never interpolated into
# the program, so no quoting or backslash in it can change what awk executes.
#
# A standalone marker line inside the replacement is dropped rather than copied
# through. That is what lets ONE draft file serve both `gh pr create` (which
# needs the markers in the body it uploads) and this script; copying them
# through would nest a second pair and break the next run. A marker mentioned
# mid-sentence in the replacement is content, and survives.
PB_BEGIN="$BEGIN_MARK" PB_END="$END_MARK" PB_FILE="$replacement" awk "$IS_MARK"' BEGIN{b=ENVIRON["PB_BEGIN"];e=ENVIRON["PB_END"];f=ENVIRON["PB_FILE"]} ismark($0,b){print;while((getline l<f)>0){if(ismark(l,b)||ismark(l,e))continue;print l}s=1;next} ismark($0,e){s=0} !s{print}' "$current" > "$merged"

if [ -n "$dry_run" ]; then
  cat "$merged"
  exit 0
fi

gh pr edit "$pr" --body-file "$merged"
printf 'pr-body-update: #%s body region replaced (%s lines outside it preserved)\n' \
  "$pr" "$(($(wc -l < "$current") - (line_end - line_begin + 1)))"
