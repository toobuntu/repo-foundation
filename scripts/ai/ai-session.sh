#!/bin/sh

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# ai-session.sh — bookend the volatile .ai/ files so a session cannot drop
# work silently, and keep every pre-write state of them recoverable.
#
# `.ai/progress.md` and `.ai/scratchpad/` are gitignored by design (ADR 0022):
# per-developer, rewritten freely, no history. That is right for status and
# wrong for anything that turns out to be a commitment — a rewrite has no
# diff, a deletion has no reflog, and branches do not version untracked
# files, so "work on a branch" protects none of it. Two mechanisms close the
# gap:
#
#   - `start`/`end` snapshot and diff progress.md, so removals are STATED in
#     the handoff (accountability; the 2026-07-25 silent loss is the
#     incident record, repo-foundation ADR 0022).
#   - `vault` copies the pre-write state of those files into a per-repo
#     directory under ${XDG_STATE_HOME:-~/.local/state}/ai-history/ before
#     hooks let an overwrite or deletion proceed (recovery). Hooks run
#     outside the agent sandbox and can write there; the sandboxed agent
#     cannot, so the vault is one-way by construction.
#
# Vault pruning is evidence-first, never wall-clock for anything that could
# still matter: progress.md copies keep the newest 10; a draft's copies are
# kept while the draft exists, auto-pruned once it is gone AND its work
# provably landed (a commit whose message matches, a parked merged/prNN
# branch), and merely REPORTED as expired otherwise — `vault-gc`, the only
# deleting subcommand for that class, is maintainer-run and wired into no
# hook (asserted by spec).
#
# Usage:
#   scripts/ai/ai-session.sh start [--session=ID]  # snapshot; warn on an
#                                             # unclean previous close
#   scripts/ai/ai-session.sh end [--session=ID]    # report removed lines,
#                                             # write the clean-close marker
#   scripts/ai/ai-session.sh relay-consume    # retire a promoted relay
#   scripts/ai/ai-session.sh init             # create the .ai/ layer here
#   scripts/ai/ai-session.sh vault [--json] [--session=ID] FILE...
#                                             # copy pre-write state in
#   scripts/ai/ai-session.sh vault-gc         # remove REPORTED-expired copies
#   scripts/ai/ai-session.sh close-check      # Stop-hook gate on the close
#                                             # ritual (reads hook JSON stdin)
#   scripts/ai/ai-session.sh compact-check    # PreCompact gate: progress.md
#                                             # current before detail is lost
#   scripts/ai/ai-session.sh vault-hook       # hook shim: vault the pre-write
#                                             # state named by hook JSON stdin
#
# Every subcommand except init is a no-op in a directory with no .ai/ layer,
# so the hooks that call them are safe to fire everywhere. A directory that
# is not a git repository is handled: the root falls back to
# CLAUDE_PROJECT_DIR (or PWD), and git-dependent checks skip themselves.

set -eu

usage() {
  printf 'Usage: %s start|end|relay-consume|init|vault [args]|vault-hook|vault-gc|close-check|compact-check\n' \
    "${0##*/}" >&2
}

if root=$(git rev-parse --show-toplevel 2> /dev/null); then
  in_git=1
else
  root="${CLAUDE_PROJECT_DIR:-$PWD}"
  in_git=0
fi

progress="$root/.ai/progress.md"
snapshot="$root/.ai/.progress.session-start"
snapshot_sid="$root/.ai/.progress.session-start.sid"
closed_marker="$root/.ai/.session-closed"
relay="$root/.ai/org/relay.md"

# One optional flag shared by start/end: the hook passes the session id it
# reads from the hook JSON. Everything degrades gracefully without it.
session=""
case "${2:-}" in
--session=*) session="${2#--session=}" ;;
*) ;;
esac

progress_sum() {
  cksum "$progress" 2> /dev/null | cut -d' ' -f1
}

