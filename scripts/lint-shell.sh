#!/bin/sh

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# lint-shell.sh — ksh -n (syntax) + shfmt (formatting) + shellcheck (analysis).
#
# One implementation, two triggers: the .githooks/pre-commit.d/05-shell plugin
# runs it with --staged, the shell-lint CI job with --tracked. shfmt reads
# .editorconfig (two-space, the toobuntu house style) and shellcheck reads
# .shellcheckrc. Homebrew-aligned repos defer to `brew style` and do NOT ship
# this script (brew style runs shfmt + shellcheck with Homebrew's own config).
#
# The static-analysis pass runs at --severity=warning: warning-and-above gates,
# while the style/info suggestions the .shellcheckrc `enable=`s surface stay
# advisory (visible on a bare local run, not a CI failure).
#
# Usage: lint-shell.sh [--staged | --tracked | <path>...]   (default --tracked)

set -eu

severity=warning

usage() {
  printf 'Usage: %s [--staged | --tracked | <path>...]\n' "${0##*/}" >&2
}

# Is $1 a shell script? By extension, or by a shebang naming a shell (every
# shell name — sh, bash, ksh, dash, zsh — ends in "sh"), so the extension-less
# hooks and run-parts plugins are caught too.
is_shell() {
  case "$1" in
  *.sh | *.bash | *.ksh) return 0 ;;
  esac
  [ -f "$1" ] || return 1
  head -n 1 "$1" 2> /dev/null | grep -qE '^#!.*sh([[:space:]]|$)'
}

# Emit the candidate path set (newline-delimited) for the chosen mode.
candidates() {
  case "${1:---tracked}" in
  --staged) git diff --cached --name-only --diff-filter=ACMRT ;;
  --tracked) git ls-files ;;
  -h | --help)
    usage
    exit 0
    ;;
  --)
    shift
    printf '%s\n' "$@"
    ;;
  -*)
    usage
    exit 2
    ;;
  *) printf '%s\n' "$@" ;;
  esac
}

tmp=$(mktemp "${TMPDIR:-/tmp}/lint-shell.XXXXXX")
trap 'rm -f "$tmp"' EXIT INT TERM

candidates "$@" | while IFS= read -r f; do
  [ -n "$f" ] && is_shell "$f" && printf '%s\n' "$f"
done > "$tmp"

if [ ! -s "$tmp" ]; then
  printf 'lint-shell: no shell files to check\n'
  exit 0
fi

rc=0
# ksh -n is a stricter syntax check than bash -n / sh -n and parses bash scripts
# too; it is macOS's default AT&T ksh93 (/bin/ksh). Run first — a parse error
# makes the formatter and analyzer moot. (This subsumes the standalone ksh -n CI
# job cert-automation used to carry.)
if command -v ksh > /dev/null 2>&1; then
  while IFS= read -r f; do ksh -n "$f" || rc=1; done < "$tmp"
else
  printf 'warning: ksh not found — skipping shell syntax check (ksh ships with macOS; apt/brew install ksh on Linux)\n' >&2
fi
if command -v shfmt > /dev/null 2>&1; then
  # shfmt -d exits non-zero (and prints a diff) when a file is not formatted.
  xargs shfmt -d < "$tmp" || rc=1
else
  printf 'warning: shfmt not found — skipping shell formatting check (brew install shfmt)\n' >&2
fi
if command -v shellcheck > /dev/null 2>&1; then
  xargs shellcheck --severity="$severity" < "$tmp" || rc=1
else
  printf 'warning: shellcheck not found — skipping shell static analysis (brew install shellcheck)\n' >&2
fi

exit "$rc"
