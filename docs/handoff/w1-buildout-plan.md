<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# W1 build-out — inventory, canonical map, and sync design

Backbone doc for the repo-foundation (RF) full build-out. Spans multiple
sessions. Records the cross-repo inventory, the per-file canonical-source
decisions, the locked organization + sync design, and the phased roadmap.
Authoritative for *what goes where and why*; supersedes the narrower
reconciliation framing in `bootstrap-prompt.md` where they differ.

## 1. Scope and method

W1 is a **full build-out**, not a reconciliation pass. The task:

1. Inventory every active `toobuntu/` repo's entire tree.
2. Classify each file: **canonical-in-RF → synced** · **baseline-in-RF →
   merged with repo addenda** · **repo-specific only**.
3. Decide RF's organization and implement it (existing dirtree is irrelevant;
   started fresh).
4. Place the canonical content (multi-way derived, not 2-way).
5. Design + implement the sync (manifest + Ruby engine + workflows), modeled
   on Homebrew's `Homebrew/.github` `sync-shared-config`.

**Active repos in scope:** blackoutd, babble, bob-book, cert-automation,
dot-github, homebrew-cask-tools, zman-didan, repo-foundation. **Excluded:**
`babble-refactor-modular` (WIP worktree), `_dormant/*`,
`_claude-config-baseline*`.

**Canonical derivation is multi-way.** For each artifact, enumerate every
copy across all active repos (`find … -exec stat` / `git ls-files` +
`md5`), then pick the most-evolved as canonical — or synthesize a new
canonical. A 2-way RF-vs-blackoutd diff is insufficient and was misleading
(see pre-commit and lint-perms below).

## 2. Inventory summary

Per-repo tracked-file counts: blackoutd 180, babble 167, homebrew-cask-tools
93, zman-didan 80, bob-book 50, repo-foundation 49, cert-automation 45,
dot-github 7 (pre-initial-commit). 46 distinct relpaths appear in ≥2 repos —
the sync-candidate backbone. Three buckets emerged (md5-grouped):

- **Pure-canonical (byte-identical sync):** scripts, hooks, specs,
  zizmor/actionlint configs + matcher, agent-principles.md, adrs.toml,
  `.pinact.yaml`, `checkmake.ini`, `.rspec`, `Gemfile`, LICENSES/, the
  117-byte `CLAUDE.md` one-liner (blackoutd=zman-didan; cert/hct never
  migrated).
- **Baseline + addenda (merge sync):** `AGENTS.md` (all diverge),
  `.claude/settings.json` (**RF currently == blackoutd's full 11565 bytes —
  the LCD slimming did not happen / was overwritten; must be re-derived**),
  `.gitignore`, `ci.yml`, `codeql.yml`, `dependabot.yml` (→ template),
  `Makefile`, `copilot-instructions.md`.
- **Repo-specific (filename convention only, not synced):** `README.md`,
  `docs/architecture.md`, `docs/technical-debt.md`,
  `docs/migration-investigation/`, `docs/reviews/`.

## 3. Per-artifact canonical map

`zd`=zman-didan, `bd`=blackoutd, `bb`=bob-book, `RF`=repo-foundation.