git_dir=""
if [ "$in_git" -eq 1 ]; then
  git_dir=$(git -C "$root" rev-parse --git-dir 2> /dev/null) || git_dir=""
  case "$git_dir" in
  '' | /*) ;;
  *) git_dir="$root/$git_dir" ;;
  esac
fi

# Is .ai/progress.md current WITH RESPECT TO THE WORK, rather than merely
# newer than session start?
#
# "Newer than the session-start snapshot" is too weak and would pass the case
# that matters: progress rewritten in the first hour of a five-hour session is
# stale by the time compaction fires, yet its mtime is still newer than the
# snapshot. So compare it against every cheap marker of activity instead —
# each is one `-nt`, which is POSIX and needs no epoch arithmetic:
#
#   the session-start snapshot   progress was never touched at all
#   the last-compact marker      nothing written since the previous compaction
#   .git/logs/HEAD               a commit, switch, or reset landed since
#   modified tracked files       edits in flight are newer than the write-up
#   .ai/scratchpad/*             a draft was written after the write-up
#
# Any one of them newer than progress.md means work happened that progress.md
# does not describe.
progress_is_current() {
  [ -f "$progress" ] || return 1
  for _ev in "$snapshot" "$root/.ai/.last-compact" "$git_dir/logs/HEAD"; do
    case "$_ev" in
    /logs/HEAD) continue ;; # no git_dir: skip rather than test "/logs/HEAD"
    *) ;;
    esac
    [ -e "$_ev" ] || continue
    [ "$progress" -nt "$_ev" ] || return 1
  done
  for _f in "$root"/.ai/scratchpad/*; do
    [ -f "$_f" ] || continue
    [ "$progress" -nt "$_f" ] || return 1
  done
  [ "$in_git" -eq 1 ] || return 0
  _mods=$(mktemp "${TMPDIR:-/tmp}/ai-session-mods.XXXXXX") || return 0
  git -C "$root" diff --name-only > "$_mods" 2> /dev/null || true
  _stale=0
  while IFS= read -r _f; do
    [ -n "$_f" ] && [ -e "$root/$_f" ] || continue
    [ "$progress" -nt "$root/$_f" ] || _stale=1
  done < "$_mods"
  rm -f "$_mods"
  [ "$_stale" -eq 0 ]
}

# ---------- vault helpers ----------

# Per-repo vault directory. The slug prefers the origin remote's
# <org>/<repo> (stable across clones of the same repository); a remoteless
# or non-git directory gets local/<basename>-<cksum-of-path>, so same-named
# trees cannot collide. cksum is POSIX; the decimal is ugly but unambiguous.
vault_dir() {
  _state="${XDG_STATE_HOME:-$HOME/.local/state}/ai-history"
  _url=""
  if [ "$in_git" -eq 1 ]; then
    _url=$(git -C "$root" remote get-url origin 2> /dev/null) || _url=""
  fi
  if [ -n "$_url" ]; then
    # Normalize the scp-like form (git@host:org/repo.git) and URL forms
    # alike: take the last two path components, drop a .git suffix.
    _slug=$(printf '%s\n' "$_url" | sed -e 's/\.git$//' -e 's/:/\//g' |
      awk -F/ 'NF >= 2 { print $(NF - 1) "/" $NF }')
  else
    _sum=$(printf '%s' "$root" | cksum | cut -d' ' -f1)
    _slug="local/$(basename "$root")-$_sum"
  fi
  printf '%s/%s\n' "$_state" "$_slug"
}

# Vault copy name for a repo file: the path relative to .ai/, flattened to a
# single level and reversible.
#
# ESCAPE BEFORE JOIN, never refuse. A path component may itself contain the
# separator sequence, and the naive flatten made `scratchpad/foo__bar.md`
# decode back as `scratchpad/foo/bar.md`. Skipping such a file was considered
# and is WRONG: this is a forced-backup mechanism, so declining to copy a
# file because its NAME is awkward converts a naming inconvenience into the
# data loss the vault exists to prevent. Every source gets a copy.
#
# Encode, in order: `_` -> `_U`, then `/` -> `__`, then ` ` -> `_S`. After the
# first pass no bare `_` survives from the original, so every `_` in the
# result opens a two-character marker and the mapping is one-to-one. Escaping
# the space as well is what keeps whitespace out of the sweep's bookkeeping
# format, so no name needs refusing on that ground either.
#
# Readability is preserved for the ordinary case: a component with no
# underscore or space flattens exactly as before, so copies written under the
# earlier scheme still decode correctly and need no migration.
vault_name_of() {
  printf '%s\n' "${1#"$root"/.ai/}" | sed -e 's/_/_U/g' -e 's|/|__|g' -e 's/ /_S/g'
}

# The inverse. Expression ORDER IS LOAD-BEARING: `__` must be consumed before
# `_S`, or an encoded `a__Sb` (from `a/Sb`) would decode through the space
# marker instead of the separator.
vault_source_of() {
  printf '%s/.ai/%s\n' "$root" \
    "$(printf '%s\n' "$1" | sed -e 's|__|/|g' -e 's/_S/ /g' -e 's/_U/_/g')"
}

# List vault copy filenames, newest last. Copies are <UTC>-<sid8>-<name>,
# so lexical sort is chronological; the timestamp prefix filter keeps
# bookkeeping files (.gone-noticed) out. The ls|grep pattern is safe here:
# every listed name is script-generated (timestamp prefix, no whitespace),
# so the glob-hostile cases ShellCheck warns about cannot occur.
# shellcheck disable=SC2010
vault_copies() {
  ls -1 "$vdir" 2> /dev/null | grep '^[0-9]\{8\}T[0-9]\{6\}Z-' | sort
}

vault_copies_of() {
  vault_copies | grep -F -- "-$1" || true
}

vault_newest() {
  vault_copies_of "$1" | tail -n 1
}

# Whitespace-normalize a message: strip trailing space per line, drop
# trailing blank lines. Shared by the draft-landed test and close-check.
norm_msg() {
  sed 's/[[:space:]]*$//' "$1" |
    awk '{ l[NR] = $0 } END { while (NR > 0 && l[NR] == "") NR--; for (i = 1; i <= NR; i++) print l[i] }'
}

# The commit-landed test for a commit-msg draft. A subject-only match is NOT
# landing evidence — an --amend keeps the subject while the body changes —
# so the return distinguishes: 0 full match, 1 subject-only, 2 no match.
draft_landed() {
  [ "$in_git" -eq 1 ] || return 2
  _subject=$(sed -n '1p' "$1")
  [ -n "$_subject" ] || return 2
  _draft=$(norm_msg "$1")
  _found=2
  for _h in $(git -C "$root" log -200 --fixed-strings --grep="$_subject" \
    --format='%H' 2> /dev/null); do
    _tmp=$(mktemp "${TMPDIR:-/tmp}/ai-session-msg.XXXXXX")
    git -C "$root" log -1 --format='%B' "$_h" > "$_tmp"
    _msg=$(norm_msg "$_tmp")
    rm -f "$_tmp"
    if [ "$_msg" = "$_draft" ]; then
      return 0
    fi
    [ "$(printf '%s\n' "$_msg" | sed -n '1p')" = "$_subject" ] && _found=1
  done
  return "$_found"
}

# The merged test for a pr<N>-named draft: a parked merged/prNN/* branch
# (the org's park convention) proves the PR landed. Zero-padding tolerated
# by comparing the numbers, not the strings.
pr_parked() {
  [ "$in_git" -eq 1 ] || return 1
  _n=$(printf '%s\n' "$1" | sed -n 's/.*pr0*\([1-9][0-9]*\).*/\1/p' | head -n 1)
  [ -n "$_n" ] || return 1
  git -C "$root" branch --list 'merged/pr*' --format='%(refname:short)' 2> /dev/null |
    sed -n 's/^merged\/pr0*\([1-9][0-9]*\)\/.*/\1/p' |
    grep -q "^$_n\$"
}

