<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Opening prompt — clean up Vale prose violations in the consumer repos

Paste this to open a session that brings each `toobuntu/*` consumer's Markdown
corpus into compliance with the canonical `Toobuntu` Vale style, after the style
has synced to it.

## Context

W1 Session 5 landed the canonical org-wide `Toobuntu` Vale style in
`repo-foundation` (`.vale/styles/Toobuntu/`, vocab at
`.vale/styles/config/vocabularies/Toobuntu/accept.txt`) and the Vale CI job
(`.github/workflows/prose.yml`). It syncs to consumers via the `prose_lint`
manifest set (ADR 0014, ADR 0003). repo-foundation's own corpus already passes;
each consumer's existing prose does not yet.

The style is in `repo-foundation/.vale.ini` (RF's own) and
`repo-foundation/provides/vale/vale.ini.template` (the per-repo scaffold
`foundation-init` seeds). `vale-styles-evaluation.md` (in
`~/devel/claude/desktop/workspace/repo-foundation/`) is the rule roster and
rationale.

## What gates and what does not

`MinAlertLevel = error`, so only **error-level** rules fail CI:

- `Toobuntu.AmericanSpelling` — en_GB → en_US (deterministic; correctness, not
  voice; enforced **everywhere**, even in working-note globs).
- `Toobuntu.We` — first-person plural (`we`/`our`/`ours`/`ourselves`/`let's`);
  relaxed per-glob for handoff/working-note docs only.
- `Toobuntu.AbbreviationPlurals` — `PR's` → `PRs` (POS-aware; possessives pass).
- `Toobuntu.MergeConflictMarkers` — leftover `<<<<<<<` / `>>>>>>>`.

`Vale.Spelling` rides at **warning** (non-gating) until the org vocab matures,
and the mechanical rules `NonStandardQuotes` / `SentenceSpacing` /
`WordSlashWord` / `Acronyms` / `Terms` / `InclusiveLanguage` are at warning too.
They report but do not fail CI; promote them to error per consumer after a clean
pass.

## Task, per consumer

Consumers: blackoutd, zman-didan, babble, bob-book, cert-automation,
homebrew-cask-tools. For each (once the `prose_lint` sync has delivered the
style and the repo has a `.vale.ini`):

1. Run `vale .` from the repo root. Fix every **error-level** alert:
   - en_GB spellings → en_US.
   - First-person plural → impersonal phrasing. Where first person is genuinely
     the right voice (prose-heavy docs, not code/config), either backtick a
     quoted example (Vale skips the `code` scope) or add a per-glob
     `Toobuntu.We = NO` relaxation in that repo's `.vale.ini`. **bob-book** is
     largely prose, not code, so expect legitimate first-person there — relax
     the prose globs rather than rewrite voice, and bring any ambiguous case to
     the maintainer.
   - `PR's`-style abbreviation plurals → `PRs`.
2. Run `vale --minAlertLevel=warning .` to see the non-gating findings; fix the
   easy ones (curly quotes, `and/or`, term casing) opportunistically.
3. Reduce `Vale.Spelling` noise by adding **genuine** domain terms to a vocab.
   Put org-wide tech terms in repo-foundation's `Toobuntu/accept.txt` (then
   re-sync); put **repo-specific** terms (a project's jargon) in a repo-local
   vocab and add it to `Vocab =` in that repo's `.vale.ini`.

## Special case: zman-didan migrates off its local `Didan` style

zman-didan built the original `Didan` style, now superseded by the synced
`Toobuntu`. After the sync:

- Point `.vale.ini` at `BasedOnStyles = Vale, Toobuntu` and `Vocab = Toobuntu`.
- Delete `.vale/styles/Didan/` and the `Didan` vocab from zman-didan.
- The Hebrew/Judaica terms in didan's old `accept.txt` are **didan-specific**,
  not org-wide — keep them in a **repo-local** vocab (e.g. a `Didan` vocab kept
  only in zman-didan, added alongside `Toobuntu` in `Vocab =`), not in the
  canonical `Toobuntu/accept.txt`.

## When a consumer is clean

Once a consumer passes `vale .` at error and the warnings are addressed, the
maintainer may promote `Vale.Spelling` and the mechanical rules to error in that
repo's `.vale.ini` (and, once true org-wide, in repo-foundation's canonical
`.vale.ini` and the scaffold). Promotion is per ADR 0014: warning → run the
corpus → promote on a clean pass.