| Path | Mode | Canonical source | Notes |
|---|---|---|---|
| `.githooks/pre-commit` | canonical | **zd** | most-evolved, repo-agnostic base; classicalre `pre-commit.d` rule; `REUSE_LINT_SKIP`. **Add** working-tree-vs-staged-blob review comment (no first person). |
| `.githooks/pre-push` | canonical | identical (bd=bb=zd=RF) | settled |
| `.githooks/pre-commit.d/10-go` | example | RF | example plugin (no extension → classicalre) |
| `scripts/annotate.sh` | canonical | **bd** | fullest (plist→sidecar category + `--no-multiprocessing`). **Drop** stale "keep in sync with hct" header; sync prepends the "synced from" header. |
| `scripts/lint-perms.sh` | canonical | **zd + RF merge** | zd: classicalre pattern + `SC2016` + single-line annotation fix; RF: `LINT_PERMS_FORMAT` validation. Neither alone is canonical. |
| `scripts/lint-unicode.sh` | canonical | **bd** | `LC_ALL=C sed`, `/usr/bin/grep`, NUL/UTF-16 skip comment. |
| `scripts/rewrite-pr-as-merge-commit.sh` | canonical | identical (bd=RF) | |
| `scripts/re-sign-unpushed.sh` | canonical | RF only | new |
| `scripts/sandbox-*.sh` | canonical | RF only | W6 renames to `isolate`; `sandbox-vm-*` are mode 0640 (verify intent vs lint-perms) |
| `spec/integration/*.rb`, `spec/spec_helper.rb` | canonical | identical (bd=RF) | hook test suite (syncs with the hooks) |
| `docs/agent-principles.md` | canonical | **bd** | +3 sections (confirm-policy-intent, preserve-WIP, cross-repo-refs) + commit-chaining + zizmor; 0 leaks. Add `last_review_date`. |
| `.github/zizmor.yml` | upstream→canonical | Homebrew/.github | bd=RF 190-byte base; hct/zd added rules (revisit as addenda) |
| `.github/actionlint.yaml` | upstream→canonical | Homebrew/brew | mutated (`config-variables: [SYNC_APP_CLIENT_ID]`) |
| `.github/actionlint-matcher.json` (+`.license`) | upstream→canonical | Homebrew/brew | (initially missed) |
| `.github/workflows/actionlint.yml` | canonical | near-identical | template |
| `.github/workflows/codeql.yml` | template | per-repo language | baseline+addenda |
| `.github/workflows/ci.yml` | template | per-repo | baseline+addenda; Homebrew-tap variant noted |
| `.github/workflows/copilot-setup-steps.yml` | upstream→canonical | Homebrew/brew | mutated (core/cask false) |
| `.github/dependabot.yml` | generated | `dependabot.template.yml` | per-repo ecosystem filter (bundler, github-actions, pip) |
| `.github/copilot-instructions.md` | baseline-merge | TBD | |
| `.github/instructions/licenses.instructions.md` | canonical | bd/hct | |
| `.github/pull_request_template.md` | **dot-github** | dot-github | org-fallback community-health file |
| `adrs.toml` | canonical | 158-byte (bd=bb=zd) | `adr_dir="docs/decisions"`, `[templates] format="madr"`, no `mode=ng`. hct's 174-byte drifted. |
| `.pinact.yaml` | canonical | identical (bd=RF) | |
| `checkmake.ini` | canonical | identical (bd=RF) | |
| `.rspec` | canonical | identical (bd=RF) | |
| `Gemfile` / `Gemfile.lock` | baseline | bd=RF | test-infra baseline |
| `config` | canonical | RF | bundler `.bundle/config` content |
| `Makefile` | repo-specific (+shared targets) | per-repo | only the lint/test targets are shared convention |
| `LICENSE` | canonical | GPL-3.0 text | babble diff is the copyright line |
| `LICENSES/GPL-3.0-or-later.txt` | canonical | `reuse download` | |
| `CLAUDE.md` | canonical | 117-byte one-liner (bd=zd) | cert/hct migrate off legacy big files |
| `AGENTS.md` | baseline-merge | per-repo | shared skeleton + repo addenda; baseline → `provides/repo/AGENTS.template.md` |
| `.claude/settings.json` | baseline-merge | **re-derive LCD** | RF copy is blackoutd's full set, not an LCD |
| `.gitignore` | baseline-merge | derive base + addenda | bd huge (3811), others small |
| `README.md` | repo-specific | — | not synced (a `provides/repo/README.template.md` is optional) |
| `docs/architecture.md`, `technical-debt.md`, `reviews/`, `migration-investigation/` | repo-specific | — | filename convention only |

## 4. Organization (locked)

**Mirror layout + `.template` infix + minimal `provides/`.**

- **RF-consumed canonical at natural paths, no marker** — RF uses these and
  ships them: `.githooks/`, `scripts/`, `.github/{workflows,zizmor.yml,
  actionlint.yaml,actionlint-matcher.json,dependabot.yml,copilot-*}`,
  `docs/agent-principles.md` + org-wide docs/ADRs, `adrs.toml`, `spec/`,
  `.pinact.yaml`, `checkmake.ini`, `.rspec`, `Gemfile`, `LICENSES/`, and RF's
  own `AGENTS.md`/`CLAUDE.md`/`.claude/settings.json` (which double as the
  project-scope baseline).
- **`.template` is an infix** (`name.template.ext`) so editors/linters/Markdown
  viewers still recognize the file. Marks files consumers transform or must
  edit. Transformed templates that pair with an RF-own file live beside the
  sync engine: `.github/actions/sync/dependabot.template.yml` (Homebrew's
  exact choice).
- **`provides/` holds only files with no natural RF path:**
  - `provides/claude-user/{CLAUDE.md,settings.json}` — the version-controlled
    `~/.claude/` user-global config. Applied to the maintainer's home, **not**
    consumer-synced. (No user-global `AGENTS.md`: Claude Code auto-loads
    `CLAUDE.md` there, and no other tool reads `~/.claude/`.)
  - `provides/objc/{.clang-format,.clang-tidy}` — Objective-C toolchain for
    objc consumers (blackoutd); per-consumer opt-in.
  - `provides/repo/CONTRIBUTING.template.md`, `provides/repo/AGENTS.template.md`
    — consumer-edited skeletons (baseline for the merge sync).

