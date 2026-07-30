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
