<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Org memory — toobuntu

> Durable org-wide knowledge, homed in toobuntu/repo-foundation and synced read-only to every consumer's `.ai/org/memory.md` (ADR 0022). Append dated entries (`## YYYY-MM-DD — Topic`); never rewrite history — a correction is a new entry naming what it supersedes. Edit only in repo-foundation: a consumer-rooted session that learns an org-wide fact drops it in the gitignored `.ai/org/relay.md` for promotion. Per-repo knowledge belongs in that repo's `.ai/memory.md`; a durable decision graduates to an ADR.

## 2026-07-15 — Commit-style split across the org

repo-foundation itself uses conventional-commit-style subjects (`feat(scope):`, `docs:` — see its history). The Homebrew-aligned repos (homebrew-babble, homebrew-cask-tools) REJECT Conventional Commits and follow Homebrew's commit style instead. Do not carry one repo's style into the other.

## 2026-07-15 — Sandbox: git commits work everywhere; init and .git/config do not

Established by probes during the org-continuity bootstrap: the Claude Code Bash sandbox denies writes to `.git/config` and copies into `.git/hooks/` within the project tree, while allowing everything a normal commit needs (objects, index, refs, plain files in `.git/`). Consequences: `git init` is the one git command that trips it (it must write config and copy hook samples) — create new repos via the git MCP server (unsandboxed) or the maintainer; never hand-edit `.git/config` (maintainer rule) — the unsigned-commit recipe's per-command flags are the sanctioned signing relax and need no config edit. `$TMPDIR` is exempt (full write grant; init works there normally).

## 2026-07-15 — Git Data commit signing is token-type-dependent

Verified by test: REST Git Data commits minted with a GitHub App installation token are GitHub-signed (web-flow, Verified) and tree modes are honored; the same commits minted with a user token are NOT signed. This is why repo-foundation's sync adopts its own Git Data commit loop — Verified commits with real file modes, no machine user, no SSH signing key. The App configuration recipe lives in repo-foundation `docs/bootstrap/sync-bot-and-signing.md`; current installation state is read live from GitHub, never from this file.

## 2026-07-23 — Org knowledge tier homed in repo-foundation

The org-wide durable knowledge tier moved from the maintainer's private workspace into this file (repo-foundation `.ai/org/memory.md`, synced canonically to every consumer), so every clone and fork carries it. The volatile org tier — session dispatch and org-level progress — remains maintainer coordination state outside the sync. Recorded in ADR 0022 (amended 2026-07-23).

## 2026-07-25 — Spawning Ruby, and running a suite inside the sandbox