Rationale: this is Homebrew's proven mirror model; the only departure is the
small `provides/` area, needed because toobuntu is heterogeneous (objc
daemon, Ruby gems, taps, docs) whereas Homebrew's consumers are uniform.
`global/`+`project/` was rejected (adds indirection; RF stops using its own
configs).

## 5. Sync design

Modeled on `Homebrew/.github`:
`https://github.com/Homebrew/.github/blob/main/.github/workflows/sync-shared-config.yml`,
`.../.github/actions/sync/shared-config.rb`,
`.../.github/actions/sync/dependabot.template.yml`.

Distilled Homebrew mechanics:

- Canonical files live at natural paths in the source repo; the engine reads
  each and, per a `case` on the path, **pure-copies**, **prepends a "synced
  from X — do not modify" header** (added *by the sync*, not stored in the
  source), or **generates** (dependabot filtered to the target's ecosystems;
  ruby-version with a downgrade guard).
- Commits one file per change (`<basename>: update to match main
  configuration`), then the workflow opens/updates a `sync-shared-config`
  branch + PR via `gh`.
- Workflow: `generate-matrix` (consumer list) → `sync` matrix; per consumer
  clone source+target, run the engine, branch + PR. Token via a GitHub App /
  workflow-token secret. Homebrew **signs** the bot's commits
  (setup-commit-signing) — decide whether the toobuntu sync bot signs (our
  0008 ADR forbids a signing *gate* in CI, but a bot signing its *own*
  commits is a separate, allowed thing).

**Toobuntu implementation:**

- `sync-manifest.yaml` (root) — declarative. Schema sketch:

  ```yaml
  version: 1
  upstreams:               # pulled INTO RF by sync-from-upstreams.yml
    - source_repo: Homebrew/.github
      files:
        - {source: .github/zizmor.yml, target: .github/zizmor.yml, mutations: []}
    - source_repo: Homebrew/brew
      files:
        - {source: .github/actionlint.yaml, target: .github/actionlint.yaml,
           mutations: [{type: yq, expr: '.config-variables=["SYNC_APP_CLIENT_ID"]'}]}
        - {source: .github/actionlint-matcher.json, target: .github/actionlint-matcher.json}
  consumers:               # pushed FROM RF by sync-to-consumers.yml
    - repo: toobuntu/blackoutd
      components:
        - {source: .githooks/pre-commit, target: .githooks/pre-commit, mode: canonical}
        - {source: scripts/annotate.sh, target: scripts/annotate.sh, mode: canonical}
        - {source: provides/repo/AGENTS.template.md, target: AGENTS.md, mode: baseline-merge}
        - {source: .github/actions/sync/dependabot.template.yml, target: .github/dependabot.yml, mode: generate}
        # objc opt-in:
        - {source: provides/objc/.clang-format, target: .clang-format, mode: canonical}
    # … per consumer …
  sources:                 # files canonical in dot-github, synced from there
    - repo: toobuntu/dot-github
      provides: [.github/pull_request_template.md, SECURITY.md, profile/README.md]
  sync:
    strategy: pr
    branch: sync-from-foundation
  ```

  Modes: `canonical` (byte copy + synced header), `template` (copy verbatim,
  strip `.template` infix), `generate` (build per-target, e.g. dependabot),
  `baseline-merge` (RF baseline + consumer addenda region — see §6).

- `.github/actions/sync/sync-files.rb` — Ruby engine. Reads
  `sync-manifest.yaml`, resolves the consumer's component list, applies each
  mode, commits per-file, sets `pull_request=true`. Header text added here.
- `.github/actions/sync/action.yml` — composite action wrapping the engine
  (inputs: `repo`, `manifest_path`, `dry_run`).
- `.github/workflows/sync-to-consumers.yml` — matrix over `consumers`;
  schedule + dispatch + push-to-main-of-synced-file. `permissions:
  {contents: read}` top-level, elevated only where it writes.
- `.github/workflows/sync-from-upstreams.yml` — iterate `upstreams`; fetch,
  apply mutations (`yq`), open PR on drift.

## 6. Baseline-merge (AGENTS.md, .claude/settings.json, .gitignore)

