---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 20
title: Lint Markdown structure and enforce soft-wrap with rumdl
status: accepted
date: 2026-07-21
decision-makers:
  - toobuntu
---

# Lint Markdown structure and enforce soft-wrap with rumdl

## Context and Problem Statement

ADR 0014 adopted Vale for **prose** (house style and vocabulary) and explicitly left Markdown **structure** — heading spacing, fenced-code languages, list formatting, line wrapping — as "a separate concern". With no local structural gate, CodeRabbit's `markdownlint-cli2` began flagging those issues on pull requests: findings no pre-commit or CI check caught first, which is exactly the review-bot churn the org tries to pre-empt.

Three questions follow. Which Markdown structure linter, and what rules? What is the line-wrapping policy that MD013 governs — and it is not obvious, because a hard wrap that reads well in a committed `.md` file breaks when the same text is pasted into a GitHub PR or issue **comment**. And how should the choice reconcile with CodeRabbit so it stops duplicating a gate the repo owns?

## Decision Drivers

- One structural gate, org-wide and synced (ADR 0003), running both pre-commit and in CI (the hook-plus-CI split of ADRs 0005/0006/0017).
- Start from Homebrew's proven docs ruleset; diverge only with a stated reason.
- A wrapping rule that renders correctly both in a rendered `.md` file and when pasted into a GitHub comment, since this repo routinely writes snippets for that use.
- Do not have CodeRabbit re-run a linter the repo already gates; instead give its AI reviewer the house context it keeps missing.
- Prefer the maintainer's Rust-over-Node tooling preference where it fits.

## Considered Options

For the linter:

- **`mdl`** (Ruby gem) — Homebrew's own tool; runs its `.mdl_style.rb` and Ruby custom rules verbatim. But it has no formatter, a coarse MD013, and needs Ruby.
- **`markdownlint-cli2`** (Node) — the tool CodeRabbit runs; reads `.markdownlint.yaml`. But it has no true formatter and adds a Node dependency.
- **`rumdl`** (Rust) — reads both markdownlint configs and its own `.rumdl.toml`; has a real `rumdl fmt`; MD013 supports reflow and a separate code-block cap; installs via `brew`. (chosen)

For the wrapping policy:

- **Hard-wrap at a fixed width** — renders fine in a committed `.md` file, but a paragraph's single newlines become `<br>` when pasted into a GitHub comment, so it renders as broken short lines there.
- **Soft-wrap** — one logical line per paragraph and list item, no hard breaks. Renders as a reflowing paragraph everywhere, including comments. (chosen)

## Decision Outcome

Adopt **rumdl** as the org-wide Markdown structure linter and formatter, configured by a single `.rumdl.toml`, enforcing **soft-wrap**.

- **Tool: rumdl.** It is the only one of the three with a real formatter (`rumdl fmt`) and a granular MD013 (reflow plus a separate code-block cap), it installs via `brew` exactly as Vale and `adrs` do, and it satisfies the Rust-over-Node preference. The config is a single `.rumdl.toml`, not a `.markdownlint.yaml` + `.rumdl.toml` split: rumdl ignores a `.markdownlint.yaml` when a `.rumdl.toml` is present (verified), and the soft-wrap reflow is a rumdl-only capability, so a split would buy no portability.
- **Wrapping: soft-wrap** via `reflow-mode = "normalize"` with `line-length = 10000`, which collapses each paragraph and list item to a single logical line. A hard-wrapped paragraph renders as separate lines when pasted into a GitHub PR/issue comment (GitHub turns single newlines into `<br>` in comments, though not in rendered `.md` files), and this repo routinely produces such snippets, so one org-wide soft-wrap rule keeps both committed docs and paste-ready snippets correct. `rumdl check` flags un-normalized content and `rumdl fmt` joins it, so the rule is enforced, not merely available.
- **Code blocks keep a real cap of 118** — matching `brew style`'s RuboCop line limit, so a command shown in a doc obeys the same width the repos' Ruby does — because code never reflows. A genuinely unbreakable command (a long path) is exempted by wrapping its block in a `<!-- rumdl-disable MD013 -->` / `<!-- rumdl-enable MD013 -->` pair, since an inline directive cannot sit inside a fence.

### Rules: Homebrew-seeded vs adapted

The ruleset is seeded from Homebrew's docs config (`mdl`: `.mdlrc` + `.mdl_style.rb` + `.mdl_ruleset.rb`) and adapted where house needs differ.

