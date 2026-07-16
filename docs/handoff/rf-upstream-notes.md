<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Upstream work queued from the babble W3 session (2026-07-04)

Two destinations: toobuntu/repo-foundation (RF) and Homebrew/brew.
Babble's hand-staged copies on `b1-tap-toolchain` are the reference
implementations; each item below names its reference file.

## 1. repo-foundation

### 1.1 lint-unicode.sh canonical is broken — adopt babble's repair

RF's `scripts/lint-unicode.sh` cannot parse: lines ~55–203 were
block-indented seven spaces at some point (the embedded Python heredoc
body is flattened to one indent level, and the `PYEOF` terminator is
indented, so with `<<'PYEOF'` — not `<<-` — the here-document never
closes; `sh -n` fails with "unexpected end of file"). The python3 path
can never have run. Root cause of the mangling is consistent with the
Homebrew shfmt wrapper bug in § 2 (line-based transforms applied
through heredoc bodies).

Babble's repair (reference: `scripts/lint-unicode.sh` +
`scripts/lint-unicode.py` on `b1-tap-toolchain`):

- Move the detector out of the heredoc into `scripts/lint-unicode.py`
  (sidesteps every formatter-vs-heredoc hazard permanently); the .sh
  keeps the POSIX grep fallback and calls the .py when python3 exists.
- Honest `#!/bin/bash` shebang (the file uses `[[ ]]` throughout).
- Update the `lint-unicode` job docs in `lint.yml`'s comments if the
  file layout changes ("scripts/lint-unicode.sh (python3 here…)").
- Functional check used in babble: repo scan green on both paths;
  both paths detect a planted U+200B file.

### 1.2 annotate.sh: already fixed upstream — but note the sandbox bug class

RF's copy already has `reuse --no-multiprocessing lint --json`
(line 112). babble's W2-era copy predated it and silently no-op'd
under Seatbelt (`reuse lint --json` dies on `SC_SEM_NSEMS_MAX`, and
`|| true` swallowed it — exit 0, nothing annotated). Sweep other
canonicals for the same pattern: any `reuse` invocation without
`--no-multiprocessing`, and any `|| true` that can mask a total
failure of the command whose output drives the script.

### 1.3 ksh -n as authoritative syntax pass — canonicals have warnings

Org rule (lint-shell.sh): `ksh -n` runs over ALL shell. RF canonicals
currently emit six warnings babble fixed locally (reference: babble
commit "Use printf for usage banner; pass ksh -n"):

- `lint-perms.sh:33` — `=` inside `[[ ]]` → `==`
- `lint-unicode.sh`, `re-sign-unpushed.sh`, `sandbox-enter.sh` (×2),
  `sandbox-exit.sh` — `-eq`/`-gt` inside `[[ ]]` → `(( ))`

### 1.4 Exec bits: re-sign-unpushed.sh and rewrite-pr-as-merge-commit.sh ship 100644

babble's `lint-perms.sh --tracked` caught both as non-executable on
copy-in. Fix modes in RF (`chmod 755` + `git update-index --chmod=+x`)
so consumers don't inherit the violation.

### 1.5 sync-manifest.yaml updates

- **babble gains `brew_plugin`** (it is now effectively a tap:
  cmd/babble.rb landed in W3 Block B; 30-brew's brew style checks
  apply). The manifest comment says "tap consumers only (cask-tools
  today)" — extend to babble.
- **New upstream pulls from Homebrew/brew** (babble + cask-tools are
  excluded from `shell_lint` by design, so these fill that hole):
  - `.shellcheckrc` → new component set (e.g. `brew_style_config`)
    mapped to the Homebrew-aligned consumers
  - `.editorconfig` → same set
  Reference copies + BSD-2-Clause sidecar convention: babble root.
- **New upstream pull: `.github/workflows/reject-conventional-commits.yml`**
  ("Commit Style") → synced to babble + cask-tools, since external
  commands must follow Homebrew's commit-style rules. Companion local
  enforcement: a `.githooks/commit-msg` dispatcher (new hook stage in
  the git_hooks set) plus a commit-msg module for tap consumers that
  applies the same rejection to the message being written.
  **Drift guard between module and workflow**: the workflow's `run:`
  block is plain bash and is the single source of truth. Options, in
  increasing automation:
  1. sync-from-upstreams asserts a checksum of the extracted `run:`
     block against the one recorded when the module was last updated;
     on mismatch the sync PR gets a loud failing check/comment
     ("Commit Style upstream changed — reconcile the commit-msg
     module").
  2. The module extracts the `run:` block from the synced workflow
     file at hook time (yq '.jobs.*.steps[].run') and executes it with
     the commit-message file adapted to the env the block expects.
     Fully automatic but fragile to upstream restructuring; only
     viable if the block's input contract (env vars / commit range) is
     pinned by the extraction.
  Recommendation: ship (1) now — the loud-complaint checksum — and
  revisit (2) only if upstream churn becomes frequent.

### 1.6 ADR 0017 gap: synced POSIX shell vs brew style in Homebrew-aligned consumers

`brew style --changed` lints any changed `.sh` in a tap repo with
Homebrew's shfmt dialect + optional shellcheck checks. Every sync PR
that touches RF's POSIX-layout `.sh` canonicals in babble/cask-tools
will therefore fail the style job. babble's interim treatment
(reference: any staged script): `brew style --fix` layout plus a
one-line file-level exemption
`# shellcheck disable=SC2249,SC2250,SC2292,SC2310,SC2311,SC2312`.
RF should either adopt that layout+directive form in the canonicals
themselves (they remain valid everywhere else) or exclude
Homebrew-aligned consumers from `.sh`-bearing sets. Related: keep
heredocs out of org `.sh` files entirely (§ 2); Todd's printf rewrite
of `rewrite-pr-as-merge-commit.sh`'s usage banner is the pattern.

## 2. Homebrew/brew: shfmt wrapper corrupts heredoc bodies

**Bug.** `brew style [--fix]` on a shell file whose heredoc body or
terminator can be mistaken for shell: the post-shfmt transforms in
`Library/Homebrew/utils/shfmt.sh` (`wrap_then_do`,
`align_multiline_if_condition`, and the other line-based regex
rewrites) are applied to every line of the file, including heredoc
bodies, because they track no heredoc state. Effects observed:
content lines re-indented (Python bodies flattened), terminators
indented so the heredoc never closes, following functions absorbed
into the heredoc, and false "fixable bad styles" reports on valid
scripts. shfmt itself is fine — the corruption is Homebrew's
post-processing.

**Repro** (minimal):

```sh
usage() {
  cat <<EOF
Usage: script.sh [options]
  --flag   description
EOF
  exit 1
}
parse_args() { :; }
```

`brew style --fix` on this file mis-indents `EOF` and swallows
`parse_args` into the heredoc context.

**Fix sketch.** Give the transform loop a heredoc state machine:
recognize `<<[-]?['"]?WORD` on a line, then pass lines through
untouched until the matching terminator (column-0 `WORD`, or
tab-stripped for `<<-`), stacking for multiple pending heredocs on
one line. Apply to every line-based transform in shfmt.sh, not just
`wrap_then_do`. Add regression fixtures: quoted/unquoted delimiters,
`<<-`, two heredocs on one line, heredoc containing `then`/`do`
tokens and Python-style indentation.

**Acceptance odds.** Good: objective corruption of valid input in
Homebrew-authored post-processing (not upstream shfmt), with a
two-line repro; brew's own style docs require `brew style --fix`
before commits, so the bug bites their contributors too. Risks to
frame in the PR: the transforms are self-admittedly line-based
hacks, so maintainers may prefer either a minimal state-machine
guard (propose that) or dropping the custom transforms in favor of
stock shfmt behavior (their call; offer both). Follow Homebrew's
AGENTS.md checks (`brew typecheck`, `brew style --fix --changed`,
`brew tests --only=…`) and non-Conventional commit style. Suggested
subject: `utils/shfmt.sh: skip heredoc bodies in style transforms`.
Session setup: Tier 3 remoteless clone from
`~/devel/claude/desktop/fork/Homebrew/brew` (or `$(brew --repo)`),
patch + fixtures, then push from the fork and open the PR upstream.

## 3. Babble sandbox config so agents can run brew dev-cmds

Two independent unlocks (reference: this session verified both):

1. **Cache redirection** (works today, no config): `HOMEBREW_CACHE`
   and `HOMEBREW_TEMP` pointed at `$TMPDIR` let `brew style` and
   plain `brew typecheck` run fully sandboxed once gems are current.
2. **Write-allowlist additions** for gem reconciliation and the
   hardlink harnesses — add to babble's `.claude/settings.json`
   (`sandbox.filesystem.allowWrite`), or the machine settings for
   all Homebrew-aligned repos:

   ```json
   "sandbox": {
     "filesystem": {
       "allowWrite": [
         "/opt/homebrew/Library/Homebrew/vendor",
         "/opt/homebrew/Library/Homebrew/cmd",
         "/opt/homebrew/Library/Homebrew/test"
       ]
     }
   }
   ```

   Rationale for the shape: `bundle install` writes under
   `vendor/` (`vendor/bundle` gems, `vendor/portable-ruby` updates);
   the harnesses create directory entries `cmd/babble.rb`,
   `cmd/babble/…`, `test/cmd/babble_spec.rb`, `test/cmd/babble/…`,
   `test/fixtures/…` — the *parent* directories `cmd/` and `test/`
   need write permission for `ln -f`/`mkdir`/`rm -f`, so scoping to
   `…/cmd/babble` alone is not sufficient. Scoping to `cmd`,
   `test`, and `vendor` (not all of `Library/Homebrew`) keeps
   brew.rb, the DSL, and git metadata read-only. Acceptable at
   Tier 3, where the remoteless clone is the containment; the
   `excludedCommands`+ask entries stay as the interactive-session
   fallback, and `brew mcp-server` (see `.mcp.json`) covers
   style/typecheck/tests without any of this.

## 4. Org convention proposal: stacked-PR labels and emoji-free PR bodies

Adopt in RF's contributing/agent docs (source: babble W3 session,
2026-07-05):