These have a shared baseline + per-repo addenda. Design (to refine in impl):
a **sentinel-delimited region** in the consumer file marks the
foundation-managed baseline; the sync replaces only that region and leaves
the repo's own content outside it untouched. Mirrors Homebrew's marker-line
idea and the cask-extract marker-comment scheme (master-plan W8). For
`.claude/settings.json` (JSON, no comments), use a documented key
convention or a deep-merge of a `settings.base.json` with a repo
`settings.local-addenda.json`. **First task here: re-derive the true LCD
`.claude/settings.json`** (the RF copy is blackoutd's full set).

**Session-4 inputs and open questions (added 2026-06-23):**

- **Starting LCD candidate:** blackoutd's `docs/debug/settings.baseline.json` was
  prepared as an LCD candidate for promotion to RF — read it, but still re-derive
  the TRUE LCD multi-way across all active repos; the `baseline` infix marks it a
  candidate, not the authoritative answer.
- **JSON merge boundary:** besides the documented-key-convention / deep-merge
  options above, consider **static, deterministic sentinels embedded in a
  template** that the generator deletes on emit. An explicit, fixed boundary is
  simpler and more robust than targeting a key/value that can shift as the JSON
  evolves. Decide in Phase D.
- **Tooling:** the sync engine stays **Ruby stdlib only** (its `json` module) so
  it runs in CI without bundler; `jq` (`/usr/bin/jq`, 1.7.1-apple on modern
  macOS) is fine for local exploration. Ruby is at `/usr/bin/ruby` (2.6.10) and
  the portable build at
  `"$(brew --repository)/Library/Homebrew/vendor/portable-ruby/current/bin/ruby"`
  (4.0.5).
- **Nomenclature revisit:** `.template` (ADR 0002) is not the only infix in play —
  `settings.baseline.json` uses `baseline`, and others may arise. Revisit the
  infix vocabulary AND the `provides/` directory name in Phase D, and amend
  ADRs 0001/0002 if the model changes.

### Phase D outcome (Session 4 — DONE)

The `provides/` tree, the LCD `.claude/settings.json`, and baseline-merge for
all three target types are built, verified (`reuse lint` 95/95, `adrs doctor`
exit 0, `rspec` green except the known in-sandbox gpg-agent pre-push flake), and
on disk uncommitted.

- **`provides/` created.** `claude-user/{CLAUDE.md,AGENTS.md,settings.json}`
  (the version-controlled `~/.claude/`: CLAUDE.md is the live, most-evolved
  user-global, and settings.json is the user-global deny rail + personal scalars
  from blackoutd's `_user-claude-config/` staging. No user-global AGENTS.md —
  Claude Code auto-loads CLAUDE.md there and nothing else reads ~/.claude/). `objc/{.clang-format,.clang-tidy}` (identical to
  blackoutd's, inline `#` SPDX). `repo/{CLAUDE.md,AGENTS.baseline.md,
  CONTRIBUTING.baseline.md,gitignore.baseline,settings.baseline.json(+.license),
  REUSE.toml}`.
- **LCD re-derived multi-way.** Validated blackoutd's `settings.baseline.json`
  (8783) candidate against the full corpus: blackoutd full (11565), cert-automation
  (724, permission-only + repo-specific certbot/ksh), homebrew-cask-tools (524,
  hooks-only brew tap), and the user-global deny rail. The LCD is the org-wide-safe
  core (git/gh read allows, git/gh-mutate asks, the full deny rail,
  `disableBypassPermissionsMode`, sandbox denyRead + core domains + core
  excludedCommands, the block-main PreToolUse hook, `HOMEBREW_NO_ANALYTICS`);
  repo-specifics (objc tooling, daemon commands, apple domains, brew hooks) are
  consumer addenda. The candidate was correct; adopted verbatim as
  `provides/repo/settings.baseline.json`.
- **Nomenclature settled (ADR 0002 amended).** Two infixes, one per sync role:
  `.template` = transform/copy-once (consumer then owns the whole file);
  `.baseline` = perpetually-managed region merged into a consumer-owned file.
  No-infix = verbatim canonical. The four baseline-merge sources were renamed
  `AGENTS.template.md`/`settings.json`/`gitignore.base`/`CONTRIBUTING.template.md`
  → `AGENTS.baseline.md`/`settings.baseline.json`/`gitignore.baseline`/
  `CONTRIBUTING.baseline.md`; the manifest set `claude_merged` → `repo_baseline`.
  the directory was renamed `templates/` → `provides/` (it holds more than
  templates, and `provides/` matches the manifest's `provides:` vocabulary); ADRs
  0001/0002 updated to match.
- **baseline-merge implemented in `sync-files.rb`.** Text targets now get
  sentinels rendered in the TARGET's comment syntax (`#` for `.gitignore`,
  `<!-- -->` for Markdown — the prior hash-only sentinels would have injected `#`
  heading lines into AGENTS.md/CONTRIBUTING.md). JSON targets (`.claude/settings.json`)
  are **deep-merged**: the engine reads the consumer's `<stem>.addenda.json` beside
  the target and merges baseline + addenda (objects recurse; arrays union so a
  consumer can only ADD to the deny rail, never drop one; scalars take the
  consumer's value), regenerating the target. Idempotent (rebuilt from both inputs
  each run, so baseline removals propagate). The explicit boundary is the file
  split (baseline = RF, addenda = consumer, target = generated), not a fragile
  in-JSON region. Manifest `defaults` now carry `merge_label_begin`/`merge_label_end`
  (ASCII, comment-agnostic labels). Two new rspec examples cover text+JSON merge
  and idempotency.
