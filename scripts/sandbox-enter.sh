#!/bin/sh
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Create an isolated sandbox clone of a local git repository for use
# with Claude Code or other agentic tooling that should not have
# direct access to the upstream remote.
#
# Companion: scripts/sandbox-exit.sh restores remotes and (optionally)
# pushes when the agent's work is complete.
#
# Usage:
#   scripts/sandbox-enter.sh [--mode=MODE] [--parent=DIR] <source-repo>
#
# After this script exits, cd into the printed path manually:
#   cd "$(scripts/sandbox-enter.sh ~/devel/foo)"

set -eu

usage() {
  cat << USAGE
Usage: $(basename "$0") [--mode=MODE] [--parent=DIR] <source-repo>

Modes (--mode):
  no-remote        (default) Save remotes to .sandbox-remotes and
                   remove them all. \`gh\` and \`git push\` are
                   unreachable until sandbox-exit.sh restores them.
  repoint-origin   Save remotes; leave origin pointing at the source
                   path (the natural result of \`git clone <local>\`).
                   Pushes go to your primary checkout, not GitHub.
                   \`gh\` is broken inside the sandbox by design.
  add-local        Save remotes; restore origin to the GitHub URL and
                   add a 'local' remote pointing at the source path.
                   \`gh\` continues to work; explicit
                   \`git push local\` for sandbox-only pushes.

Options:
  --parent=DIR     Parent dir for the sandbox (default:
                   ~/.cache/sandboxes, created if absent). A parent
                   under /tmp or /private/tmp works but is subject to
                   the macOS tmp reaper: files not accessed or
                   modified in three days are deleted, which silently
                   rots a multi-day clone (see agent-principles.md,
                   "Sandbox clones and the macOS tmp reaper").

The sandbox is created at <parent>/<repo-name>-sandbox-<timestamp>.
Remotes are saved to .sandbox-remotes/saved.tsv inside the sandbox
for later restoration by sandbox-exit.sh. The script prints the
absolute path of the sandbox on stdout.
USAGE
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

resolve_path() {
  (cd "$1" 2> /dev/null && pwd) ||
    die "cannot resolve path: $1"
}

# Saves source repo's remotes to .sandbox-remotes/saved.tsv.
# Format: one row per remote, "<name><TAB><url>".
save_source_remotes() {
  _src=$1
  _out=$2
  mkdir -p "$(dirname "$_out")"
  : > "$_out"
  git -C "$_src" remote | while IFS= read -r _name; do
    [ -n "$_name" ] || continue
    _url=$(git -C "$_src" remote get-url "$_name")
    printf '%s\t%s\n' "$_name" "$_url" >> "$_out"
  done
}

remove_all_remotes() {
  git remote | while IFS= read -r _name; do
    [ -n "$_name" ] || continue
    git remote remove "$_name"
  done
}

main() {
  mode=no-remote
  # Default OUTSIDE /tmp: the macOS tmp reaper deletes /private/tmp entries
  # not accessed or modified in three days, which destroys the untouched
  # files of a multi-day sandbox clone (hardlinked git objects included).
  parent="${HOME}/.cache/sandboxes"
  parent_defaulted=1
  source=

  while [ $# -gt 0 ]; do
    case "$1" in
    --mode=*)
      mode=${1#--mode=}
      shift
      ;;
    --parent=*)
      parent=${1#--parent=}
      parent_defaulted=""
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      [ $# -eq 1 ] || die "expected one positional after --"
      source=$1
      shift
      break
      ;;
    --*) die "unknown option: $1" ;;
    *)
      [ -z "$source" ] || die "multiple positional args: $source $1"
      source=$1
      shift
      ;;
    esac
  done

  [ -n "$source" ] || {
    usage >&2
    exit 1
  }

  case "$mode" in
  no-remote | repoint-origin | add-local) ;;
  *) die "invalid --mode value: $mode (use no-remote, repoint-origin, or add-local)" ;;
  esac

  source_abs=$(resolve_path "$source")
  [ -d "$source_abs/.git" ] || die "$source_abs is not a git repository"

  # The default parent is created on demand; an explicit --parent must
  # already exist (a typo should fail, not mint a directory).
  [ -n "$parent_defaulted" ] && mkdir -p "$parent"
  parent_abs=$(resolve_path "$parent")
  [ -d "$parent_abs" ] || die "parent dir does not exist: $parent"

  case "$parent_abs" in
  /tmp/* | /private/tmp/*)
    printf 'note: %s is under the macOS tmp reaper (files untouched for 3 days are deleted);\n' "$parent_abs" >&2
    printf '      fine for a clone that lives under a day, risky for longer (see agent-principles.md).\n' >&2
    ;;
  esac

  repo_name=$(basename "$source_abs")
  ts=$(date +%Y%m%d-%H%M%S)
  sandbox_dir="$parent_abs/${repo_name}-sandbox-${ts}"
  [ ! -e "$sandbox_dir" ] || die "sandbox path already exists: $sandbox_dir"

  # Capture source's remotes BEFORE cloning. After clone the new repo's
  # origin points at the source path, not at the source's GitHub URL,
  # so the source's remote list cannot be reconstructed from the clone.
  saved_remotes=$(mktemp -t blackoutd-sandbox.XXXXXX)
  save_source_remotes "$source_abs" "$saved_remotes"
  [ -s "$saved_remotes" ] || {
    rm -f "$saved_remotes"
    die "source has no remotes: $source_abs"
  }

  git clone --quiet "$source_abs" "$sandbox_dir"

  cd "$sandbox_dir"
  mkdir -p .sandbox-remotes
  mv "$saved_remotes" .sandbox-remotes/saved.tsv

  case "$mode" in
  no-remote)
    remove_all_remotes
    ;;
  repoint-origin)
    # The clone's origin already points at source_abs.
    :
    ;;
  add-local)
    original_origin=$(awk -F'\t' '$1 == "origin" {print $2}' .sandbox-remotes/saved.tsv)
    [ -n "$original_origin" ] ||
      die "source has no origin remote; cannot use --mode=add-local"
    git remote set-url origin "$original_origin"
    git remote add local "$source_abs"
    ;;
  esac

  printf '%s\n' "$sandbox_dir"
  {
    printf '\nSandbox created. Next:\n'
    printf '  cd %s\n' "$sandbox_dir"
    printf '  claude\n'
    printf '\nWhen done, run scripts/sandbox-exit.sh from inside the sandbox.\n'
  } >&2
}

main "$@"