- PR bodies and titles are emoji-free; the AI-assistance footer is
  plain text: `Generated with [Claude Code](https://claude.com/claude-code)`.
- Stacked PRs (long-lived staging branches like babble's
  ruby-migration) carry two labels from birth: `stacked` (uniform
  query handle) and `retarget-to-<interim-base>` (parameterized
  instruction). Lifecycle: after the base PR merges, retarget with
  `gh pr edit <branch> --base <staging> --remove-label retarget-to-…`,
  verify the diff shrank to the stack's own commits (`gh pr diff
  --stat`), then `gh pr ready`. CORRECTION (2026-07-07, learned the hard way): deleting a merged PR's branch can CLOSE dependent PRs outright (no auto-retarget on this path), and gh pr merge --delete-branch also deletes the LOCAL branch, violating park-merged-branches. Approved flow: merge without the flag; retarget dependents FIRST (gh pr edit --base); then git push origin --delete <branch> and park local as merged/prN-<branch>.

## 5. Amendments (2026-07-06)

- §1.3/§1.4 refinement: the right fix for the sh-shebang canonicals is
  restoring POSIX test forms ([ ], =, [ "$#" -gt 0 ]), NOT bash
  shebangs — passes dash runtime, checkbashisms, ksh -n, and brew
  style at once (babble commit "Restore POSIX test forms"). RF's own
  ubuntu lint-perms job has the same latent [[-under-dash failure.
- Add checkbashisms to scripts/lint-shell.sh's checker set (stock via
  Homebrew formula; catches sh-shebang bashisms the other tools miss).
- babble is being renamed toobuntu/homebrew-babble ahead of the
  v0.6.0 gate: update sync-manifest.yaml's consumer repo slug, and
  babble now qualifies for the homebrew_tap component set
  (copilot-setup-steps from upstream) in addition to brew_plugin.
- reject-conventional-commits.yml + .githooks/commit-msg now staged in
  babble (reference implementation for the §1.5 upstream-pull +
  commit-msg module + checksum drift guard).
- re-sign-unpushed.sh: the rebase --exec pass runs WITHOUT
  --rebase-merges while the unpushed range can legitimately contain a
  merge commit (babble hit this: stacked-branch merge + re-sign after
  a rejected push). Today it silently linearizes the branch and
  replays the merged-in side as patch-id duplicates. Fix: detect a
  merge in the range and either add --rebase-merges to the exec pass
  or refuse with guidance ("re-sign before merging, or rerun with
  --rebase-merges"). The pre-push hook's suggested one-liner has the
  same gap — mirror the fix there.
- (Confirmed for §5 shellcheck item: disable= directives accept only
  SC codes; named checks like require-double-brackets are an SC1072
  parse error — names are valid only in enable=. brew style forces
  --shell=bash --enable=all in style.rb, which is why sh-shebang
  files receive bash-dialect optional findings at all.)

## 6. CodeRabbit findings deferred to RF canonicals (2026-07-07, PR #8)

All verified against babble copies; each is for RF to fix so consumers
stay byte-identical:

- .githooks/pre-commit bidi scan: LC_ALL=en_US.UTF-8 -> C.UTF-8
  (verified present on macOS 26; standard on Ubuntu; en_US.UTF-8 is
  not guaranteed on minimal Linux). babble's lint-unicode.sh repair
  copy already made the swap — same one-liner.
- .github/instructions/licenses.instructions.md: no H1 after the
  applyTo frontmatter trips markdownlint MD041 in review bots; add a
  heading or record the exemption wherever RF configures markdownlint
  (if ever).
- scripts/rewrite-pr-as-merge-commit.sh fetch_refs(): the BASE_BRANCH
  fetch is `|| true`d, so a failed fetch leaves a stale
  origin/<base> that compute_merge_base() and the --force-with-lease
  push then trust. Base fetch should fail loudly; HEAD fetch may stay
  non-fatal (recreate_branch_if_needed covers it).
- scripts/sandbox-enter.sh:143 mktemp prefix still says
  blackoutd-sandbox; rename to the RF-era convention.
- Consider ruff (python) and markdownlint in RF's lint stack: these
  are the tools CodeRabbit runs, so pre-empting them locally converts
  review-bot churn into pre-commit/CI signal. babble now carries one
  python file (lint-unicode.py, ruff-clean after the read_utf8
  extraction).

## 7. Addenda (2026-07-07, second pass)

- re-sign-unpushed.sh merge-topology item, refined by a live failure:
  plain rebase linearizes, and even --rebase-merges REPLAYS the
  merged-in side when those commits are inside the range, minting
  patch-id duplicates that conflict on every later merge. Safe
  orders: re-sign before merging, or amend the unsigned commit at a
  detached HEAD and re-merge. The script should detect a merge in
  range and print exactly that guidance.
- Also clarify in the script's usage/help that it PUSHES (the
  lease-pinned force push is the blessing step); consumers keep
  appending redundant git push because the name says only "re-sign".
- Lint-stack adoption stance (babble session): ruff yes;
  markdownlint-cli2 yes but only with an org config (MD013 off,
  rules tuned to CodeRabbit's actual findings; coordinate with the
  vale prose stack); ast-grep no (bare engine, no ruleset to
  pre-empt); act for exercising ubuntu-runner workflows locally
  (macOS jobs do not run under act).

## 8. re-sign push UX + commit-msg perms (2026-07-07, third pass)

- re-sign-unpushed.sh: the fully-signed early return skips the push
  section silently (babble hit it with a signed merge commit).
  Reference fix on babble branch b2-followups: report, fall through
  to the push logic, and rename the no-remote message accordingly.
- lint-perms.sh PERMS_PATTERN gains commit-msg in the top-level-hook
  alternation once RF adopts the commit-msg stage (babble already
  ships the hook; pattern's header designates the extension point).
- brew style vs RF formatting on shared .sh canonicals, settled
  recommendation: there is NO per-file or per-rule shfmt exemption
  (in-file directives are shellcheck-only; Homebrew's shfmt.sh
  transforms apply to every changed .sh). The two format targets
  conflict at the flag level (space-redirects and same-line do vs
  Homebrew's opposites), so one byte-canonical cannot satisfy both.
  Make formatting a SYNC-TIME TRANSFORM: the consumer-sync engine
  already supports per-file mutations — add a "format with
  Homebrew's shfmt" mutation for Homebrew-aligned consumers, so RF
  keeps its canonical layout, consumers receive deterministically
  brew-style-clean copies, and drift is zero by construction.

## 9. shfmt exclusion mechanics, settled (2026-07-07)

mvdan/sh#1037 + man page: shfmt honors EditorConfig `ignore = true`
when walking directories, and `--apply-ignore` extends that to
direct-file runs — BUT any explicit parser/printer flag makes shfmt
discard EditorConfig entirely. brew's style.rb run_shfmt\! passes
`--language-dialect bash --indent 2 --case-indent` plus explicit
file lists, and hardcodes its only exclusions (completions/bash/brew,
Dockerfile). So no babble-side .editorconfig entry can exempt a file
from brew style today. Two consequences:
- The sync-time formatting mutation (§ 8) remains the org-side fix.
- Upstream ask for Homebrew/brew, companion to the heredoc PR:
  support per-repo shfmt exclusions — simplest form is passing
  --apply-ignore so a tap's .editorconfig `[path] ignore = true`
  works; alternative is making the exclusion list configurable.

## 10. sandbox-enter parent dir vs the macOS /tmp reaper (2026-07-08)

The babble-w3 clone (created Jul 3 under /private/tmp/claude) lost
worktree files AND hardlinked loose git objects to macOS's periodic
tmp cleanup (~3 days without access) while the session paused across
days. Local `git clone` hardlinks loose objects, so the source repo
lost nothing — but promotes from a reaped clone become unreliable.
sandbox-enter.sh should either default --parent to a non-reaped
location (e.g. ~/tmp or ~/.cache/sandboxes) or document the 3-day
hazard loudly and touch-refresh on entry. Session hygiene: check the
clone's `git status` for phantom deletions at every session start,
and promote/destroy within a day or two.

## 11. re-sign-unpushed.sh v2 + rename question (2026-07-08)

Canonical candidate at /tmp/claude/re-sign-unpushed.sh (org
formatting, validated: dash -n, ksh -n, checkbashisms, shellcheck
clean): fall-through publish, --set-upstream for unborn remote
branches, per-outcome messages, detached-HEAD guard, header
documenting sign+publish as one blessing step. Rename question
(Todd): the fall-through design is right — the script's contract was
always "bless" (that is why it pushes) — and the name now
undersells it. Recommendation: rename to sign-and-push.sh AT RF
ADOPTION TIME (pre-first-sync is the cheapest moment: only RF, the
sync manifest entry, ~/.claude/CLAUDE.md, and agent-principles
reference it; consumers have not synced yet). If renamed, update the
pre-push hook hint text too. Keeping the old name is acceptable if
reference churn is unwanted; in that case the header contract line
must stay.

## 12. re-sign v3: settled design + rename (2026-07-08, supersedes § 11's rec)

Design (Todd's ruling): publish is the COMPLETION of a re-sign, not a
generic push. v3 at /tmp/claude/re-sign-unpushed.sh (org formatting;
dash/ksh/checkbashisms/shellcheck clean): re-signed → publish with
narration (--set-upstream / ff / lease; local-only repos — no origin —
sign and stop, restoring the case v2 dropped); nothing to re-sign →
never push; up-to-date exits 0, pending push prints the exact git push
command and exits 2; detached HEAD skipped; multi-repo loop aggregates
exit codes. Rename recommendation: re-sign-and-publish.sh — keeps the
load-bearing "re-sign" stem (its identity and original purpose), adds
the publish contract; NOT git-publish.sh, which invites generic-push
usage the exit-2 path deliberately refuses. Rename at adoption
(pre-first-sync = cheapest; update manifest entry, ~/.claude/CLAUDE.md,
agent-principles, pre-push hint together).

## 13. Sandbox placement docs (2026-07-08)

Ready-to-insert agent-principles section + sandbox-enter.sh change
spec: /tmp/claude/rf-sandbox-hygiene.md (tmp_cleaner mechanics,
~/.cache/sandboxes default, touch-refresh rule, git-status session
hygiene).

### 12a. Amendment (2026-07-08): name is sign-push.sh; push vocabulary

Todd's ruling supersedes the § 12 rename recommendation: the script
only signs what was never signed (mechanically: rebases/recommits
with signing), so the "re-" prefix misdescribes it — rename to
**sign-push.sh** at RF adoption. User-facing messages and the header
now use push (mechanism, greppable, git-native) rather than publish
(outcome word); "publish" survives only in prose where it names the
outcome concept. Functional validation: local-only and up-to-date
paths verified by Todd (exit 0, correct messages); unsigned-ahead
verified (re-sign → fast-forward push narration); the exit-2 hint
path requires a SIGNED ahead commit to trigger.

### 12b. Amendment (2026-07-08): no auto force; name still open

v4 (both /tmp/claude variants, validated): the auto force-with-lease
branch is REMOVED per Todd's safety review. Rationale: the re-sign
rebase never rewrites remote-reachable commits, so post-re-sign
divergence implies origin holds foreign work (other machine/bot/
fetched review push) — the one case where forcing destroys something;
the maintainer's amend-after-review case exits 2 instead (amends are
signed). Force stays human-only org-wide. New exit code 3: re-signed
but diverged; prints `git log HEAD..origin/<branch>` inspect line and
the exact lease-pinned push. Exit codes documented in header (0/2/3).
Naming: sign-push.sh recommended; Todd floated signpost.sh (whimsy vs
the plain-literal-prose rule — recommendation is sign-push.sh with a
signpost mnemonic in the header if wanted); final call is his at RF
adoption. Still open for the RF session: merge-commit-in-range guard
for the rebase (the PR #9 linearization hazard).

### 12c. Amendment (2026-07-08): merge-preserving re-sign implemented (v6)

Both /tmp/claude variants now handle merges in the rewrite range
automatically instead of refusing: rebuild the first-parent spine
(cherry-pick + amend-sign ordinary commits; each merge reconstructed
via commit-tree with identical tree/message/non-first parents, then
amend-signed — the incoming side is referenced, never replayed, so no
duplicates and no conflicts are possible), print a restore command
before mutating, then fall through to the push logic. Narrow exit-4
refusal remains for the one genuinely unsafe sub-case: a merge whose
incoming side carries unsigned unpushed commits (the script names the
commit and says to sign/push that branch first). Rationale for
automating this but never the force-push: local, reflog-reversible,
conflict-free by tree reuse — vs. network-destructive to others'
work. Sandbox validation with a throwaway SSH signing key: spine
signed (%G? = U), merge topology and content byte-identical, branch
restored. Verified by Todd's harness (pending): exit-4 pathological
side case; pushed-side pass-through (needs real remote-tracking
refs). Exit codes now 0/2/3/4, documented in the header.

### 12d. v7 + test suite (2026-07-08, final for this workstream)

- Guard refined per Todd's review: exit-4 now prints an EXACT recipe
  (discovers the side branch via `git branch --contains`; falls back
  to a create-branch recipe when none holds the commit), and unsigned
  side commits by OTHER committers are tolerated with a note — the
  pre-push gate rejects only an unsigned tip, and signing someone
  else's commits is not the script's business. Refusal applies only
  to your own unsigned unpushed side commits.
- scripts/re-sign-unpushed-test.sh: self-contained suite
  (promote-from-isolated-test.sh pattern; mktemp repos, throwaway SSH
  key + local allowedSignersFile, bare-repo origins for REAL pushes,
  no network). 35 assertions, all green: exits 0/2/3/4, both hints,
  set-upstream + ff pushes verified against origin, merge rebuild
  (topology, byte-identical content, signatures), refusal recipe +
  repo-untouched, foreign-committer tolerance. The harness already
  caught one real bug class: without gpg.ssh.allowedSignersFile, ssh
  signatures verify as not-good — pin it in any test env; user
  machines have it globally.
- RF intake: bring script + test together; run the suite in spec.yml
  or as a standalone job; reformat layout with RF's shfmt on intake
  (files ship brew-compatible for babble's CI).

### 12e. brew style --fix REWRITES POSIX tests to [[ ]] (2026-07-08)

New finding, upgrades § 1.6 from "flags" to "mutates": brew style
--fix applied shellcheck's SC2292 auto-fix and CONVERTED [ ] to
[[ ]] throughout the un-exempted test file (the exempted script was
untouched). Consequence: ANY RF-canonical POSIX .sh landing in a
Homebrew-aligned repo must carry the numeric-disable header or a
routine --fix pass will silently de-POSIX it (breaking dash/ubuntu
consumers). The test suite now carries the same header, plus SC2015
for its assert idiom. This also strengthens the sync-time-mutation
design: the mutation should ADD the exemption header, not only
reformat layout.

### 12f. Comment-prose trap (2026-07-08): never start a comment line
with lowercase "# shellcheck" — the directive parser claims it and
errors (SC1072/SC1073). Writing ABOUT the tool in explanatory
comments (org policy requires explanations above disable lines) must
word-wrap so the name lands mid-line, or use "ShellCheck" (the
parser matches lowercase only). Hit while widening babble's
re-sign exemption header.

### 13a. sandbox-exit.sh has no --mode=destroy (2026-07-08)

babble's docs/handoff.md § B.5 references `sandbox-exit.sh
--mode=destroy`, but the script only implements --push/--push-target
(remote restoration). Either implement a --destroy mode (verify
nothing unpromoted: clean tree + all commits reachable from some
non-sandbox ref or patch-id-present in the source repo, then remove
the clone dir) or keep teardown as documented plain removal and fix
the handoff wording. Pairs with § 13's ~/.cache/sandboxes default.

## 14. Name settled (2026-07-08, Todd): sign-push.sh

The script lands in RF as scripts/sign-push.sh (test:
scripts/sign-push-test.sh). Update on intake: the sync-manifest entry
(currently re-sign-unpushed.sh in scripts_core), ~/.claude/CLAUDE.md's
reference, agent-principles' commit-procedure section, the pre-push
hook's hint text, and babble's copy at the first sync. Payloads sit
beside these notes: sign-push.sh, sign-push-test.sh (test's default
script path already updated), rf-sandbox-hygiene.md.

## 15. Pre-sync freshness audit — REQUIRED before the first consumer sync (2026-07-13)

Maintainer requirement, and babble is the live proof case: consumers
now hold hand-staged copies that are NEWER AND BETTER than RF's
canonicals (lint-unicode repair, POSIX/ksh fixes, exec bits,
sign-push v7 + tests, commit-msg hook, widened shellcheck exemption
headers). A blind first sync would overwrite improvements with
older/broken canonicals.

Before ANY consumer sync runs:

1. For every manifest (source → target, consumer) pair, compare RF
   canonical vs the consumer's on-disk file: content hash first
   (mtime only as a review signal — mtimes lie after cp/clone).
2. Identical → syncable as-is. Different → REQUIRED diff review with
   a three-way disposition per file: adopt-consumer-into-RF first
   (expected for babble), keep-RF (consumer regression), or
   deliberate divergence (record why; usually means the manifest
   mapping or a sync mutation is wrong).
3. The audit gates the sync: no consumer sync until its audit is
   clean or every mismatch is dispositioned.

Implementation: an --audit (dry-run/report) mode in the sync engine
or a standalone script reusing sync-files.rb's manifest parsing;
output one row per pair: target, same/differs, consumer mtime, RF
mtime, and the diffstat for mismatches. Add the audit step to
docs/handoff/first-sync-and-consumer-cleanup.md as a hard
prerequisite alongside the App installs.

GitHub App status (2026-07-13): renamed toobuntu-token-app; has
access to repo-foundation, homebrew-cask-tools, and
toobuntu/CrimsonProT. Remaining consumer installs (incl.
homebrew-babble) DEFERRED by the maintainer until this audit and
the reconciliation pass exist — recorded intent, not an oversight.
(CORRECTED 2026-07-15, verified by the 18g DEBUG run and the
maintainer: the App covers ONLY homebrew-cask-tools and CrimsonProT
— repo-foundation was never on the selected list. Consequence
already materialized: the live Monday cron opened hct sync PR #49
pre-audit; see 18h for dispositions.)

## 16. Pre-sync investigation: BrewUI/Brewy conventions evaluation (2026-07-13)

Session prompt: workspace/reference-eval-next-steps.md. Homebrew's
official BrewUI ships an .ai/ memory system (dated append-only
memory.md as decision log — explicitly no ADRs — plus gitignored
progress.md/scratchpad.md and a committed progress template) that
may fix the docs/handoff "what is actually next?" sprawl; Brewy
(maintainer side project, AGPL, cask-only tap) runs a "fleet"
sentinel-region multi-repo sync analogous to RF's baseline-merge —
tooling located and read 2026-07-13 in the hub clone at
reference/starhaven-io/.github/fleet/ (four-tier ownership model,
consumer-side .fleet.yml params, cited exceptions, required
fleet-guard PR check, createCommitOnBranch Verified commits, CalVer
sole-pin-writer releases; full recon in the session prompt).
Evaluate hybrid adoption BEFORE the first sync freezes RF's shape;
the org keeps ADRs (adrs tooling + lint-adrs are invested), so the
candidate is memory/progress continuity layered beside them.

## 17. Homebrew #22952 receipt model — W7/BundleDiscovery re-evaluation (2026-07-13)

brew now (a) writes INSTALL_RECEIPT.json during cask upgrades after
artifacts install (fresh receipt per upgrade; forced upgrades repair
missing receipts), and (b) moves installed-cask metadata to a
deliberately minimal <token>.json that RELIES on the receipt for
receipt-owned data (installed version, uninstallable artifacts) —
see Library/Homebrew/json_api_postinstall_preflight_postflight_plan.md
§ "Installed Cask Metadata Format" on current main.

Consequences to evaluate (hct session, before/with W8):

- lib/cask_tools/bundle_discovery.rb:199 uses
  Cask::CaskLoader.load(token) — the CURRENT tap/API definition, not
  what was installed. The receipt is now the authoritative record of
  installed artifacts and strictly better for bundle discovery (the
  DSL may have changed since install). Consider a receipt-backed
  tier (Cask::Tab / INSTALL_RECEIPT.json, or
  load_from_installed_caskfile with receipt hydration) above or
  replacing the loader tier; re-rank the 7 tiers accordingly.
- Receipts are now reliably PRESENT going forward (upgrade writes
  them; forced upgrade repairs them) — the historical
  missing-receipt caveat weakens, but old installs predating the
  change still lack them: keep a fallback tier.
- Sweep recent brew commits/PRs for effects on brew adopt,
  brew extract --cask, and anything else hct's extractor touches.
- babble C.3 note added to c2-next-steps/master-plan: verify the
  lifecycle sketch's `brew info --json=v2 | .artifacts[].target`
  still reports installed-artifact targets under the minimal-JSON
  model, or switch to receipt/Tab data.

## 18. BrewUI/Brewy/fleet evaluation outcome — pre-sync RF queue (2026-07-14)

Closes § 16. Full adopt/adapt/skip rationale:
workspace/reference-eval-recommendations.md (babble items went to
workspace/c2-next-steps.md, 2026-07-14 addendum). Everything below
is queued for the RF pre-sync session(s), alongside the § 15 audit
and the canonical repairs — all cheapest before the first consumer
sync.

### 18.1 Engine: --guard mode + consumer guard workflow (headline adopt)

Fleet's strongest mechanism, adapted. sync-files.rb grows
`--guard <base>`: render every component for the consumer in memory,
compare against the PR tree, flag ONLY files the PR touched
(merge-base filter — drift predating the branch belongs to the sync,
not the PR author); baseline-merge targets compare the managed
region only; the settings.json deep-merge path compares regenerated
output (also catches direct edits bypassing the addenda file). New
canonical `.github/workflows/foundation-guard.yml` (ci_core): check
out consumer PR tree + RF at a PINNED SHA, run the guard reading the
manifest from the RF checkout — never from consumer-writable content
(fleet learned this: its guard now locks consumer edits to
.fleet.yml because config-driven guards are bypassable via config;
RF's hub-side manifest solves it by construction). Exempt sync-bot
PRs. Tamper backstop is branch protection requiring the check BY
NAME (an in-tree pull_request guard cannot defend its own caller —
fleet's honestly-stated limit; a deleted/broken caller leaves the
required check missing and the PR blocked). Bonus: --guard gives the
engine fleet's three local modes (render / dry-run / guard), same
engine everywhere.

### 18.2 Engine: sentinel fixes (verified against sync-files.rb)

- Inverted marker pair (end before begin) passes the 1/1 count
  check, the region regex never matches, `sub` returns the input
  unchanged, and the run reports "no change" — mangled markers that
  do NOT fail loudly. Fix: assert the substitution occurred; abort
  otherwise.
- Pad `:html`-style (Markdown) regions with a blank line inside the
  sentinels (fleet does this for Prettier; RF's driver is the § 7
  markdownlint candidate, whose blanks-around-headings rules would
  flag content adjacent to comment lines). Do it while zero
  consumers have regions on disk. Hash-style regions stay tight.
- Recorded divergence (no change): markers entirely absent → RF
  appends the region (fleet fails loudly). Deliberate — first-sync
  bootstrap plus post-bootstrap self-healing. Document in the
  manifest comment.

### 18.3 Manifest: exceptions with cited reasons

`exclude:` entries become mappings with a required reason —
`{target: ..., reason: "..."}` — replacing bare strings (structured,
so tooling can print them; YAML comments cannot). The § 15 audit
report and the sync PR body list every exception; the audit's
record-divergence dispositions land as exactly these entries. Small
engine change (exclude match reads target from a Hash).

### 18.4 Workflow: createCommitOnBranch Verified commits (recommended; maintainer decides)

Corrects docs/bootstrap/sync-bot-and-signing.md § 2's cost estimate,
which priced the REST Git Data chain. The GraphQL
createCommitOnBranch mutation is ONE call per commit (fileChanges =
base64 additions + deletions), auto-signed by GitHub's web-flow key:
Verified with no machine user and no SSH-signing-key secret — fleet
runs it in production. Keep per-file commits: N files = N mutations
chained via expectedHeadOid, after a ref-create. Engine seam: emit
the changed-file list; the workflow replaces local-commit+push with
the mutation loop. Adopting now deletes the § 2 machine-user setup
from the bootstrap checklist before anyone performs it; rewrite § 2
with the API path as primary.

### 18.5 Workflow: sync PR body lists converged surfaces

Engine already prints per-file update lines; pass them into the
`gh pr create`/`edit` body (fleet's PR body doubles as the drift
alarm). Add "scheduled silence is the health signal" to the
README/usage doc so a quiet Monday cron reads as health.

### 18.6 Continuity redesign (the § 16 main prize — hybrid, not wholesale)

ADRs stay the only decision log (BrewUI's no-ADR stance rejected;
record as considered-and-rejected when convenient). Adopt:

- **docs/log.md per repo** — dated append-only knowledge log
  (`## YYYY-MM-DD — Topic`), the formalization of what THIS file
  became organically. Graduation rules: decisions → ADR; code-visible
  facts → code; agent rules → agent-principles; per-session "what
  shipped" stays OUT (git/PRs own it). Not synced (per-repo content,
  like .vale.ini); foundation-init seeds an empty one. This file
  closes at the repairs session — queue §§ dispositioned, durable §§
  (2, 9, 12f, 13) seed RF's docs/log.md, pointer left behind.
