# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Invisible-Unicode / Trojan Source (CVE-2021-42574) scanner: the python3
# detector for scripts/lint-unicode.sh, which passes the newline-delimited
# file list as argv[1].
#
# It lives in its own file rather than a shell heredoc because Homebrew's
# shfmt wrapper (`brew style --fix`) applies line-based alignment transforms
# that track no heredoc state, so they rewrite embedded Python as if it were
# shell: indentation flattened, the terminator indented until the
# here-document never closes, the rest of the file swallowed. That is how
# this canonical copy was corrupted once already. A separate file sidesteps
# the whole class permanently.
#
# Mirrors Red Hat's RHSB-2021-007 approach: flag every character in Unicode
# category Cf (Format), extended to Cc (Control) minus a TAB/LF/CR allowlist.
# Invisible characters added to Cf/Cc in later Unicode revisions are caught
# as the runner's python3 updates. Per-file opt-out via a
# `bidi-allow: U+XXXX,U+YYYY` annotation anywhere in the file.
#
# Rationale, codepoint coverage, and alternatives considered (org-wide ADR):
# https://github.com/toobuntu/repo-foundation/blob/main/docs/decisions/0006-trojan-source-detection-strategy.md

import contextlib
import pathlib
import re
import sys
import unicodedata

ALLOWED = {0x09, 0x0A, 0x0D}  # TAB, LF, CR
ALLOW_RE = re.compile(r'bidi-allow:\s*([U+0-9A-Fa-f,]+)')


def parse_allow(text):
    m = ALLOW_RE.search(text)
    if not m:
        return frozenset()
    cps = set()
    for token in m.group(1).split(','):
        stripped = token.strip()
        if stripped.startswith('U+'):
            with contextlib.suppress(ValueError):
                cps.add(int(stripped[2:], 16))
    return frozenset(cps)


def is_suspicious(ch, allow):
    cp = ord(ch)
    if cp in ALLOWED or cp in allow:
        return False
    return unicodedata.category(ch) in ('Cf', 'Cc')


def read_utf8(path):
    """Read path under the UTF-8-without-BOM policy.

    Returns (text, issue): decoded text on success; an issue string when
    the file violates the encoding policy; (None, None) when the file
    should be skipped (unreadable, or binary per the NUL heuristic).
    """
    try:
        with path.open('rb') as fh:
            head = fh.read(4096)
            if b'\x00' in head:
                # A NUL alone does not prove "binary": UTF-16/UTF-32
                # text contains NULs but is still text we reject under
                # the UTF-8 policy.
                for enc in ('utf-16', 'utf-32'):
                    try:
                        head.decode(enc)
                    except UnicodeDecodeError:
                        continue
                    return None, f'{path} (looks like {enc}; project requires UTF-8)'
                # NUL but not decodable as UTF-16/32: treat as binary
                # and skip, mirroring RHSB-2021-007's text/* MIME gate.
                # Falling through to the UTF-8 check would mis-flag
                # tracked binaries as violations.
                return None, None
            raw = head + fh.read()
    except OSError:
        return None, None
    try:
        return raw.decode('utf-8'), None
    except UnicodeDecodeError:
        return None, str(path)


def main():
    with open(sys.argv[1]) as fh:
        paths = [line.rstrip('\n') for line in fh if line.strip()]

    bidi_failures = []
    utf8_failures = []
    for p in paths:
        path = pathlib.Path(p)
        if not path.is_file():
            continue
        text, issue = read_utf8(path)
        if issue is not None:
            utf8_failures.append(issue)
            continue
        if text is None:
            continue
        allow = parse_allow(text)
        if any(is_suspicious(c, allow) for c in text):
            bidi_failures.append(str(path))

    ok = True
    if utf8_failures:
        print('Files violating UTF-8-without-BOM policy:', file=sys.stderr)
        for f in utf8_failures:
            print(f'  {f}', file=sys.stderr)
        ok = False
    if bidi_failures:
        print('Invisible Unicode characters found (CVE-2021-42574):',
              file=sys.stderr)
        for f in bidi_failures:
            print(f'  {f}', file=sys.stderr)
        print('', file=sys.stderr)
        print('A file may opt out of specific codepoints with an in-file',
              file=sys.stderr)
        print('annotation, e.g.:  // bidi-allow: U+200E,U+200F',
              file=sys.stderr)
        ok = False
    if not ok:
        sys.exit(1)


if __name__ == '__main__':
    main()
