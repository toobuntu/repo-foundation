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
# SCOPE is the unit of policy here, not the entry point that happens to invoke
# it. Three scopes, all implemented here (ADR 0006, amended 2026-07-29):
#
#   staged   No staged change introduces a finding. Run by the
#            .githooks/pre-commit.d/80-unicode plugin. Scans the INDEX content
#            -- what will actually be committed -- not the possibly-dirty
#            working-tree copy at the same path: the staged blobs are
#            materialized with `git checkout-index` into a throwaway tree and
#            scanned there, so the bidi-allow annotation is read from the blob
#            and an annotation edited but not staged exempts nothing.
#   tracked  The tracked repository is clean. The default, and what CI runs.
#   tree     The whole working tree is clean, vendored and generated content
#            included. Trojan Source deceives the human reading a diff rather
#            than the compiler, so a dependency nothing here builds is still in
#            scope; the remediation for a finding under vendor/ is an upstream
#            report. See ADR 0006 for where this scope is exercised.
#
# Usage:
#   scripts/lint-unicode.sh                  # --scope=tracked (the default)
#   scripts/lint-unicode.sh --scope=tracked  # same, said out loud
#   scripts/lint-unicode.sh --scope=staged   # index content (the hook's form)
#   scripts/lint-unicode.sh --scope=tree     # whole working tree
#   scripts/lint-unicode.sh PATH...          # exactly these; directories walked
#
# A path list narrows the tracked and tree scopes (staged takes none). Without
# --scope the default is `tracked` when no path is given and `tree` when one
# is, which is what makes `lint-unicode.sh some/dir` scan that directory
# rather than intersecting it with the index.
#
# --classify-report=FILE additionally records, for EVERY candidate file, the
# file(1) MIME type(s) and the binary/text decision as TAB-separated rows --
# the diagnostic for comparing how a runner's file(1) classifies this tree
# against how the local one does. One batched file(1) pass. python3 path only.
#
# LINT_UNICODE_NO_PYTHON=1 forces the shell fallback (test seam).

set -eu

scope=""
classify_report=""

# Resolved before any chdir: $0 may be relative, and the staged scope moves
# the working directory into the materialized tree.
_script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

die() {
  printf '%s: %s\n' "${0##*/}" "$1" >&2
  exit 2
}

usage() {
  printf 'Usage: %s [--scope=staged|tracked|tree] [--classify-report=FILE] [PATH...]\n\n' "${0##*/}"
  printf '  --scope=staged    the index content (what the pre-commit hook runs)\n'
  printf '  --scope=tracked   files git tracks (the default, and what CI runs)\n'
  printf '  --scope=tree      the whole working tree, vendored content included\n'
  printf '  --classify-report=FILE  record MIME type and scan/skip per file\n'
  printf '  PATH...           exactly these paths; directories are walked\n'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --scope=*) scope="${1#--scope=}" ;;
  --scope)
    [ "$#" -ge 2 ] || die "--scope needs a value (staged, tracked, or tree)"
    scope=$2
    shift
    ;;
  --classify-report=*) classify_report="${1#--classify-report=}" ;;
  --help | -h)
    usage
    exit 0
    ;;
  --)
    shift
    break
    ;;
  -*) die "unknown option: $1" ;;
  *) break ;;
  esac
  shift
done

case "${scope:-}" in
staged)
  [ "$#" -eq 0 ] || die "scope 'staged' takes no paths; the index is the list"
  ;;
tracked | tree) ;;
"") if [ "$#" -eq 0 ]; then scope=tracked; else scope=tree; fi ;;
*) die "unknown scope: $scope (expected staged, tracked, or tree)" ;;
esac