# Same question, asked of GitHub. The parked branch is checked FIRST by every
# caller because it is local, free, and authoritative for this org's own
# workflow; this covers the pull request that merged without being parked yet.
pr_merged_upstream() {
  _n=$(printf '%s\n' "$1" | sed -n 's/.*pr0*\([1-9][0-9]*\).*/\1/p' | head -n 1)
  [ -n "$_n" ] || return 1
  _slug=$(repo_slug) || return 1
  net_get "repos/$_slug/pulls/$_n" |
    jq -e '.merged == true' > /dev/null 2>&1
}

# The filed test for an issue-* draft. A draft names its destination
# repository in its own text (the tb-issue-draft house style), so the first
# owner/repo slug in the file is the repository to ask — which matters
# because these drafts usually target an UPSTREAM, not this repository. An
# open or closed issue whose title matches the draft's title is the evidence.
# No slug, no title, or no network means no evidence, which is the
# report-only path, not a finding.
issue_filed() {
  command -v jq > /dev/null 2>&1 || return 1
  _title=$(sed -n 's/^#[[:space:]]*//p' "$1" | head -n 1)
  [ -n "$_title" ] || _title=$(grep -v '^[[:space:]]*$' "$1" | sed -n '1p')
  [ -n "$_title" ] || return 1
  _target=$(grep -o -E '\b[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*\b' "$1" |
    grep -v -E '^(\.|/)' | grep -E '^[A-Za-z0-9]' | head -n 1)
  [ -n "$_target" ] || _target=$(repo_slug) || return 1
  net_get "repos/$_target/issues?state=all&per_page=100" |
    jq -e --arg t "$_title" '[.[] | select(.title == $t)] | length > 0' > /dev/null 2>&1
}

# ---------- landing evidence that needs the network ----------

# Days a vault copy's source may be gone, with no landing evidence, before
# `start` reports it. This is a REPORT and never a deletion, so the cost of
# firing early is one line while the cost of firing late is that nobody
# remembers what the file was — which is why it is short.
ORPHAN_REPORT_DAYS=14

# Cache lifetime for an API answer. A pull request's merged state and a
# repository's issue list change on the scale of minutes at most, and the
# caller runs at every turn end, so this is what keeps a session's network
# cost at roughly one call rather than one per turn.
NET_TTL=600

repo_slug() {
  [ "$in_git" -eq 1 ] || return 1
  _u=$(git -C "$root" remote get-url origin 2> /dev/null) || return 1
  [ -n "$_u" ] || return 1
  printf '%s\n' "$_u" | sed -e 's/\.git$//' -e 's/:/\//g' |
    awk -F/ 'NF >= 2 { print $(NF - 1) "/" $NF }'
}

