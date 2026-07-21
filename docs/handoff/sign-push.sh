#!/bin/sh
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# sign-push.sh -- re-sign the unpushed, unsigned commits a sandboxed
# agent left behind, then push what was re-signed. For each repo argument
# (default: the current repo):
#
#   1. find the oldest UNSIGNED commit not yet on any remote -- so published
#      history is never rewritten, and a remoteless repo re-signs only its
#      unsigned tip rather than its already-signed base;
#   2. if one exists: rebase from just before it, re-signing each replayed
#      commit, then push the branch -- --set-upstream when origin does not
#      know the branch yet, a fast-forward push when origin still descends
#      it. A diverged origin is NEVER force-pushed automatically: force is
#      a human call org-wide, and divergence here means origin holds work
#      this checkout does not -- the script exits 3 with the lease-pinned
#      command to run after inspecting. A local-only repo (no origin
#      remote) re-signs and stops with a note.
#   3. if nothing needed re-signing: this is NOT a stand-in for git push --
#      nothing is pushed. Up to date: says so (exit 0). Branch ahead of or
#      unknown to origin: prints the exact push command to run and exits 2.
#
# A merge commit inside the rewrite range gets special handling: git rebase
# (even --rebase-merges) would linearize it or replay its merged-in side,
# minting patch-id duplicates. Instead the first-parent spine is rebuilt --
# ordinary commits cherry-picked and amend-signed, each merge reconstructed
# with commit-tree (same tree, same message, same non-first parents; the
# merged-in side is referenced, never replayed) and amend-signed. Local,
# conflict-free by construction (trees are reused byte-for-byte), and
# reversible via the restore command printed before anything moves.
#
# Exit codes: 0 done or nothing to do; 2 push pending (nothing was
# re-signed); 3 re-signed but origin diverged (manual force required);
# 4 a merge's incoming side carries YOUR unsigned unpushed commits (an
# exact sign-that-branch-first recipe is printed; unsigned commits by
# other committers are tolerated with a note, since the pre-push gate
# rejects only an unsigned tip).
# Detached HEAD is skipped with a note. The .githooks/pre-push gate is the
# backstop -- it rejects any unsigned commit this misses. POSIX sh; no
# bashisms.

set -eu