- **docs/progress.md gitignored + committed template**:
  provides/repo/progress.template.md → docs/progress.template.md,
  mode canonical (sections: Last touched / Done recently / In flight
  / Blocked / Handoff); gitignore.baseline gains docs/progress.md.
  Replaces ad-hoc per-repo next-steps files; opening prompts stay
  (conversation-management.md) but get shorter — point at log/progress.
- **AGENTS.baseline.md managed region gains**: the session workflow
  (start: read docs/log.md + docs/progress.md; end: append durable
  learnings, update progress) and an instruction-precedence list
  (explicit user instruction > repo AGENTS.md incl. agent-principles
  > user-global CLAUDE.md > tool defaults; executable checks outrank
  prose about them).
- **agent-principles additions**: (a) precedence pointer if not
  fully in the baseline region; (b) BrewUI's "always web-search
  versioned or scheduled values" rule (runner tags, action/tool
  versions — agents author pinact-verified pins from stale training
  data otherwise); (c) project knowledge belongs in the repo
  (docs/log.md / ADRs / code), NOT in Claude's per-project memory —
  memory is per-machine, per-path, contributor-invisible, and dies
  with retired Tier-3 clones (the orphaned babble-w3 memory dir is
  the proof case); memory holds only agent-workflow preferences.
- **docs/handoff/ genre rule**: live prompts and plans only;
  executed prompts / outcome records move to docs/handoff/completed/
  (or are deleted once the log records the outcome); payloads leave
  at intake (§ 14).