- **Licensing model decided + ADR 0016.** License follows ownership: mirrors
  (canonical/template/generate) keep RF's GPL inline; merges (baseline-merge)
  carry the consumer's license, so the region sources are license-neutral
  (`provides/repo/REUSE.toml` declares their SPDX so nothing leaks into the
  consumer's managed region). `settings.baseline.json` keeps a real `.license`
  sidecar because that sidecar IS synced. Per-file override via the consumer's
  own REUSE.toml `precedence=override`. ADR 0016 records this with the
  counter-argument (a license-pure consumer would force the uniform-consumer-license
  model — deferred). `annotate.sh` amended with a clang-config category (inline `#`).

## 7. ADR policy (locked)

- Org-wide / cross-cutting ADRs are **canonical in RF `docs/decisions/`
  only**, with RF's own clean numbering. Renumber freely (numbering is not
  load-bearing).
- The **implementation** an ADR governs (hook, CI job, script, config) **is
  synced**; the ADR **rationale is not** — child repos carry one generic
  **pointer** (in `CONTRIBUTING.md` / `agent-principles.md`) to
  `toobuntu/repo-foundation/docs/decisions/`. No per-repo ADR copies, no
  reserved-number scheme (rejected: brittle), no cross-repo collisions.
- Repo-specific ADRs stay in the child repo's `docs/decisions/` with local
  numbering.
- Promote into RF: trojan-source (generalize), reuse-lint-hook-strategy
  (bd 0005, referenced by the zd pre-commit), pre-push-signing (bd 0008,
  authored for RF). RF-original org-wide already present:
  adopt-standard-readme, logging-os_log-vs-newsyslog (+ `newsyslog-log-rotation.md`
  is org-wide per maintainer). Rationalize the final sequence.

### Curation plan (dedicated session — see resume prompt "Session 3")

MADR 4.0's `date:` frontmatter IS the "last updated" date (maintained
manually on edit), so promoted/new ADRs need **no** `last_review_date` — keep
`date` current. Numbering is not load-bearing; assign a clean sequence.

| Source ADR | Disposition | RF slot |
|---|---|---|
| bd `0005-reuse-lint-hook-strategy` | promote | `0005` (hook cites ADR 0005 — keep the number) |
| bd `0001` + RF `0001` trojan-source | reconcile (bd newer, 22993 > 21366) + generalize | `0006` |
| bd `0008-pre-push-signing` | promote (authored for RF) | new |
| bd `0004-merge-strategy` | promote (org-wide git policy) | new |
| bd `0007-homebrew-analytics-opt-out` | promote (any Homebrew repo) | new |
| bd `0006-ruby-test-toolchain` | evaluate → likely promote (RF uses it) | new |
| hct `0001-pipx-for-ci-python-tools` | promote (CI Python policy) | new |
| hct `0002-sync-branch-pr-strategy` | promote — feeds the sync-architecture ADR | absorb |
| zd `0001-run-vale-via-homebrew` | evaluate → likely promote (prose-lint) | absorb |
| RF `0008-adopt-standard-readme` | keep | `0008` |
| RF `0009-logging-os_log-vs-newsyslog` | keep (newsyslog org-wide) | `0009` |
| bd `0002`/`0003` daemon, zd `0002` go-floor, inject_edid (dormant) | stay repo-specific | — |

New RF ADRs to author (record decisions already made in this build-out):
repo organization (mirror + templates layout); `.template` infix convention;
cross-repo sync architecture (push-from-canonical; manifest; absorbs hct
`0002`); org-wide-ADR-pointer policy (the treatment decided here);
prose/markdown lint discipline (absorbs zd `0001`). Each promoted/new ADR:
full read for org-wide-leak check; SPDX via `annotate.sh` (after frontmatter);
`adrs doctor` exit 0. Consider whether saved memories / `agent-principles.md`
/ `AGENTS.md` / `~/.claude/CLAUDE.md` decisions warrant their own ADRs.

### Curation outcome (Session 3 — DONE)

`docs/decisions/` is now one clean MADR 4.0 sequence, 15 ADRs contiguous
0001–0015, `adrs doctor` exit 0 · `reuse lint` compliant · `lint-unicode` clean:

