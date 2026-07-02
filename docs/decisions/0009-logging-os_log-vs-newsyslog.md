---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 9
title: Unified logging (os_log) for daemons; newsyslog only for self-managed files
status: accepted
date: 2026-05-20
decision-makers:
  - toobuntu
---

# Unified logging (os_log) for daemons; newsyslog only for self-managed files

## Context and Problem Statement

Across these projects there are two kinds of log producers: long-running
daemons/agents (e.g. blackoutd, which currently logs via `NSLog`) and shell
scripts/tools that append to a plaintext file (e.g. the legacy `restore_rgb.sh`
writing `~/Library/Logs/restore-rgb.log`). Both need bounded retention. The
question is which retention mechanism applies to which, so the choice is not
re-litigated per project.

## Decision Drivers

* Don't let any log grow unbounded.
* Prefer the platform-idiomatic mechanism; avoid bolting a file-rotation tool
  onto something that isn't a file.
* Keep logs queryable/filterable.
* Reusability: a single rule (and a single setup recipe) across projects.

## Considered Options

* **A — `NSLog` / `os_log` → unified logging** for daemons, with `newsyslog`
  only for self-managed plaintext files.
* **B — Everything writes a plaintext file**, rotated by `newsyslog`.
* **C — Everything to unified logging**, including shell scripts (via `logger`
  / `os_log`).

## Decision Outcome

Chosen option: **A**. The mechanism follows the producer:

* **Daemons/agents** log to **unified logging**. `NSLog` already routes there;
  new code should use `os_log` with a subsystem
  (reverse-DNS, e.g. `io.github.toobuntu.<name>`) and categories. Retention is
  automatic (the system ring buffer); there is **no file to rotate**, so
  `newsyslog` does not apply. Query with
  `log show --predicate 'subsystem == "io.github.toobuntu.<name>"'`.
* **Scripts/tools that write their own plaintext file** use **newsyslog**, via
  an `/etc/newsyslog.d/*.conf` drop-in. The reusable recipe is in
  `../newsyslog-log-rotation.md`.

B is rejected because forcing daemons through a plaintext file discards the
structure, subsystem filtering, and automatic retention unified logging already
provides. C is rejected because routing trivial shell-script output through the
unified log is heavier than a file + newsyslog and loses the simple
`tail`-able file the scripts benefit from.

### Consequences

* Good: each producer uses the idiomatic, lowest-friction path; one rule to
  remember; the newsyslog recipe is captured once and reused.
* Constraint: a daemon must **not** redirect `StandardOutPath`/
  `StandardErrorPath` to a real file and *also* expect unified-logging
  retention — that creates an unbounded file that then *would* need newsyslog.
  Send those to `/dev/null` (or omit them) and rely on unified logging.
* Migration: existing `NSLog` call sites should move to `os_log` with a
  subsystem to gain filtering (tracked per project, e.g. blackoutd P27).

### Confirmation

* Daemon: its launchd plist sends std streams to `/dev/null` (or omits them),
  and `log show --predicate 'subsystem == "…"'` returns its entries.
* Script: `sudo newsyslog -nv` parses the drop-in and reports the intended
  rotation.

## More Information

Setup recipe: `../newsyslog-log-rotation.md`. Applied in blackoutd via
technical-debt P27 (NSLog → os_log; newsyslog N/A) and historically in the
legacy `restore_rgb.sh` watchdog (which correctly used newsyslog for its own
file log).