### 18.7 Lint stack additions (same stance framing as § 7)

- **lychee link check: adopt.** Weekly cron + PR trigger scoped to
  doc paths (Brewy's shape), canonical workflow + org lychee.toml
  (exclude flaky hosts, e.g. gnu.org), lychee via Homebrew.
- **typos: evaluate with the ruff/markdownlint pass.** Complements
  vale (typos = identifiers/strings in code; vale = Markdown prose).
  Same test: adopt if it converts review-bot churn into local
  signal. Config is ~2 lines (_typos.toml with excludes).

### 18.8 Lower-priority candidates (recorded)

- **scripts/check.sh** (scripts_core): one local gate aggregating
  the org checks with CI parity; Brewy's honest-failure design — a
  missing tool is reported AND fails the run, so green means
  everything ran. (Do not adopt `just`; a synced POSIX script
  suffices.)
- **Brewfile dev-tooling template**, foundation-init-seeded (per-repo
  tool sets differ): `brew bundle` one-command setup;
  `brew bundle check` as a foundation-doctor probe.
- Skips recorded in the recommendations doc: Mintfile pins
  (Swift-specific; revisit if Swift grows), README managed regions,
  DCO/Conventional Commits (org deliberately opposite, § 1.5),
  periphery, .cursor overlays, monotonic reusable-call guard +
  CalVer sole-pin-writer (no reusable-workflow layer; full canonical
  workflow files audit consumer-side, which is the property fleet's
  thin callers exist to preserve; the 18.1 guard subsumes the
  monotonic guard at RF scale; the sync PR is the release).

### 18a. Maintainer review rulings + revisions (2026-07-14)

Rulings from Todd's review of the recommendations doc (naming note
recorded there too):

- **18.6 naming revised**: `.ai/memory.md` (durable knowledge — the
  formalization of this file's genre) + gitignored `.ai/progress.md`
  with canonical `.ai/progress.template.md`; gitignore.baseline line
  becomes `.ai/progress.md`; foundation-init seeds `.ai/memory.md`;
  the AGENTS baseline workflow text references the `.ai/` paths.
  Semantics settled: progress is the chronological (log-like) file,
  memory is the knowledge file. Exact directory name is the
  maintainer's to confirm at implementation (`.ai/` has the
  BrewUI/ecosystem precedent).
