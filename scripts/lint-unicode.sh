#!/bin/sh
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Invisible-Unicode / Trojan Source (CVE-2021-42574) scanner and
# UTF-8-without-BOM enforcement. Single source of truth for the pre-commit
# plugin, the CI lint-unicode job, and the whole-tree audit.
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
#            scanned there, so the invisible-allow annotation is read from the blob
#            and an annotation edited but not staged exempts nothing.
#   tracked  The tracked repository is clean. The default, and what CI runs.
#   tree     The whole working tree is clean, vendored and generated content
#            included. Trojan Source deceives the human reading a diff rather
#            than the compiler, so a dependency nothing here builds is still in
#            scope; the remediation for a finding under vendor/ is an upstream
#            report. See ADR 0006 for where this scope is exercised.
#
# PATH LISTS ARE NUL-DELIMITED END TO END, so a path containing a newline is
# scanned rather than silently split into two nonexistent entries. A POSIX
# shell cannot iterate NUL records itself -- it cannot hold a NUL in a variable
# and `read` has no delimiter option -- but that only means the per-path work
# must be separately invocable, not that the pipeline has to degrade: the
# fallback delegates to `xargs -0`, which re-enters this script in its internal
# --scan-batch mode. The findings list is a temp FILE for the same reason a
# variable will not do.
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
# file(1) MIME type(s), the charset, and the binary/text decision as
# TAB-separated rows -- the diagnostic for comparing how a runner's file(1)
# classifies this tree against how the local one does. One batched file(1)
# pass. python3 path only.
#
# LINT_UNICODE_NO_PYTHON=1 forces the shell fallback (test seam).

set -eu

scope=""
classify_report=""
scan_batch=""

# Resolved before any chdir: $0 may be relative, and the staged scope moves the
# working directory into the materialized tree. The fallback re-invokes this
# same file through xargs, so the absolute form is load-bearing.
_script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
_self="$_script_dir/${0##*/}"

die() {
  printf '%s: %s\n' "${0##*/}" "$1" >&2
  exit 2
}

usage() {
  printf 'Usage: %s [--scope=staged|tracked|tree] [--classify-report=FILE] [PATH...]\n\n' "${0##*/}"
  printf '  --scope=staged    the index content (what the pre-commit hook runs)\n'
  printf '  --scope=tracked   files git tracks (the default, and what CI runs)\n'
  printf '  --scope=tree      the whole working tree, vendored content included\n'
  printf '  --classify-report=FILE  record MIME type, charset, and scan/skip per file\n'
  printf '  PATH...           exactly these paths; directories are walked\n'
}

# --- POSIX-sh fallback detector (used when python3 is absent) -------------
# Fixed codepoint table "U+XXXX:\OOO\OOO\OOO" (UTF-8 octal bytes). The ONLY
# copy in the project: the 80-unicode plugin delegates here rather than
# carrying its own (ADR 0006, amended 2026-07-29).
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
# $1. Returns 1 if all are excluded. Fixed strings under LC_ALL=C compare exact
# bytes and need no locale, where a bracket expression needs a UTF-8 locale and
# silently degrades to a BYTE set without one -- matching the E2 lead byte of
# every U+2xxx character, so an em dash trips the gate.
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

# First invisible-allow annotation in the file, or empty.
read_invisible_allow() {
  LC_ALL=C sed -n 's/.*invisible-allow:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$1" | head -n 1
}

# Internal mode: scan the paths given as arguments, appending each finding
# NUL-terminated to $LINT_UNICODE_FOUND and one byte per scan error to
# $LINT_UNICODE_ERRORS. Invoked through `xargs -0` so the caller never has to
# iterate NUL records in-shell; exits 0 even on a finding, because xargs treats
# a non-zero child as an abort condition and a finding is not an error.
scan_batch_main() {
  # `:?` rather than a bare reference: it documents the contract and lets
  # ShellCheck see these are deliberately environment-supplied.
  _found_file=${LINT_UNICODE_FOUND:?--scan-batch is internal}
  _errors_file=${LINT_UNICODE_ERRORS:?--scan-batch is internal}
  _default_patterns=$(build_patterns "")
  for _f in "$@"; do
    [ -f "$_f" ] || continue
    _allow=$(read_invisible_allow "$_f")
    if [ -n "$_allow" ]; then
      _patterns=$(build_patterns "$_allow") || continue
    else
      _patterns="$_default_patterns"
    fi
    # Three-valued status: 0 match, 1 no match, 2 error. Treating 2 as "no
    # match" would fail open.
    _status=0
    printf '%s\n' "$_patterns" |
      LC_ALL=C /usr/bin/grep --fixed-strings --file=- \
        --binary-files=without-match --quiet "$_f" || _status=$?
    case "$_status" in
    # Strip a leading ./ so the staged scope's `find .` reports the same
    # logical path the python detector does (pathlib normalizes it away).
    0) printf '%s\0' "${_f#./}" >> "$_found_file" ;;
    1) ;;
    *)
      printf 'error: grep exited %s scanning %s\n' "$_status" "$_f" >&2
      printf 'x' >> "$_errors_file"
      ;;
    esac
  done
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
  --scan-batch) scan_batch=1 ;;
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

