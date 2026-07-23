<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Handoff — reorg reference fixup (2026-06-16)

After the `git-reorg` move (relationship-based tree under `~/devel/claude/desktop/`), path references across the repos and the `workspace/` planning docs point at the old flat layout. This handoff is the runbook for fixing them, plus the `git-reorg` follow-ups (dormant default, memory rekey) surfaced while planning.

Companion tool: [`reorg-ref-rewrite.ksh`](./reorg-ref-rewrite.ksh) — a one-off, boundary-aware path rewriter (validated; see §5).

> **Status (2026-06-17): COMPLETE.** All in-scope reference fixups are applied and §9-verified across the five repos' tracked files, the live `workspace/` docs, and repo-foundation's docs. Per-repo commits are made (unsigned, on branches) and PRs are open — babble#6, homebrew-cask-tools#43, zman-didan#3, blackoutd#24; bob-book is committed locally (no remote). **Remaining is maintainer-only:** re-sign + push the branches, fold repo-foundation's `usage.md` fix into that repo's bootstrap commit, then resume the W1 review phase. Per-step status in §8; the (separate) loose ends in §10.

## 1. Decisions (this session)

- **Dormant bucket → `_dormant`** (was `dormant`). It stays *nested* under `toobuntu/` (dormant is a *state* of your originals, per the git-reorg design — not a top-level bucket). The leading `_` is the conventional "special/meta, not a regular entry" marker, matches your existing `_claude-config-baseline.deprecated`, and sorts the bucket apart from the lowercase live-repo dirs. Chosen over a numeric `NN-` prefix: `NN-` signals an *ordered sequence* (its run-parts use, `10-go`/`20-objc`, encodes execution order — which buckets don't have). A future `archived` bucket is `_archived`. **One variable to change** (`REORG_DORMANT` + one `mv` + a rewrite re-run) for `z_dormant` (sorts last, keeps active repos on top) or plain `dormant`.
- **`didan` → `zman-didan`** in all docs (matches the new dir + the GitHub repo name), per your choice.
- **Rewrite scope** (your selections): gitignored working docs **+** tracked/committed docs **+** live `workspace/` docs. **Excluded:** the dated historical snapshots in `workspace/` (rewriting them would falsify point-in-time records).

## 2. The move map

All paths are under `~/devel/claude/desktop/`. Old (flat) → new (bucketed):

| Old | New |
| --- | --- |
| `blackoutd` | `toobuntu/blackoutd` |
| `babble` | `toobuntu/babble` |
| `babble-refactor-modular` (worktree) | `toobuntu/babble-refactor-modular` |
| `bob-book` | `toobuntu/bob-book` |
| `cert-automation` | `toobuntu/cert-automation` |
| `dot-github` | `toobuntu/dot-github` |
| `homebrew-cask-tools` | `toobuntu/homebrew-cask-tools` |
| `repo-foundation` | `toobuntu/repo-foundation` |
| `didan` | `toobuntu/zman-didan` ⚠️ renamed |
| `powerstatus` | `toobuntu/_dormant/powerstatus` |
| `displayrecommitd` | `toobuntu/_dormant/displayrecommitd` |
| `inject_edid` | `toobuntu/_dormant/inject_edid` |
| `blackoutd.claude_desktop` | `toobuntu/_dormant/blackoutd.claude_desktop` |
| `brew` | `fork/Homebrew/brew` |
| `adrs` | `reference/joshrotenberg/adrs` |
| `mdbook-lint` | `reference/joshrotenberg/mdbook-lint` |
| `anti-trojan-source` | `reference/lirantal/anti-trojan-source` |
| `chabad-org-zmanim` | `reference/toolsforshlichus/chabad-org-zmanim` |

**Do NOT touch** (not moved / already correct): `workspace/`, `toobuntu/*`, `fork/*`, `reference/*`, `adrs-formula` (non-git staging dir, still top-level), `adrs.toml`, `_claude-config-baseline*`.

## 3. Scale (stale refs, boundary-aware count)

- `toobuntu/` repos: ~150 occurrences. `workspace/`: ~195 (mostly `brew` ×61, `repo-foundation` ×38, `homebrew-cask-tools` ×32, `babble` ×27, `blackoutd` ×21) — **of which only the live docs are in scope**.
- Most are in gitignored working docs; a tracked subset needs PRs (§6).

## 4. Status (done this session)

- `repo-foundation/docs/usage.md` — fixed (3 path refs + a now-broken `desktop/*` glob → `desktop/toobuntu/*`). On branch `feature/reorg-reference-fixup`, **uncommitted** (repo is pre-initial- commit; fold into the bootstrap commit or commit separately).
- `reorg-ref-rewrite.ksh` — written and validated against the tricky boundary cases.
- **Staged in `/tmp/claude/reorg-staged/`** (apply with `cp -p`):
  - the 5 live `workspace/` docs with stale refs (`master-plan.md`, `next.md`, `repo-foundation/{bootstrap-actions,bootstrap-prompt,w1-hooks-review-prompt}.md`) — already path-rewritten.
  - `git-reorg` — `REORG_DORMANT` default → `_dormant`, plus an opt-in `--rekey-memory` (slug rekey + `~/.claude.json` map update). Parses clean (`ksh -n`).

  ```sh
  D=/tmp/claude/reorg-staged
  cp -p "$D"/workspace/master-plan.md "$D"/workspace/next.md \
        ~/devel/claude/desktop/workspace/
  cp -p "$D"/workspace/repo-foundation/*.md \
        ~/devel/claude/desktop/workspace/repo-foundation/
  cp -p "$D"/git-reorg ~/devel/claude/desktop/workspace/git-reorg
  ```

## 5. Running the rewrite

Default is dry-run (diff); `--apply` writes in place. The caller chooses the paths — that is how snapshots stay excluded.

```sh
S=~/devel/claude/desktop/toobuntu/repo-foundation/docs/handoff/archive/reorg-ref-rewrite.ksh

# Repos (re-root a session at toobuntu/ first — see §8). Dry-run, then apply:
ksh "$S" ~/devel/claude/desktop/toobuntu        # review the diff
ksh "$S" --apply ~/devel/claude/desktop/toobuntu

# Live workspace docs ONLY (excludes dated/.dN/superseded snapshots).
# Review the file list before --apply:
find ~/devel/claude/desktop/workspace -maxdepth 2 -type f \
     \( -name '*.md' -o -name 'git-reorg' \) \
     ! -name '*.2026-*' ! -name '*.snapshot.*' \
     ! -name '*.d[0-9]*' ! -name '*-d[0-9]*' ! -name '*.superseded.*' -print
# then pass that set to:  ksh "$S" --apply <files...>
```

Boundary rules and the one known gap (a token immediately followed by `.` is skipped, to protect `adrs.toml` / `blackoutd.claude_desktop`) are documented in the script header. Post-apply verification grep in §9.

## 6. Tracked files → PRs (per repo)

Gitignored edits are local-only (no VCS action). These **tracked** files need a branch + unsigned commit + PR (you re-sign before push):

| Repo | Tracked files (stale-ref count) |
| --- | --- |
| babble | `docs/handoff.md` (15), `docs/preservation-actions.md` (13), `docs/preservation-prompt.md` (2), `stash/code-archive/README.md` (7) |
| blackoutd | `docs/claude-code-isolation.md` (10) ⚠️ leak |
| bob-book | `COWORK-SETUP-HANDOFF.md` (2), `SESSION-HANDOFF.md` (2) |
| homebrew-cask-tools | `docs/decisions/0001-pipx-for-ci-python-tools.md` (2) ⚠️ leak |
| zman-didan | `docs/handoff/chat-claude-next-session.md` (1), `docs/handoff/chat-claude.md` (1) |

⚠️ **leak (genericize — approved)**: `claude-code-isolation.md` and the homebrew-cask-tools ADR are committed, contributor-visible docs that bake in absolute machine paths. Per maintainer decision, **genericize** these (e.g. `<repo-root>`, `$DEVEL/...`, or a relative path) rather than just re-pathing — do it in the same per-repo PR.

## 7. git-reorg follow-ups

### 7a. Default

`workspace/git-reorg` line 40: `: "${REORG_DORMANT:=dormant}"` → `: "${REORG_DORMANT:=_dormant}"`. (Also rename the existing dir once: `mv ~/devel/claude/desktop/toobuntu/dormant ~/devel/claude/desktop/toobuntu/_dormant`.)

### 7b. Immediate one-time memory rekey (current stale slugs)

CC project memory keys on the cwd via the slug transform `s/[^A-Za-z0-9]/-/g` over the absolute path (verified against the 3 existing slugs). The reorg left two stale slugs; their **memory contents are clean** (no path refs), so a plain rename suffices. New slugs don't exist yet, so `mv` won't collide:

```sh
P=~/.claude/projects
mv "$P/-Users-todd-devel-claude-desktop-blackoutd" \
   "$P/-Users-todd-devel-claude-desktop-toobuntu-blackoutd"
mv "$P/-Users-todd-devel-claude-desktop-didan" \
   "$P/-Users-todd-devel-claude-desktop-toobuntu-zman-didan"

# Rekey the ~/.claude.json projects map (BACK UP FIRST):
cp ~/.claude.json ~/.claude.json.bak.$(date +%Y%m%d-%H%M%S)
for pair in \
  "/Users/todd/devel/claude/desktop/blackoutd|/Users/todd/devel/claude/desktop/toobuntu/blackoutd" \
  "/Users/todd/devel/claude/desktop/didan|/Users/todd/devel/claude/desktop/toobuntu/zman-didan"; do
  o=${pair%|*}; n=${pair#*|}
  jq --arg o "$o" --arg n "$n" \
    'if .projects[$o] then .projects[$n]=.projects[$o] | del(.projects[$o]) else . end' \
    ~/.claude.json > ~/.claude.json.tmp && mv ~/.claude.json.tmp ~/.claude.json
done
```

Maintainer-run for the `~/.claude.json` step specifically: the sandbox **does** allow agent writes under `~/.claude/projects/**` (so the project-memory slug `mv`s are agent-doable), but `~/.claude.json` is outside the write allowlist — so its projects-map rekey, with the backup, stays a maintainer step.

### 7c. Teach git-reorg (future moves)

Add to `workspace/git-reorg` so future `move --apply` rekeys memory:

```ksh
REKEY_MEM=false          # new flag, default off (touches global CC state)
# ... add to main(): --rekey-memory) REKEY_MEM=true; shift ;;

function slug { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

# rekey_memory <old_abs> <new_abs>
function rekey_memory {
  typeset oldabs=$1 newabs=$2 proj=$HOME/.claude/projects os ns m j
  os=$(slug "$oldabs"); ns=$(slug "$newabs")
  [[ -d $proj/$os ]] || { warn "no project memory for $oldabs"; return 0; }
  if [[ -e $proj/$ns ]]; then            # CC already created the new slug
    warn "target slug exists ($ns); merging"
    mkdir -p "$proj/$ns/memory"
    for m in "$proj/$os/memory/"*; do    # ksh93: guard, no nullglob option
      [[ -e $m ]] || continue
      [[ ${m##*/} == MEMORY.md && -e $proj/$ns/memory/MEMORY.md ]] \
        && { warn "MEMORY.md conflict; manual merge: $m"; continue; }
      mv -n "$m" "$proj/$ns/memory/"
    done
    for j in "$proj/$os/"*.jsonl; do
      [[ -e $j ]] || continue
      mv -n "$j" "$proj/$ns/" 2>/dev/null || true
    done
    rmdir "$proj/$os/memory" "$proj/$os" 2>/dev/null \
      || warn "left non-empty $proj/$os for review"
  else
    mv "$proj/$os" "$proj/$ns" && printf 'rekeyed: %s -> %s\n' "$os" "$ns"
  fi
  grep -rlF "$oldabs" "$proj/$ns/memory" 2>/dev/null \
    | while IFS= read -r f; do perl -i -pe "s{\Q$oldabs\E}{$newabs}g" "$f"; done || true
}
```

Call it in `cmd_move`, gated on `$APPLY && $REKEY_MEM`, iterating `destmap` (old `$ROOT/$lpath` → new `$ROOT/${destmap[$lpath]}`). The `~/.claude.json` rekey (7b) belongs behind the same flag, with the backup, as a final step — but stays maintainer-run given the sandbox.

> Optional, later: generalize `state` from binary `active|dormant` to N states each with a bucket name (e.g. a `REORG_STATES` map) so `20-archived` is first-class rather than a manual sibling of `_dormant`.

## 8. Sequencing

**Staged this session** (`/tmp/claude/reorg-staged/`, apply with the `cp -p` in §4): the 5 live `workspace/` docs and the patched `git-reorg`. This covers the workspace + git-reorg work without a separate session root.

Status (updated 2026-06-17):

1. **Dormant dir rename** — ✅ done (`_dormant`; old `dormant` gone; `git-reorg` default is `_dormant`, line 41).
2. **Rewrite over the repos (§5) + per-repo PRs (§6)** — ✅ done: per-repo unsigned commits made and §9-verified; the two leak files genericized; PRs open (babble#6, homebrew-cask-tools#43, zman-didan#3, blackoutd#24); bob-book committed locally. Two live `workspace/` docs the first pass missed (`homebrew-cask-tools/w8.1-followup-prompt.md`, `blackoutd/p20-cursor-on-black-prompt.md`) were caught and fixed 2026-06-17. ⏳ Re-sign + push is maintainer-only.
3. **One-time memory rekey (§7b)** — ✅ done (both slugs rekeyed; `~/.claude.json` map updated by maintainer).
4. **Resume the W1 review phase** (the original handoff's next step) — ⏳ pending.

repo-foundation's `usage.md` fix is clean and staged in its working tree, awaiting that repo's (still pre-initial-commit) bootstrap.

## 9. Verification

<!-- rumdl-disable MD013 -->

```sh
# Nothing pre-reorg should remain (run from ~/devel/claude/desktop):
grep -rIn --exclude-dir=.git 'desktop/\(blackoutd\|babble\|bob-book\|didan\|brew\|adrs\|dot-github\|homebrew-cask-tools\|repo-foundation\|cert-automation\|powerstatus\|displayrecommitd\|inject_edid\|mdbook-lint\|anti-trojan-source\|chabad-org-zmanim\)' toobuntu/ \
  | grep -v 'desktop/toobuntu/\|desktop/fork/\|desktop/reference/'
# Catch the sentence-end '.' gap the rewriter intentionally skips:
grep -rIn 'desktop/\(blackoutd\|babble\|didan\|brew\|adrs\)\.' toobuntu/ workspace/
```

<!-- rumdl-enable MD013 -->

## 10. Loose ends (not caused by this reorg)

- **`adrs-formula`** — scratch/working area for upstreaming an `adrs.rb` formula to `Homebrew/homebrew-core`. Non-git staging dir, intentionally left at `desktop/` top level (not bucketed).
- **`homebrew-babble-tools`** — a *proposed* rename of `homebrew-cask-tools` (decision still pending). Non-git staging dir at `desktop/` top level; no action until the rename is decided.
- **Stale/forward babble-migration path tokens** (`scaffolding`/`devkit`, `babble-ruby`, `babble-pr1`, `babble-base64`, `content`; ~54 refs, almost all in babble docs — `docs/handoff.md` + its `.0` backups, `scaffolding-consolidation-*.md.0`, `scaffolding-reorg.sh.0`; a few in `stash/code-archive/README.md`, `archive/_OPENING_PROMPT.txt`, `blackoutd/docs/debug/cursor-on-black-matrix.md`). **Correction to an earlier note: these are not phantom paths.** They reference babble's Ruby-migration working layout and a superseded consolidation:
  - `babble-pr1`, `babble-base64` — git **worktrees** that existed and were torn down (`git worktree remove ../babble-pr1`).
  - `babble-ruby` — the planned full **clone** for the Ruby migration; **never instantiated** (not present anywhere in the tree) — a forward-reference only.
  - `scaffolding` — the consolidation working dir that **became `repo-foundation`** (confirmed). `devkit` (and `content`) was a ChatGPT-suggested rename for it, **rejected**, so it never existed.

  They're "dead" only in that none sit under `toobuntu/`. PR #6's reviewers (CodeRabbit/Qodo/Copilot) independently flagged the surviving `babble-pr1` / `babble-base64` paths as a mixed-root inconsistency; for that PR, align them to `toobuntu/babble-*` (cf. `babble-refactor-modular` in §2) and drop/annotate the `babble-ruby` forward-reference. The `scaffolding`/`devkit` mentions live only in `.0` backups and are historical — leave them.
