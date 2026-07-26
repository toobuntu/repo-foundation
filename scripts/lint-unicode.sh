#!/bin/sh
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Invisible-Unicode / Trojan Source (CVE-2021-42574) scanner and
# UTF-8-without-BOM enforcement, run repo-wide. Single source of truth for
# the CI lint-unicode job and `make lint`; .githooks/pre-commit applies the
# same policy to staged blobs (its own copy, scoped to a commit).
#
# Prefers python3 (scripts/lint-unicode.py): Unicode category Cf+Cc detection
# plus UTF-8/UTF-16/UTF-32 validation. Falls back to a POSIX-sh detector (the
# RHSB-2021-007 grep approach over a fixed bidi/zero-width/BOM codepoint set)
# when python3 is unavailable — less capable (no Cc sweep, no encoding
# validation beyond the BOM byte sequence), but the accepted floor. Rationale
# and codepoint coverage: https://github.com/toobuntu/repo-foundation/blob/main/docs/decisions/0006-trojan-source-detection-strategy.md.
#
# The detector is a separate file, not a heredoc in this one: Homebrew's shfmt
# wrapper (`brew style --fix`, which runs over these canonicals in the
# Homebrew-aligned consumers) applies line-based transforms that track no
# heredoc state and rewrite an embedded Python body as if it were shell. That
# is how this file was corrupted once already.
#
# Usage:
#   scripts/lint-unicode.sh           # scan all tracked files (git ls-files)
#   scripts/lint-unicode.sh PATH...   # scan given files; directories walked
#
# LINT_UNICODE_NO_PYTHON=1 forces the shell fallback (test seam).

set -eu

# Collect files to scan into a newline-delimited list. No args: tracked files.
# Args: the given files; a directory argument is walked, pruning .git.
collect_files() {
  if [ "$#" -eq 0 ]; then
    git ls-files
  else
    for _p in "$@"; do
      if [ -d "$_p" ]; then
        find "$_p" -name .git -prune -o -type f -print
      elif [ -f "$_p" ]; then
        printf '%s\n' "$_p"
      fi
    done
  fi
}

_files_tmp=$(mktemp "${TMPDIR:-/tmp}/lint-unicode.XXXXXX")
trap 'rm -f "$_files_tmp"' EXIT INT TERM
collect_files "$@" > "$_files_tmp"
[ -s "$_files_tmp" ] || exit 0

if [ -z "${LINT_UNICODE_NO_PYTHON:-}" ] && command -v python3 > /dev/null 2>&1; then
  python3 "$(dirname "$0")/lint-unicode.py" "$_files_tmp"
  exit 0
fi

# --- POSIX-sh fallback (no python3) -------------------------------------
# Fixed codepoint table "U+XXXX:\OOO\OOO\OOO" (UTF-8 octal bytes), kept in
# sync with .githooks/pre-commit. Only bidi/zero-width/BOM are covered.
_bidi_table='U+061C:\330\234
U+200B:\342\200\213
U+200C:\342\200\214
U+200D:\342\200\215
U+200E:\342\200\216
U+200F:\342\200\217
U+202A:\342\200\252
U+202B:\342\200\253
U+202C:\342\200\254
U+202D:\342\200\255
U+202E:\342\200\256
U+2066:\342\201\246
U+2067:\342\201\247
U+2068:\342\201\250
U+2069:\342\201\251
U+FEFF:\357\273\277'

# Build a UTF-8 bracket pattern from the table, excluding codepoints in the
# comma-separated U+XXXX list passed as $1. Returns 1 if all are excluded.
build_pattern() {
  _exclude_csv="${1:-}"
  _fmt=""
  _saved_ifs=$IFS
  IFS='
'
  for _row in $_bidi_table; do
    _cp="${_row%%:*}"
    _esc="${_row#*:}"
    case ",$_exclude_csv," in
    *",$_cp,"*) continue ;;
    esac
    _fmt="$_fmt$_esc"
  done
  IFS=$_saved_ifs
  [ -z "$_fmt" ] && return 1
  # shellcheck disable=SC2059  # intentional dynamic format string
  printf "[$_fmt]"
}

# First bidi-allow annotation in the working-tree file, or empty.
read_bidi_allow() {
  LC_ALL=C sed -n 's/.*bidi-allow:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$1" | head -n 1
}

_default_pattern=$(build_pattern "")
_found=""
while IFS= read -r _f; do
  [ -z "$_f" ] && continue
  [ -f "$_f" ] || continue
  _allow=$(read_bidi_allow "$_f")
  if [ -n "$_allow" ]; then
    _pattern=$(build_pattern "$_allow") || continue
  else
    _pattern="$_default_pattern"
  fi
  if LC_ALL=C.UTF-8 /usr/bin/grep --binary-files=without-match \
    --extended-regexp --quiet "$_pattern" "$_f"; then
    _found="${_found:+$_found
}$_f"
  fi
done < "$_files_tmp"

if [ -n "$_found" ]; then
  printf 'Invisible Unicode characters found (CVE-2021-42574):\n' >&2
  printf '%s\n' "$_found" | while IFS= read -r _bf; do
    printf '  %s\n' "$_bf" >&2
  done
  printf '\nA file may opt out of specific codepoints with an in-file\n' >&2
  printf 'annotation, e.g.:  // bidi-allow: U+200E,U+200F\n' >&2
  exit 1
fi
