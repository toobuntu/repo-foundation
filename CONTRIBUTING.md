# Contributing to repo-foundation

repo-foundation is the org-wide canonical source for the toobuntu repositories.
The rules in the first half of this file are the **baseline** that
`provides/repo/CONTRIBUTING.baseline.md` syncs into every consumer; the second
half is specific to working on the sync hub itself. A change here that belongs
org-wide should land in the baseline so it propagates.

## License headers (REUSE)

Every file must carry SPDX license metadata before it is committed, enforced by
the CI `lint-reuse` job ([reuse.software](https://reuse.software/)). The expected
form is:

```
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
```

Do not hand-write SPDX headers. Run `scripts/annotate.sh` from the repository
root: it classifies each non-compliant file by extension and path and inserts
the SPDX block in the right comment style, or creates a `<file>.license` sidecar
where an inline comment is unsafe (JSON, plists, checksums, generated files). It
is idempotent. This **includes Architectural Decision Records**: `annotate.sh`
places their SPDX as `#` comments inside the YAML frontmatter, the form
`adrs doctor` requires — never hand-place it.

## Commits and pull requests

- Subject line ≤ 50 characters; body wraps at 72.
- Reference issues with `Closes #N` in the body.
- No verbose AI commentary in commit messages or pull-request descriptions; note
  AI assistance and what manual verification was performed.
- Pull requests merge with **merge commits** (not squash, not rebase), preserving
  pull-request identity and the original authorship and dates
  ([ADR 0010](docs/decisions/0010-merge-strategy.md)).
- READMEs follow the
  [standard-readme](https://github.com/RichardLitt/standard-readme) spec
  ([ADR 0008](docs/decisions/0008-adopt-standard-readme.md)).
- Prose follows the canonical Toobuntu Vale style
  ([ADR 0014](docs/decisions/0014-prose-and-markdown-lint-discipline.md)):
  en_US, impersonal, terse. The `prose` CI job gates on error-level alerts.

### Signed pushes (maintainer policy, not a contribution gate)

The `.githooks/pre-push` hook checks that every commit a push introduces carries
a valid signature. Signed history is a policy the maintainers impose on
themselves, not a barrier to contributing:

- With no extra configuration the hook enforces only where commit signing is
  configured locally (a maintainer machine); otherwise it warns and the push
  proceeds.
- `git config hooks.requireSignedPush true|false` overrides the detection. A
  one-off bypass that keeps every other check is
  `git -c hooks.requireSignedPush=false push …` (prefer it over `--no-verify`).
- A signature is the committer's attestation, so a maintainer may re-sign
  contributor commits before merging; authorship is preserved
  ([ADR 0007](docs/decisions/0007-pre-push-signing-self-guardrail.md)).

## Encoding and invisible Unicode

All source, documentation, and configuration must be valid UTF-8 with no BOM;
UTF-16/UTF-32 are rejected. The pre-commit hook scans each staged blob for
invisible bidi/zero-width control characters and the CI `lint-unicode` job scans
the whole tree
([ADR 0006](docs/decisions/0006-trojan-source-detection-strategy.md)). A file
that legitimately needs a blocked codepoint can opt out with a `bidi-allow:`
annotation listing the `U+XXXX` codepoints; use it sparingly.

## Working on the sync hub

repo-foundation is not an ordinary repository — a change here can rewrite a file
in every consumer. A few things to keep in mind:

- **The engine and manifest are a contract.** `sync-manifest.yaml` and
  `.github/actions/sync/sync-files.rb` decide what every consumer receives.
  Exercise `spec/integration/sync_files_spec.rb` after any engine change, and
  reason about each consumer before changing a mode, the header logic, or the
  sentinel format.
- **Canonical files are org-neutral.** A `mode: canonical` file is byte-identical
  in every consumer, so it must never name one consumer or one consumer's paths
  (that leak would sync everywhere). Keep it generic.
- **Org-wide ADRs live only here** and are referenced by pointer
  ([ADR 0004](docs/decisions/0004-org-wide-adr-location-and-references.md)).
  Author new ones with `adrs new`, keep the sequence contiguous, and verify with
  `adrs doctor`.
- **Run the gates locally** before pushing: `bundle exec rspec`, `reuse lint`,
  `scripts/lint-unicode.sh .`, `scripts/lint-perms.sh --tracked`, `adrs doctor`,
  `vale .`, `actionlint`, and `zizmor .`. The agent commit-and-signing procedure
  for sandboxed work is in `docs/agent-principles.md`.