| # | Title | Source |
|---|---|---|
| 0001 | Mirror the Homebrew/.github layout with a small provides/ area | new |
| 0002 | Mark consumer-transformed files with a .template infix, not a suffix | new |
| 0003 | Sync shared configuration by pushing from a canonical source | new; absorbs hct 0002 |
| 0004 | Keep org-wide ADRs only in repo-foundation; reference them by pointer | new |
| 0005 | Use reuse lint-file with --no-multiprocessing in the pre-commit hook | bd 0005 |
| 0006 | Trojan Source detection strategy | bd 0001 + RF 0001 reconciled |
| 0007 | Pre-push signing gate is a maintainer self-guardrail, not a contribution gate | bd 0008 |
| 0008 | Adopt the standard-readme specification for README files | RF (kept) |
| 0009 | Unified logging (os_log) for daemons; newsyslog only for self-managed files | RF (kept) |
| 0010 | Merge PRs with merge commits, not squash or rebase | bd 0004 |
| 0011 | Run the RSpec suite under Homebrew's portable Ruby | bd 0006 |
| 0012 | Use pipx to install Python CLI tools in CI | hct 0001 |
| 0013 | Disable Homebrew analytics in agent and CI contexts | bd 0007 |
| 0014 | Adopt one canonical Vale prose style, run via Homebrew in CI | new; absorbs zd 0001 |
| 0015 | Distribute copilot-setup-steps per-repo, except Homebrew taps | Session-2 0010 |
| 0016 | License a synced file by which repository owns it | new (Session 4) |

Conventions applied: new/reconciled/promoted ADRs `date: 2026-06-23`; 0008/0009
kept at 2026-05-20 (frontmatter only — added `number:`/`title:`, normalized
`decision-makers: - toobuntu`, dropped `consulted`). hct ADRs relicensed to
GPL-3.0-or-later (RF is GPL-only). Repo-specific ADRs (bd daemon 0002/0003, zd
go-floor 0002) untouched in their home repos.

ADR-reference repointing (per ADR 0004): the canonical `.githooks/pre-commit`,
`scripts/lint-unicode.sh`, and `spec/integration/precommit_unicode_spec.rb` now
cite RF's ADRs by stable URL — trojan → 0006, reuse-lint → 0005 — not a local
`docs/decisions/` path. The `annotate.sh` / no-hand-write-SPDX rule (org-wide but
previously only in `copilot-instructions.md` / `AGENTS.md`) was consolidated into
`docs/agent-principles.md`.

Follow-ups recorded here so they are not lost:

- **Consumer ADR cleanup (post first sync).** The org-wide ADRs now canonical in
  RF still exist as local copies in their source repos (bd 0001/0004/0005/0006/
  0007/0008; hct 0001/0002; zd 0001). Per ADR 0004, those consumers drop the local
  copies (keeping only repo-specific ADRs) and rely on RF + a pointer once the
  sync lands.
- **W6 numbering.** master-plan reserves `0004-isolate-cli-shape.md`, but the
  clean sequence uses 0004 for the ADR-pointer policy; Session 4 took **0016**
  for synced-file licensing and Session 5 took **0017** for the git-hooks
  base/plugins ADR, so W6's isolate ADR takes **0018** (numbering is not
  load-bearing).
- **Legacy stale ADR-number refs — RECONCILED (Session 5).** The pre-reorg tree
  cited an old/aspirational scheme; the Session-5 reorg resolved every case:
  `project/scaffolding-adrs.md` deleted; root `README.md` and `docs/usage.md`
  rewritten (no longer cite the old 0005/0006/0007 meanings);
  `scripts/sandbox-vm-enter.sh` repointed from the dangling
  `0007-layered-isolation-strategy.md` to the forthcoming W6 isolate-cli ADR
  (0018). `docs/newsyslog-log-rotation.md` ("see ADR 0009") was already correct
  (0009 = logging).

## 8. Phased roadmap

