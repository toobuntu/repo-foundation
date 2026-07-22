<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Test-coverage survey (2026-07-21)

Point-in-time inventory of what carries tests and what does not, from the session that added the Vale-rule harness and the documentation-plugin specs. Feeds future test work; items are ordered by value.

## Covered today

- Sync engine: `spec/integration/sync_files_spec.rb`.
- Base-hook checks: `precommit_reuse_spec.rb`, `precommit_unicode_spec.rb`, `lint_perms_spec.rb`, `prepush_signing_spec.rb` (the gpg web-flow case needs a running gpg-agent, which the Seatbelt sandbox blocks — a hard limit like the pty cases, not a flake — so it skips in-sandbox via a `gpg_agent_available?` probe and runs on a dev machine and in CI).
- Plugins: `precommit_swift_spec.rb` (20-swift, stub pattern); `precommit_docs_plugins_spec.rb` (15-prose, 10-markdown, 50-adrs — this session).
- Vale style rules: `vale_style_spec.rb` (all ten Toobuntu rules, flagged and clean fixtures; AbbreviationPlurals covers the possessive VBG/VBN/TO/CD extension). Needs the real `vale`; skips where absent. `spec.yml` installs vale (`brew install vale`), so the rule harness runs as a CI gate; `prose.yml` remains the corpus gate.
- Script behavior, now under RSpec (migrated from the standalone shell harnesses so all tests share one framework and CI job): `sign_push_spec.rb` (17 examples, every exit path plus `--help`, unknown-option, and both interactive diverged-origin confirm paths; the pty-driven confirm cases skip in-sandbox and run on a dev machine and CI) and `promote_from_isolated_spec.rb` (the cumulative promote lifecycle plus the merge/no-TTY/wrong-branch gates).

## Gaps, prioritized

1. **Language plugins 20-brew, 20-go, 20-objc** — no specs. The stub pattern from the Swift/docs specs transfers directly (brew/gofmt/clang-format stubs; assert gating, auto-fix re-stage, failure propagation).
2. **`scripts/lint-shell.sh`** — the dialect split (ksh93 vs sh/bash detection, shfmt skip for ksh, per-file loops) is behavior-rich and untested; a fixture-repo spec with stub tools would cover it.
3. **`scripts/annotate.sh`** — the per-filetype SPDX rules (frontmatter insertion for Markdown, `.license` sidecars for comment-hostile files) guard every commit; a fixture spec asserting placement per filetype would catch regressions the REUSE lint cannot (it checks presence, not position).
4. **`scripts/foundation-init.sh` / `foundation-doctor.sh`** — bootstrap and staleness logic untested; init is fixture-friendly (run against a temp dir, assert the seeded tree).
5. **`scripts/rewrite-pr-as-merge-commit.sh`** — untested; same throwaway-repo harness style as sign-push-test.
6. **`scripts/sandbox-enter.sh` / `sandbox-exit.sh`** — only ad-hoc verification (default parent + tmp-reaper caveat were exercised manually this session); a harness could assert remote save/restore round-trips per mode.
7. **Base-hook runner itself** — the run-parts loop (classicalre gating, dot-suffix disable, plugin failure propagation) has no dedicated spec; the pieces are exercised indirectly.
8. **rumdl config regressions** — `.rumdl.toml` choices (soft-wrap, code cap 118, MD041 exclude list, per-directory MD025) are enforced live by `rumdl check .` in CI, which doubles as the regression test; no separate harness needed unless the config grows conditional logic.