- **18.7 typos**: evaluate → **adopt** (maintainer confirmed).
- **18.8 Brewfile template**: candidate → **queued** (confirmed).
- **Swift triggers are concrete, not hypothetical**: babble plans
  the Swift notifier as a configurable option, and
  toobuntu/powerstatus (dormant) is Swift. The Mintfile-pin +
  periphery revisit rides the swift_plugin work when either lands;
  the manifest's babble swift_plugin CONFIRM already anticipates it.
- **Dormant repos** eventually come under RF management: list them
  in the manifest as commented/deferred consumer entries; onboard
  via foundation-init at revival.
- **mas stays in babble** (updates included) — corrected Brewy
  findings and the modernization notes (mas `update` verb, bundle
  IDs, JSON output) recorded in c2-next-steps.md's 2026-07-14
  addendum.
- **18.2 third bullet revised (pending final ruling)**: for missing
  sentinel markers, recommendation now follows fleet — fail loudly;
  foundation-init (or the § 15 reconciliation's hand-staging) is the
  only creator of managed regions, and the engine's append path is
  removed. Replacing whole baseline-merge files outright stays off
  the table: those four targets exist precisely because consumers
  own content around the region; `mode: canonical` files are already
  replaced outright.
- **18.4 gains a decisive pre-adoption test**: the GraphQL schema
  does not document file-mode semantics for `FileChanges`, and RF
  ships executable scripts (§ 1.4 was an exec-bit repair). Before
  choosing createCommitOnBranch over the machine-user path, test in
  a scratch repo: commit a 100755 script, modify it via the
  mutation, `git ls-tree` the result. Mode preserved → API path
  (zero key custody); mode reset to 100644 → machine-user path
  (fighting the API for exec bits is a kludge RF should not carry).
  Also confirmed from the schema: author/committer are fixed to the
  authenticating credential (no override, by design), and commits
  are auto-signed and Verified.
- **18.1 design corollary** (from the reusable-workflow question):
  implement foundation-guard.yml as a SELF-CONTAINED canonical
  workflow (checkout RF at a pinned SHA inside the job), not a thin
  caller of an RF-hosted reusable workflow — consumers then still
  carry zero cross-repo `uses:` pins, preserving the property that
  makes the monotonic-guard/CalVer skips valid. The composite action
  at .github/actions/sync/ is hub-internal (used only by RF's own
  workflows via a local path) and never appears in a consumer.
- **Open for maintainer ruling** after the 2026-07-14 session
  elaboration: createCommitOnBranch vs machine user (test above
  decides); the 18.2 fail-loud revision; RF remaining separate from
  toobuntu/dot-github (recommended keep — record as a short ADR);
  sync-system naming (recommended: no "fleet"-style codename;
  codify the existing stems — consumer-facing `foundation-*`,
  hub-side `sync-*`); scripts/ discoverability (recommended:
  scripts/README.md audience/when-to-run table now, plus a thin
  justfile front door whose recipes only call the scripts;
  enforcement paths never depend on the runner).

### 18b. Mode test performed; second-pass rulings (2026-07-14)

**The 18.4 pre-adoption test ran** (scratch repo
toobuntu/rf-createcommit-mode-test, branch `modetest`; left in place
as evidence — maintainer deletes at leisure). Results:

- Seed: script.sh committed at 100755 via REST Git Data
  (`tree` API accepts `mode:` as documented) — but that commit is
  **unsigned** (`verification.reason: unsigned`): the REST
  mode-setting path costs the signature.
- **Existing 100755 file modified via createCommitOnBranch KEEPS
  100755** (tree 60ff9211… of commit 827da810…). The community
  discussion's pessimism applies to SETTING modes, not keeping them.
- New file added via the mutation arrives **100644** (no way to
  create executables through it).
- Mutation commits: author = token owner, committer = GitHub,
  `verification: {verified: true, reason: valid}`.

**Consequence — the 18.4 decision rule resolves to the API path**
(zero key custody; machine-user/SSH-secret setup retired from the
bootstrap checklist), with one standing rule replacing the exec-bit
worry: **executables enter a consumer with their modes via a local,
maintainer-committed step** — foundation-init for fresh consumers
(extend init to copy the executable canon: .githooks/*, scripts/*),
the § 15 first-sync cleanup's chmod commit for already-onboarded
ones — and the sync thereafter only MODIFIES them (mode preserved,
verified above). If a brand-new executable is ever added to the
canon post-onboarding, the sync PR lands it 100644; the consumer's
synced lint-perms CI catches it and one `git update-index
--chmod=+x` commit on the PR fixes it. Rare, loud, cheap.

**Second-pass rulings recorded** (maintainer, 2026-07-14):

- `.ai/` name confirmed.
- RF-stays-separate ADR: accepted. foundation-*/sync- naming
  codification: accepted. scripts/README.md + front-door shape:
  accepted (just-vs-make value question answered in chat; runner
  choice is low-stakes because recipes only call scripts).
- mas `--bundle` flag verified against mas help (list/outdated/
  update); `update` has no `--json` — c2 addendum updated with the
  gather-via-outdated-then-update shape.

**Onboarding design settled** (the "could RF run foundation-init
remotely?" question): keep init-first as the documented happy path;
the sync does NOT seed consumer-owned files. Ownership boundary:
the sync owns managed surfaces; foundation-init seeds
consumer-owned ones (.vale.ini, per-repo CI scaffolds, licensing) —
a sync PR that seeded consumer-owned files would blur exactly the
"do not modify it directly" line the headers draw. Engine/workflow
changes queued instead:

- Baseline-merge behavior by file state (unambiguous, no bootstrap
  flag needed): target ABSENT → create as region-only file (safe —
  nothing to lose; an empty repo onboards to a valid minimal PR);
  markers present → replace region; file present WITHOUT markers →
  hard error (the 18.2 revision).
- That error emits a GitHub Actions annotation naming the fix:
  "AGENTS.md exists but has no managed region — run
  scripts/foundation-init.sh from a repo-foundation checkout
  against this repo, commit, then re-dispatch the sync." Matrix
  already runs fail-fast: false, so one un-bootstrapped consumer
  never blocks the others.
- sync-to-consumers.yml workflow_dispatch gains an optional
  `consumer` input filtering the matrix to one repo — onboarding
  never waits for the Monday cron: init → push → App install →
  dispatch(consumer) → merge PR.

### 18c. Third-pass rulings (2026-07-14): mutation approved; self-heal refined; workflow.md reconciliation

**createCommitOnBranch switch: APPROVED** (maintainer, conditional
on new-script manageability — confirmed). The full lifecycle for a
new executable added to the canon post-onboarding: (1) sync PR lands
it 100644; (2) the consumer's synced lint-perms CI fails the sync PR
pre-merge — loud, never latent; (3) fix is one maintainer commit on
the PR branch (`git update-index --chmod=+x` — maintainer-signed, so
still Verified); (4) NOTE: today's workflow force-recreates the sync
branch from main on every run, which would clobber any human commit
on it — queue the idempotence improvement (render against the
existing sync branch head; push only when rendered content differs)
so bot re-runs never clobber fix-ups (this also stops PR-review
churn generally); (5) the engine knows source modes
(source_file.stat.mode), so in API mode it pre-warns at render time
(annotation + PR-body line: "new executable <path> lands
non-executable; chmod on the PR branch"). Steady-state modification
is mode-safe (18b test). Onboarding-time executables arrive via
foundation-init / § 15 cleanup with correct modes.

**18.2/18b missing-markers policy refined (supersedes both): the
history split.** Maintainer principle: self-heal when the correct
disposition is mechanically certain; otherwise describe the problem
AND suggest the disposition. Markers absent + file exists →
`git log --max-count=1 -S"<begin sentinel>" -- <path>` in the
consumer checkout:

- Marker NEVER in the file's history → bootstrap case, no human
  intent to misread → self-heal: append the region (today's
  behavior), and note it in the sync PR body ("managed region
  bootstrapped into existing AGENTS.md"). Region POSITION is
  consumer-owned — the engine replaces between markers wherever they
  sit — so end-of-file placement is a default the consumer may
  relocate, not a defect.
- Marker WAS in history (deleted or destroyed) → intent is not
  mechanically determinable (deliberate opt-out vs accident) →
  abort, with the determined context and both dispositions: "managed
  region last present at <short-sha>; restore the markers
  (git restore --source=<sha> -- <path>, then re-dispatch), or
  record an opt-out as an exclude entry with a reason in
  sync-manifest.yaml (§ 18.3)."
- Requires fetch-depth: 0 on the consumer checkout (trivial at org
  repo sizes). If history is unavailable (shallow), degrade to
  abort-with-hint — never self-heal blind.
- The foundation-guard (18.1) rejects region deletions at PR time,
  so the abort branch mostly catches non-PR drift; both nets carry
  the same message.

**Onboarding documentation** (the "where would the creator find out
what to do?" question): docs/usage.md already has "Bootstrap a new
consumer" with the foundation-init command — extend that section
into the full ordered path: create repo → `scripts/foundation-init.sh
[--license SPDX-ID] <target>` → review + commit + push → add
consumer entry to sync-manifest.yaml → install toobuntu-token-app on
the repo → dispatch sync-to-consumers with `consumer=<slug>` → merge
the sync PR. Companions: foundation-init prints those next steps on
completion; RF README links the section; examples/minimal-repo
remains the worked result. This is maintainer-internal process, so
it lives in RF, not toobuntu/dot-github (the outward contributor
surface). Annotation copy (GitHub annotations render no newlines —
single line + pointer): `AGENTS.md exists but has no managed region
— see toobuntu/repo-foundation docs/usage.md ("Bootstrap a new
consumer")`; the full command sequence goes in the step log and the
doc, not the annotation.

**just: approved with conditions (recorded as invariants):**
convenience-only — hooks, CI, and scripts NEVER invoke just; every
recipe is a one-line call into scripts/ (so the runner is swappable
and recipe bodies contain nothing to lint); installed via the
Brewfile template as a maintainer/contributor convenience;
documented in scripts/README.md and usage.md. Ship justfile as a
baseline-merge target (hash-comment sentinels): org recipes inside
the managed region, repo-specific recipes outside (fleet precedent).

**docs/workflow.md reconciliation (discovered this pass):** RF
already carries a PROPOSED (2026-06-16, unconfirmed) docs-and-task
workflow doc attacking the same sprawl problem. The 18.6
implementation must reconcile with it rather than land beside it:

- Keep from workflow.md (already aligned): the status-vs-design
  split; the dated-snapshot ban (git history is the archive); one
  living roadmap — master-plan.md moves to
  repo-foundation/docs/roadmap.md; drain workspace/ incrementally.
- Replace its gitignored rolling `docs/handoff.md` with
  `.ai/progress.md` — same mechanism (gitignored, per-developer,
  rewritten not appended), richer committed template, and the name
  avoids colliding with docs/handoff/ (which stays: live opening
  prompts, per the genre rule).
- Add what workflow.md lacks: `.ai/memory.md`, the durable
  non-decision knowledge bucket (its taxonomy jumps from ADRs to
  reference docs with nothing for gotchas/constraints/queued intents
  — the rf-upstream-notes genre).
- Its open decision 1 (task substrate) is still the maintainer's:
  recommendation — GitHub Issues as the atom with labels
  (tech-debt, W-effort) and per-repo milestones; skip the org
  Project board until it earns its keep (single-maintainer org;
  saved issue searches + roadmap links suffice). Claude reads and
  writes issues via gh, so surfaced action items stop scrolling
  away in chat.
- Once reconciled, drop PROPOSED; workflow.md becomes the umbrella
  convention and the .ai/ files its continuity layer.

### 18d. Fourth pass (2026-07-14): docs split; commit-mechanics evidence round; ephemeral branches

**Onboarding gets its own doc.** New `docs/adding-a-repo.md` (final
name the maintainer's; docs/ convention is lowercase) — succinct,
plain-language, the complete ordered command sequence: create repo →
`scripts/foundation-init.sh [--license SPDX-ID] <target>` → review,
commit, push → add the consumer entry to sync-manifest.yaml →
install toobuntu-token-app on the repo → dispatch sync-to-consumers
with `consumer=<slug>` → merge the sync PR → for repos with
pre-existing content, the § 15 reconciliation pointer.
Discoverability: README gains its own short "Adding a repository"
section linking the doc (not just README → usage.md); usage.md's
bootstrap section shrinks to a pointer; foundation-init prints the
next steps on completion; the engine's annotations point at the doc.

**Docs architecture (four docs, one job each):** README = what and
why + pointers; NEW `docs/architecture.md` (org convention —
cask-tools and babble already carry one; RF has none) = how it is
built: both sync directions, engine modes and the ownership tiers,
manifest schema, guard, commit/PR mechanics, trust boundaries —
AGENTS.md's Architecture block shrinks to a pointer; `docs/usage.md`
= how it is operated day to day (what a consumer receives, receiving
a sync, scaffold freshness, user-global config, worked example — its
existing content minus bootstrap); `docs/adding-a-repo.md` = the
onboarding runbook.

**Bootstrap region placement (maintainer ruling): prepend, not
append.** In the never-in-history self-heal case, Markdown targets
get the region right after the H1 (skipping YAML frontmatter and
SPDX blocks — the engine's insert_point machinery already does
this); hash-comment targets get it after the leading comment/SPDX
block. Rationale: the org baseline is framing context and should
meet a top-down reader first; end-of-file buries it. Position
remains consumer-owned afterward. The abort message gains the date:
"managed region last present at <short-sha> (YYYY-MM-DD)".

**Commit mechanics — evidence round.**
Homebrew/actions/api-commit-and-push evaluated and REJECTED for RF:
it replays staged local changes through REST Git Data with
`mode: "100644"` hardcoded — actively mode-destructive here (every
touched executable would lose +x on every sync, strictly worse than
createCommitOnBranch, which preserves modes on modification per the
18b test); its deletion semantics look doubtful; and GitHub code
search finds ZERO adopters beyond its own README — new and unproven.
Its README's claim ("useful for GitHub Apps which need to use the
API in order to sign commits") implies App-token REST Git Data
commits get signed, which contradicts the 18b user-token result
(unsigned) — token-type-dependent signing is plausible and decisive,
so queue the five-minute CI experiment: a scratch workflow step
mints the sync App token, creates one REST git-data commit (tree
with mode 100755) on toobuntu/rf-createcommit-mode-test, reads back
`.commit.verification`. Outcomes:

- App-token git-data commits ARE verified → adopt a small OWN REST
  git-data loop (not the unproven action): full mode + deletion
  control, Verified, no machine user, and the new-executable case
  vanishes (modes ride in the trees). Best of all worlds if true.
- NOT verified → the maintainer's remaining choice is machine user
  (ZERO engine/workflow code — the setup-commit-signing step is
  already wired behind SYNC_BOT_SIGN; local git sets modes natively;
  uniform SSH-signed Verified; costs one account + a rotatable
  signing-only key, which cannot push — impersonation-only risk) vs
  the createCommitOnBranch hybrid (most engine work; rare unsigned
  REST mode-fix commits). The 18c "API path approved" ruling is
  SUSPENDED pending this test; the maintainer's instinct that the
  machine-user path is not yet dismissed is correct — on current
  evidence it is the boring front-runner if the App-token test
  comes back unsigned.

Also established: GitHub suggested-change review comments cannot
carry file-mode changes (content-only), so the one-button-commit
idea is structurally unavailable for the mode case. Sibling actions:
setup-commit-signing is the already-wired machine-user path;
git-try-push (retry contended pushes) is useful if local-git push is
kept; git-user-config / create-pull-request / post-comment are thin
conveniences the existing gh calls in RF already cover.

**Ephemeral sync branches (adopt, any commit path):**
Dependabot/fleet-style — one branch per sync run
(`sync/<date-or-run>`), skip entirely when an open sync PR already
matches the rendered content, auto-close superseded sync PRs with a
comment. Replaces the eternal force-pushed `sync-from-foundation`
branch; solves stale-PR reuse and the human-fix-up clobber in one
move; subsumes 18c's idempotence item.

**check-commit-format (Homebrew/actions): candidate for
brew-aligned consumers** (homebrew-babble, homebrew-cask-tools) — PR
check enforcing Homebrew commit style with label flow
(automerge-skip on failure, autosquash, ignore label). Production
evidence (maintainer grep, 2026-07-14): used by homebrew-core and
homebrew-cask in their triage.yml, NOT by Homebrew/brew itself — so
it is the TAP-side enforcement, precedent directly on point for the
org's two taps. Settle the interplay with § 1.5's
reject-conventional-commits pull + commit-msg hook at implementation
(read its main.mts rules then; it may complement or supersede the
workflow half). Pin per pinact like existing Homebrew/actions uses.

**Front door: converge on make, not just (CORRECTED 2026-07-14 —
the first inventory was wrong).** An earlier pass claimed no active
repo has a Makefile; the command ran under zsh, whose glob-abort on
one non-matching pattern (GNUmakefile) suppressed the whole listing.
The true inventory (maintainer's find): active blackoutd,
cert-automation, AND zman-didan each carry a substantial Makefile —
build targets plus quality/task targets (blackoutd: build + daemon
lifecycle + format/tidy/lint/test/check; cert-automation: all =
lint + build, with a help target; zman-didan: Go build + check =
style scan test, vale/actionlint/zizmor/reuse/hooks). So make is
the org's de facto front door already, three-for-three in active
code repos — and checkmake.ini is in use, not anticipatory. That
flips the recommendation: RF gets a MAKEFILE (help target + check +
wrappers over scripts/), the org standardizes the target VOCABULARY
(check/lint/test/build/help) rather than adopting a second runner,
and the real observed gap — three hand-rolled front doors with
drifting target names — is fixed by convention (repo-standards doc,
18e) now and possibly a synced include later. just drops to
revisit-if-make-friction-accrues; its `--list` discoverability is
real but does not outweigh converging on the incumbent.
scripts/README.md stands regardless.

**workflow.md task substrate — refined recommendation (maintainer
doubts sole-GH-Issues; agreed).** Three tiers, files as the local
atoms:

1. `.ai/progress.md` (gitignored) — session state.
2. Committed in-repo registers — `docs/technical-debt.md` STAYS the
   per-repo backlog (established org convention and load-bearing:
   the C.2 prompt references its P-numbers; workflow.md's
   "tech-debt becomes labels" clause is dropped) and `.ai/memory.md`
   holds durable knowledge. Local-first, greppable, agent-readable
   without network.
3. GitHub Issues as the PROMOTION tier, not the atom: an item
   graduates when it needs PR cross-references, changes state across
   sessions, or invites outside contribution. Claude files/updates
   them via gh so surfaced action items stop scrolling away.

docs/roadmap.md (ex-master-plan) links registers and issues; the org
Project board stays skipped until a second maintainer exists.

### 18e. Fifth pass (2026-07-14): vale rule fixed; App-token test staged; docs answers; debt lifecycle

**Vale AbbreviationPlurals rule FIXED and verified** (it was already
a POS-tagged sequence rule designed to pass possessives; the two
false positives were tag-set gaps): the negated tag set gains
VBG|VBN|TO|CD — participial adjectives ("RF's existing calls"),
predicative infinitives ("is RF's to fix"), numbers. Verified: both
constructions pass; `several PR's were merged` still fires. Same
precision-over-recall trade the rule's own header documents for its
JJ extension; comment updated in the rule file. Rule is in the
synced prose_lint set, so the fix reaches every consumer at sync.

**App-token Git Data signing test STAGED** (the agent cannot run it:
minting an installation token needs SYNC_APP_PRIVATE_KEY, which
lives only in RF's Actions secrets — correctly out of local reach).
The workflow is written at .github/workflows/zz-app-signing-test.yml
(actionlint + zizmor clean; no checkout; permissions: {}; creates
one Git Data commit with a 100755 tree entry on a throwaway RF
branch via the App token, prints RESULT mode + RESULT verification,
deletes the branch). To run: scripts/annotate.sh (SPDX), commit to
main (workflow_dispatch is only reliably dispatchable from the
default branch), `gh workflow run zz-app-signing-test.yml`, read the
two RESULT lines in the job log, delete the file. verified:true →
own Git Data loop wins (18d); unsigned → machine user vs
createCommitOnBranch hybrid, maintainer's call.

**Onboarding is ONE doc** (no duplicated guide): the full runbook in
docs/, and README carries only a quick-reference card — the one-line
step list + link. Doc name: maintainer's pick between
docs/onboarding.md (one word; covers both a new repo and bringing an
existing repo under management) and docs/adding-a-repo.md (more
self-describing to an outsider); slight recommendation for
onboarding.md since the org already uses the term throughout.

**usage.md**: keep the filename (renames churn cross-references for
marginal gain); sharpen the H1/intro to the operator-guide framing
("Operating repo-foundation: what consumers receive, how syncs
arrive, keeping scaffolds fresh") once the bootstrap section moves
to the onboarding doc.

**NEW: docs/repo-standards.md** (fills a real gap none of
README/architecture/usage covers): one page stating what is expected
of every org repo — signed commits, REUSE compliance, ADR practice
(org-wide decisions live in RF, per-repo ADRs from 0001), hooks
activated (core.hooksPath), synced CI green, prose style, naming
conventions (technical-debt.md, docs layout), Makefile target
vocabulary (18d correction) — with each standard naming its
enforcing check (hook, CI job, doctor). Doubles as
foundation-doctor's eventual checklist; linked from the CONTRIBUTING
baseline and the onboarding doc.

**Sentinels: both markers confirmed already present** — the engine
renders begin AND end lines per region (`>>> label >>>` /
`<<< label <<<` in the host comment syntax) and validates both
counts; fleet parity was already there. The 18.2 fixes (inverted
pair, Markdown padding) stand; no further change.

**technical-debt.md lifecycle (the garbage-collection design the
maintainer asked for):** the file is a register of OPEN items only,
never a ledger. A resolved item is DELETED in the same PR that
resolves it (the commit references the item number; git history is
the ledger — same principle as the snapshot ban). Item numbers
(babble's P-style) are never reused, so references in old prompts
and commits stay meaningful. An item needing longitudinal
discussion, cross-PR tracking, or outside visibility graduates to a
GitHub issue and its file entry shrinks to one line with the issue
link, deleted when the issue closes. Bounded file, full history,
closure semantics on both tiers. Terminology, recorded: "registers"
= the committed per-repo files (technical-debt.md + .ai/memory.md);
status lives in .ai/progress.md and issues; design/intent lives in
ADRs, architecture.md, and .ai/memory.md; the ONE living roadmap is
the FILE repo-foundation/docs/roadmap.md (the renamed master-plan) —
not GitHub infrastructure — linking registers and issues.

**Maintainer housekeeping noted:** certctl-additions.retired.archived
moves under an _archived/ location of the maintainer's choosing
(rekey ~/.claude.json only if it had a projects entry).

### 18f. Sixth pass (2026-07-14): warning companion; debt ledger; doc names; local test script

**Vale second pass ADDED and verified** (maintainer request):
.vale/styles/Toobuntu/AbbreviationPluralsAmbiguous.yml fires at
WARNING on exactly the four tags the error rule now passes
(VBG|VBN|TO|CD), so the reduced-relative plural misuse (`the PR's
merged yesterday were…`) is surfaced instead of lost. By design it
also warns on legitimate possessives in those contexts ("RF's
existing calls") — resolve by reading, not rewording; the rule
comment says so. It stays at warning permanently (inherently
ambiguous, never promotable — distinct from the .vale.ini
warning-then-promote pipeline). Warnings do not gate
(MinAlertLevel = error); view them with
`vale --minAlertLevel=warning` or an editor integration. Added to
the prose_lint set in sync-manifest.yaml. Needs annotate.sh before
commit.

**technical-debt lifecycle REVISED (maintainer veto of
delete-in-place — bare P-number references elsewhere would point at
nothing).** Resolved entries MOVE, never merely delete: the active
docs/technical-debt.md stays a register of open items only, and a
sidecar — recommended name docs/technical-debt-resolved.md
("resolved" is the plainest of the candidates; "ledger" is metaphor,
"history" collides with git history, "closed" is issue vocabulary) —
receives each resolved entry with its P-number (never reused), the
resolution date, a capsule summary, and the PR/issue link; entries
may run longer than one line. A P-number cited in any prompt,
commit, or issue then greps to exactly one of two files, forever.
Supersedes 18e's delete-in-place design.

**repo-standards.md gains the tests requirement**: every org repo
ships tests matching the org pattern for its languages (RSpec for
shell/Ruby hook-and-script suites, per the ruby_hook_tests set;
Swift Testing for Swift; and so on), enforced by the repo's spec/CI
jobs.

**Doc names settled**: onboarding doc = docs/adding-a-repo.md (the
maintainer's original instinct; "onboarding" judged too abstract and
less discoverable — "adding" covers a brand-new repo and an existing
repo equally, since either is being added to the sync). usage.md
rename is back on (maintainer overrode the churn concern:
pre-first-sync is the cheap moment, the same argument used
everywhere else in this queue) — recommended
docs/maintaining-a-repo.md, forming the verb-first pair
adding-a-repo.md / maintaining-a-repo.md; the maintainer's
managing-repos/repo-management candidates read as hub-operator
titles and collide with the onboarding doc's territory. The
user-global-config section (provides/claude-user) moves to the
README at the split — it is maintainer-machine setup, not repo
maintenance.

**App-token test: local script is now the primary path** (the
maintainer holds the App private key). workspace/app-signing-test.sh
— POSIX sh; dash -n, ksh -n, shellcheck, checkbashisms all clean;
executable. Usage:
`./app-signing-test.sh APP-CLIENT-ID PRIVATE-KEY.pem [OWNER/REPO]`
(defaults to toobuntu/repo-foundation). It mints a 9-minute App JWT
with openssl, exchanges it for an installation token scoped to
contents:write on the one repo, makes ONE Git Data commit with a
100755 tree entry on throwaway branch zz-app-signing-test, prints
`RESULT mode:` and `RESULT verification:`, deletes the branch, and
revokes the token. Interpretation is in the script header
(verified:true → RF's own Git Data loop wins per 18d; unsigned →
machine user vs createCommitOnBranch hybrid). The
zz-app-signing-test.yml workflow stays as the CI fallback.

### 18g. Seventh pass (2026-07-14): two-pass vale wiring; script v2; placement rules

**Test script v2 (first run failed usefully).** The maintainer's run
produced one 422 then six 401s: v1 piped curl into jq, and POSIX sh
has no pipefail, so the first failure's error body flowed into jq,
variables went empty, and every later call cascaded as 401 with the
root cause hidden. v2 (same path, all four shell checks clean) fails
fast at the FIRST error, names the step (list-installations,
mint-token, create-blob, …), and prints GitHub's error body — whose
"message" field names exactly what was rejected. `DEBUG=1` prints
every call's step/method/path/status plus response bodies to stderr
(the token-mint response is redacted; the JWT and token are never
printed). Re-run: `DEBUG=1 ./app-signing-test.sh CLIENT-ID KEY.pem`;
the 422's body will identify the cause (leading suspects: the
access-token request body, or repository access on the
installation).

**422 DIAGNOSED (maintainer's DEBUG run):** the flow itself is
proven — JWT accepted, installation 126011516 found with
contents:write. The scoped token mint failed with GitHub's "at least
one repository... is not accessible to the parent installation," and
the installation shows `repository_selection: "selected"` — so
**repo-foundation is not currently on the installation's
selected-repository list**, contradicting § 15's recorded access
list (repo-foundation, homebrew-cask-tools, CrimsonProT), which is
therefore stale or was never completed. This matters beyond the
test: sync-to-consumers.yml mints tokens the same way and would hit
the same wall. Fix: add repo-foundation at
https://github.com/settings/installations/126011516 (Repository
access), then re-run. The maintainer's server-to-server question:
answered no — the installation-token flow IS server-to-server; the
user-access-token flow is the on-behalf-of-a-user variant, unused
here. The script now SELF-DIAGNOSES this failure mode: on a mint
422 it mints an unscoped token, prints the repositories the
installation can actually access plus the settings URL, revokes,
and exits. Update § 15's App-status line once the true list is
known.

**Two-pass vale wiring (maintainer directive), commands VERIFIED
locally**: the infrastructure keeps `MinAlertLevel = error` as the
gate; the 15-prose pre-commit plugin and the prose.yml CI job each
gain a second, NON-gating pass surfacing only the ambiguous-plural
rule:

    vale --no-exit --minAlertLevel=warning \
      --filter='.Name == "Toobuntu.AbbreviationPluralsAmbiguous"' <paths>

Verified: the filter isolates the one rule (Vale.Spelling and the
rest stay out of the second pass, per the maintainer's
overwhelming-warnings concern) and `--no-exit` returns 0 with
warnings present. Implement in both canonicals at the RF session.

**annotate.sh runs fine in this sandbox** (maintainer challenged the
claim; tested: it annotated the new vale rule file directly). The
"annotate.sh itself no-ops in sandboxes" line in c2-next-steps.md's
locked-decisions paragraph describes babble's Tier-3 clone context
and should be revisited there — as written it reads as a general
claim and this session disproves the general form.

**Placement rules recorded (memory.md vs agent-principles.md — the
maintainer's question):** docs/agent-principles.md holds NORMATIVE,
org-wide rules of conduct and method — anything a new agent on ANY
org repo should obey; synced, contributor-visible. .ai/memory.md
holds DESCRIPTIVE per-repo knowledge — facts, constraints, gotchas
about this project's reality; dated log entries. Claude's private
memory holds personal maintainer-agent interaction preferences
(18a). Boundary test: if the sentence would make sense unchanged in
a different organization's repo, it is principles-shaped; if it is
about one repo's reality, it is memory-shaped. Applying it: the
restate-referents rule ("when citing a numbered item — a point, a
P-number, a § — attach a capsule of its content; never let an
identifier outlive its definition") is conduct, org-wide → queue it
for agent-principles.md (natural home: beside "Plain, literal
prose"), where the sync carries it everywhere.

**Doc names ACCEPTED** (maintainer): docs/adding-a-repo.md +
docs/maintaining-a-repo.md. The user-global ~/.claude config section
does NOT move to the README (maintainer veto — not repo info): it
moves to docs/bootstrap/, the existing home for maintainer-machine
setup (branch-protection.md, sync-bot-and-signing.md live there) —
as docs/bootstrap/claude-user-config.md or a section in a
maintainer-setup doc there.

### 18h. Eighth pass (2026-07-14): the cron is live; hct PR #49 is open; test target settled

**App-install state corrected** (maintainer): the App covers ONLY
homebrew-cask-tools and CrimsonProT today — repo-foundation was
never on the list; § 15's access line was wrong about
repo-foundation too.

**Live finding (gh, 2026-07-14): the sync is not hypothetical.**
sync-to-consumers.yml's Monday cron has fired on 2026-07-06 and
2026-07-13 (plus a push run when RF PR #1 merged); six matrix legs
fail at token minting (no App access — that protection works), but
hct's leg SUCCEEDS: **homebrew-cask-tools PR #49 ("Sync shared
configuration from repo-foundation") is open, created 2026-07-13**
— a real first-sync rendering against a real consumer, standing
open before the § 15 freshness audit exists.

Dispositions:

- **Do not merge hct #49 yet** — it proposes RF's canonicals over
  hct's tree ahead of the audit. Its diff is valuable, though: it is
  the § 15 audit in miniature, PR-shaped — review it as the first
  real per-file disposition list for hct.
- **Disable the schedule until the audit ships** (maintainer
  one-liner): `gh workflow disable "Sync to consumers" --repo
  toobuntu/repo-foundation` (reversible; workflow_dispatch still
  works for deliberate runs). This is the clean pre-first-sync
  state: no scheduled surprises anywhere, dispatch-only.
- **Mechanics clarified for the RF-install wariness**: installing
  the App on RF does NOT enable consumer syncs — each matrix leg
  mints a token scoped to that CONSUMER, so babble stays unreachable
  until the App is installed on babble, regardless of RF. What an RF
  install enables is sync-from-upstreams opening PRs on RF itself
  (also merge-gated). The deferred-installs policy (§ 15) stands
  unchanged; with the schedule disabled, RF's own install carries no
  standing risk when it eventually happens.

**Signing-test target settled**: no new repo needed — reuse the
existing private scratch repo toobuntu/rf-createcommit-mode-test
(already holds the 18b mutation-test debris; everything deletes
together later). Maintainer installs the App on it (one click at
the installation's Repository access), then:
`./app-signing-test.sh CLIENT-ID KEY.pem toobuntu/rf-createcommit-mode-test`
— the script's third argument targets it; its main branch exists.

### 18i. TEST RESULT (2026-07-15): App-token Git Data commits are signed — the Git Data loop wins

Maintainer ran the script against the scratch repo. Both answers,
verbatim: `RESULT mode: 100755` and
`RESULT verification: {"verified":true,"reason":"valid"}`. The debug
detail confirms every element: the NEW file carried 100755 (set via
the tree API — the thing createCommitOnBranch cannot do), the commit
carries a GitHub PGP signature (committer `GitHub <noreply@github.com>`,
web-flow), author is a clean `toobuntu-token-app[bot]` identity with
no configuration, and cleanup worked (ref deleted, token revoked).
Combined with 18b's user-token result (unsigned), signing of Git
Data commits is **token-type-dependent**: App installation tokens
get web-flow signing; user tokens do not. Homebrew's
api-commit-and-push README claim is confirmed — their hardcoded-mode
implementation remains rejected, but the mechanism it relies on is
real.

**Resolution (per the 18d decision rule the maintainer
pre-approved): RF adopts its OWN REST Git Data loop** for
sync-to-consumers (and sync-from-upstreams) commits. Everything
lands at once:

- Real file modes on new AND modified files (the new-executable
  problem vanishes — modes ride in the trees, from
  source_file.stat.mode the engine already computes).
- Verified commits, no machine user, no SSH signing key ever
  created: sync-bot-and-signing.md § 2's machine-user path retires
  UNIMPLEMENTED; SYNC_BOT_SIGN / SYNC_BOT_NAME / SYNC_BOT_EMAIL
  vars, the SYNC_APP_SSH_SIGNING_KEY secret, and the
  setup-commit-signing step come out of sync-to-consumers.yml; the
  actionlint.yaml config-variables mutation in the manifest shrinks
  to SYNC_APP_CLIENT_ID alone. Rewrite § 2 around the Git Data path.
- createCommitOnBranch is retired too (no longer needed for
  anything; its mode gap was the only open question).

Implementation notes for the RF session:

- Keep per-file commits: chain N blob→tree→commit rounds (each tree
  built on the previous commit's tree), one ref update per commit or
  one at the end; branch created fresh from the consumer's main head
  (ephemeral branches per 18d). No CAS equivalent of
  expectedHeadOid in Git Data ref creation, but the workflow-level
  concurrency group already serializes runs.
- Deletions: tree entry with `sha: null` removes the path.
- The engine can stay stdlib-only: Ruby net/http covers the four
  endpoints; alternatively the workflow drives `gh api` around an
  engine that emits the change list. Choose at implementation.
- Cleanup now unblocked: uninstall the App from the scratch repo and
  delete toobuntu/rf-createcommit-mode-test whenever; delete the
  now-superseded .github/workflows/zz-app-signing-test.yml (never
  committed); workspace/app-signing-test.sh is the durable record of
  how the answer was obtained and can stay in workspace/.

This closes the last open datum of the reference-evaluation
follow-on. Remaining maintainer decisions stand as listed in
18a–18h (sentinel history-split blessing, hct PR #49 review,
schedule disable, § 15 status correction).

### 18j. Ninth pass (2026-07-15): hct #41; paths stay stripped; branch discovery; org dispatch

- **hct PR #41: already ruled** — pr36-reconciliation-outcome.md (on
  the feature/pr36-adr-tooling branch) says close it unmerged; its
  content is upstream config the RF pipeline supersedes. Side
  effect recorded there: hct's scheduled sync-shared-config.yml
  re-creates the PR on Wednesdays while it exists, so also
  `gh workflow disable "Sync shared configuration"` on hct; the
  cutover deletes the workflow.
- **actionlint paths policy: KEEP the del(.paths) mutation** (this
  corrects the 18-series lean toward keeping paths verbatim). #41's
  payload was brew's new paths ignore keyed on the GENERIC filename
  tests.yml — and babble's tests.yml is the maintainer's own
  independent workflow, unrelated to brew's beyond the name. A
  name-keyed brew-internal ignore would mask unknown-permission-
  scope findings in consumer files that merely share the name. If a
  consumer ever needs a paths rule, it enters RF's mirrored copy as
  a deliberate, commented addition — never relayed blind.
- **§ 15 audit inputs the queue was missing (maintainer,
  2026-07-15)**: blackoutd carries its own RF-reconciliation notes —
  `docs/handoff/repo-foundation-tooling.2026-06-14.md` and
  `docs/handoff/w1-scaffolding-reconcile.2026-06-15.md` — REQUIRED
  reading for the repairs session and the § 15 audit run (each
  consumer's own reconcile notes are dispositions waiting to be
  consumed; sweep every consumer's docs/handoff/ for the same genre
  before the audit). Two new RF-management candidates from the same
  look: **blackoutd docs/branch-protection.md** — branch-protection
  documentation looks RF-manageable with per-repo mutations keyed on
  the workflow jobs each consumer actually runs (required checks
  differ per repo; relates to docs/bootstrap/branch-protection.md
  and the 18.1 guard's required-by-name backstop) — and
  **docs/releases.md** (release-process doc; assess canonical vs
  baseline-merge vs per-repo). To be clear about state: the
  reconciliation itself has NOT run yet — nothing was "missed" from
  a pass that has not happened; these entries make sure it cannot be
  missed when it does.
- **Session-map correction (continuity proof case)**: the PR #36
  ADR-tooling reconciliation session already happened — its 8
  commits sit unpushed on feature/pr36-adr-tooling (all unsigned,
  `%G? = N`), yet the 2026-07-15 session map listed it as pending.
  This session's commits join that branch; one re-sign blesses the
  whole batch. The class of state that failed here (which sessions
  are done-but-unpushed, what the maintainer owes next) now has an
  owner: the org dispatch layer — workspace/dispatch.md plus
  org-scoped workspace/.ai/{memory,progress}.md, adopted 2026-07-15,
  mirroring the per-repo .ai pattern; sessions that cannot write
  workspace relay via a gitignored `<repo>/.ai/org/` drop the
  maintainer or the next desktop-rooted session merges. The
  conventions session folds this into workflow.md and
  conversation-management.md.
