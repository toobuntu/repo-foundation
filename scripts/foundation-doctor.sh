#!/bin/sh

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# foundation-doctor.sh — flag per-repo scaffold workflows that have gone stale.
#
# The ci / codeql / copilot-setup-steps workflows are copy-once scaffolds owned
# per repo (ADR 0015), so the sync cannot realign them and there is no clean
# canonical to diff them against. This is an age-based nudge instead: a scaffold
# untouched for longer than the threshold is reported for manual reconciliation
# against current upstream guidance. The scheduled scaffold-drift.yml workflow
# runs the same check and opens an issue — one implementation, two triggers.
#
# A scaffold that carries the "do not modify it directly" sync header is skipped:
# it is a synced canonical file (a Homebrew tap's copilot-setup-steps), not a
# per-repo scaffold, and it self-heals through the sync.
#
# Usage: scripts/foundation-doctor.sh [--max-age-days N] [repo-root]
#   FOUNDATION_DOCTOR_MAX_AGE_DAYS overrides the default (365). Exits non-zero
#   if any scaffold is stale, so a caller (CI) can act on it.

set -eu

max_age_days="${FOUNDATION_DOCTOR_MAX_AGE_DAYS:-365}"
while [ $# -gt 0 ]; do
  case "$1" in
  --max-age-days)
    max_age_days="${2:?--max-age-days needs an argument}"
    shift 2
    ;;
  --max-age-days=*)
    max_age_days="${1#--max-age-days=}"
    shift
    ;;
  -h | --help)
    printf 'Usage: %s [--max-age-days N] [repo-root]\n' "${0##*/}"
    exit 0
    ;;
  --)
    shift
    break
    ;;
  -*)
    printf 'error: unknown option: %s\n' "$1" >&2
    exit 2
    ;;
  *) break ;;
  esac
done
root="${1:-.}"

now=$(date +%s)
stale=0
found=0
for name in ci.yml codeql.yml copilot-setup-steps.yml; do
  rel=".github/workflows/$name"
  f="$root/$rel"
  [ -f "$f" ] || continue
  # Synced canonical files self-heal; only per-repo scaffolds are nudged.
  grep -qF "do not modify it directly" "$f" && continue
  found=1
  # Last-commit time of the file. Untracked / no history → treat as fresh.
  ct=$(git -C "$root" log -1 --format=%ct -- "$rel" 2> /dev/null || true)
  [ -n "$ct" ] || {
    printf 'ok (untracked): %s\n' "$rel"
    continue
  }
  age_days=$(((now - ct) / 86400))
  if [ "$age_days" -gt "$max_age_days" ]; then
    printf 'STALE: %s — last changed %d days ago (> %d). Reconcile against current upstream guidance.\n' \
      "$rel" "$age_days" "$max_age_days" >&2
    stale=1
  else
    printf 'ok: %s — %d days\n' "$rel" "$age_days"
  fi
done

[ "$found" -eq 1 ] || printf 'no per-repo scaffold workflows present; nothing to check\n'

# Advisory: does Gemfile.lock's BUNDLED WITH match the bundler that will run?
#
# A mismatch is not a defect. Bundler installs the recorded version and restarts
# under it, so the resolution stays deterministic and local and CI agree -- the
# cost is one gem install per run, and the pinning is why they agree. Dependabot
# does not touch this field and no ecosystem does, so drift accumulates silently
# as the toolchain moves. Reported, never failed: `bundle update --bundler` is
# the fix when the noise justifies it.
#
# Resolving bundler needs care. A bare `bundle` finds the frozen macOS system
# Ruby 2.6, which cannot even report a version when the lockfile pins a bundler
# it lacks -- it exits with Gem::GemNotFoundException. So prefer Homebrew's
# portable Ruby, which is the toolchain AGENTS.md documents, and skip rather
# than guess when neither is usable.
bundled_with=""
if [ -f "$root/Gemfile.lock" ]; then
  bundled_with=$(awk '/^BUNDLED WITH$/ { getline; gsub(/[[:space:]]/, ""); print; exit }' \
    "$root/Gemfile.lock")
fi

# A bundler version, or empty if this candidate cannot report one.
is_version() {
  case "${1:-}" in
  "" | *[!0-9.]*) return 1 ;;
  *) return 0 ;;
  esac
}

if [ -n "$bundled_with" ]; then
  running=""
  fix_form=""
  # Prefer the toolchain AGENTS.md documents. PATH twice on purpose: BSD
  # `env -P` uses the alternate path only to locate the utility, so children
  # would fall back to system Ruby.
  if command -v brew > /dev/null 2>&1; then
    _rb="$(brew --repository)/Library/Homebrew/vendor/portable-ruby/current/bin"
    if [ -x "$_rb/bundle" ]; then
      running=$(env -P"$_rb:$PATH" PATH="$_rb:$PATH" bundle --version 2> /dev/null |
        awk 'NR == 1 { print $NF }')
      is_version "$running" || running=""
      [ -z "$running" ] || fix_form=portable
    fi
  fi
  # Fall back to whatever `bundle` PATH resolves, which is the right answer on a
  # Linux runner after setup-ruby. It self-excludes on macOS without needing a
  # platform test: there PATH finds the frozen system Ruby 2.6, which exits with
  # Gem::GemNotFoundException rather than printing a version whenever the
  # lockfile pins a bundler it does not have.
  if [ -z "$running" ] && command -v bundle > /dev/null 2>&1; then
    running=$(bundle --version 2> /dev/null | awk 'NR == 1 { print $NF }')
    is_version "$running" || running=""
    [ -z "$running" ] || fix_form=path
  fi
  if [ -z "$running" ]; then
    printf 'ok (skipped): Gemfile.lock pins bundler %s; no bundler here can report a version to compare\n' \
      "$bundled_with"
  elif [ "$running" = "$bundled_with" ]; then
    printf 'ok: bundler %s matches Gemfile.lock\n' "$running"
  else
    printf 'note: Gemfile.lock pins bundler %s but %s is installed. Bundler will\n' \
      "$bundled_with" "$running"
    printf '  self-install %s and restart, which is correct but costs a gem\n' "$bundled_with"
    printf '  install per run. To record %s instead:\n' "$running"
    if [ "$fix_form" = portable ]; then
      # The literal $PATH belongs in the printed command, not expanded here.
      # shellcheck disable=SC2016
      printf '    env -P"%s:$PATH" PATH="%s:$PATH" bundle update --bundler\n' "$_rb" "$_rb"
    else
      # Reached only because the PATH bundler answered, so recommending it is
      # not the trap it would be on macOS.
      printf '    bundle update --bundler\n'
    fi
  fi
fi

[ "$stale" -eq 0 ] || exit 1