- **Phase A — COMPLETE:** structural inventory + multi-way canonical derivation
  done for scripts, hooks, docs, specs, shared repo configs, AND (Session 2) the
  `.github/` workflows + CI configs. Finalized classifications (these supersede
  the provisional §3 rows for `.github/` files):
  - **canonical, ci_core (synced to all):** RF-authored `actionlint.yml` and new
    `lint.yml` (reuse + lint-unicode + lint-perms + lint-adrs, the universal jobs
    lifted out of per-repo `ci.yml`); plus the upstream-tracked `zizmor.yml`,
    `actionlint.yaml`, `actionlint-matcher.json` (+`.license`), and
    `copilot-setup-steps.yml`.
  - **canonical, agent_docs:** `.github/instructions/licenses.instructions.md`
    (identical across repos modulo the license line).
  - **canonical, ruby_hook_tests:** new `spec.yml` (rspec).
  - **generate, ci_templates:** `dependabot.yml` (superset now includes `gomod`,
    with `cooldown`).
  - **per-repo, NOT synced (RF ships scaffolds under
    `provides/github/workflows/`):** `ci.yml`, `codeql.yml` — matrix AND steps
    both vary by language, so byte-sync would clobber each repo's languages.
  - **repo-specific, NOT synced:** `copilot-instructions.md` — each repo's is
    fully bespoke; the shared part is two sentences.
  - **`upstreams` (mirrors homebrew-cask-tools' sync, which RF supersedes; a
    Session-2 over-correction to "RF-authored" was reverted on maintainer
    review):** `zizmor.yml` (Homebrew/.github); `actionlint.yaml` (mutations:
    config-variables → `[SYNC_APP_CLIENT_ID, SYNC_BOT_SIGN]`, `del(.paths)`);
    `actionlint-matcher.json`; `copilot-setup-steps.yml` (core/cask false +
    tools appended) — the last three from Homebrew/brew. mikefarah yq preserves
    comments; the consumer-sync engine strips the relay "do not modify it
    directly" header and writes a repo-foundation one so consumers see RF as
    their single source.
  **Community-health files** (CONTRIBUTING, SECURITY, PR/issue templates,
  profile) are GitHub org-fallbacks served from dot-github (not RF-synced);
  the org-wide baseline `CONTRIBUTING` is RF-hosted
  (`provides/repo/CONTRIBUTING.template.md`) and synced to children with
  per-repo mutations; dot-github keeps a stub fallback; RF's own
  `CONTRIBUTING.md` adds sync-hub specifics.
- **Phase B — IN PROGRESS:** canonical scripts/hooks placed at natural paths
  and reconciled — pre-commit (zd + working-tree review comment), lint-perms
  (zd + RF `LINT_PERMS_FORMAT` up-front validation), lint-unicode (bd),
  annotate (bd, consumer header removed), agent-principles (bd). Spec
  `REUSE_LINT_SKIP` coupling fixed in `precommit_unicode_spec.rb`. Verified:
  `sh -n`/`bash -n` + shellcheck clean.
  **Remaining Phase B:** run `bundle exec rspec` against the reconciled hooks;
  de-leak spec temp-dir prefixes (`blackoutd-*` → generic); add
  `last_review_date` to standalone docs — skipped `agent-principles.md`
  because it is `@import`-ed raw into `AGENTS.md`, so YAML frontmatter would
  surface as visible content; decide per-doc with SPDX-after-frontmatter
  ordering. Curate `docs/decisions/`: **DONE in Session 3** — `docs/decisions/` is a clean
  15-ADR MADR 4.0 sequence (0001–0015), `adrs doctor` exit 0. See §7 "Curation
  outcome" for provenance, the consumer-cleanup follow-up, the legacy-ref
  reconcile list, and the W6 → 0016 numbering note.