# GET a GitHub API path, cached. Prefers `gh`: hooks run OUTSIDE the agent
# sandbox, so the credentials the sandboxed agent cannot read are available
# here, which is 5000 requests/hour instead of 60. Falls back to
# unauthenticated api.github.com with a hard timeout.
#
# EVERY failure path is silence: no network, no gh, a timeout, a rate-limit
# body, a private repository. A landing check that cannot reach the network
# must behave exactly like one that found no evidence — never like one that
# found the work unlanded, and never like an error the user has to see.
#
# Which transport answered is appended to .netcache/.path-log, so the
# gh-from-a-hook question is settled by production rather than by assertion.
net_get() {
  [ -n "${1:-}" ] || return 1
  _cache="$vdir/.netcache"
  # cksum is a CRC, so the filename alone is a lossy key. Line 2 stores the
  # requested path and is compared before any hit is served: a collision then
  # reads as a miss and refetches, rather than answering one question with
  # another question's cached answer.
  _f="$_cache/$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
  _now_s=$(date +%s)
  if [ -f "$_f" ]; then
    _ts=$(sed -n '1p' "$_f")
    _key=$(sed -n '2p' "$_f")
    case "$_ts" in
    '' | *[!0-9]*) ;;
    *)
      if [ "$_key" = "$1" ] && [ "$((_now_s - _ts))" -lt "$NET_TTL" ]; then
        sed '1,2d' "$_f"
        return 0
      fi
      ;;
    esac
  fi
  mkdir -p "$_cache" 2> /dev/null || return 1
  _body=""
  _via=""
  if command -v gh > /dev/null 2>&1; then
    _body=$(gh api "$1" 2> /dev/null) && _via=gh || _body=""
  fi
  if [ -z "$_body" ]; then
    _body=$(curl -sS --max-time 3 "https://api.github.com/$1" 2> /dev/null) &&
      _via=curl || _body=""
  fi
  [ -n "$_body" ] || return 1
  # A rate-limit or not-found body is not an answer; do not cache it as one.
  printf '%s' "$_body" | jq -e 'has("message") | not' > /dev/null 2>&1 || return 1
  {
    printf '%s\n' "$_now_s"
    printf '%s\n' "$1"
    printf '%s' "$_body"
  } > "$_f"
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_via" "$1" >> "$_cache/.path-log"
  printf '%s' "$_body"
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Physical path of an existing file: macOS reaches the same tree as both
# /var/... and /private/var/..., and git reports the physical form, so a
# hook-supplied path must be canonicalized before any prefix comparison.
canon() {
  _cd=$(cd "$(dirname -- "$1")" 2> /dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$_cd" "$(basename -- "$1")"
}

drop_gone_record() {
  [ -f "$gone_record" ] || return 0
  grep -v "^$1 " "$gone_record" > "$gone_record.tmp" || true
  mv "$gone_record.tmp" "$gone_record"
}

# Sweep the vault: enforce the progress cap, auto-prune evidence-landed
# copies of gone drafts, record first-noticed-gone times for the rest.
# Deletes NOTHING whose source still exists, and nothing in the no-evidence
# class — that is vault-gc's job, and only the maintainer runs vault-gc.
vault_sweep() {
  [ -d "$vdir" ] || return 0

  # progress.md: keep the newest 10 copies.
  _n_prog=$(vault_copies_of progress.md | wc -l | tr -d ' ')
  if [ "$_n_prog" -gt 10 ]; then
    vault_copies_of progress.md | sed -n "1,$((_n_prog - 10))p" |
      while IFS= read -r _old; do
        rm -f "$vdir/$_old"
      done
  fi

  _now=$(date +%s)
  vault_copies | sed 's/^[0-9]\{8\}T[0-9]\{6\}Z-[^-]*-//' | sort -u |
    grep -v '^progress\.md$' |
    while IFS= read -r _name; do
      _src=$(vault_source_of "$_name")
      if [ -e "$_src" ]; then
        drop_gone_record "$_name" # live again (or still): clear any record
        continue
      fi
      _newest=$(vault_newest "$_name")
      [ -n "$_newest" ] || continue
      _landed=1
      case "$_name" in
      scratchpad__commit-msg-*)
        if draft_landed "$vdir/$_newest"; then _landed=0; fi
        ;;
      scratchpad__pr*)
        # Parked branch first: local, free, and authoritative here.
        if pr_parked "$_name" || pr_merged_upstream "$_name"; then _landed=0; fi
        ;;
      scratchpad__issue-*)
        if issue_filed "$vdir/$_newest"; then _landed=0; fi
        ;;
      *) ;; # no evidence rule for this class; falls to the report path
      esac
      if [ "$_landed" -eq 0 ]; then
        vault_copies_of "$_name" | while IFS= read -r _c; do
          rm -f "$vdir/$_c"
        done
        drop_gone_record "$_name"
        continue
      fi
      # No landing evidence: record when the sweep first noticed the source
      # gone. Any TTL for the report runs from this noticing, never from a
      # copy's own (possibly much older) timestamp.
      if ! { [ -f "$gone_record" ] && grep -q "^$_name " "$gone_record"; }; then
        printf '%s %s\n' "$_name" "$_now" >> "$gone_record"
      fi
    done
}

# Expired report-only copies: source gone ORPHAN_REPORT_DAYS+ per the
# noticing record. Prints "name<TAB>days"; empty output means none expired.
vault_expired() {
  [ -f "$gone_record" ] || return 0
  _now=$(date +%s)
  while IFS=' ' read -r _name _epoch; do
    [ -n "$_name" ] && [ -n "$_epoch" ] || continue
    _days=$(((_now - _epoch) / 86400))
    if [ "$_days" -ge "$ORPHAN_REPORT_DAYS" ]; then
      printf '%s\t%s\n' "$_name" "$_days"
    fi
  done < "$gone_record"
}