Applies to every Ruby repository in the org (first recorded in repo-foundation `.ai/memory.md`, 2026-07-24, while building the sync engine's spec harness; promoted here because the constraint is the toolchain's, not that repository's).

- **A child Ruby is spawned as `RbConfig.ruby`, never as bare `ruby`.** A bare name resolves through `PATH`, and on macOS that finds the frozen system Ruby 2.6 — so a suite that passes under the portable Ruby fails, confusingly, inside anything it shells out to.
- **BSD `env -P` does not export the modified `PATH` to children.** It uses the alternate path to locate the utility it runs and nothing more, which is why `env -P"<portable-ruby-bin>:$PATH" bundle exec rspec` alone is not enough: bundler runs under the right Ruby, and every process it spawns does not. Pass `PATH` explicitly as well.
- **`brew exec` supplies the portable Ruby but strips `TMPDIR`.** Under the Claude Code sandbox that sends `Dir.mktmpdir` to the repository root, where a spec that runs `git init` trips the `.git/hooks` write denial (org memory, 2026-07-15).

The in-sandbox invocation that satisfies all three:

```sh
env -P"$(brew --repository)/Library/Homebrew/vendor/portable-ruby/current/bin:$PATH" \
    PATH="$(brew --repository)/Library/Homebrew/vendor/portable-ruby/current/bin:$PATH" \
    bundle exec rspec
```

## 2026-07-30 — SPDX goes INSIDE YAML frontmatter, including for Claude Code skills

Settles a direct conflict between two repositories' `scripts/annotate.sh` comments, and closes blackoutd's technical-debt item P16, whose acceptance criteria were "construct minimal repros, run `reuse annotate --style=html` on each, capture the output."

**Measured, reuse 6.2.0, both repros:** a Markdown file with skill-style frontmatter (`name:`/`description:`) and one with ADR-style frontmatter (`number:`/`title:`) both receive the SPDX block as `#` comments **inside** the frontmatter, above the other keys:

```markdown
---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

name: skill-name
---
```

**And the Claude Code skill loader accepts that**, which was the open half of P16. Proof rather than argument: `toobuntu/bob-book`'s `bob-book-transcription` skill carries its SPDX inside the frontmatter and loads — it was present, with its folded multi-line `description:` intact, in the available-skills list of the session that ran this test. YAML `#` comments are comments; a real YAML parser consumes them as nothing.

So repo-foundation's `annotate.sh` comment is correct and blackoutd's is wrong on both of its claims: `reuse-tool 4+` does not insert the block *after* the frontmatter, and skills do not *require* after-frontmatter placement. blackoutd's `CONTRIBUTING.md` § "YAML frontmatter and SPDX placement" documents the after-frontmatter form as "required for Claude Code skills" on the strength of an assumption P16 itself flagged as unverified ("The on-disk files were created or normalized by hand"). Its four hand-normalized `.claude/skills/*/SKILL.md` files are consistent with a convention that is not needed; the synced CONTRIBUTING baseline, which already documents the inside-frontmatter form, corrects that prose at the first sync.

**Standing rule, unchanged but now evidenced:** never hand-place an SPDX block in a frontmatter-bearing file — run `scripts/annotate.sh` and let `reuse` decide. Where that is impossible (the agent sandbox has denied writes under `<repo-root>/.claude/skills/`, so a session could create a skill it could not annotate), reproduce the measured placement above and then **verify it properly**, because a clean `annotate.sh` run proves nothing about placement: it acts only on files `reuse lint` reports as non-compliant, and `reuse lint` is satisfied by the SPDX strings appearing *anywhere* in the file. The test that does verify — copy the file, strip its SPDX block, re-annotate the copy with the arguments `annotate.sh` passes, and diff:

```sh
reuse annotate --copyright="<name>" --merge-copyrights --license=<spdx-id> \
  --copyright-prefix=spdx-string --style=html <copy>
```

`--copyright-prefix=spdx-string` is load-bearing there. Without it `reuse` prepends its own year, and the diff shows a copyright-text difference that reads like a placement difference. Run that way against the three skills added the same day, all three came out byte-identical to their hand-written form.

## 2026-08-02 — sandbox.excludedCommands contaminates the whole compound

A Bash call whose command string matches an excludedCommands entry (here `zizmor *`) runs the ENTIRE compound unsandboxed, not just the matched command. Measured via pty: `PTY.spawn` fails under Seatbelt in every plain invocation, succeeded in the one compound that also ran zizmor, and the 3 pty-gated sign_push specs silently ran (234/0/0 instead of 234/0/3). Consequences: (1) never chain an excluded command with anything whose behavior you are using to reason about the sandbox; (2) a compound containing an excluded command has the sandbox OFF for every part of it — treat exclusions as widening the whole call, not the one tool.

## 2026-08-03 — Three sandbox facts the org docs currently get wrong

- **`gh` does not run in the agent sandbox at all.** `~/.config/gh` sits in `denyRead`, so every invocation dies at config load — `failed to load config: open /Users/<user>/.config/gh/config.yml: operation not permitted`, then `failed to create root command` — before it parses an argument. This is a sandbox denial, not a permission prompt, so no allowlist entry helps. `docs/agent-principles.md` still lists `gh pr view/list/checks`, `gh run view/list`, and `gh api -X GET` under "Universal tools available without prompt": true of the permission layer, false of the sandbox. The working read-only fallback for a PUBLIC repository is plain `curl` against `api.github.com`, which is on the network allowlist and needs no credentials — verified 2026-08-03 by reading the latest `guard-pin.yml` run (`.../actions/workflows/guard-pin.yml/runs?per_page=1` → `conclusion: success`). Anything authenticated or private is a maintainer step.
- **The `annotate.sh` PreToolUse guard matches the PATH, not the invocation.** Its `case "$cmd" in *scripts/annotate.sh*)` fires on any Bash command whose string merely *contains* that path — including `git restore scripts/annotate.sh` and `git diff -- scripts/annotate.sh`, which are the two commands its own refusal message tells you to run. Two consequences, both measured: a session that dirties the script can revert it only with the Edit tool or a command that does not name the path (`git add scripts/` works); and **once a session edits `annotate.sh`, it cannot run `annotate.sh` again for the rest of that session** — so annotate every newly created file BEFORE touching that script. The guard lives in `provides/repo/settings.baseline.json`, so this reaches every consumer, not just repo-foundation. The narrow fix, if it is wanted, is a `git\ *) ;;` arm ahead of the match: git never executes the script, so letting git commands through costs no protection and removes the trap.
- **Ruby's `Encoding.default_external` follows `LANG`/`LC_ALL`, and the sandbox shell sets neither.** It therefore defaults to US-ASCII, and `File.read` on any repository file holding a non-ASCII byte raises `invalid byte sequence in US-ASCII`. It reads like a code defect and is environmental: measured 2026-08-03 as 48 examples / 2 failures with no locale against 48 / 0 with `LANG=en_US.UTF-8`, same commit. `sync-files.rb` had already set `Encoding.default_external = Encoding::UTF_8` at load for exactly this; `spec/spec_helper.rb` (canonical, so every Ruby consumer gets it) now does the same. Any new org Ruby entry point should, and a spec that means to read raw bytes uses `File.binread`.

## 2026-08-03 — `adrs doctor` warns ADR014 on the word "describe"

Its ADR014 check reports `Section '<name>' appears to be empty or contains only placeholder text` for a section that is neither. The trigger is a substring of MADR's own template text — the placeholder that begins `{Describe the context and problem statement…}` — so **any section containing the word "describe", in any casing, is flagged.** Bisected to a single word on a throwaway ADR repository: `They describe org-wide procedure.` warns, `They cover org-wide procedure.` does not, and `decorate` (which contains no such substring boundary issue) does not. Two sections of a new ADR tripped it; both went quiet on one word each.

It is a warning, so `adrs doctor` still exits 0 and neither the `50-adrs` plugin nor the `lint-adrs` job blocks. The cost is warning-blindness: a permanent pair of warnings on a healthy ADR trains a reader to skim past the ones that matter. Choosing a different verb costs nothing and keeps the signal, which is what repo-foundation's ADR 0025 did. Do not read this warning as a sign the ADR is thin — check whether the section merely contains that word before rewriting anything. Worth an upstream report against `adrs`; none filed yet.

## 2026-08-04 — ADR014, corrected: it is mdbook-lint's rule, and there is no per-file escape

Supersedes the 2026-08-03 entry above on two points. That entry sent a report to the wrong project and said "choosing a different verb costs nothing", which the maintainer overruled — the natural wording is worth keeping, so the question became how to suppress rather than how to reword.

**The rule belongs to mdbook-lint, not `adrs`.** `adrs` 0.10.1 pulls `mdbook-lint-core` and `mdbook-lint-rulesets` 0.14.4 through `adrs-core`, so the report goes to joshrotenberg/mdbook-lint. The trigger is `PLACEHOLDER_REGEX` in `crates/mdbook-lint-rulesets/src/adr/adr014.rs`, and `is_placeholder_content` returns true when it matches ANYWHERE in a section rather than when the section is only placeholder text. `PLACEHOLDER_LITERALS` contains `"..."` and is matched with `contains`, so an ellipsis in ordinary prose fires identically. Unchanged at mdbook-lint v0.15.1.

**There is no working per-file suppression, and the one that looks like it works is not.** `adrs.toml` gained `[doctor]` in adrs PR #321, but `DoctorConfig` declares exactly two fields — `ignore` and `warnings_as_errors`. There is no `path`, and `Config::load` parses with plain `toml::from_str` without `deny_unknown_fields`, so an invented key is dropped silently and `ignore` applies repository-wide. The tell: add a second unrelated ADR that trips the same rule and the suppression count goes 1 → 2 while the config still names one file. Inline `<!-- mdbook-lint-disable ADR014 -->` does not work mid-file either. Scoped inline directives are proposed in mdbook-lint#469 (2026-08-03); `adrs` has no issue tracking them and would inherit them by bumping its pins, two minor versions behind.

**Carry this into any fix:** `adrs.toml` is a `mode: canonical` synced file, so a repo-specific `[doctor]` entry would reach every consumer — the invariant against consumer-specific paths in canonical files applies. Until #469 lands the honest choices are reword, or a standing warning recorded with what would retire it.

## 2026-08-06 — Permission-rule and hook semantics, measured (Claude Code 2.1.220)

Every claim here was measured with a positive and a negative control during the session-hygiene work in repo-foundation; none is from documentation alone.

- **Permission rules DO match pipelines** — the 2026-08-04 worry that Claude Code splits compounds so a pipe rule can never fire is false. A `Bash(echo * | cat)` deny blocked `echo alpha | cat` (and a no-rule pipeline passed). Components are ALSO checked individually: a `Bash(probetail:*)` deny blocked both `echo hi | probetail x` and `true && probetail x`. **Pipe spacing is normalized** (`echo echoing|cat` matched a `| cat` rule — enumerating spacing variants adds dead rules). **The match is anchored at the end**: `echo x | cat -A` sailed past a `| cat` deny, which is why the org's curl-pipe denies are PAIRS per shell (`curl * | sh` + `curl * | sh *`), never a trailing glob (`sh*` would deny `curl URL | shasum -a 256`). Settings edits hot-reload mid-session; a probe rule is live on the next call.
- **`claude doctor` validates PROJECT settings files** (not only user scope), labels each finding with the owning file path, and **exits 0 even with findings** — so a settings-lint gate must parse its output, never trust the status. Measured against a deliberately invalid `Bash(curl:* | sh)` rule in a throwaway project.
- **Hook commands run unsandboxed with full user permissions** while the agent's Bash stays sandboxed. Measured both directions: a PreToolUse-invoked script wrote `~/.local/state/ai-history/...` (outside the sandbox write allowlist) successfully; a sandboxed `touch` into the same directory failed `Operation not permitted`. This asymmetry is what makes a one-way vault constructible — and it also means any hook line in settings is unsandboxed code, which is why hook logic belongs in lint-covered, specced `scripts/` files with thin `[ -x ]`-gated shims.
- **A `Stop` hook receives `last_assistant_message`** (the turn's final text) **and `stop_hook_active`** (true when this Stop already blocked once — the built-in loop brake), both confirmed live on 2.1.220. Stop fires when a turn's final act is TEXT — mid-turn tool calls do not suppress it, but a turn ending in a question or permission prompt never fires it. Exit-0 stdout of a Stop hook is shown to no one; the working channels are JSON `decision:"block"`+`reason` (fed to the agent, turn continues) and `systemMessage` (shown to the user).
- **The settings JSON Schema is the authoritative, reachable answer for harness knobs** — `https://json.schemastore.org/claude-code-settings.json`, on the network allowlist, and already named by `$schema` in every settings file the org ships. Reach for it before reading issue threads or saying a value cannot be verified. Compaction controls it documents: `autoCompactEnabled` (boolean, **default true**), `DISABLE_AUTO_COMPACT` (`1` disables auto, leaves `/compact`), `DISABLE_COMPACT` (`1` disables both), `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` ("context capacity percentage threshold for auto-compaction (1-100)"), and `CLAUDE_CODE_AUTO_COMPACT_WINDOW` ("context capacity for compaction calculations in tokens"). Both `PreCompact` and `PostCompact` are real hook events. What the schema does NOT state is the DEFAULT threshold percentage — it documents the override, not the value being overridden, so treat any specific figure as unmeasured until observed.

  **Do not transfer the API's compaction numbers to Claude Code.** `platform.claude.com` documents a *server-side Messages API* compaction feature with its own trigger (150,000 input tokens; the cookbook's worked example uses 100,000 against a 200k window). That governs API applications and is a different mechanism from the CLI's client-side auto-compact, which is the one these settings control. The figures do not carry across, and quoting them at each other is the available trap.

  Two practical consequences. **The threshold is a percentage of a token window Claude Code is told about, not necessarily of the model's actual window** — that is what `CLAUDE_CODE_AUTO_COMPACT_WINDOW` exists to set — so on a session with a much larger context than the default assumption, the percentage can fire far earlier than the raw numbers suggest; setting BOTH variables makes the behavior deterministic instead of inferred. And the direction is easy to get backwards: a hook that demands work AT compaction time gets *more* headroom from a LOWER percentage, not a higher one.
- **A `Write(path)` permission rule is INERT; only `Edit(path)` rules are matched by file permission checks**, and an Edit rule covers every file-editing tool. Claude Code says so at session start — `Write(...) is not matched by file permission checks ... Use Edit(...) instead` — and a rule written the wrong way is another deny that reads as protection and is not. Measured 2026-08-07 after exactly that mistake shipped into all three settings files in this repository.
- **`claude doctor` does NOT catch everything session startup does.** Startup reported the inert `Write(...)` rule above while `claude doctor` exited 0 with no "Invalid settings" section at all on the same files. So doctor is the gate for *malformed* rules, not for *ineffective* ones, and a settings-lint plugin built on it must not be described as catching every settings defect.
- **`/context` reports the compaction numbers directly**, which ends the guessing: it prints `Auto-compact window: <n> tokens` and an `Autocompact buffer` line with its own percentage, alongside a per-category breakdown (system prompt, tools, memory files, skills, messages). That is the measurement to run before theorizing about thresholds. It also surfaces what memory files cost — 15% of a 200k window in this repository on 2026-08-07, `docs/agent-principles.md` alone 22.3k tokens and flagged as over a 40k-CHARACTER limit, which is the org's own "keep AGENTS.md terse, move reference material to docs/<topic>.md" rule now applying to the principles file itself.
- **macOS path identity trap for hook-supplied paths**: hooks and tools may hand a path as `/var/...` while `git rev-parse --show-toplevel` reports `/private/var/...` — a prefix `case` match on the repo root silently misses. Canonicalize with `cd dir && pwd -P` before comparing; found by a spec whose fixture lived in `$TMPDIR`.
