#!/usr/bin/env ksh
#
# ARCHIVED / SPENT ONE-OFF (2026-06-16 reorg; kept for provenance only, do
# NOT reuse as-is). Known limitation: the substitutions guard the RIGHT
# boundary but not the LEFT, so a path like "mydesktop/babble" would be
# wrongly rewritten. This was harmless for its single run — the caller
# passed only the maintainer's known "~/devel/claude/desktop/…" paths, where
# no such left-embedded case occurs — but any reuse must first anchor the
# match on the left (e.g. a leading "/" or start-of-token before "desktop/").
#
# reorg-ref-rewrite — boundary-aware rewrite of pre-reorg
# ~/devel/claude/desktop path references, per the 2026-06-16 git-reorg
# move map. ONE-OFF: the move map below is hardcoded to THIS reorg.
#
#   reorg-ref-rewrite [--apply] [path ...]
#
#   (default)   dry-run: list files that would change, show a unified diff
#   --apply     rewrite matching files in place
#   path ...    files or dirs to scan (dirs are walked, skipping .git and
#               dependency caches). With no paths, scans the current dir.
#
# Boundary-aware: a token is rewritten only when NOT followed by another
# identifier char, '.', or '-'. So 'desktop/babble' never eats
# 'babble-ruby'/'babble-base64', and 'desktop/adrs' never eats 'adrs.toml'
# or 'adrs-formula'. The map is applied longest-token-first, so
# 'blackoutd.claude_desktop' is handled before 'blackoutd'.
#
# The CALLER chooses which paths to pass. For workspace/, pass the explicit
# LIVE docs only (never the dated snapshots) — see the runbook.
#
# Known gap: a token immediately followed by '.' (e.g. a sentence-ending
# "...desktop/blackoutd.") is intentionally skipped to protect adrs.toml and
# blackoutd.claude_desktop. After --apply, run the verification grep in the
# runbook to catch the rare sentence-end case for manual fixing.
#
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
PROG=${0##*/}
APPLY=false

# Substitution program (perl), LONGEST token first. \Q..\E quotes the token
# (so '.' and '_' are literal); (?![\w.-]) is the right-boundary guard.
SUBS=$(cat <<'PERL'
s{desktop/\Qblackoutd.claude_desktop\E(?![\w.-])}{desktop/toobuntu/_dormant/blackoutd.claude_desktop}g;
s{desktop/\Qbabble-refactor-modular\E(?![\w.-])}{desktop/toobuntu/babble-refactor-modular}g;
s{desktop/\Qchabad-org-zmanim\E(?![\w.-])}{desktop/reference/toolsforshlichus/chabad-org-zmanim}g;
s{desktop/\Qanti-trojan-source\E(?![\w.-])}{desktop/reference/lirantal/anti-trojan-source}g;
s{desktop/\Qhomebrew-cask-tools\E(?![\w.-])}{desktop/toobuntu/homebrew-cask-tools}g;
s{desktop/\Qdisplayrecommitd\E(?![\w.-])}{desktop/toobuntu/_dormant/displayrecommitd}g;
s{desktop/\Qcert-automation\E(?![\w.-])}{desktop/toobuntu/cert-automation}g;
s{desktop/\Qrepo-foundation\E(?![\w.-])}{desktop/toobuntu/repo-foundation}g;
s{desktop/\Qmdbook-lint\E(?![\w.-])}{desktop/reference/joshrotenberg/mdbook-lint}g;
s{desktop/\Qpowerstatus\E(?![\w.-])}{desktop/toobuntu/_dormant/powerstatus}g;
s{desktop/\Qinject_edid\E(?![\w.-])}{desktop/toobuntu/_dormant/inject_edid}g;
s{desktop/\Qdot-github\E(?![\w.-])}{desktop/toobuntu/dot-github}g;
s{desktop/\Qblackoutd\E(?![\w.-])}{desktop/toobuntu/blackoutd}g;
s{desktop/\Qbob-book\E(?![\w.-])}{desktop/toobuntu/bob-book}g;
s{desktop/\Qbabble\E(?![\w.-])}{desktop/toobuntu/babble}g;
s{desktop/\Qdidan\E(?![\w.-])}{desktop/toobuntu/zman-didan}g;
s{desktop/\Qbrew\E(?![\w.-])}{desktop/fork/Homebrew/brew}g;
s{desktop/\Qadrs\E(?![\w.-])}{desktop/reference/joshrotenberg/adrs}g;
PERL
)

function process {            # $1 = file
  typeset f=$1 tmp
  tmp=$(mktemp) || return 1
  perl -pe "$SUBS" "$f" >"$tmp"
  if cmp -s "$f" "$tmp"; then rm -f "$tmp"; return 0; fi
  if $APPLY; then
    perl -i -pe "$SUBS" "$f"
    rm -f "$tmp"
    printf 'rewrote: %s\n' "$f"
  else
    printf '\n===== %s =====\n' "$f"
    diff -u "$f" "$tmp" || true
    rm -f "$tmp"
  fi
}

function scan {               # $1 = path (file or dir)
  if [[ -f $1 ]]; then process "$1"; return 0; fi
  find "$1" \
      \( -name .git -o -name node_modules -o -name bundle -o -name .bundle \
         -o -name _site -o -name target \) -prune \
    -o -type f -print \
    | while IFS= read -r f; do
        grep -Iq . "$f" 2>/dev/null && process "$f"
      done
}

typeset -a paths=()
while (( $# )); do
  case $1 in
    --apply) APPLY=true; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    --) shift; while (( $# )); do paths+=("$1"); shift; done ;;
    -*) printf '%s: unknown option: %s\n' "$PROG" "$1" >&2; exit 2 ;;
    *)  paths+=("$1"); shift ;;
  esac
done
(( ${#paths[@]} )) || paths=(.)

for p in "${paths[@]}"; do scan "$p"; done