vdir=$(vault_dir)
gone_record="$vdir/.gone-noticed"

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

  # Report vault copies whose source is long gone with no landing evidence.
  # Removal is deliberately manual and the maintainer's alone: vault-gc is
  # the only deleter for this class, and no hook invokes it.
  _expired=$(vault_expired)
  if [ -n "$_expired" ]; then
    printf 'ai-session: vault copies whose source is gone 30+ days, no landing evidence:\n'
    printf '%s\n' "$_expired" | while IFS="$(printf '\t')" read -r _n _d; do
      printf '  - %s (gone %s days)\n' "$_n" "$_d"
    done
    printf 'Review and remove with: scripts/ai/ai-session.sh vault-gc\n'
  fi

  # Same session resuming (Claude Code fires SessionStart on resume too):
  # keep the existing snapshot — re-copying would destroy the diff base the
  # end ritual needs, and would bury the unclean-close evidence below.
  _prev_sid=$(cat "$snapshot_sid" 2> /dev/null || true)
  if [ -n "$session" ] && [ "$session" = "$_prev_sid" ] && [ -f "$snapshot" ]; then
    printf 'ai-session: same session resumed; keeping the existing snapshot\n'
    exit 0
  fi

  # Unclean-close detection, BEFORE the snapshot is overwritten: a previous
  # session left a snapshot but no clean-close marker matching the current
  # progress.md. The prior session holds the context, so the primary remedy
  # is to reopen IT and close there; reconciling here (from git log, the
  # vault, and dispatch — not the transcript) is the stated fallback.
  if [ -n "$_prev_sid" ]; then
    _closed_ok=0
    if [ -f "$closed_marker" ]; then
      _rec_sum=$(sed -n '3p' "$closed_marker")
      [ "$_rec_sum" = "$(progress_sum)" ] && _closed_ok=1
    fi
    if [ "$_closed_ok" -eq 0 ]; then
      printf 'ai-session: the previous session here did NOT complete its close ritual\n'
      printf '  session: %s\n' "$_prev_sid"
      printf 'Its .ai/progress.md state is unreconciled. The vault holds dated copies.\n'
      printf 'Preferred: reopen that session (it has the context) and close it there:\n'
      printf '  claude --resume %s\n' "$_prev_sid"
      printf '  then, as its first prompt:  /tb-session-close\n'
      printf 'Fallback: reconcile here first (git log, the vault, dispatch) before new work.\n'
    fi
  fi

  cp "$progress" "$snapshot"
  if [ -n "$session" ]; then
    printf '%s\n' "$session" > "$snapshot_sid"
  else
    rm -f "$snapshot_sid"
  fi
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

  # The clean-close marker: session id, UTC, and the progress checksum the
  # next session's `start` verifies. Written on every `end` — the ritual is
  # idempotent, so the newest run's state is always the one recorded.
  {
    printf '%s\n' "${session:-unknown}"
    date -u +%Y-%m-%dT%H:%M:%SZ
    progress_sum
  } > "$closed_marker"

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

init)
  # Explicit, never automatic: creating a continuity layer is a state change
  # the maintainer opts into per directory, not a side effect of a hook.
  if [ -d "$root/.ai" ]; then
    printf 'ai-session: %s already has a .ai/ layer\n' "$root"
    exit 0
  fi
  mkdir -p "$root/.ai/scratchpad" "$root/.ai/org"
  {
    printf '# Session progress\n\n'
    printf '> Volatile per-developer session state. Rewritten freely; untracked.\n\n'
    printf '## Last touched\n\n## State\n\n## Next action\n\n## Watch out\n'
  } > "$progress"
  printf 'ai-session: created %s/.ai (progress.md seeded)\n' "$root"
  if [ "$in_git" -eq 1 ] &&
    ! { [ -f "$root/.gitignore" ] && grep -q '^\.ai/progress\.md$' "$root/.gitignore"; }; then
    printf 'NOTE: add the .ai ignore lines to .gitignore (see the synced\n'
    printf 'gitignore.baseline: progress.md, scratchpad/, session markers).\n'
  fi
  ;;

vault)
  shift
  as_json=0
  session=unknown
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --json) as_json=1 ;;
    --session=*) session="${1#--session=}" ;;
    *) break ;;
    esac
    shift
  done
  [ "$#" -gt 0 ] || exit 0
  # Hyphens are stripped, not just truncated: the sweep splits a copy name on
  # `-` to recover the file name, so a session id whose first characters
  # include one would cut the field short. A UUID's first eight are hex, but
  # nothing guarantees the id is a UUID.
  sid8=$(printf '%s' "$session" | tr -d '-' | cut -c1-8)
  utc=$(date -u +%Y%m%dT%H%M%SZ)
  msg=""
  _phys_root=$(cd "$root" 2> /dev/null && pwd -P) && root="$_phys_root"
  for f in "$@"; do
    case "$f" in
    /*) abs="$f" ;;
    *) abs="$root/$f" ;;
    esac
    [ -f "$abs" ] || continue
    abs=$(canon "$abs") || continue
    case "$abs" in
    "$root/.ai/progress.md" | "$root/.ai/scratchpad/"*) ;;
    *) continue ;; # only the volatile continuity files are vault material
    esac
    # No name is refused: vault_name_of escapes rather than skipping, so
    # separators, underscores, and spaces in a source name all round-trip.
    name=$(vault_name_of "$abs")
    mkdir -p "$vdir"
    newest=$(vault_newest "$name")
    if [ -n "$newest" ] && cmp -s "$abs" "$vdir/$newest"; then
      continue # identical to the newest copy; nothing to save
    fi
    dest="$vdir/$utc-$sid8-$name"
    cp -p "$abs" "$dest"
    rel="${abs#"$root"/}"
    short="ai-history/${vdir##*/ai-history/}/$utc-$sid8-$name"
    if [ -n "$msg" ]; then
      msg="$msg; "
    fi
    msg="${msg}Snapshotting $rel → $short"
  done
  vault_sweep
  if [ -n "$msg" ]; then
    if [ "$as_json" -eq 1 ]; then
      printf '{"systemMessage":"%s"}\n' "$(json_escape "$msg")"
    else
      printf 'ai-session: %s\n' "$msg"
    fi
  fi
  ;;

