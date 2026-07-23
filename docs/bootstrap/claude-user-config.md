<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# The user-global Claude config

Maintainer-machine setup, alongside the other bootstrap docs here (branch protection, the sync App). Moved out of the repo-maintenance guide because it configures the maintainer's home directory, not any repository.

`provides/claude-user/` holds the version-controlled `~/.claude/` user config (the `CLAUDE.md` and `settings.json` Claude Code loads for every project). It is applied to the maintainer's home, not synced to consumers:

```sh
cp provides/claude-user/CLAUDE.md     ~/.claude/CLAUDE.md
cp provides/claude-user/settings.json ~/.claude/settings.json
```

Re-apply after editing the versioned copies; the copies here are the source of truth, and hand edits to `~/.claude/` drift.