- **Phase C — sync engine COMPLETE (Session 2):** `sync-files.rb` (modes
  canonical / template / generate / baseline-merge; `YAML.safe_load`; up-front
  component validation; comment syntax chosen from the TARGET; synced header
  inserted after shebang / frontmatter / the SPDX block; relayed upstream files
  have their "do not modify it directly" header stripped and replaced so
  consumers see one repo-foundation header; exec-bit preserving; dependabot
  generate keeps Gemfile-or-lock etc. and re-adds SPDX; missing sources skipped;
  per-file commits; `--dry-run` never writes), `action.yml` (composite),
  `sync-to-consumers.yml` and `sync-from-upstreams.yml` (both use a v3 GitHub App
  token with `workflows: write`, since workflow files are pushed; from-upstreams
  mirrors homebrew-cask-tools' curl + yq + header + `annotate.sh`). Bot commit
  signing is opt-in (`SYNC_BOT_SIGN` repo var + `SYNC_APP_SSH_SIGNING_KEY`).
  Tested by `spec/integration/sync_files_spec.rb` (3 examples) plus actionlint,
  zizmor (0 findings), reuse, and `ruby -c` on 2.6 + 4.0.5. **baseline-merge for
  JSON (`.claude/settings.json`) is deferred to Session 4**; its
  `provides/repo/*` sources are Phase D, so those components skip cleanly now.
- **Phase D — DONE (Session 4):** `provides/` tree (claude-user, objc, repo
  baselines); LCD `.claude/settings.json` re-derived multi-way; baseline-merge
  implemented for text (style-aware sentinels) and JSON (deep-merge with a
  consumer `<stem>.addenda.json`); `.baseline` infix settled (ADR 0002 amended,
  0001 updated); synced-file licensing decided (ADR 0016). See §6 "Phase D
  outcome".
- **Phase E:** `policies/`, RF `README.md` + `CONTRIBUTING.md`,
  `examples/minimal-repo/`, dot-github coordination; `scripts/foundation-init.sh`
  (consumer bootstrap); `docs/bootstrap/{branch-protection,sync-bot-and-signing}.md`;
  and the **scaffold staleness check** per ADR 0015 — a `foundation doctor` mode
  plus a scheduled "scaffold drift" workflow that flags per-repo scaffolds
  (ci/codeql/copilot-setup-steps) untouched in ~1 year and nudges a manual
  reconciliation with upstream. Age-based nudge, not a diff (customized scaffolds
  have no clean canonical to diff against); one check, two triggers; Dependabot
  keeps the action pins fresh independently. `docs/bootstrap/sync-bot-and-signing.md`
  already landed in Session 2 as a maintainer reference.
- **Phase F:** REUSE annotate + lint, actionlint, shellcheck, rspec; initial
  commit series (unsigned; maintainer re-signs the batch).

## 9. Conventions

- `.template` infix (`name.template.ext`), never trailing.
- en_US spelling; long options; 50-char commit subjects; signed-off.
- SPDX headers via `scripts/annotate.sh` (never hand-written above YAML
  frontmatter).
- `last_review_date` frontmatter on canonical docs (Homebrew convention);
  SPDX block goes *after* the frontmatter.
- Agent commits unsigned in-sandbox; maintainer re-signs the batch
  (`scripts/re-sign-unpushed.sh`).
- Root license filename: **`COPYING` for GPL-only repos, `LICENSE` for
  others** (RF is GPL-only → `COPYING`; the sync can normalize others). The
  license text lives in `LICENSES/`; the root copy gets a `REUSE.toml` entry,
  not an inline header. Formalize in the lint/compliance phase (Session 5).

## Inputs from the workspace planning docs (read 2026-06-22)

Authoritative docs in `~/devel/claude/desktop/workspace/repo-foundation/`:
`w1-hooks-review-prompt.md` **supersedes `bootstrap-prompt.md`** where they
conflict; `bootstrap-actions.md` is the maintainer's manual runbook (GitHub repo
+ App, push, first sync, delete deprecated baseline); `vale-styles-evaluation.md`
is the Vale rule survey. Read them before building.

The hook *content* was independently reconciled to the correct didan/zd
canonical, but these scope items were missed in Session 1 and must be done:

1. **Language-plugin architecture** — base hooks carry NO language checks;
   per-language checks are `pre-commit.d/` plugin MASTERS in RF, synced only to
   consumers of that language. NOW in the manifest (`go_plugin`→zman-didan,
   `objc_plugin`→blackoutd).
2. **Create `20-objc`** — extract blackoutd's pre-commit clang-format/clang-tidy
   stanzas into a self-contained `provides/git/hooks/pre-commit.d/20-objc`
   (own `staged_z`/`has_files`, SPDX, exec bit, keep `-DBD_BUNDLE_ID`/framework
   flags). Manifest forward-references it. Session 2.
3. **File-by-file disposition review** under `docs/reviews/` — per-file
   `pick-now / pick-defer / have / drop`, diff-grounded, across every repo with
   `.githooks/` (model: zman-didan `docs/reviews/pr1-review.md`). Makes
   push-from-canonical safe (else the first sync can clobber an intentional
   divergence). Session 2 or 3.
4. **Hook ADR refs** — the canonical hook cites `0001-trojan` + `0005-reuse-lint`;
   repoint both to RF's canonical ADR location/URL (trojan → `0006`) with ADR
   curation (Session 3).
5. **Vale → one `Toobuntu` style** — consolidate `Didan.*` with the
   Homebrew/GitLab/Elastic adoptions per `vale-styles-evaluation.md` (Tier-1 +
   acronyms-with-vocab at error; Tier-2 at warning); rename `Didan.*`→`Toobuntu.*`;
   one `accept.txt`. Session 5.
6. **`lint-perms` CI job** — `lint-perms.sh --tracked` with
   `LINT_PERMS_FORMAT: ci`; land as a canonical workflow/CI-template stanza.
   Part of the Session 2 `.github/` derivation.

## 10. Open items

- dot-github is pre-initial-commit (7 files); confirm its org-fallback file
  set (PR/issue templates, SECURITY.md, profile/README) before wiring it as a
  sync source.
- Whether the sync bot signs its commits (App key vs none).
- `sandbox-vm-*.sh` mode 0640 vs lint-perms expectations.
- Doc/ADR curation depth may warrant a dedicated pass (acceptable to defer
  with a handoff).