vault-gc)
  # The ONLY deleter for the no-evidence class, and deliberately unreachable
  # from hooks (a spec asserts none wires it) and from the sandboxed agent
  # (the vault is outside its writable area). Removes exactly what `start`
  # reported as expired; everything else stays.
  _expired=$(vault_expired)
  if [ -z "$_expired" ]; then
    printf 'ai-session: nothing expired in %s\n' "$vdir"
    exit 0
  fi
  printf '%s\n' "$_expired" | while IFS="$(printf '\t')" read -r _name _days; do
    vault_copies_of "$_name" | while IFS= read -r _c; do
      rm -f "$vdir/$_c"
      printf 'ai-session: removed %s (source gone %s days)\n' "$_c" "$_days"
    done
    drop_gone_record "$_name"
  done
  ;;

vault-hook)
  # One shim for every vault wiring. Reads the hook JSON and decides what to
  # copy: an Edit/Write's file_path; the .ai/scratchpad/ paths named by a
  # Bash rm command; or — with no tool_input at all (SessionStart,
  # PreCompact) — progress.md itself. Always exits 0: this hook only saves,
  # never gates, and the vault subcommand scope-filters, so anything outside
  # the volatile continuity set is skipped there.
  command -v jq > /dev/null 2>&1 || exit 0
  [ -d "$root/.ai" ] || exit 0
  _in=$(cat)
  [ -n "$_in" ] || exit 0
  _sid=$(printf '%s' "$_in" | jq -r '.session_id // "unknown"')
  _fp=$(printf '%s' "$_in" | jq -r '.tool_input.file_path // empty')
  _cmd=$(printf '%s' "$_in" | jq -r '.tool_input.command // empty')
  set --
  if [ -n "$_fp" ]; then
    set -- "$_fp"
  elif [ -n "$_cmd" ]; then
    case "$_cmd" in
    rm\ * | *[\;\&\|]\ rm\ * | *[\;\&\|]rm\ * | */bin/rm\ *)
      for _tok in $(printf '%s\n' "$_cmd" |
        grep --only-matching '\.ai/scratchpad/[^ `"'"'"');]*' | sort -u); do
        set -- "$@" "$root/$_tok"
      done
      ;;
    *) ;; # not a deletion; nothing to save
    esac
  else
    set -- "$root/.ai/progress.md"
  fi
  [ "$#" -gt 0 ] || exit 0
  exec "$0" vault --json "--session=$_sid" "$@"
  ;;

compact-check)
  # The PreCompact gate. Compaction is the moment mid-session detail is
  # summarized away, and it is the LAST moment the agent still holds that
  # detail — so this blocks until .ai/progress.md has been brought current,
  # for MANUAL and AUTO compaction alike.
  #
  # Blocking auto-compaction was first declined on the theory that it fires
  # too near context-full to leave room for the writing. That does not
  # survive the arithmetic (maintainer, 2026-08-07): auto fires around 80%,
  # so the remaining fifth of the window is ample for a progress rewrite and
  # a memory entry, and a PostCompact pointer to the vault copy is strictly
  # worse — after compaction the agent no longer holds what it would need to
  # write accurately, which is the whole problem.
  #
  # The copy is unconditional and happens FIRST, so a block can never cost a
  # snapshot. The gate is self-clearing by mtime: the agent updates
  # progress.md, the next attempt passes and stamps the marker. A counter
  # caps consecutive blocks so a session that genuinely cannot write the file
  # still compacts rather than wedging.
  command -v jq > /dev/null 2>&1 || exit 0
  [ -f "$progress" ] || exit 0
  _in=$(cat)
  _sid=$(printf '%s' "$_in" | jq -r '.session_id // "unknown"' 2> /dev/null || echo unknown)
  _trigger=$(printf '%s' "$_in" | jq -r '.trigger // .matcher // "unknown"' 2> /dev/null || echo unknown)

  printf '%s' "$_in" | "$0" vault-hook > /dev/null 2>&1 || true

  _mark="$root/.ai/.last-compact"
  _state="$root/.ai/.compact-check-state"

  if ! progress_is_current; then
    _n=0
    _prev=$(cat "$_state" 2> /dev/null || true)
    case "$_prev" in
    "$_sid "*) _n=${_prev#"$_sid "} ;;
    *) ;;
    esac
    case "$_n" in
    '' | *[!0-9]*) _n=0 ;;
    *) ;;
    esac
    if [ "$_n" -lt 2 ]; then
      printf '%s %s\n' "$_sid" "$((_n + 1))" > "$_state"
      jq -n --arg t "$_trigger" '{
        decision: "block",
        reason: ("Context is about to be compacted (" + $t + ") and the detail this session holds will not survive it. Update .ai/progress.md to the current state and next action, and append any durable learning to .ai/memory.md, NOW while you still hold the detail. A pre-compaction copy of progress.md is already in the vault. Then let the compaction proceed; this check passes once progress.md is newer than the last compaction.")
      }'
      exit 0
    fi
    jq -n '{systemMessage: "compact-check: .ai/progress.md is still stale after two prompts; allowing compaction so the session does not wedge. The pre-compaction copy is in the vault."}'
  else
    # Progress is current: clear the counter. The cap is on CONSECUTIVE stale
    # checks, so a session that complies and later goes stale again gets the
    # full prompt budget rather than inheriting a spent one.
    rm -f "$_state"
  fi
  : > "$_mark"
  ;;

