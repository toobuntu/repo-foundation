#!/bin/sh

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# guard-curl-pipe.sh — PreToolUse Bash guard for the curl-into-shell shapes
# no permission rule can express.
#
# The plain pipelines (`curl … | sh`, with or without shell arguments) are
# covered by the anchored deny-rule pairs in the settings; the matcher was
# measured (2026-08-05) to see pipelines whole and per-component with pipe
# spacing normalized, so those rules are live and this guard does NOT
# duplicate them. What rules cannot see is executing a curl SUBSTITUTION:
#
#   eval "$(curl …)"        sh -c "$(curl …)"        bash <(curl …)
#
# Each hands network-fetched text to a shell in one step, which is the
# curl-pipe-shell operation under docs/agent-principles.md "Universally
# denied operations" in a different spelling. The refusal names the policy
# and the sanctioned path: download to a file, read it, then run it — the
# download and the run each pass review on their own.
#
# Deliberately narrow: word-boundary shell names, so `shellcheck $(curl …)`
# never matches; download-then-execute across separate commands
# (`curl -o f … && sh f`) is dataflow no string pattern can follow, and
# `curl` itself stays ask-gated — that prompt is the covering control.
#
# jq missing fails OPEN: the deny rules still stand, and a guard that
# refuses every Bash call on a missing tool would be the defect.

set -eu

command -v jq > /dev/null 2>&1 || exit 0
cmd=$(jq -r '.tool_input.command // empty' 2> /dev/null) || exit 0
[ -n "$cmd" ] || exit 0

shells='(sh|bash|zsh|ksh|dash|csh|tcsh|fish)'
# A curl invocation as it appears inside a substitution. Optional leading
# whitespace (`$( curl …` is valid shell), an optional `command` builtin
# prefix, and an optional directory prefix (`/usr/bin/curl`) are all the same
# fetch. The trailing class is the word boundary that keeps `curl-config` —
# a legitimate build helper — out: it excludes a following hyphen or
# alphanumeric, while admitting the space or `)` a real call is followed by.
# The trailing class excludes hyphen, UNDERSCORE, and alphanumerics, so
# `curl-config` and `curl_config` are both left alone: an underscore is part
# of a command token, not a boundary. Demonstrated the hard way — the first
# version refused a diagnostic of this very file that merely spelled
# `curl_config`.
curlword='(command[[:space:]]+)?([^[:space:]]*/)?curl[^-_[:alnum:]]'
sub='\$\([[:space:]]*'"$curlword"'|`[[:space:]]*'"$curlword"

# Normalize runs of whitespace so spacing games cannot dodge the patterns.
flat=$(printf '%s' "$cmd" | tr -s '[:space:]' ' ')

matched=0
# eval of a curl substitution.
printf '%s\n' "$flat" |
  grep -q -E "(^|[^[:alnum:]_])eval[^;|&]*($sub)" && matched=1
# A shell invocation whose arguments carry a curl substitution (sh -c "$(…)").
printf '%s\n' "$flat" |
  grep -q -E "(^|[^[:alnum:]_])$shells(\.exe)? [^;|&]*($sub)" && matched=1
# A shell fed a curl process substitution (bash <(curl …)).
printf '%s\n' "$flat" |
  grep -q -E "(^|[^[:alnum:]_])$shells [^;|&]*<\([[:space:]]*$curlword" && matched=1

[ "$matched" -eq 1 ] || exit 0

{
  printf 'curl-into-shell refused.\n'
  # The $( in this message quotes the refused shape for the reader; nothing
  # here expands.
  # shellcheck disable=SC2016
  printf 'Executing a curl substitution (eval/sh -c "$(curl …)", a <(curl …)\n'
  printf 'feed) is the curl-pipe-shell operation the org denies, in a different\n'
  printf 'spelling (docs/agent-principles.md, Universally denied operations).\n'
  printf 'Sanctioned path: download to a file, read it, then run the file —\n'
  printf 'each step passes review on its own.\n'
} >&2
exit 2
