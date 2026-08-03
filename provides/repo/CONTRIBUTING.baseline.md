## License headers (REUSE)

Every file must carry SPDX license metadata *before* it is committed, enforced by the CI `lint-reuse` job ([reuse.software](https://reuse.software/)). The expected format is:

```text
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
```

The annotation can live inline (preferred) or in a sidecar `<file>.license` file — used when a file's format has no comment syntax (such as `.json`) or when tooling rewrites the file and would strip an inline comment (such as a `.plist` edited by PlistBuddy).

### How to add headers to new files

Run `scripts/annotate.sh` from the repository root. It scans for non-compliant files, classifies them by extension and path, and inserts SPDX blocks in the right comment style (or creates a sidecar where inline is unsafe). The script is idempotent — already-compliant files are skipped.

```sh
scripts/annotate.sh
```

To use a different copyright owner or license (for example when running the script in a non-toobuntu repository), set environment variables:

```sh
ANNOTATE_COPYRIGHT="Some Other Person" \
ANNOTATE_LICENSE="MIT" \
scripts/annotate.sh
```

`scripts/annotate.sh` is synced from `toobuntu/repo-foundation`; this repository holds a downstream copy. Change it there, not here.

### YAML frontmatter and SPDX placement

Markdown files with YAML frontmatter (Architectural Decision Records, Claude Code skills, MkDocs pages) need care: the SPDX block must not push the frontmatter off file position 1, or the tools that parse it (`adrs doctor`, Claude Code's skill loader) break. Let `scripts/annotate.sh` decide: it runs `reuse annotate --style=html` for `.md` files, which is frontmatter-aware and inserts the SPDX block as `#` comments *inside* the frontmatter, above the other keys — so the frontmatter still opens at line 1 and parses cleanly. Never hand-place the SPDX block above or after the frontmatter.

This was verified rather than assumed (2026-07-30, `reuse` 6.2.0): both skill-style and ADR-style frontmatter receive the block inside the fences, and a skill annotated that way loads — YAML `#` comments are comments, so a frontmatter parser consumes them as nothing. An after-the-frontmatter HTML comment block also satisfies `reuse lint`, so a file carrying one is not broken; it is simply not what the tool produces, and `annotate.sh` leaves already-compliant files alone. Prefer the tool's placement for anything new.

## Testing workflows before you push

The CI workflows in this repository can be exercised locally with [`act`](https://github.com/nektos/act) — a schema check needs nothing but `act` itself, and a real run of an `ubuntu-latest` job needs Colima plus the Docker CLI it requires (`brew install act colima docker`). The copy-paste forms, the flags that are hard to discover, and a VM-isolated flow for the macOS job are in `docs/testing-github-workflows-locally.md` (synced into this repository; canonical copy [in repo-foundation](https://github.com/toobuntu/repo-foundation/blob/main/docs/testing-github-workflows-locally.md)); start at its Quick reference.

## Commits and pull requests

- Subject line ≤ 50 characters; body wraps at 72.
- [Conventional Commits](https://www.conventionalcommits.org/) for the subject — `type(scope): summary`, with `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `build`, `ci` as the types. Homebrew-aligned repositories are the exception: Homebrew prohibits Conventional Commits, so its taps and external commands follow Homebrew's own commit style and enforce it with a `Commit Style` check.
- Reference issues with `Closes #N` in the commit body.
- No verbose AI commentary in commit messages or PR descriptions; note AI assistance and what manual verification was performed.
- PRs are merged with **merge commits** (not squash, not rebase), preserving PR identity in `git log --graph` and keeping the original commit authorship and dates. See repo-foundation [ADR 0010](https://github.com/toobuntu/repo-foundation/blob/main/docs/decisions/0010-merge-strategy.md).

### Signed pushes (maintainer policy, not a contribution gate)

The `.githooks/pre-push` hook validates that every commit a push introduces carries a valid signature. Signed history is a policy the maintainers impose on themselves; it is not a barrier to contributing:

- With no extra configuration, the hook **enforces** only where commit signing is configured locally (`commit.gpgsign=true` or `user.signingkey` set) — that is, on maintainer machines. If signing is not configured, the same scan runs but prints a warning and the push proceeds, so a contributor who enabled the hooks for the pre-commit checks is informed but never blocked.
- `git config hooks.requireSignedPush true|false` overrides the detection in either direction. A one-off bypass that keeps every other check: `git -c hooks.requireSignedPush=false push ...` (prefer this over `--no-verify`, which skips the hook entirely).
- A signature is the committer's attestation, not the author's, so a maintainer may re-sign contributor commits before merging; authorship is preserved. For the routine case — signing a repository's own unpushed unsigned commits and pushing — use `scripts/sign-push.sh`; for an arbitrary fetched range (a contributor's PR branch, which sign-push.sh's unpushed-commit detection deliberately skips because those commits are already remote-reachable), the underlying recipe is `git rebase --exec 'git commit --amend --no-edit --gpg-sign' <base>`. Any server-side signed-commit rule on `main` applies regardless of local hooks — keep the GitHub ruleset consistent with this policy.

## Prose and style

Markdown prose is linted with [Vale](https://vale.sh) against the org-wide `Toobuntu` style, enforced by the CI `prose` job and the `15-prose` pre-commit plugin. Run it locally over the tracked files:

```sh
git ls-files -z '*.md' |
  xargs -0 -r sh -c 'for f in "$@"; do [ -r "$f" ] && printf "%s\0" "$f"; done' keep-readable |
  xargs -0 -r vale
```

Vale has no `.gitignore` support, so a bare `vale .` also scans any vendored documentation in the working tree; listing the tracked files avoids that where the vendored content is untracked, and the `-z`/`-0` pairing keeps a path containing a space intact.

One rule deliberately never gates. `Toobuntu.AbbreviationPluralsAmbiguous` flags an abbreviation followed by an apostrophe-s in a position where a possessive is legitimate and a plural would be wrong — no linter can decide between those, so it rides at warning and asks for a human read. The pre-commit plugin prints its findings when a commit contains any, and the CI job logs them; neither blocks. To see them before you get as far as committing, run the same second pass those two run:

```sh
git ls-files -z '*.md' | xargs -0 -r vale --minAlertLevel=warning \
  --filter='.Name=="Toobuntu.AbbreviationPluralsAmbiguous"'
```

`--filter` narrows to that one rule, which is what keeps `Vale.Spelling` — also at warning, against a still-maturing vocabulary — from burying the result. It is a **second** pass, never a substitute for the gate above: `--filter` drops non-matching alerts before vale computes its exit code, so a filtered run reports success on a file that has a real error. Chain the two with `&&`.

Judging a finding, and excusing a deliberate example without weakening the rule, are covered in [`docs/prose-linting.md`](https://github.com/toobuntu/repo-foundation/blob/main/docs/prose-linting.md).

## Encoding and invisible Unicode

All source, documentation, and configuration files must be valid **UTF-8** and contain **no BOM** (U+FEFF anywhere, including a leading byte-order mark); UTF-16/UTF-32 are rejected. This is enforced automatically: the pre-commit hook scans each staged blob for invisible bidi/zero-width control characters (RedHat's [RHSB-2021-007](https://access.redhat.com/security/vulnerabilities/RHSB-2021-007) approach, in POSIX `/bin/sh`), and the CI `lint-unicode` job rejects any Unicode Cf/Cc-category character on the Ubuntu runner. Rationale, full codepoint coverage, and alternatives considered live in repo-foundation
[ADR 0006](https://github.com/toobuntu/repo-foundation/blob/main/docs/decisions/0006-trojan-source-detection-strategy.md).

A file that legitimately needs a blocked codepoint (for example an i18n library, or an iCalendar writer emitting LRM in an RTL string) can opt out with an `invisible-allow:` annotation anywhere in it:

```go
// invisible-allow: U+200E
package icalwriter
```

The annotation lists comma-separated `U+XXXX` codepoints from the blocked set; both the pre-commit hook and the CI scanner honor it, and it is reviewable in the PR diff and grep-able (`grep -r invisible-allow:`). Use it sparingly — each exemption widens the attack surface.
