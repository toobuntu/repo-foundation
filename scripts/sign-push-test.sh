#!/bin/sh
# POSIX [ ] tests are deliberate (dash-compatible; ksh -n clean). brew style
# runs shellcheck with --shell=bash --enable=all, and its --fix mode
# AUTO-CONVERTS [ ] to [[ ]] unless the optional checks are disabled -- so
# this file carries the same exemption as the script under test. SC2015 is
# also exempted: the `check && ok-report || fail-report` assert idiom is
# deliberate (the && branch is a printf that cannot fail).
# shellcheck disable=SC2015,SC2249,SC2250,SC2292,SC2310,SC2311,SC2312
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Self-contained test harness for sign-push.sh (throwaway repos under
# mktemp, promote-from-isolated-test.sh pattern). Real signing via a
# throwaway SSH key; real pushes via a local bare "origin" -- no network.
# Covers every exit path: 0 (no-op states, sign+push, merge rebuild,
# --no-push), 2 (signed-but-unpushed hints), 3 (diverged origin,
# non-interactive -- the TTY confirm path needs a pty and is verified
# manually), 4 (own unsigned side), and the foreign-committer tolerance.
#
# Usage: sign-push-test.sh [path-to-script-under-test]

set -eu

SCRIPT=${1:-"$(cd "$(dirname "$0")" && pwd)/sign-push.sh"}
[ -f "$SCRIPT" ] || {
  printf 'no script under test: %s\n' "$SCRIPT" >&2
  exit 1
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/resign-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
# Without an allowedSignersFile, git reports ssh signatures as unverifiable
# (not "good"), which reads as unsigned on machines without the global
# signing config -- pin verification locally so %G? is deterministic.
printf 'me@test,other@test %s\n' "$(cat "$WORK/key.pub")" > "$WORK/allowed"
OUT="$WORK/out"
fails=0

new_repo() {
  _d=$(mktemp -d "$WORK/repo.XXXXXX")
  git -C "$_d" init -q -b main
  git -C "$_d" config user.email me@test
  git -C "$_d" config user.name Me
  git -C "$_d" config commit.gpgsign false
  git -C "$_d" config gpg.format ssh
  git -C "$_d" config user.signingkey "$WORK/key.pub"
  git -C "$_d" config gpg.ssh.allowedSignersFile "$WORK/allowed"
  printf '%s\n' "$_d"
}

c() { # c <repo> <msg> [extra git-commit args...]
  _r=$1
  _m=$2
  shift 2
  echo "$_m" >> "$_r/file"
  git -C "$_r" add file
  git -C "$_r" commit -q -m "$_m" "$@"
}

run() { # run <want-exit> <name> <repo> [script-flags...]
  _want=$1
  _name=$2
  _repo=$3
  shift 3
  set +e
  sh "$SCRIPT" "$@" "$_repo" > "$OUT" 2>&1
  _got=$?
  set -e
  if [ "$_got" -eq "$_want" ]; then
    printf 'ok   %s (exit %s)\n' "$_name" "$_got"
  else
    printf 'FAIL %s: exit %s, want %s\n' "$_name" "$_got" "$_want"
    sed 's/^/     /' "$OUT"
    fails=$((fails + 1))
  fi
}

expect_out() { # expect_out <pattern> <name>
  if grep -q "$1" "$OUT"; then
    printf 'ok   %s (output)\n' "$2"
  else
    printf 'FAIL %s: missing %s in output:\n' "$2" "$1"
    sed 's/^/     /' "$OUT"
    fails=$((fails + 1))
  fi
}

no_n_in() { # no_n_in <repo> <range> <name>
  if git -C "$1" log --format='%G?' "$2" | grep -qx N; then
    printf 'FAIL %s: unsigned commit remains in %s\n' "$3" "$2"
    fails=$((fails + 1))
  else
    printf 'ok   %s (all signed)\n' "$3"
  fi
}

# 1. empty repo
R=$(new_repo)
run 0 "empty repo" "$R"
expect_out 'no commits yet' "empty repo message"

# 2. detached HEAD
R=$(new_repo)
c "$R" one
git -C "$R" switch -q --detach HEAD
run 0 "detached HEAD" "$R"
expect_out 'detached HEAD' "detached message"

# 3. local-only, unsigned: re-sign, nothing to push
R=$(new_repo)
c "$R" one
c "$R" two
run 0 "local-only re-sign" "$R"
expect_out 'local-only repo' "local-only message"
no_n_in "$R" HEAD "local-only re-sign"

# 4/5/6/7/8 need an origin: bare repo wired as a real remote.
mk_origin() { # mk_origin <repo>
  _b=$(mktemp -d "$WORK/bare.XXXXXX")/o.git
  git init -q --bare "$_b"
  git -C "$1" remote add origin "$_b"
}

# 4. unsigned, branch unborn on origin: re-sign then push -u
R=$(new_repo)
c "$R" one
mk_origin "$R"
run 0 "re-sign + set-upstream push" "$R"
expect_out 'pushing with --set-upstream' "set-upstream message"
no_n_in "$R" HEAD "set-upstream push"
[ "$(git -C "$R" rev-parse HEAD)" = "$(git -C "$R" rev-parse origin/main)" ] &&
  printf 'ok   origin updated (set-upstream)\n' ||
  {
    printf 'FAIL origin not updated after set-upstream push\n'
    fails=$((fails + 1))
  }

# 5. unsigned on top of pushed history: re-sign then fast-forward push
c "$R" two
run 0 "re-sign + fast-forward push" "$R"
expect_out 'fast-forward' "fast-forward message"
[ "$(git -C "$R" rev-parse HEAD)" = "$(git -C "$R" rev-parse origin/main)" ] &&
  printf 'ok   origin updated (ff)\n' ||
  {
    printf 'FAIL origin not updated after ff push\n'
    fails=$((fails + 1))
  }

# 6. fully signed and current: exit 0, no push needed
run 0 "signed and current" "$R"
expect_out 'origin/main is current' "current message"

# 7. fully signed, ahead (signed commit): exit 2 + push hint
c "$R" three --gpg-sign
run 2 "signed-ahead hint" "$R"
expect_out 'To push: git -C' "ahead hint"
git -C "$R" push -q origin main # settle for next case

# 8. fully signed, new branch unborn on origin: exit 2 + set-upstream hint
git -C "$R" switch -qc topic
c "$R" t1 --gpg-sign
run 2 "signed new-branch hint" "$R"
expect_out 'push --set-upstream origin topic' "new-branch hint"
git -C "$R" switch -q main

# 9. re-signed but origin diverged: exit 3 + lease hint, no push
R=$(new_repo)
c "$R" one
mk_origin "$R"
git -C "$R" push -qu origin main
alt=$(git -C "$R" commit-tree "HEAD^{tree}" -p HEAD -m alt)
git -C "$R" update-ref refs/remotes/origin/main "$alt" # origin moved elsewhere
c "$R" two
run 3 "diverged origin" "$R"
expect_out 'DIVERGED; not force-pushing' "diverged message"
expect_out 'force-with-lease' "lease hint"

# 10. merge in range, side pushed: spine rebuilt, merge preserved, push ok
R=$(new_repo)
c "$R" base
mk_origin "$R"
git -C "$R" push -qu origin main
git -C "$R" switch -qc side
echo s > "$R/s"
git -C "$R" add s
git -C "$R" commit -qm sidework
git -C "$R" push -qu origin side
git -C "$R" switch -q main
c "$R" spine1
git -C "$R" merge -q --no-ff --no-edit side
c "$R" spine2
orig=$(git -C "$R" rev-parse HEAD)
# The rebuilt merge must keep its original author identity and date
# (commit-tree takes the author from the environment; the script exports it).
merge_author_before=$(git -C "$R" log -1 --format='%an <%ae> %aD' \
  "$(git -C "$R" rev-list --merges --max-count=1 HEAD)")
run 0 "merge-preserving rebuild + push" "$R"
expect_out 'rebuilding spine' "rebuild message"
merge_author_after=$(git -C "$R" log -1 --format='%an <%ae> %aD' \
  "$(git -C "$R" rev-list --merges --max-count=1 HEAD)")
[ "$merge_author_after" = "$merge_author_before" ] &&
  printf 'ok   merge author preserved\n' ||
  {
    printf 'FAIL merge author drifted: %s -> %s\n' \
      "$merge_author_before" "$merge_author_after"
    fails=$((fails + 1))
  }
[ "$(git -C "$R" rev-list --merges --count origin/main..HEAD)" = 0 ] || true
[ "$(git -C "$R" rev-list --merges --count HEAD)" = 1 ] &&
  printf 'ok   merge topology preserved\n' ||
  {
    printf 'FAIL merge topology lost\n'
    fails=$((fails + 1))
  }
git -C "$R" diff --quiet "$orig" HEAD &&
  printf 'ok   content identical after rebuild\n' ||
  {
    printf 'FAIL content drifted after rebuild\n'
    fails=$((fails + 1))
  }
[ "$(git -C "$R" rev-parse HEAD)" = "$(git -C "$R" rev-parse origin/main)" ] &&
  printf 'ok   origin updated (rebuild)\n' ||
  {
    printf 'FAIL origin not updated after rebuild\n'
    fails=$((fails + 1))
  }
no_n_in "$R" "origin/side..HEAD" "rebuild signatures (side excluded)"

# 11. merge in range, OWN unsigned side: exit 4 + recipe, repo untouched
R=$(new_repo)
c "$R" one
git -C "$R" switch -qc side
echo s > "$R/s"
git -C "$R" add s
git -C "$R" commit -qm sidework
git -C "$R" switch -q main
c "$R" three
git -C "$R" merge -q --no-ff --no-edit side
orig=$(git -C "$R" rev-parse HEAD)
run 4 "own unsigned side refused" "$R"
expect_out 'git -C .* switch side' "recipe names the side branch"
[ "$(git -C "$R" rev-parse HEAD)" = "$orig" ] &&
  printf 'ok   repo untouched on refusal\n' ||
  {
    printf 'FAIL repo mutated despite refusal\n'
    fails=$((fails + 1))
  }

# 12. merge in range, FOREIGN unsigned side: tolerated with a note.
# The shared base is signed: otherwise the side's ancestry would carry OUR
# unsigned base commit and the exit-4 refusal would (correctly) fire.
R=$(new_repo)
c "$R" one --gpg-sign
git -C "$R" switch -qc side
echo s > "$R/s"
git -C "$R" add s
git -C "$R" -c user.email=other@test -c user.name=Other commit -qm foreignwork
git -C "$R" switch -q main
c "$R" three
git -C "$R" merge -q --no-ff --no-edit side
run 0 "foreign unsigned side tolerated" "$R"
expect_out 'leaving it (only the tip is gated)' "foreign-side note"
expect_out 'rebuilding spine' "rebuild proceeded past foreign side"

# 13. --no-push: sign only, print the push command, origin untouched
R=$(new_repo)
c "$R" one
mk_origin "$R"
git -C "$R" push -qu origin main
c "$R" two
run 0 "--no-push signs without pushing" "$R" --no-push
expect_out 'NOT pushing' "--no-push message"
expect_out 'To push: git -C' "--no-push hint"
# Scope to the unpushed range: commit "one" was pushed unsigned above, and
# published history is deliberately never rewritten.
no_n_in "$R" "origin/main..HEAD" "--no-push signatures"
[ "$(git -C "$R" rev-parse origin/main)" != "$(git -C "$R" rev-parse HEAD)" ] &&
  printf 'ok   origin untouched under --no-push\n' ||
  {
    printf 'FAIL origin moved despite --no-push\n'
    fails=$((fails + 1))
  }

printf '\n%s\n' "----------------------------------------"
if [ "$fails" -eq 0 ]; then
  printf 'ALL TESTS PASSED\n'
else
  printf '%s FAILURE(S)\n' "$fails"
  exit 1
fi
