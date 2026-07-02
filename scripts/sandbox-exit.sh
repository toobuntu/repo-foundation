#!/bin/sh
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Restore git remotes saved by sandbox-enter.sh and (optionally) push
# the current branch.
#
# Usage:
#   scripts/sandbox-exit.sh [--push] [--push-target=REMOTE]
#
# Run from inside a sandbox dir created by sandbox-enter.sh.

set -eu

usage() {
  cat << USAGE
Usage: $(basename "$0") [--push] [--push-target=REMOTE]

Restore git remotes from .sandbox-remotes/saved.tsv (created by
sandbox-enter.sh).

Options:
  --push                  Push the current branch and set upstream
                          (default target: origin).
  --push-target=REMOTE    Remote to push to. Implies --push.
USAGE
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

main() {
  do_push=
  push_target=origin

  while [ $# -gt 0 ]; do
    case "$1" in
    --push)
      do_push=1
      shift
      ;;
    --push-target=*)
      push_target=${1#--push-target=}
      do_push=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1" ;;
    esac
  done

  saved=.sandbox-remotes/saved.tsv
  [ -f "$saved" ] || die "no $saved found; not in a sandbox?"

  # Remove any existing remotes first to avoid 'remote already exists'
  # collisions during restoration.
  git remote | while IFS= read -r _name; do
    [ -n "$_name" ] || continue
    git remote remove "$_name"
  done

  _tab=$(printf '\t')
  while IFS="$_tab" read -r name url; do
    [ -n "$name" ] && [ -n "$url" ] || continue
    git remote add "$name" "$url"
    printf 'Restored remote: %s -> %s\n' "$name" "$url"
  done < "$saved"

  if [ -n "$do_push" ]; then
    branch=$(git branch --show-current)
    [ -n "$branch" ] || die "no current branch (detached HEAD?); cannot push"
    git fetch "$push_target"
    git push --set-upstream "$push_target" "$branch"
  fi
}

main "$@"