| Rule | Homebrew (`mdl`) | repo-foundation | Disposition |
| --- | --- | --- | --- |
| MD007 list indent | 2 | 2 | adopted |
| MD026 heading punctuation | `,;:` | `,;:` | adopted (lets `?`/`.` headings pass) |
| MD013 line length | excluded | soft-wrap (reflow) + code cap 118 | diverged: enforce paste-safe wrapping |
| MD046 code-block style | excluded | fenced | diverged: a fence carries a language, reads in diffs |
| MD033 inline HTML | excluded | excluded | adopted (the `<repo>`/`<branch>` placeholders) |
| MD004 list marker | default | dash, org-wide | diverged: one marker; `adrs doctor` accepts dash |
| MD025 single H1 | default | `front-matter-title = ""` | config fix: ADR frontmatter `title:` + body `# H1` |
| MD041 first-line H1 | out of scope (`mdl` lints `docs/` only) | on, with an exclude list | the pointer `CLAUDE.md`, `*.instructions.md`, and `*.baseline.md` fragments are non-documents |
| MD060 table alignment | none (`mdl` predates it) | aligned-delimiter | a Toobuntu addition beyond Homebrew |
| HB034 / HB100 / HB101 (Ruby custom) | present | dropped | HB100/HB101 are `docs.brew.sh`-specific; HB034 ≈ built-in MD034 |

### CodeRabbit reconciliation

- The **`markdownlint`** tool is **off**: repo-foundation gates the same rules itself (the `10-markdown` plugin and the CI job), so a second CodeRabbit pass only re-reports the repo's own gate.
- The **`languagetool`** grammar checker stays **on**: it is a distinct tool from Vale, which enforces house style and vocabulary rather than grammar, and its comments can be declined.
- **`path_instructions`** carry the house conventions the AI reviewer keeps missing: the BSD-userland `grep --null-data` / `xargs --no-run-if-empty` idioms, the self-contained pre-commit-plugin helper pattern (ADR 0017), and the SPDX-inside-ADR-frontmatter rule.
- `.coderabbit.yaml` is canonical and synced to every consumer via `repo_config`.

### Distribution

The `markdown_lint` component set (`.rumdl.toml` plus the `10-markdown` plugin) maps to every hook-carrying consumer; the `markdownlint` CI job rides the canonical `lint.yml` (`ci_core`); `rumdl` joins the Copilot install lists (the `upstreams` tap mutation and the non-tap scaffold, per ADR 0015); and `.coderabbit.yaml` rides `repo_config`. The `10-markdown` master sits at the natural path because repo-foundation runs it on its own commits (ADR 0001), alongside `10-shell`, `15-prose`, and `50-adrs`; `15-prose` is numbered after it on purpose, because vale must lint the text this plugin reformats and re-stages (ADR 0019).

### Consequences

- Good, because structural and wrapping issues are caught at the commit (auto-fixed by the plugin) and in CI, so CodeRabbit stops nagging about them, and one config drives both gates.
- Good, because soft-wrap makes committed docs and pasted snippets render correctly everywhere and removes the re-wrap diff noise a hard cap creates on mid-paragraph edits.
- Good, because rumdl's formatter makes the whole rule auto-applied rather than hand-maintained.
- Bad, because soft-wrap makes source lines long, so an editor that does not soft-wrap its display shows wide lines; accepted, since the rendered and pasted output is what matters.
- Bad, because the first `rumdl fmt` pass rewrites nearly every doc; accepted as a one-time org-wide standardization the maintainer chose.
- Neutral, because rumdl's MD071 (blank after frontmatter) and MD076 (list-item spacing) are rumdl-only extensions; `markdownlint-cli2` silently ignores them if a consumer ever runs it.

## More Information

Refines ADR 0014 (prose lint via Vale) and complements ADR 0008 (README structure via remark). The hook-plugin mechanics are ADR 0017; the natural-path mastering rule is ADR 0001; the sync that distributes all of it is ADR 0003; the Copilot install-list distribution is ADR 0015. Homebrew's ruleset lives in its docs `.mdlrc`, `.mdl_style.rb`, and `.mdl_ruleset.rb`. rumdl reads `.rumdl.toml` and markdownlint configs; `reflow-mode = "normalize"` joins both paragraphs and list items into single lines.
