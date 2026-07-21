---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

last_review_date: 2026-06-25
---

# Log rotation with newsyslog (macOS/BSD)

Reusable recipe for rotating a plaintext log file that a script or tool writes itself (e.g. `~/Library/Logs/myapp.log`). For daemons that log via `NSLog` / `os_log`, you do **not** need this — unified logging manages its own retention; see ADR 0009.

## Where the config goes

Use a drop-in under `/etc/newsyslog.d/` rather than editing `/etc/newsyslog.conf`:

```sh
sudo install -m 644 myapp.conf /etc/newsyslog.d/myapp.conf
```

`newsyslog` is run periodically by launchd (`com.apple.newsyslog`); it checks each config and rotates when the `when`/`size` thresholds are met. It is not a daemon you start.

## Config line format

```text
logfilename  [owner:group]  mode  count  size  when  flags  [/pidfile]  [signum]
```

- **logfilename** — absolute path. `newsyslog` does **not** expand `~`; write the full path, or a glob (see the `G` flag) for per-user logs.
- **owner:group** — set this for a user-owned log (e.g. `alice:staff`); omitting it leaves rotated files owned by `root`.
- **mode** — octal permissions, e.g. `644`.
- **count** — number of archived generations to keep.
- **size** — rotate when the file exceeds this many KB; `*` disables size-based rotation.
- **when** — time-based rotation: `$D0` daily at midnight, `$W0` weekly on Sunday, `$M1` monthly on the 1st; `*` disables time-based rotation. (At least one of `size`/`when` should be set.)
- **flags** — common: `Z` gzip, `J` bzip2, `G` treat `logfilename` as a shell glob (required if the path contains `*`), `N` do not signal a process, `B` binary log (no rotation header). Combine them: `GZ`, `NZ`.
- **pidfile / signum** — optional; signal a daemon after rotation (rarely needed for script logs).

## Example (per-user log, weekly, 4 gzip archives)

```text
# /etc/newsyslog.d/myapp.conf
/Users/*/Library/Logs/myapp.log   alice:staff  640  4  *  $W0  GZ
```

The `*` in the path is a glob, so the `G` flag is required. For a single known user, a literal path without `G` is simpler:

```text
/Users/alice/Library/Logs/myapp.log   alice:staff  640  4  *  $W0  Z
```

## Verify before trusting it

```sh
# Validate parsing and show what newsyslog *would* do, without rotating:
sudo newsyslog -nv

# Force a one-off rotation of just this config to confirm end to end:
sudo newsyslog -f /etc/newsyslog.d/myapp.conf -v
```

## Gotchas

- No `~` expansion — absolute paths only.
- A `*` in the path needs the `G` flag, or it is treated literally.
- For a non-root log, set `owner:group`, or rotated files become root-owned and the writer may fail to recreate the active file with the right ownership.
- `count` is generations kept, not a size cap; pair with `size` if the log can spike between `when` intervals.
