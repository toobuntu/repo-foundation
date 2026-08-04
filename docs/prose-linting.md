<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Prose linting

[Vale](https://vale.sh) checks the tracked Markdown against the org-wide `Toobuntu` style under `.vale/styles/` (ADR 0014). This page covers the parts that are not obvious from the config: the one rule that deliberately never gates, how to review it, and how to excuse a deliberate example without weakening the rule. For the everyday command, see the gates list in [`CONTRIBUTING.md`](../CONTRIBUTING.md).

## The gate

```sh
git ls-files -z '*.md' |
  xargs -0 -r sh -c 'for f in "$@"; do [ -r "$f" ] && printf "%s\0" "$f"; done' keep-readable |
  xargs -0 -r vale
```

Vale has no `.gitignore` support, so a bare `vale .` also scans whatever vendored documentation the working tree happens to carry — `vendor/bundle/`, `node_modules/`, a checked-out dependency; listing the tracked files avoids all of it, provided it is untracked — which vendored dependencies normally are, but a repository that commits its vendored docs will see them in this run. The `-z`/`-0` pairing is not decoration — a path containing a space or a newline is split into pieces without it. The inner filter drops a tracked file that has been deleted on disk without the deletion being staged, which vale would otherwise fail on; it is a no-op on a clean tree.

The same command runs in the `prose` CI job and, over the staged files, in the `15-prose` pre-commit plugin. One policy, three triggers.

## The rules that never gate

`.vale.ini` sets `MinAlertLevel = error`, so warning-level rules are evaluated and then discarded. Two rules ride at warning in repo-foundation: `Toobuntu.AbbreviationPluralsAmbiguous` permanently, and `Toobuntu.Acronyms` until the rule itself is redesigned. `Vale.Spelling` was a third until 2026-08-03 and now gates — see [the vocabulary](#the-vocabulary) for what that costs and why it was worth it.

`Toobuntu.AbbreviationPluralsAmbiguous` flags an abbreviation followed by `'s` in a position where a possessive is perfectly legitimate (`RF's existing calls`) and a plural would be wrong (`the PR's merged yesterday`). No linter can decide between those, so it is a prompt to read, never a build failure. Expect it to fire on correct prose; resolve each by reading, not by rewording.

`Toobuntu.Acronyms` flags an all-caps token used without ever being spelled out. Its `first` pattern is `\b([A-Z]{3,})\b`, which cannot tell an acronym from anything else written in capitals — and this house style writes emphasis in capitals constantly. Measured over the tracked Markdown on 2026-08-03: 481 alerts across 186 distinct tokens, of which **51% are ordinary English words used for emphasis** (`NOT`, `PATH`, `DONE`, `AND`, `HEAD`, `ONE`, `ONLY`), **18% are file names** (`README`, `AGENTS`, `CONTRIBUTING`, `CLAUDE`, `LICENSES`), and only 31% are acronyms at all. Its `second` pattern — the one that recognizes a definition — is `(?:\b[A-Z][a-z]+[\s-]?)+\(([A-Z]{3,})\)`, so it accepts "Architectural Decision Record (ADR)" and rejects "You Aren't Gonna Need It (YAGNI)", which means a properly defined acronym is still reported.

Both defects are in the rule, not the corpus, and neither is reachable through the `exceptions` list: closing the first would mean listing every English word the docs ever emphasize, which would also stop the rule firing on a genuine undefined acronym that happens to be a word. So it stays advisory, and promoting it is off the table until it is rewritten. That rewrite is a separate decision and is not queued.

You do not have to remember to look for it. The `15-prose` plugin prints its findings when a commit contains any, and the `prose` workflow logs them in an informational step that neither annotates nor gates — the only exposure a contributor who never enabled the git hooks gets.

## The vocabulary

Two lists, and vale reads both: `Toobuntu` is the canonical org-wide vocabulary under `.vale/styles/config/vocabularies/Toobuntu/accept.txt`, synced read-only from repo-foundation; `Local`, in the sibling directory, is the repository's own and is never synced. Every repository but this one seeds `Vocab = Toobuntu, Local` from `provides/vale/vale.ini.template`. repo-foundation carries only `Toobuntu`, deliberately — it owns the canonical list, so a local layer here would be a place for org-wide terms to hide from the consumers that need them. Everywhere else, a product name, a daemon, or a flag goes in `Local` first, and the canonical list is for terms that are genuinely org-wide.

`.vale.ini` itself is per-repo and is not synced, because the scope-block relaxations at the bottom of it vary — one repository excuses `docs/handoff/*.md`, another will want its design notes. That has a consequence worth naming: the alert level of a rule lives in six independent files, so **promoting a rule is a per-repo decision taken against that repository's own corpus**, never one org-wide switch.

What an entry matches, all measured against vale 3.17.0:

- **Entries are regular expressions.** `frob(s|bed)?` accepts `frob`, `frobs` and `frobbed`, and nothing else.
- **Matching is case-insensitive in both directions.** `repo` accepts `Repo` and `REPO`; `Quux` accepts `quux`. Natural casing in the file is therefore for the reader, not the matcher. (Canonical *casing* is enforced separately, by `Toobuntu.Terms`, which keeps its own swap list and does not read this file.)
- **An entry covers the possessive but not the plural.** The apostrophe is a word boundary, so `repo` already accepts `repo's` — but `repos` needs `repo(s)?`. This is the single most common reason a term looks accepted and still fires.
- **Ordinary English words sometimes need an entry, and that is not a mistake.** The dictionary licenses the possessive for most nouns — `dog's`, `system's`, `file's`, `user's`, `branch's` all pass unaided — but not for all of them: `commit's` and `maintainer's` are flagged until `commit` and `maintainer` are listed. That is why a domain vocabulary contains a few plain words.
- **There are no comments.** Every line is a pattern, so `# like this` would be one. Rationale for a group of entries belongs here, not in the file.

**Naming a vocabulary that does not exist is a hard failure, not a silent skip.** Vale reports `E100 [vocab] Runtime error — '<name>' vocabulary not found`, exits 2, and lints nothing at all — so the prose gate and the `15-prose` hook both fail with a config error rather than a finding. A vocabulary *directory* that exists but is empty is fine, and so is an empty `accept.txt`. Git does not track an empty directory, though, which is why `foundation-init` seeds `Local/accept.txt` as a real (empty) tracked file with its `.license` sidecar: seeding only the name would hard-fail every prose run on the next clone.

### Vale.Spelling was promoted on 2026-08-03

It had ridden at warning since ADR 0014 "until the vocabulary matures". The review that closed that out measured 710 findings across 207 distinct terms in this repository — and **not one was a misspelling.** Every one was a domain term, an identifier, a proper noun, or a deliberate coinage; `repo`, `repos` and `repo's` alone accounted for 154. Adding them, mostly as plural-tolerant patterns, took the corpus to zero.

The rule gates here now. The ongoing cost is one line in the canonical vocabulary in the commit that introduces a new term, and the benefit is that a genuine typo fails at the commit rather than never. Two things make that trade acceptable rather than merely defensible: the `Local` layer means a consumer's own domain terms never need a repo-foundation round trip, and promotion is per-repo, so each repository takes it when its own corpus reads clean. Consumers stay at warning until then.

## Reviewing warnings by hand

The everyday form narrows to the one rule, which is exactly what the pre-commit plugin and the CI step already run:

```sh
git ls-files -z '*.md' | xargs -0 -r vale --minAlertLevel=warning \
  --filter='.Name=="Toobuntu.AbbreviationPluralsAmbiguous"'
```

The review forms on this page are deliberately short: they skip the readable-path filter the gate uses. That filter guards one narrow case — a tracked file deleted on disk without the deletion staged — which is worth handling silently in an automated gate and not worth carrying in a command you type, where the resulting `no such file` names the path and tells you exactly what to do. `--filter` takes a vale expression matching against the alert's fields; `.Name` is the rule. It is what keeps `Toobuntu.Acronyms` — which reports several hundred times per full-tree run, most of them not acronyms — from burying the handful of results you asked for, and it does that without a `jq` pipeline. Chain it after the gate with `&&` for a full sweep in one line.

**One caveat, and it is the reason this is a second pass rather than a replacement for the first.** `--filter` drops non-matching alerts *before* vale computes its exit code, so a file with a real error exits 0 under a filtered run. Never let a filtered invocation stand in for the gate.

Without a filter, the level alone is safe to raise: **vale's exit code keys on errors, not on `--minAlertLevel`.** A warning-only file exits 0 at either level, and a file with an error exits 1 at either level.

```sh
git ls-files -z '*.md' | xargs -0 -r vale --minAlertLevel=warning
```

So that single unfiltered pass gates exactly as the default does while also showing every warning. Be ready for the volume: `Toobuntu.Acronyms` outnumbers everything else by two or three orders of magnitude, so this form is for a deliberate review pass, not for finding the handful of alerts you came for. Day to day, run the plain gate and let the hook and CI raise the ambiguity rule when it applies.

### Slicing one run with jq

When you do want to narrow, prefer filtering in `jq` over re-running vale. Vale's part-of-speech tagging is the expensive step; `jq` is free, and one run can answer several questions:

```sh
git ls-files -z '*.md' |
  xargs -0 -r vale --output=JSON --no-exit --minAlertLevel=warning |
  jq -r '
    to_entries[]
    | .key as $file
    | .value[]
    | select(.Check == "Toobuntu.AbbreviationPluralsAmbiguous")
    | "\($file):\(.Line):\(.Span[0]): \(.Match)"
  '
```

Which keys are worth printing depends on whether you narrowed to a single rule:

| key | filtered to one rule | across rules |
| --- | --- | --- |
| `Check` | constant — clutter | essential; names the rule |
| `Message` | constant — clutter | essential; differs per rule |
| `Match` | essential; it is the suppression key | essential |
| `Line` | essential | essential |
| `Span` | worth keeping (see below) | worth keeping |

`Span` earns its place here specifically because this org soft-wraps prose (ADR 0020): a source line runs hundreds of characters, and the same match text can appear more than once on one of them. `Line` alone does not locate it; `Line` plus `Span[0]` does.

## Excusing a deliberate example

A document that discusses the rule will trip it. Two mechanisms, in order of preference.

**Code spans.** Vale skips inline code, so an example written as `` `the PR's merged yesterday` `` needs no directive at all. This is honest markup rather than a workaround — these are literal example strings — and it is per-example precise. Prefer it.

**Directives**, where the example has to be running prose:

```html
<!-- vale Toobuntu.AbbreviationPluralsAmbiguous = NO -->

Deliberate: "the PR's merged yesterday" illustrates the plural misuse.

<!-- vale Toobuntu.AbbreviationPluralsAmbiguous = YES -->
```

Always restore with the `YES` corollary — without it the rule stays off for the rest of the file.

### Directives act a block at a time

This is the one thing worth internalizing. A *block* is a Markdown block-level element — a paragraph, a list, a heading, a fenced code block — not a code fence specifically.

A `NO` applies from the block it sits in through the end of the file, or until the matching `YES`. Where inside that block it sits makes no difference, so a directive trailing its own paragraph still covers that paragraph, and a directive cannot reach backwards into an earlier block.

The corollary: **`NO` and `YES` must not share a block.** Put both inside one paragraph and the result is unreliable — keyed, it suppresses nothing at all; unkeyed, it silences the first match and lets the next through. Give each directive its own line between blocks.

### Naming a single match

A directive can carry a bracketed key, suppressing one match and leaving every other match of the same rule in the same block reported:

```html
<!-- vale Toobuntu.AbbreviationPluralsAmbiguous["PR's merged"] = NO -->
```

The key must be the **whole matched span**, exactly as vale reports it — not a word you pick out of it. For a `sequence` rule the span covers every token in the sequence, so the key is `PR's merged`; the intuitive `PR's` matches nothing and silently suppresses nothing, which is worse than an error because it looks like it worked.

Never guess the key. Read it from the `Match` field of the JSON output above. [ADR 0010](https://github.com/toobuntu/repo-foundation/blob/main/docs/decisions/0010-merge-strategy.md) carries a worked example: a confirmed possessive in published prose, excused by name with a comment recording what was confirmed, leaving the ADR's text untouched.

## Traps

- **Never use `--filter` on the gate.** It removes non-matching alerts *before* the exit code is computed, so a file with a real error exits 0. `--filter` belongs only on a review pass.
- A token instead of the full match span (`["PR's"]`) suppresses nothing, silently.
- `NO` and `YES` in the same block cancel unreliably.
- Writing any of these directives inside a fence or a code span, as this page does throughout, is safe: vale does not act on a documented example.

Verified against vale 3.17.0.