resign_one() {
  repo_dir=$1
  branch=$(git -C "$repo_dir" branch --show-current)

  if ! git -C "$repo_dir" rev-parse --quiet --verify HEAD > /dev/null 2>&1; then
    printf '%s (%s): no commits yet; skipping\n' "$repo_dir" "$branch"
    return 0
  fi

  if [ -z "$branch" ]; then
    printf '%s: detached HEAD; nothing to push, skipping\n' "$repo_dir"
    return 0
  fi

  has_origin=1
  git -C "$repo_dir" config --get remote.origin.url > /dev/null 2>&1 || has_origin=0
  remote_ref="refs/remotes/origin/${branch}"

  # Oldest unsigned commit among those not on any remote. The pipeline prints
  # the first match and breaks; the command substitution captures it.
  oldest_unsigned=$(
    git -C "$repo_dir" rev-list --reverse HEAD --not --remotes |
      while IFS= read -r oid; do
        if [ "$(git -C "$repo_dir" log -1 --format='%G?' "$oid")" = N ]; then
          printf '%s\n' "$oid"
          break
        fi
      done
  )

  if [ -z "$oldest_unsigned" ]; then
    # Nothing was re-signed, so nothing is pushed: publishing here would make
    # this a generic-push tool. Report the state; when a push is still
    # pending, hand over the exact command and exit 2 so the pending state
    # cannot be missed.
    if [ "$has_origin" -eq 0 ]; then
      printf '%s (%s): already signed; local-only repo (no origin remote), nothing to push\n' \
        "$repo_dir" "$branch"
      return 0
    fi
    if ! git -C "$repo_dir" rev-parse --quiet --verify "$remote_ref" > /dev/null 2>&1; then
      printf '%s (%s): already signed; nothing re-signed, so NOT pushing the new branch.\n' \
        "$repo_dir" "$branch" >&2
      printf '  To push: git -C %s push --set-upstream origin %s\n' "$repo_dir" "$branch" >&2
      return 2
    fi
    if [ "$(git -C "$repo_dir" rev-parse HEAD)" = "$(git -C "$repo_dir" rev-parse "$remote_ref")" ]; then
      printf '%s (%s): already signed; origin/%s is current, nothing to push\n' \
        "$repo_dir" "$branch" "$branch"
      return 0
    fi
    printf '%s (%s): already signed; nothing re-signed, so NOT pushing (origin/%s differs).\n' \
      "$repo_dir" "$branch" "$branch" >&2
    printf '  To push: git -C %s push origin HEAD:%s\n' "$repo_dir" "$branch" >&2
    return 2
  fi

  if git -C "$repo_dir" rev-parse --quiet --verify "${oldest_unsigned}^" > /dev/null 2>&1; then
    range_base="${oldest_unsigned}^"
    range_spec="${range_base}..HEAD"
  else
    range_base=""
    range_spec="HEAD"
  fi

  merge_count=$(git -C "$repo_dir" rev-list --merges --count "$range_spec")
  if [ "$merge_count" -eq 0 ]; then
    if [ -n "$range_base" ]; then
      git -C "$repo_dir" rebase --exec 'git commit --amend --no-edit --gpg-sign' "$range_base"
    else
      git -C "$repo_dir" rebase --root --exec 'git commit --amend --no-edit --gpg-sign'
    fi
  else
    # Merge-preserving re-sign: rebuild the first-parent spine. Ordinary
    # commits are cherry-picked and amend-signed; each merge is rebuilt via
    # commit-tree reusing its exact tree, message, and non-first parents,
    # then amend-signed (amend keeps all parents). The merged-in side is
    # referenced, never replayed, so nothing duplicates and nothing can
    # conflict; every step is local and undone by the restore line below.
    # The rebuild re-signs the first-parent spine only; a merge's incoming
    # side is kept by reference. If that side itself carries unsigned
    # unpushed commits (it forked from unsigned history, or is an unsigned
    # topic), they would stay reachable unsigned -- refuse and say which
    # branch to sign first. In the sanctioned workflow the incoming side is
    # already pushed, so its ancestry is remote-reachable and passes.
    me=$(git -C "$repo_dir" config user.email 2> /dev/null) || me=""
    for m in $(git -C "$repo_dir" rev-list --merges "$range_spec"); do
      mparents=$(git -C "$repo_dir" log -1 --format='%P' "$m")
      for p in ${mparents#* }; do
        for oid in $(git -C "$repo_dir" rev-list "$p" --not --remotes); do
          [ "$(git -C "$repo_dir" log -1 --format='%G?' "$oid")" = N ] || continue
          committer=$(git -C "$repo_dir" log -1 --format='%ce' "$oid")
          if [ -n "$me" ] && [ "$committer" != "$me" ]; then
            # Foreign unsigned history (e.g. merged upstream work): tolerated.
            # The pre-push gate rejects only an unsigned TIP, and signing
            # someone else's commits is not this script's business.
            printf '%s (%s): note: merge %s carries unsigned commit %s by %s; leaving it (only the tip is gated).\n' \
              "$repo_dir" "$branch" "$(git -C "$repo_dir" rev-parse --short "$m")" \
              "$(git -C "$repo_dir" rev-parse --short "$oid")" "$committer"
            continue
          fi
          side_branch=$(git -C "$repo_dir" branch --format='%(refname:short)' --contains "$oid" |
            grep -Fxv "$branch" | head -n 1) || side_branch=""
          printf '%s (%s): merge %s brings in your unsigned unpushed commit %s; refusing.\n' \
            "$repo_dir" "$branch" "$(git -C "$repo_dir" rev-parse --short "$m")" \
            "$(git -C "$repo_dir" rev-parse --short "$oid")" >&2
          if [ -n "$side_branch" ]; then
            printf '  Recipe -- sign that branch, then rerun here:\n' >&2
            printf '    git -C %s switch %s\n' "$repo_dir" "$side_branch" >&2
            printf '    %s %s\n' "$0" "$repo_dir" >&2
            printf '    git -C %s switch %s\n' "$repo_dir" "$branch" >&2
            printf '    %s %s\n' "$0" "$repo_dir" >&2
          else
            printf '  No local branch holds it; put one on it, sign, then rerun here:\n' >&2
            printf '    git -C %s branch resign-side %s\n' "$repo_dir" "$oid" >&2
            printf '    git -C %s switch resign-side\n' "$repo_dir" >&2
            printf '    %s %s\n' "$0" "$repo_dir" >&2
            printf '    git -C %s switch %s\n' "$repo_dir" "$branch" >&2
            printf '    %s %s\n' "$0" "$repo_dir" >&2
          fi
          return 4
        done
      done
    done

    orig_head=$(git -C "$repo_dir" rev-parse HEAD)
    printf '%s (%s): %s merge(s) in range; rebuilding spine with signatures.\n' \
      "$repo_dir" "$branch" "$merge_count"
    printf '  If interrupted, restore with: git -C %s switch -C %s %s\n' \
      "$repo_dir" "$branch" "$orig_head"
    cur=""
    [ -n "$range_base" ] && cur=$(git -C "$repo_dir" rev-parse "$range_base")
    for c in $(git -C "$repo_dir" rev-list --reverse --first-parent "$range_spec"); do
      parents=$(git -C "$repo_dir" log -1 --format='%P' "$c")
      case "$parents" in
      *' '*)
        # Merge: same tree and message, first parent replaced with the
        # rebuilt spine, every other parent kept.
        pargs="-p $cur"
        for p in ${parents#* }; do
          pargs="$pargs -p $p"
        done
        # shellcheck disable=SC2086  # pargs is a deliberate word-split flag list
        new=$(git -C "$repo_dir" log -1 --format='%B' "$c" |
          git -C "$repo_dir" commit-tree "${c}^{tree}" $pargs)
        git -C "$repo_dir" switch --quiet --detach "$new"
        ;;
      *)
        if [ -z "$cur" ]; then
          # Unsigned root commit: rebuild it parentless.
          new=$(git -C "$repo_dir" log -1 --format='%B' "$c" |
            git -C "$repo_dir" commit-tree "${c}^{tree}")
          git -C "$repo_dir" switch --quiet --detach "$new"
        else
          git -C "$repo_dir" switch --quiet --detach "$cur"
          git -C "$repo_dir" cherry-pick --allow-empty "$c" > /dev/null
        fi
        ;;
      esac
      git -C "$repo_dir" commit --amend --no-edit --gpg-sign
      cur=$(git -C "$repo_dir" rev-parse HEAD)
    done
    git -C "$repo_dir" switch --quiet -C "$branch" "$cur"
    printf '%s (%s): spine rebuilt; commits signed, merge topology preserved\n' \
      "$repo_dir" "$branch"
  fi

  # Push what was just re-signed.
  if [ "$has_origin" -eq 0 ]; then
    printf '%s (%s): re-signed; local-only repo (no origin remote), nothing to push\n' \
      "$repo_dir" "$branch"
    return 0
  fi
  if ! git -C "$repo_dir" rev-parse --quiet --verify "$remote_ref" > /dev/null 2>&1; then
    printf '%s (%s): re-signed; origin has no such branch, pushing with --set-upstream\n' \
      "$repo_dir" "$branch"
    git -C "$repo_dir" push --set-upstream origin "HEAD:${branch}"
  elif git -C "$repo_dir" merge-base --is-ancestor "$remote_ref" HEAD; then
    printf '%s (%s): re-signed; pushing (fast-forward)\n' "$repo_dir" "$branch"
    git -C "$repo_dir" push origin "HEAD:${branch}"
  else
    # The rebase only rewrites commits absent from every remote, so origin
    # remains an ancestor after a normal re-sign (fast-forward above).
    # Reaching here means origin holds work this checkout does not (another
    # machine, a bot, a fetched review push). Force-pushing that away is a
    # human call, org-wide -- hand over the lease-pinned command instead.
    printf '%s (%s): re-signed, but origin/%s DIVERGED; not force-pushing.\n' \
      "$repo_dir" "$branch" "$branch" >&2
    printf '  Inspect what origin has that you do not: git -C %s log --oneline HEAD..%s\n' \
      "$repo_dir" "$remote_ref" >&2
    printf '  If only your own rewritten history differs, push with:\n' >&2
    printf '  git -C %s push --force-with-lease=refs/heads/%s:%s origin HEAD:%s\n' \
      "$repo_dir" "$branch" "$(git -C "$repo_dir" rev-parse "$remote_ref")" "$branch" >&2
    return 3
  fi
}

if [ "$#" -eq 0 ]; then
  set -- "$PWD"
fi

rc=0
for repo in "$@"; do
  resign_one "$repo" || rc=$?
done
exit "$rc"
