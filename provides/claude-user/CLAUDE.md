<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# CLAUDE.md — User-global agent context

This file lives at `~/.claude/CLAUDE.md` and is loaded automatically
by Claude Code on every session, regardless of project. It is for
**personal cross-project context** that any agent on any of your
repos should know about your environment.

It is intentionally short. Operating principles (pre-action
discipline, modern git verbs, sandbox model, universal denies, etc.)
do NOT live here — they live in each repo's `docs/agent-principles.md`
file (committed, contributor-visible) and are imported by each repo's
`AGENTS.md`. That way contributors who clone a repo automatically
get the principles; they don't depend on the maintainer's
`~/.claude/`.

This file holds only stuff that's true about **this user** (your
environment, your preferred patterns) and would be the same on any
project you work on.

## Personal-tooling preferences

Maintainer is on macOS Tahoe (26.x), MacBook Air M2 (Mac14,2),
arm64, en_US locale, US-Eastern timezone.

Shells:

- **zsh** is the interactive default (Apple's default since Catalina).
- **ksh93** is the preferred shell for administrative scripts —
  POSIX-compliant, portable, available out of the box on macOS, and
  supports the maintainer's preferred patterns (`ERR` traps,
  `${var:-default}`, etc.) without bash-isms.
- **bash** is acceptable for tests and one-off cases where zsh
  quirks are problematic; it is not the day-to-day choice.

When writing scripts intended to run on this machine, prefer
`/bin/sh` (POSIX) or `/usr/bin/env ksh` (ksh93). Use bash only
when a feature genuinely requires it. **Never assume GNU coreutils**
— this is BSD-userland macOS; `awk`, `sed`, `find`, `date`, `xargs`
all behave differently from their GNU counterparts. Use long
options (e.g. `--extended-regexp` not `-E`) where supported and
fall back to portable POSIX where not.
- maintainer prefers `printf` in scripts/tool calls; heredocs or
message files for multi-line strings.

Ruby:

- The maintainer uses Homebrew portable-ruby via `brew ruby` or
  "$(brew --repository)/Library/Homebrew/vendor/portable-ruby/current/bin/ruby",
  NOT the system Ruby at `/usr/bin/ruby` (which Apple keeps frozen
  at 2.6 for legacy compatibility) or Homebrew-installed Ruby. The
  system version is in `$PATH` first.
- For projects with Bundler, the maintainer expects `.bundle/config`
  with `BUNDLE_PATH: vendor/bundle` and `BUNDLE_DISABLE_SHARED_GEMS:
  true` — see the project's `docs/agent-principles.md` for
  rationale. **Never** run `gem install` or `sudo gem install` on
  the system Ruby; that is denied by policy and will pollute
  `/Library/Ruby/Gems/`.
- A typical bundler invocation is `env -P"$(brew --repository)/Library/Homebrew/vendor/portable-ruby/current/bin:$PATH" bundle exec rspec`.

Editors and developer tooling:

- Xcode Command Line Tools are installed (clang, ld, dyld_info,
  xcrun, etc.). Full Xcode is NOT typically installed unless a
  project specifically requires it.
- Homebrew formulas commonly installed: `gh` (GitHub CLI),
  `actionlint`, `zizmor`, `shellcheck`, `shfmt`, `clang-format`,
  `clang-tidy` (via `llvm@*`), `reuse`, `ipsw`, `jq`, `yq`.
- The maintainer prefers compiled binaries over scripted equivalents
  when both exist (e.g., `ipsw` over a Python frida-tool).

Agent commit + signing procedure under sandbox isolation:

