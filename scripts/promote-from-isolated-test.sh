#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# promote-from-isolated-test.sh — self-contained test harness for
# promote-from-isolated.sh. Builds throwaway live/clone repo pairs under
# mktemp and simulates the re-sign SHA divergence with unsigned rewrites
# (same patch-ids, new SHAs). Exits non-zero on any failure; safe to wire
# into CI. Override the script under test with PROMOTE_SCRIPT=<path>.

set -uo pipefail

SCRIPT=${PROMOTE_SCRIPT:-$(cd "$(dirname "$0")" && pwd)/promote-from-isolated.sh}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/promote-test.XXXXXX")
trap 'rm -rf "${ROOT}"' EXIT
LIVE="$ROOT/live" CLONE="$ROOT/clone"
LOGS="$ROOT/logs"
mkdir -p "$LOGS"
pass=0 fail=0

g() { git -C "$1" -c commit.gpgsign=false -c user.name=t -c user.email=t@example.com "${@:2}"; }
commit() { # repo file msg
  printf '%s\n' "$3" >>"$1/$2"
  g "$1" add "$2"
  g "$1" commit --quiet --no-gpg-sign -m "$3"
}
check() { # desc expected_status actual_status
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    printf 'PASS: %s\n' "$1"
  else
    fail=$((fail + 1))
    printf 'FAIL: %s (expected %s got %s)\n' "$1" "$2" "$3"
  fi
}

# --- setup: live repo with base, clone taken from it, agent commits c1 c2
mkdir -p "$LIVE"
g "$LIVE" init --quiet -b main
commit "$LIVE" base.txt "base"
git clone --quiet --no-hardlinks "$LIVE" "$CLONE" 2>/dev/null
g "$CLONE" remote remove origin
g "$CLONE" switch --quiet -c feat
commit "$CLONE" a.txt "feat: add a"
commit "$CLONE" b.txt "feat: add b"

# --- 1. first promotion picks both commits, oldest first
g "$LIVE" switch --quiet -c feat
(cd "$LIVE" && "$SCRIPT" --yes "$CLONE" feat >"$LOGS/1.log" 2>&1)
check "first promotion exits 0" 0 $?
n=$(g "$LIVE" rev-list --count main..feat)
check "first promotion applied 2 commits" 2 "$n"
order=$(g "$LIVE" log --reverse --format='%s' main..feat | tr '\n' '|')
check "commits applied in original order" "feat: add a|feat: add b|" "$order"

# --- 2. simulate re-sign: rewrite live feat with same patches, new SHAs
c1=$(g "$LIVE" rev-parse feat~1) c2=$(g "$LIVE" rev-parse feat)
g "$LIVE" reset --quiet --hard main
g "$LIVE" cherry-pick --quiet --no-gpg-sign "$c1" "$c2" >/dev/null 2>&1
new_c2=$(g "$LIVE" rev-parse feat)
if [ "$new_c2" != "$c2" ]; then rewrote=0; else rewrote=1; fi
check "re-sign simulation rewrote SHAs" 0 "$rewrote"

# --- 3. idempotent: nothing to promote after divergence
(cd "$LIVE" && "$SCRIPT" --yes "$CLONE" feat >"$LOGS/3.log" 2>&1)
check "idempotent run exits 0" 0 $?
grep -q "Nothing to promote" "$LOGS/3.log"
check "idempotent run reports nothing to promote" 0 $?

# --- 4. follow-up batch: clone adds c3; only c3 is picked
commit "$CLONE" c.txt "feat: add c"
(cd "$LIVE" && "$SCRIPT" --yes "$CLONE" feat >"$LOGS/4.log" 2>&1)
check "follow-up promotion exits 0" 0 $?
n=$(g "$LIVE" rev-list --count main..feat)
check "live has exactly 3 commits (no duplicates)" 3 "$n"
grep -q "Promoted 1 commit" "$LOGS/4.log"
check "reports exactly 1 promoted commit" 0 $?

# --- 4b. dependent commits: the second edits the same file as the first,
#         so a newest-first replay cannot apply — order bugs fail here
commit "$CLONE" dep.txt "feat: dep line1"
commit "$CLONE" dep.txt "feat: dep line2"
(cd "$LIVE" && "$SCRIPT" --yes "$CLONE" feat >"$LOGS/4b.log" 2>&1)
check "dependent-commit promotion exits 0" 0 $?
content=$(tr '\n' '|' <"$LIVE/dep.txt" 2>/dev/null)
check "dependent edits applied in order" "feat: dep line1|feat: dep line2|" "$content"
n=$(g "$LIVE" rev-list --count main..feat)
check "live has exactly 5 commits after dependent batch" 5 "$n"

# --- 5. subject collision: amend the promoted tip's content in live
#        (its patch-id now differs from the clone copy), clone adds c4
printf 'tweak\n' >>"$LIVE/c.txt"
g "$LIVE" add c.txt
g "$LIVE" commit --quiet --no-gpg-sign --amend --no-edit
commit "$CLONE" d.txt "feat: add d"
(cd "$LIVE" && "$SCRIPT" --yes "$CLONE" feat >"$LOGS/5.log" 2>&1)
check "amended-pair run exits 1" 1 $?
grep -q "subject collision" "$LOGS/5.log"
check "amended-pair run names the collision" 0 $?
n=$(g "$LIVE" rev-list --count main..feat)
check "nothing was applied on collision" 5 "$n"

# --- 6. merge-commit gate (fresh pair)
LIVE2="$ROOT/live2" CLONE2="$ROOT/clone2"
mkdir -p "$LIVE2"
g "$LIVE2" init --quiet -b main
commit "$LIVE2" base.txt "base"
git clone --quiet --no-hardlinks "$LIVE2" "$CLONE2" 2>/dev/null
g "$CLONE2" remote remove origin
g "$CLONE2" switch --quiet -c feat
commit "$CLONE2" a.txt "feat: add a"
g "$CLONE2" switch --quiet -c side main
commit "$CLONE2" s.txt "side work"
g "$CLONE2" switch --quiet feat
g "$CLONE2" merge --quiet --no-gpg-sign --no-edit side >/dev/null 2>&1
g "$LIVE2" switch --quiet -c feat
(cd "$LIVE2" && "$SCRIPT" --yes "$CLONE2" feat >"$LOGS/6.log" 2>&1)
check "merge-commit run exits 1" 1 $?
grep -q "must be linear" "$LOGS/6.log"
check "merge-commit run explains linearity" 0 $?

# --- 7. no TTY and no --yes: abort before applying (fresh linear branch)
g "$CLONE2" switch --quiet -c feat2 main
commit "$CLONE2" b.txt "feat: add b"
g "$LIVE2" switch --quiet -c feat2 main
(cd "$LIVE2" && "$SCRIPT" "$CLONE2" feat2 </dev/null >"$LOGS/7.log" 2>&1)
check "no-TTY without --yes exits 1" 1 $?
grep -q "re-run with --yes" "$LOGS/7.log"
check "no-TTY guidance shown" 0 $?

# --- 8. wrong-branch guard
(cd "$LIVE2" && git switch --quiet main && "$SCRIPT" --yes "$CLONE2" feat >"$LOGS/8.log" 2>&1)
check "wrong-branch run exits 1" 1 $?
grep -q "git switch feat" "$LOGS/8.log"
check "wrong-branch hint shown" 0 $?

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
