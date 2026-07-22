<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Drop-in for RF docs: sandbox clones vs the macOS tmp reaper

Where it goes: docs/agent-principles.md, in the sandbox/isolation section (near the Tier 3 / sandbox-enter.sh discussion); the sandbox-enter.sh behavior change itself is a scripts/ commit. If it outgrows a section, docs/decisions/ ADR on sandbox placement.

## Text to insert (adjust heading level to context)

### Sandbox clones and the macOS tmp reaper

macOS deletes /tmp (/private/tmp) entries not accessed OR modified in three days: /usr/libexec/tmp_cleaner (a find over -atime/-mtime) runs daily at midnight via /System/Library/LaunchDaemons/com.apple.tmp_cleaner.plist (StartCalendarInterval). A Tier 3 sandbox clone parked under /private/tmp across a multi-day session loses exactly its untouched files — including hardlinked loose git objects, since local `git clone` hardlinks the object store. The source repo loses nothing (hardlinks: the original inode survives), but the clone silently rots: worktree files vanish and `git restore` starts failing with "unable to read sha1 file". Observed on babble-w3, 2026-07-08.

Rules:

- **Prefer a non-reaped parent.** `sandbox-enter.sh` defaults `--parent` to `~/.cache/sandboxes` (create it; not subject to tmp_cleaner). /private/tmp remains fine for clones that live less than a day.
- **If a clone must sit in /tmp**, touch-refresh it at each session start so nothing crosses the 3-day line — e.g. `find <clone> -exec touch -a {} +` — and plan to promote and destroy within a day or two anyway.
- **Session hygiene:** at every session start in an existing clone, read `git status` critically. A wall of unexplained `D` (worktree deletions) in an untouched clone is reaper damage, not your doing: stop, salvage pending work as files/patches to /tmp/claude/, and do not trust the clone for promotes.
- Corollary the reaper gives for free: /tmp/msg-<slug>.txt commit message files are preserved for ~3 days and then self-clean.

## sandbox-enter.sh change (companion commit)

- Default parent: ~/.cache/sandboxes (mkdir -p), overridable with --parent as today; keep /private/tmp working but print the 3-day caveat when the resolved parent is under /tmp or /private/tmp.
