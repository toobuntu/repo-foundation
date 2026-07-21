<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Test-coverage survey (2026-07-21)

Point-in-time inventory of what carries tests and what does not, from the session that added the Vale-rule harness and the documentation-plugin specs. Feeds future test work; items are ordered by value.

## Covered today

- Sync engine: `spec/integration/sync_files_spec.rb`.
- Base-hook checks: `precommit_reuse_spec.rb`, `precommit_unicode_spec.rb`, `lint_perms_spec.rb`, `prepush_signing_spec.rb` (the gpg web-flow case is a known in-sandbox flake; passes on the maintainer's machine and in CI).
- Plugins: `precommit_swift_spec.rb` (20-swift, stub pattern); `precommit_docs_plugins_spec.rb` (10-prose, 10-markdown, 50-adrs — this session).
- Vale style rules: `vale_style_spec.rb` (all ten Toobuntu rules, flagged and clean fixtures; AbbreviationPlurals covers the possessive VBG/VBN/TO/CD extension). Needs the real `vale`; skips where absent — `spec.yml` does not install vale today, so CI exercises the skip path and `prose.yml` remains the corpus gate. Wiring `brew install vale` into `spec.yml` to activate the rule harness in CI is an open choice.
- Self-contained script harnesses: `scripts/sign-push-test.sh` (13 cases, every exit path; the interactive diverged-origin confirm needs a pty and is verified manually), `scripts/promote-from-isolated-test.sh`.

## Gaps, prioritized

1. **Language plugins 20-brew, 20-go, 20-objc** — no specs. The stub pattern from the Swift/docs specs transfers directly (brew/gofmt/clang-format stubs; assert gating, auto-fix re-stage, failure propagation).
2. **`scripts/lint-shell.sh`** — the dialect split (ksh93 vs sh/bash detection, shfmt skip for ksh, per-file loops) is behavior-rich and untested; a fixture-repo spec with stub tools would cover it.
3. **`scripts/annotate.sh`** — the per-filetype SPDX rules (frontmatter insertion for Markdown, `.license` sidecars for comment-hostile files) guard every commit; a fixture spec asserting placement per filetype would catch regressions the REUSE lint cannot (it checks presence, not position).
4. **`scripts/foundation-init.sh` / `foundation-doctor.sh`** — bootstrap and staleness logic untested; init is fixture-friendly (run against a temp dir, assert the seeded tree).
5. **`scripts/rewrite-pr-as-merge-commit.sh`** — untested; same throwaway-repo harness style as sign-push-test.
6. **`scripts/sandbox-enter.sh` / `sandbox-exit.sh`** — only ad-hoc verification (default parent + tmp-reaper caveat were exercised manually this session); a harness could assert remote save/restore round-trips per mode.
7. **Base-hook runner itself** — the run-parts loop (classicalre gating, dot-suffix disable, plugin failure propagation) has no dedicated spec; the pieces are exercised indirectly.
8. **rumdl config regressions** — `.rumdl.toml` choices (soft-wrap, code cap 118, MD041 exclude list, per-directory MD025) are enforced live by `rumdl check .` in CI, which doubles as the regression test; no separate harness needed unless the config grows conditional logic.