# The report lands where the CALLER said, not relative to a directory this
# script may chdir into.
case "$classify_report" in
"" | /*) ;;
*) classify_report="$PWD/$classify_report" ;;
esac

_files_tmp=$(mktemp "${TMPDIR:-/tmp}/lint-unicode.XXXXXX")
_stage_dir=""
_paths_tmp=""
cleanup() {
  rm -f "$_files_tmp"
  [ -z "$_paths_tmp" ] || rm -f "$_paths_tmp"
  if [ -n "$_stage_dir" ]; then rm -rf "$_stage_dir"; fi
}
trap cleanup EXIT INT TERM

# The staged scope scans INDEX content. `git checkout-index` materializes the
# staged blobs into a throwaway tree preserving relative paths, so findings
# report the logical path and the bidi-allow annotation is read from the blob
# a commit would actually record. The runner's PRE_COMMIT_STAGED_LIST (a
# NUL-delimited file of ACMRT paths, computed once per commit) is honored when
# present; standalone runs derive the same list. Non-regular entries (a staged
# symlink) are recreated as symlinks and skipped by `find -type f` -- a link's
# target string is not scannable content. checkout-index applies checkout-time
# conversions; the only one configured in these repositories is line-ending
# normalization, and CR is on the detector's allowlist, so the scan outcome is
# unaffected. Every step fails CLOSED: this is a security gate, so a path list
# that cannot be built or materialized must refuse the commit, never scan an
# empty tree and report success.
#
# The path list is therefore written to a file and its status checked, NOT piped
# into checkout-index. A pipeline's status is its LAST command's, and an empty
# stdin is a perfectly successful checkout-index -- so `git diff | git
# checkout-index` reports success when the diff failed, materializes nothing,
# and the empty-list early exit below then returns 0. That is the whole gate
# silently passing.
if [ "$scope" = staged ]; then
  _stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/lint-unicode-staged.XXXXXX")
  # _paths_file is what we READ; _paths_tmp is only what we OWN and clean up.
  # The runner's list belongs to the runner -- every other plugin reads it too,
  # so removing it here would sabotage the rest of the commit.
  if [ -n "${PRE_COMMIT_STAGED_LIST:-}" ] && [ -r "${PRE_COMMIT_STAGED_LIST}" ]; then
    _paths_file="$PRE_COMMIT_STAGED_LIST"
  else
    _paths_tmp=$(mktemp "${TMPDIR:-/tmp}/lint-unicode-paths.XXXXXX")
    _paths_file="$_paths_tmp"
    git diff --cached --name-only --diff-filter=ACMRT -z > "$_paths_file" ||
      die "could not enumerate the staged paths"
  fi

  # The list is NUL-delimited, so a newline inside it means a path contains
  # one. Everything downstream is newline-delimited (the detector reads the
  # file list a line at a time, and the POSIX fallback cannot use `read -d ''`),
  # so such a path would be split into two entries that do not exist and
  # silently go unscanned. Refuse instead: loud beats bypassed.
  # Count the newlines rather than grepping for one: the extracted text is
  # newlines only, so every "line" in it is empty and `grep '.'` matches
  # nothing -- a guard that silently never fires, which is how this was first
  # written and how the test caught it.
  if [ "$(LC_ALL=C tr -dc '\n' < "$_paths_file" | wc -c | tr -d ' ')" -ne 0 ]; then
    die "a staged path contains a newline; refusing to scan it unsafely"
  fi

  git checkout-index --prefix="$_stage_dir/" --stdin -z < "$_paths_file" ||
    die "could not materialize the staged blobs"
  cd "$_stage_dir" || die "cannot enter the staged materialization"
fi

# Collect files to scan into a newline-delimited list.
collect_files() {
  case "$scope" in
  staged)
    find . -type f -print | sed 's|^\./||'
    ;;
  tracked)
    if [ "$#" -eq 0 ]; then git ls-files; else git ls-files -- "$@"; fi
    ;;
  tree)
    [ "$#" -gt 0 ] || set -- .
    for _p in "$@"; do
      if [ -d "$_p" ]; then
        find "$_p" -name .git -prune -o -type f -print
      elif [ -f "$_p" ]; then
        printf '%s\n' "$_p"
      fi
    done
    ;;
  *) die "unreachable scope: $scope" ;;
  esac
}

collect_files "$@" > "$_files_tmp"
[ -s "$_files_tmp" ] || exit 0

if [ -z "${LINT_UNICODE_NO_PYTHON:-}" ] && command -v python3 > /dev/null 2>&1; then
  if [ -n "$classify_report" ]; then
    python3 "$_script_dir/lint-unicode.py" "$_files_tmp" "$classify_report"
  else
    python3 "$_script_dir/lint-unicode.py" "$_files_tmp"
  fi
  exit 0
fi

[ -z "$classify_report" ] || die "--classify-report needs the python3 detector"

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

# Build the fixed-string pattern list from the table, one UTF-8 byte sequence
# per line, excluding codepoints in the comma-separated U+XXXX list passed as
# $1. Returns 1 if all are excluded. Kept identical to the 80-unicode plugin's
# copy, which carries the full rationale: fixed strings under LC_ALL=C compare
# exact bytes and need no locale, where a bracket expression needs a UTF-8
# locale and silently degrades to a BYTE set without one -- matching the E2
# lead byte of every U+2xxx character, so an em dash trips the gate.
build_patterns() {
  _exclude_csv="${1:-}"
  _out=""
  _saved_ifs=$IFS
  IFS='
'
  for _row in $_bidi_table; do
    _cp="${_row%%:*}"
    _esc="${_row#*:}"
    case ",$_exclude_csv," in
    *",$_cp,"*) continue ;;
    *) ;;
    esac
    # shellcheck disable=SC2059  # intentional dynamic format string
    _seq=$(printf "$_esc")
    _out="${_out:+$_out
}$_seq"
  done
  IFS=$_saved_ifs
  [ -n "$_out" ] || return 1
  printf '%s' "$_out"
}

# First bidi-allow annotation in the working-tree file, or empty.
read_bidi_allow() {
  LC_ALL=C sed -n 's/.*bidi-allow:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$1" | head -n 1
}

_default_patterns=$(build_patterns "")
_found=""
while IFS= read -r _f; do
  [ -z "$_f" ] && continue
  [ -f "$_f" ] || continue
  _allow=$(read_bidi_allow "$_f")
  if [ -n "$_allow" ]; then
    _patterns=$(build_patterns "$_allow") || continue
  else
    _patterns="$_default_patterns"
  fi
  # Three-valued status: 0 match, 1 no match, 2 error. Treating 2 as "no
  # match" would fail open -- see the same guard in the 80-unicode plugin.
  _status=0
  printf '%s\n' "$_patterns" |
    LC_ALL=C /usr/bin/grep --fixed-strings --file=- \
      --binary-files=without-match --quiet "$_f" || _status=$?
  case "$_status" in
  0)
    _found="${_found:+$_found
}$_f"
    ;;
  1) ;;
  *)
    printf 'error: grep exited %s scanning %s\n' "$_status" "$_f" >&2
    exit 1
    ;;
  esac
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