- These repos require signed commits (`commit.gpgsign = true`,
  `gpg.format = ssh`, key under `~/.ssh`). A sandboxed agent's shell denies read
  access to `~/.ssh`, so any `git commit` that tries to sign **hangs** on the
  key/askpass step (often a macOS passphrase dialog that never returns) or fails
  outright. The agent therefore commits *unsigned*, and the human re-signs the
  batch before pushing: `ZIZMOR_OFFLINE=true GIT_TERMINAL_PROMPT=0 git commit --no-gpg-sign -m "subject" < /dev/null`.
  Do NOT add `-c commit.gpgsign=false` — redundant with `--no-gpg-sign`, and the
  string matches a `sandbox.excludedCommands` entry whose unsandboxed routing
  hangs the commit in the agent harness (validated 2026-07-21). Multi-line `-m`
  commits hang (auto-backgrounded) in the sandbox; write the message to
  /tmp/claude/msg.txt and commit with --file.
- Add `--no-verify` **only** if the pre-commit hook genuinely can't run in the
  sandbox (e.g. `reuse lint` without `--no-multiprocessing` aborts on the macOS
  Seatbelt `SC_SEM_NSEMS_MAX` syscall; `go vet ./...` / `staticcheck` can't write
  the module/build cache). A correctly written hook (`reuse --no-multiprocessing
  lint-file`, language checks gated on staged files) runs clean in-sandbox and
  should *not* be bypassed.
- Apprise the human to re-sign the batch before pushing. Re-sign exactly the
  unpushed commits; derive the base from what is already on a remote rather than
  hard-coding `origin/main` (which assumes the branch sits on main's tip and can
  silently rebase onto a moved main or across unsigned published commits):

  ```sh
  base=$(git rev-list HEAD --not --remotes 2>/dev/null | tail -1)  # oldest unpushed
  if [ -z "$base" ]; then
    echo "nothing unpushed to re-sign"
  elif git rev-parse -q --verify "$base^" >/dev/null 2>&1; then
    git rebase --exec 'git commit --amend --no-edit --gpg-sign' "$base^"
  else
    git rebase --root --exec 'git commit --amend --no-edit --gpg-sign'  # root is unpushed
  fi
  ```

  `--not --remotes` keys on pushed-vs-unpushed, so it never rewrites published
  history and needs no signature parsing; it also covers the unborn-repo and
  root-commit edges. Scope to one remote with `--not --remotes=origin` in
  multi-remote clones. The re-signed branch diverges from a stale local `main`;
  treat it as the source of truth and realign main after it lands
  (`git switch main && git reset --hard origin/main`).
- For the airtight version — base on the oldest *unsigned* commit (so a
  remoteless repo, or one with already-signed unpushed commits, isn't
  needlessly re-signed) plus a fast-forward-or-lease-pinned-force push —
  use `repo-foundation/scripts/sign-push.sh [repo...]` (defaults
  to the current repo). The inline snippet above stays the quick path for
  a repo that has a remote.

## Memory index maintenance
Claude **can** write its own memory, including the index: the sandbox write
policy allows `/Users/todd/.claude/projects/**`, where both the per-memory
files and the `memory/MEMORY.md` index live. So Claude updates `MEMORY.md`
directly — there is no human paste step. Still maintainer-only: `~/.claude.json`
(the projects map, outside the write allowlist) and the rest of `~/.claude/`
(e.g. this `CLAUDE.md`, `settings.json`), which stay read/write-denied — so any
rekey of the projects map (e.g. after renaming or moving a project dir), which
touches `~/.claude.json`, remains a maintainer step.

## What can go here

- Personal-environment context (the above).
- Personal-tooling preferences that span all your repos.
- Personal preferences for tone or output that aren't project-specific.

## What does NOT go here

- Operating principles (those live in each repo's
  `docs/agent-principles.md`).
- Permission rules and sandbox config (those live in
  `~/.claude/settings.json`).
- Project-specific anything (that lives in `<repo>/AGENTS.md`).

## Why this file is short

Most users don't need much here. If you find yourself adding a lot:

- If the content is universal-but-imposable-on-contributors → move
  to a project's `docs/agent-principles.md` and the import in its
  `AGENTS.md` will surface it for that project.
- If the content is environment / tooling preference → keep it
  short and personal.
- If the content is project-specific → it shouldn't be in this file.