# The xargs re-entry: no scope, no collection, no temp files of its own.
if [ -n "$scan_batch" ]; then
  : "${LINT_UNICODE_FOUND:?--scan-batch is internal and needs LINT_UNICODE_FOUND}"
  : "${LINT_UNICODE_ERRORS:?--scan-batch is internal and needs LINT_UNICODE_ERRORS}"
  scan_batch_main "$@"
  exit 0
fi

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
_found_tmp=""
_errors_tmp=""
cleanup() {
  rm -f "$_files_tmp"
  [ -z "$_paths_tmp" ] || rm -f "$_paths_tmp"
  [ -z "$_found_tmp" ] || rm -f "$_found_tmp"
  [ -z "$_errors_tmp" ] || rm -f "$_errors_tmp"
  if [ -n "$_stage_dir" ]; then rm -rf "$_stage_dir"; fi
}
trap cleanup EXIT INT TERM

# The staged scope scans INDEX content. `git checkout-index` materializes the
# staged blobs into a throwaway tree preserving relative paths, so findings
# report the logical path and the invisible-allow annotation is read from the blob a
# commit would actually record. The runner's PRE_COMMIT_STAGED_LIST (a
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
  git checkout-index --prefix="$_stage_dir/" --stdin -z < "$_paths_file" ||
    die "could not materialize the staged blobs"
  cd "$_stage_dir" || die "cannot enter the staged materialization"
fi

# Collect files to scan into a NUL-delimited list.
collect_files() {
  case "$scope" in
  staged)
    find . -type f -print0
    ;;
  tracked)
    if [ "$#" -eq 0 ]; then git ls-files -z; else git ls-files -z -- "$@"; fi
    ;;
  tree)
    [ "$#" -gt 0 ] || set -- .
    for _p in "$@"; do
      if [ -d "$_p" ]; then
        find "$_p" -name .git -prune -o -type f -print0
      elif [ -f "$_p" ]; then
        printf '%s\0' "$_p"
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

_found_tmp=$(mktemp "${TMPDIR:-/tmp}/lint-unicode-found.XXXXXX")
_errors_tmp=$(mktemp "${TMPDIR:-/tmp}/lint-unicode-errors.XXXXXX")

# xargs -0 is how a POSIX shell iterates NUL records: it splits them and hands
# each batch back to this script as arguments. `-r` (--no-run-if-empty) is a
# GNU-compatibility option macOS xargs also accepts.
LINT_UNICODE_FOUND="$_found_tmp" LINT_UNICODE_ERRORS="$_errors_tmp" \
  xargs -0 -r "$_self" --scan-batch < "$_files_tmp"

if [ -s "$_errors_tmp" ]; then
  printf 'error: the invisible-Unicode scan could not complete; refusing\n' >&2
  printf '  rather than passing files it never managed to read.\n' >&2
  exit 1
fi

if [ -s "$_found_tmp" ]; then
  printf 'Invisible Unicode characters found (CVE-2021-42574):\n' >&2
  # NUL to newline only HERE, at the human-output boundary: a path with a
  # newline in it prints across two lines, which is a display quirk rather
  # than the silent skip that newline-delimiting the pipeline would cause.
  LC_ALL=C tr '\0' '\n' < "$_found_tmp" | while IFS= read -r _bf; do
    printf '  %s\n' "$_bf" >&2
  done
  printf '\nA file may opt out of specific codepoints with an in-file\n' >&2
  printf 'annotation, e.g.:  // invisible-allow: U+200E,U+200F\n' >&2
  exit 1
fi