close-check)
  # The Stop-hook gate on the close ritual. Reads the hook JSON from stdin
  # and inspects last_assistant_message — the agent's final text — so three
  # of the four checks need no guess about whether the session is closing:
  # a message naming a dead path is wrong regardless.
  #
  # Output contract (all exits are 0; the JSON carries the decision):
  #   {"decision":"block","reason":...}  — the turn does not end; the reason
  #                                        is fed back to the agent to fix.
  #   {"systemMessage":...}              — user-visible note, turn ends.
  #   (nothing)                          — silence.
  #
  # Loop safety is layered: stop_hook_active=true (the harness's own signal
  # that this Stop already blocked once this chain) always downgrades, and
  # .ai/.close-check-state remembers the finding-set hash per session, so a
  # distinct finding set blocks at most ONCE — an unfixable finding costs
  # one retry turn and then surfaces as a visible note, never a loop.
  #
  # jq missing fails OPEN, unlike the annotate guard: that guard gates a
  # sandbox escape, this one gates politeness — blocking every turn end on
  # a missing tool would be the hook misfiring, which is worse than no hook.
  command -v jq > /dev/null 2>&1 || exit 0
  [ -d "$root/.ai" ] || exit 0
  _in=$(cat)
  [ -n "$_in" ] || exit 0

  _msgf=$(mktemp "${TMPDIR:-/tmp}/close-check-msg.XXXXXX")
  _fencef=$(mktemp "${TMPDIR:-/tmp}/close-check-fence.XXXXXX")
  _blockf=$(mktemp "${TMPDIR:-/tmp}/close-check-block.XXXXXX")
  _notef=$(mktemp "${TMPDIR:-/tmp}/close-check-note.XXXXXX")
  trap 'rm -f "$_msgf" "$_fencef" "$_blockf" "$_notef"' EXIT INT TERM

  printf '%s' "$_in" | jq -r '.last_assistant_message // empty' > "$_msgf"
  _sid=$(printf '%s' "$_in" | jq -r '.session_id // "unknown"')
  _active=$(printf '%s' "$_in" | jq -r '.stop_hook_active // false')

  # ---- check 1: recipe truth, fenced blocks only ----
  # Prose narration ("I deleted X") must never false-positive, so only the
  # contents of ``` fences are parsed.
  awk '/^[[:space:]]*```/ { inb = !inb; next } inb' "$_msgf" > "$_fencef"

  # Resolve a recipe path token to an absolute path for existence checks.
  # Scope mirrors where session artifacts actually live; anything else in a
  # recipe (repo files, system paths) is not this check's business.
  resolve_tok() {
    case "$1" in
    .ai/scratchpad/*) printf '%s/%s\n' "$root" "$1" ;;
    /tmp/claude*) printf '%s\n' "$1" ;;
    "\$HOME"/.claude* | "~"/.claude*) printf '%s/%s\n' "$HOME" "${1#*/}" ;;
    provides/claude-user/*) printf '%s/%s\n' "$root" "$1" ;;
    *) printf '\n' ;;
    esac
  }

  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _is_rm=0
    case "$_line" in
    rm\ * | *[\;\&]\ rm\ * | *\|\ rm\ *) _is_rm=1 ;;
    *) ;;
    esac
    # cp/mv already-done detection: both endpoints exist and compare equal.
    case "$_line" in
    cp\ * | */bin/cp\ *)
      # Word-splitting is the tokenizer here; recipe lines in org drafts
      # carry no glob characters or spaces-in-paths worth preserving.
      # shellcheck disable=SC2086
      set -- $_line
      _src=""
      _dst=""
      for _w in "$@"; do
        case "$_w" in
        -*) continue ;;
        *cp) continue ;;
        *)
          if [ -z "$_src" ]; then _src="$_w"; else _dst="$_w"; fi
          ;;
        esac
      done
      _rs=$(resolve_tok "$_src")
      _rd=$(resolve_tok "$_dst")
      if [ -n "$_rs" ] && [ -n "$_rd" ] && [ -f "$_rs" ] && [ -f "$_rd" ] &&
        cmp -s "$_rs" "$_rd"; then
        # The backticks are markdown quoting for the reader, not expansion.
        # shellcheck disable=SC2016
        printf 'recipe step already done: `%s` (source and destination are identical; the real next step is removing the mirror copy)\n' \
          "$_line" >> "$_blockf"
      fi
      ;;
    *) ;;
    esac
    # Every in-scope path token on the line must exist — except on rm lines,
    # where an ABSENT path is the finding (a stale step: the deletion
    # already happened, so the recipe was not re-derived from state).
    # The $HOME in the grep pattern is literal text to match, not expansion.
    # shellcheck disable=SC2016
    for _tok in $(printf '%s\n' "$_line" |
      grep --only-matching --extended-regexp \
        '(\.ai/scratchpad|/tmp/claude[^ ]*|\$HOME/\.claude[^ ]*|~/\.claude[^ ]*|provides/claude-user)[^ `"'"'"');]*' |
      sed 's/[),.;:]*$//' | sort -u); do
      _abs=$(resolve_tok "$_tok")
      [ -n "$_abs" ] || continue
      if [ -e "$_abs" ]; then
        continue
      fi
      if [ "$_is_rm" -eq 1 ]; then
        # The backticks are markdown quoting for the reader, not expansion.
        # shellcheck disable=SC2016
        printf 'stale recipe step: `%s` — %s does not exist (already removed); re-derive the recipe from current state\n' \
          "$_line" "$_tok" >> "$_blockf"
      else
        # The backticks are markdown quoting for the reader, not expansion.
        # shellcheck disable=SC2016
        printf 'recipe names a path that does not exist: %s (in `%s`); re-derive the recipe from current state\n' \
          "$_tok" "$_line" >> "$_blockf"
      fi
    done
  done < "$_fencef"

  # ---- close-shape and recipe presence ----
  _ahead=0
  _clean=0
  if [ "$in_git" -eq 1 ]; then
    if git -C "$root" rev-parse --verify --quiet '@{u}' > /dev/null 2>&1; then
      _ahead=$(git -C "$root" log '@{u}..HEAD' --format='%H' | wc -l | tr -d ' ')
    elif git -C "$root" rev-parse --verify --quiet origin/main > /dev/null 2>&1; then
      _ahead=$(git -C "$root" log origin/main..HEAD --format='%H' | wc -l | tr -d ' ')
    fi
    [ -z "$(git -C "$root" status --porcelain)" ] && _clean=1
  fi
  _has_recipe=0
  grep -qi 'closing recipe' "$_msgf" && _has_recipe=1
  _claims_close=0
  grep -qiE 'closing recipe|sign-push|hand-?off' "$_msgf" && _claims_close=1
  _close_shaped=0
  [ "$_ahead" -gt 0 ] && [ "$_clean" -eq 1 ] && _close_shaped=1

  # ---- check 2: close claim (or shape) over a stale progress.md ----
  if [ -f "$snapshot" ] && [ -f "$progress" ] && [ ! "$progress" -nt "$snapshot" ] &&
    { [ "$_claims_close" -eq 1 ] || [ "$_close_shaped" -eq 1 ]; }; then
    printf '.ai/progress.md has not been rewritten this session; update it to the current state and next action before closing\n' \
      >> "$_blockf"
  fi

  # ---- check 4: close-shaped turn with no recipe and no reasoned decline ----
  if [ "$_close_shaped" -eq 1 ] && [ "$_has_recipe" -eq 0 ]; then
    # The backticks are markdown quoting for the reader, not expansion.
    # shellcheck disable=SC2016
    printf 'this turn looks like a session close (commits ahead, clean tree) but carries no closing recipe; print the full runnable recipe, or state `Closing recipe: none — <reason>`\n' \
      >> "$_blockf"
  fi

  # ---- check 3: spent drafts still in the scratchpad ----
  for _d in "$root"/.ai/scratchpad/commit-msg-*.md; do
    [ -f "$_d" ] || continue
    set +e
    draft_landed "$_d"
    _r=$?
    set -e
    if [ "$_r" -eq 0 ]; then
      printf 'spent draft: %s matches a landed commit; delete it (the rm is vault-protected)\n' \
        ".ai/scratchpad/${_d##*/}" >> "$_blockf"
    elif [ "$_r" -eq 1 ]; then
      printf 'draft %s shares a subject with a landed commit but the body differs — a pending --amend, or stale\n' \
        ".ai/scratchpad/${_d##*/}" >> "$_notef"
    fi
  done
  for _d in "$root"/.ai/scratchpad/pr*-*.md "$root"/.ai/scratchpad/pr-body-*.md; do
    [ -f "$_d" ] || continue
    if pr_parked "${_d##*/}"; then
      printf 'spent draft: %s — its PR has a parked merged/prNN branch; delete it (the rm is vault-protected)\n' \
        ".ai/scratchpad/${_d##*/}" >> "$_blockf"
    fi
  done

  # ---- session reports (notes): direct-on-main writes the guard exempted ----
  if [ "$in_git" -eq 1 ]; then
    _gd=$(git -C "$root" rev-parse --git-dir)
    case "$_gd" in
    /*) ;;
    *) _gd="$root/$_gd" ;;
    esac
    if [ -s "$_gd/claude-exempt-writes" ]; then
      printf 'written directly on main this session (guard-exempt continuity files): %s\n' \
        "$(sort -u "$_gd/claude-exempt-writes" | tr '\n' ' ')" >> "$_notef"
      : > "$_gd/claude-exempt-writes"
    fi
  fi

  # ---- decide: block once per distinct finding set, then downgrade ----
  sort -u -o "$_blockf" "$_blockf"
  _state="$root/.ai/.close-check-state"
  if [ -s "$_blockf" ]; then
    _hash=$(cksum "$_blockf" | cut -d' ' -f1)
    _prev=$(cat "$_state" 2> /dev/null || true)
    if [ "$_active" = "true" ] || [ "$_prev" = "$_sid $_hash" ]; then
      # Already blocked on exactly this: let the turn end, but visibly.
      printf 'finding persists after one retry, letting the turn end:\n%s\n' \
        "$(cat "$_blockf")" >> "$_notef"
    else
      printf '%s %s\n' "$_sid" "$_hash" > "$_state"
      if [ -s "$_notef" ]; then
        jq -n --rawfile r "$_blockf" --rawfile n "$_notef" \
          '{decision: "block", reason: ("close-check found:\n" + $r), systemMessage: $n}'
      else
        jq -n --rawfile r "$_blockf" \
          '{decision: "block", reason: ("close-check found:\n" + $r)}'
      fi
      exit 0
    fi
  fi
  if [ -s "$_notef" ]; then
    jq -n --rawfile n "$_notef" '{systemMessage: ("close-check: " + $n)}'
  fi
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
