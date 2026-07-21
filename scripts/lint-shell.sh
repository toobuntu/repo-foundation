#!/bin/sh

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# lint-shell.sh — ksh -n (syntax) + shfmt (formatting) + shellcheck (analysis),
# dialect-aware.
#
# One implementation, two triggers: the .githooks/pre-commit.d/10-shell plugin
# runs it with --staged, the shell-lint CI job with --tracked.
#
# AT&T ksh93 scripts (a .ksh extension, or a ksh shebang — both /bin/ksh and
# /usr/bin/env ksh, plus ksh93/ksh88) are checked with `ksh -n` and
# `shellcheck --shell=ksh`, but NOT shfmt: shfmt has no ksh93 dialect and either
# reformats it wrongly or fails to parse it, even with -ln mksh (mvdan/sh#614).
# its own ksh dialect analyzes them without needing the ksh binary, so ksh files
# are still linted on a runner that lacks ksh (the Ubuntu runner); this is why
# the synced CI need not install ksh93.
#
# sh / bash scripts get shfmt (reads .editorconfig, two-space) + shellcheck
# (dialect from the shebang). `ksh -n` — a stricter syntax check than
# bash -n / sh -n — runs over ALL shell wherever ksh is present (stock on
# macOS), as the authoritative syntax pass. shellcheck runs at --severity=warning
# (warning-and-above gates; the .shellcheckrc `enable=`s stay advisory).
#
# Homebrew-aligned repos defer to `brew style` and do not ship this script.
#
# Usage: lint-shell.sh [--staged | --tracked | <path>...]   (default --tracked)

set -eu

severity=warning

usage() {
  printf 'Usage: %s [--staged | --tracked | <path>...]\n' "${0##*/}" >&2
}

# Is $1 a shell script? By extension, or by a shebang naming a shell (every
# shell name ends in "sh"), so extension-less hooks and plugins are caught.
is_shell() {
  case "$1" in
  *.sh | *.bash | *.ksh) return 0 ;;
  esac
  [ -f "$1" ] || return 1
  head -n 1 "$1" 2> /dev/null | grep -qE '^#!.*sh([[:space:]]|$)'
}

# Is $1 an AT&T ksh93 script? A .ksh extension, or a shebang whose command is
# ksh / ksh93 / ksh88 — matching both /bin/ksh and /usr/bin/env ksh.
is_ksh() {
  case "$1" in
  *.ksh) return 0 ;;
  esac
  [ -f "$1" ] || return 1
  head -n 1 "$1" 2> /dev/null | grep -qE '^#!.*[/ ]ksh[0-9]*([[:space:]]|$)'
}

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

all=$(mktemp "${TMPDIR:-/tmp}/lint-shell.XXXXXX")
kshf=$(mktemp "${TMPDIR:-/tmp}/lint-shell-ksh.XXXXXX")
other=$(mktemp "${TMPDIR:-/tmp}/lint-shell-other.XXXXXX")
trap 'rm -f "$all" "$kshf" "$other"' EXIT INT TERM

# The `if` (not `&&`) keeps each iteration's status 0, so the pipeline does not
# exit non-zero when the last candidate is not a shell file — which under set -e
# would abort before any check runs.
candidates "$@" | while IFS= read -r f; do
  if [ -n "$f" ] && is_shell "$f"; then printf '%s\n' "$f"; fi
done > "$all"

if [ ! -s "$all" ]; then
  printf 'lint-shell: no shell files to check\n'
  exit 0
fi

# Partition into ksh93 vs sh/bash.
while IFS= read -r f; do
  if is_ksh "$f"; then printf '%s\n' "$f" >> "$kshf"; else printf '%s\n' "$f" >> "$other"; fi
done < "$all"

rc=0

# ksh -n: authoritative syntax check over ALL shell, where ksh is present.
if command -v ksh > /dev/null 2>&1; then
  while IFS= read -r f; do ksh -n "$f" || rc=1; done < "$all"
else
  printf 'note: ksh not found — skipping ksh -n syntax check (stock on macOS; apt/brew install ksh93 on Linux)\n' >&2
fi

# shfmt: formatting, sh/bash only (no ksh93 dialect exists).
# Per-file loops rather than xargs: default xargs splits on any whitespace
# and can read a leading-dash name as an option. `--` ends option parsing.
# (The newline-delimited lists still assume no newlines in filenames.)
if [ -s "$other" ]; then
  if command -v shfmt > /dev/null 2>&1; then
    while IFS= read -r f; do shfmt --diff -- "$f" || rc=1; done < "$other"
  else
    printf 'warning: shfmt not found — skipping shell formatting check (brew install shfmt)\n' >&2
  fi
fi

# Static analysis (shellcheck): ksh files use --shell=ksh (no ksh binary
# needed); sh/bash files let shellcheck pick the dialect from the shebang.
if command -v shellcheck > /dev/null 2>&1; then
  while IFS= read -r f; do shellcheck --severity="$severity" -- "$f" || rc=1; done < "$other"
  while IFS= read -r f; do shellcheck --shell=ksh --severity="$severity" -- "$f" || rc=1; done < "$kshf"
else
  printf 'warning: shellcheck not found — skipping shell static analysis (brew install shellcheck)\n' >&2
fi

exit "$rc"
