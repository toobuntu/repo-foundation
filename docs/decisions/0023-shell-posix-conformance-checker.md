---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 23
title: ShellCheck is the POSIX-conformance gate; checkbashisms is not adopted
status: accepted
date: 2026-07-26
decision-makers:
  - toobuntu
---

# ShellCheck is the POSIX-conformance gate; checkbashisms is not adopted

## Context and Problem Statement

Org shell policy (ADR 0017) is that a script declaring `#!/bin/sh` must actually be POSIX `sh`: macOS `/bin/sh` is bash 3.2 in POSIX mode and the Ubuntu CI runners' `/bin/sh` is dash, so a bashism that both a developer's macOS shell and `bash -n` accept can still fail on a runner. `scripts/lint-shell.sh` is the single implementation of the shell gate, run by the `10-shell` pre-commit plugin with `--staged` and by the `shell-lint` CI job with `--tracked`.

A 2026-07-06 queue item (`docs/handoff/rf-upstream-notes.md` § 5) proposed adding Debian's `checkbashisms` to that checker set, on the reasoning that it "catches sh-shebang bashisms the other tools miss." That reasoning dated from before `lint-shell.sh` became dialect-aware and settled on `shellcheck --severity=warning`. Executing the item at the 2026-07-25 canonical-repairs session tested the premise, and it did not hold.

## Decision Drivers

- A gate must find something the existing gates do not; a second opinion that is a strict subset is cost without coverage.
- A gate must not fire on correct code. There is no suppression mechanism to fall back on in `checkbashisms`, and the org's own canonical files are what it fires on.
- The sentinel-marker format in `scripts/foundation-init.sh` is safety-critical: the sync engine's managed regions are delimited by it, so editing it to satisfy a linter risks rewriting files in every consumer.
- Whatever gates POSIX conformance must run identically in the pre-commit plugin and the CI job, since both call one script.

## Considered Options

- **ShellCheck alone, at `--severity=warning`** (chosen).
- **ShellCheck plus `checkbashisms`**, the queued proposal.
- **`checkbashisms` alone** — never seriously in contention; it does no static analysis beyond the bashism list.
- **`dash -n` on every `sh` script** — syntax only; it accepts many bashisms that dash then mis-executes, so it is weaker than either.

## Decision Outcome

Chosen: **ShellCheck alone**, at `--severity=warning`, as it already runs. `checkbashisms` is not adopted.

ShellCheck's `SC3xxx` family *is* a POSIX-conformance checker — each finding reads "In POSIX sh, X is undefined" — and those checks are severity `warning`, so they already gate rather than advise. ShellCheck takes its dialect from the shebang, so an `#!/bin/sh` file is checked as POSIX `sh` without further configuration.

Measured on one planted `#!/bin/sh` script containing `[[ ]]`, `==`, `echo -e`, an array assignment, an array reference, `source`, `let`, and `++`:

| | ShellCheck `--severity=warning` | checkbashisms |
| --- | --- | --- |
| `[[ ]]` | SC3010 | reported |
| `==` in test | SC3014 | reported |
| `echo -e` | SC3037 | reported |
| `arr=(a b c)` | **SC3030** | **missed** |
| `${arr[1]}` | SC3054 | reported |
| `source` | SC3046, SC3051 | reported |
| `let` | SC3039 | reported |
| `$((n++))` | SC3018 | reported |

ShellCheck reported everything `checkbashisms` did, plus the array *assignment* it missed.

Against that, `checkbashisms` reports two false positives on `scripts/foundation-init.sh`. It reads the literal `<<<` inside the managed-region sentinel strings — `html_end="<!-- <<< ${label_end} <<< -->"` — as a here-string, because its matcher does not track double-quoted context. It offers no inline directive and no per-file exclusion, so the only ways to green the tree would be a skip list for the whole file, which would hide real findings in a 200-line script, or rewriting the sentinel construction to please a linter, which is not an acceptable reason to touch that format.

### Consequences

- Good, because the gate that exists already covers the failure mode, so nothing is lost and no tool is added to the bootstrap for every consumer.
- Good, because the checker set stays one tool per concern in `lint-shell.sh`: `ksh -n` for syntax, `shfmt` for formatting, ShellCheck for analysis and POSIX conformance.
- Good, because no canonical file is edited to accommodate a linter, and the sentinel format is untouched.
- Bad, because ShellCheck's POSIX checks are keyed on the shebang: a file with no shebang, or one invoked as `sh script` despite a `bash` shebang, is analyzed in the wrong dialect and its bashisms are not reported. `checkbashisms` guesses more aggressively there. The org's scripts all carry accurate shebangs, and `lint-shell.sh`'s own `is_shell`/`is_ksh` detection reads them, so the gap is theoretical today.
- Neutral, because this can be revisited: the standard to reopen it is a concrete construct that ShellCheck misses at `--severity=warning` and `checkbashisms` catches.

## More Information

Amendment (2026-07-26): the gate severity moved from `--severity=warning` to `--severity=style` (maintainer ruling), so every `.shellcheckrc` `enable=` now gates rather than advises. The comparison above was measured at warning; the change only strengthens the chosen option, since everything ShellCheck reports at warning it also reports at style.

The evidence and the reverted change are recorded in `docs/handoff/rf-upstream-notes.md` § 20 (the closing amendment), which supersedes that document's § 5 proposal. `lint-shell.sh`'s dialect split — and why AT&T ksh93 files are analyzed with `shellcheck --shell=ksh` but never formatted with `shfmt` — is ADR 0017. The related constraint that `brew style --fix` rewrites POSIX `[ ]` tests in Homebrew-aligned consumers, which is a different pressure on the same files, is recorded in `.ai/memory.md` (2026-07-25).
