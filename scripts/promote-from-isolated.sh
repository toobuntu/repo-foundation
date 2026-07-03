#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# promote-from-isolated.sh — bring patch-new commits from an isolated
# (remoteless) agent clone into the current repo as UNSIGNED cherry-picks.
#
# Usage: scripts/promote-from-isolated.sh [--yes] <clone-path> [<branch>]
#
#   <branch> defaults to the current branch. It names both the ref fetched
#   from the clone and the local branch that must be checked out. For a
#   first promotion, create the local branch from its base first
#   (git switch -c <branch> main).
#
# Workflow contract: unsigned == under evaluation. The picks land unsigned
# so the promoted batch is visually distinct (%G? = N), freely amendable,
# and testable; signing via re-sign-unpushed.sh is the final blessing, and
# the pre-push hook rejects unsigned tips. This script only replaces the
# transport (ff-merge broke because promotion re-signs rewrite SHAs, so the
# clone and this repo are patch-equivalent but SHA-divergent after the
# first promotion); the evaluate-then-sign workflow is unchanged.
#
# Verification gates, all BEFORE anything is applied:
#   - clean working tree, correct branch checked out
#   - the clone branch must be linear: any merge commit on its side fails
#   - left/right subject collisions fail: a commit whose promoted copy was
#     amended here shares its subject but not its patch-id, and picking it
#     again would conflict or duplicate — reconcile first
#   - a preview of the patch delta, then an explicit [y/N] confirmation
#     (--yes skips it; without --yes a non-TTY stdin aborts)
#
# `--cherry-pick` filtering keys on patch-ids instead of SHAs, so commits
# already promoted (under different SHAs) are skipped and re-running when
# there is nothing new is a no-op.

set -euo pipefail

yes=0
if [ "${1:-}" = "--yes" ]; then
  yes=1
  shift
fi

clone=${1:?"usage: promote-from-isolated.sh [--yes] <clone-path> [<branch>]"}
branch=${2:-$(git branch --show-current)}

if [ -z "${branch}" ]; then
  printf 'error: detached HEAD and no <branch> argument\n' >&2
  exit 1
fi

current=$(git branch --show-current)
if [ "${current}" != "${branch}" ]; then
  printf 'error: run on %s (currently on %s): git switch %s\n' \
    "${branch}" "${current:-detached HEAD}" "${branch}" >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  printf 'error: working tree not clean\n' >&2
  exit 1
fi

git fetch "${clone}" "${branch}"

# --reverse: replay order (oldest first). This list feeds cherry-pick
# --stdin verbatim, which applies commits in the order given.
right_all=$(git rev-list --reverse --right-only --cherry-pick HEAD...FETCH_HEAD)
right=$(git rev-list --reverse --no-merges --right-only --cherry-pick HEAD...FETCH_HEAD)

if [ "${right_all}" != "${right}" ]; then
  printf 'error: the clone branch contains merge commit(s); agent branches must be linear:\n' >&2
  git log --merges --right-only --cherry-pick --format='  %h %s' HEAD...FETCH_HEAD >&2
  exit 1
fi

if [ -z "${right}" ]; then
  printf '==> Nothing to promote: every clone commit is already patch-equivalent here.\n'
  exit 0
fi

left=$(git rev-list --no-merges --left-only --cherry-pick HEAD...FETCH_HEAD)

if [ -n "${left}" ]; then
  left_subj=$(printf '%s\n' "${left}" | git log --stdin --no-walk=unsorted --format='%s' | sort -u)
  right_subj=$(printf '%s\n' "${right}" | git log --stdin --no-walk=unsorted --format='%s' | sort -u)
  collisions=$(comm -12 <(printf '%s\n' "${left_subj}") <(printf '%s\n' "${right_subj}"))
  if [ -n "${collisions}" ]; then
    printf 'error: subject collision across the patch delta — a promoted copy was\n' >&2
    printf 'probably amended here, so its patch-id no longer matches the clone and\n' >&2
    printf 'the pick would conflict or duplicate. Colliding subject(s):\n' >&2
    printf '  %s\n' "${collisions}" >&2
    printf 'Reconcile first: refresh the clone branch onto this one (or drop its\n' >&2
    printf 'stale copies), then re-run.\n' >&2
    exit 1
  fi
fi

printf '==> Patch delta (< only here, > only in the clone, to be picked):\n'
printf '  %s\n' "${branch}"
git log --no-merges --format='%m %h %G? %s' --left-right --cherry-pick HEAD...FETCH_HEAD

count=$(printf '%s\n' "${right}" | wc -l | tr -d ' ')

if [ -n "${left}" ]; then
  printf '\nwarning: %s commit(s) on the "<" side have no patch-equivalent in the\n' \
    "$(printf '%s\n' "${left}" | wc -l | tr -d ' ')"
  printf 'clone. That is normal for your own follow-up commits or an advanced base,\n'
  printf 'but review the list above before proceeding.\n\n'
fi

if [ "${yes}" -ne 1 ]; then
  # Both checks: -t 0 is the standard interactivity signal (catches CI,
  # cron, pipes into the script); the /dev/tty probe covers the rarer
  # tty-less case, since that is where the prompt actually reads.
  if [ ! -t 0 ] || ! { : < /dev/tty; } 2> /dev/null; then
    printf 'error: not interactive; re-run with --yes\n' >&2
    exit 1
  fi
  # -n 1: answer on a single keypress, no Enter needed (-n, not bash 4.1's
  # -N, so the system bash 3.2 works too; Enter alone counts as "no").
  printf 'Promote %s commit(s), unsigned? [y/N] ' "${count}"
  read -r -n 1 reply < /dev/tty
  printf '\n'
  case "${reply}" in
  y | Y) ;;
  *)
    printf 'Aborted; nothing applied.\n'
    exit 1
    ;;
  esac
fi

# --stdin: one ordered, deterministic stream — oldest first, because
# ${right} was built with --reverse and cherry-pick --stdin applies the
# commits in the order given. (--stdin is a revision-machinery option,
# so it does not appear in `git cherry-pick -h`; it is in the man page.)
printf '%s\n' "${right}" | git -c commit.gpgsign=false cherry-pick --no-gpg-sign --stdin || {
  status=$?
  printf '\n==> cherry-pick stopped (exit %s). This usually means the histories\n' "${status}" >&2
  printf 'drifted in a way the gates could not see (e.g. an amended promoted copy\n' >&2
  printf 'with a reworded subject). Inspect with "git status"; then either resolve\n' >&2
  printf 'and "git cherry-pick --continue", or back out with\n' >&2
  printf '"git cherry-pick --abort" (the branch returns to its pre-promotion state).\n' >&2
  exit "${status}"
}

printf '==> Promoted %s commit(s), unsigned (%%G? = N):\n' "${count}"
git log --reverse --format='  %h %G? %s' "HEAD~${count}..HEAD"
printf '==> Next: run the checks; amend freely while unsigned; then\n'
printf '    re-sign-unpushed.sh and push (the pre-push hook rejects unsigned tips).\n'
