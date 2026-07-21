---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 19
title: Run the prose lint pre-commit via a 10-prose plugin
status: accepted
date: 2026-07-03
decision-makers:
  - toobuntu
---

# Run the prose lint pre-commit via a 10-prose plugin

## Context and Problem Statement

ADR 0014 established Vale with the org-wide Toobuntu style as the prose gate, running in CI (`prose.yml`, `vale .` under the repo's `MinAlertLevel = error`). After the ADR-tooling reconciliation (ADR 0018), prose was the only repo-foundation lint gate with no pre-commit counterpart: shell, permissions, invisible Unicode, REUSE, workflow lint, and ADR health all run at commit time, so their findings surface before a push; a prose error surfaces only when CI fails the pull request. Should prose lint also run pre-commit, and if so, how is it distributed?

## Decision Drivers

- Findings should surface at the cheapest point — the commit — with CI as the whole-tree backstop (the established hook-plus-CI split of ADRs 0005, 0006, 0017).
- One policy, not two: a hook stricter or laxer than CI trains contributors to distrust one of them.
- The check must be a no-op where it does not apply and must not hard-fail where the tool or its config is absent (the warn-and-skip house pattern).
- `.vale.ini` is per-repo (seeded once by foundation-init, deliberately not synced — ADR 0014); the plugin cannot assume it exists.

## Considered Options

- **A `pre-commit.d` plugin running `vale` on staged Markdown** (chosen).
- **Keep prose CI-only** — the ADR 0014 status quo.
- **Vale inside the base hook** — rejected on the ADR 0017 ground that language- and tool-specific checks do not belong in the byte-identical base.

## Decision Outcome

Chosen: a **`10-prose` plugin** at `.githooks/pre-commit.d/10-prose`, running `vale` over the staged `.md` files.

- **Identical policy to CI.** The plugin invokes bare `vale`, which reads the repo's own `.vale.ini` (`MinAlertLevel = error`): error-level alerts block the commit exactly as they would block the `prose.yml` job; warning-level rules report without gating. One policy, two triggers — the same split `scripts/lint-perms.sh` and `scripts/lint-shell.sh` already use.
- **Self-gating.** It runs only when a `.md` file is staged; it warns and skips when `vale` is not installed (`brew install vale`) or when the repo has no `.vale.ini` (pointing at `provides/vale/vale.ini.template`). CI remains the backstop for both.
- **Mastered at the natural path**, because repo-foundation runs it on its own commits — the ADR 0001 rule, following the `10-shell` and `50-adrs` precedent recorded in ADR 0018.
- **Distributed via the `prose_plugin` set** to the hook-carrying `prose_lint` consumers (blackoutd, zman-didan, babble, bob-book, cert-automation, homebrew-cask-tools). dot-github takes no hooks and no prose lint, so it is not mapped.
- `10-prose` shares the `10-` format-check tier with `10-shell` and `10-markdown`; that tier runs before the `20-` language checks, and ordering among the format plugins is not significant.

### Consequences

- Good, because a prose error blocks the commit that introduces it rather than the pull request an hour later, at the cost of a sub-second `vale` run on the staged Markdown.
- Good, because hook and CI cannot diverge: both read the same `.vale.ini`, so promoting a rule (ADR 0014's warning-to-error path) changes both gates in one edit.
- Bad, because like the base hook's REUSE stanza, `vale` reads the working-tree content of the staged paths, not the staged blob; a path staged clean but dirty on disk is checked as it sits on disk. Accepted for the same reason: pinning staged content is fragile in shell, and CI's whole-tree run is the backstop.
- Neutral, because a consumer that received the plugin but never seeded `.vale.ini` gets a one-line warning per Markdown commit until it either seeds the config or disables the plugin (`10-prose.off`).

## More Information

Refines ADR 0014 (prose and Markdown lint discipline), which remains the decision on style content, vocabulary, and the warning-to-error promotion path. The plugin mechanics are ADR 0017; the natural-path mastering rule is ADR 0001 as applied in ADR 0018.
