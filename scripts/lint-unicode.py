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
# A finding is confirmed against file(1)'s MIME type before it is reported,
# because the Cc extension reaches ordinary binary content: a fixture holding
# a NUL decodes as valid UTF-8, so the encoding check alone calls it text.
# Red Hat scopes its own scanner to text/* for the same reason. See
# `looks_binary` for why the check runs per finding rather than per file.
#
# Rationale, codepoint coverage, and alternatives considered (org-wide ADR):
# https://github.com/toobuntu/repo-foundation/blob/main/docs/decisions/0006-trojan-source-detection-strategy.md

import codecs
import contextlib
import pathlib
import re
import subprocess
import sys
import unicodedata

ALLOWED = {0x09, 0x0A, 0x0D}  # TAB, LF, CR
ALLOW_RE = re.compile(r'bidi-allow:\s*([U+0-9A-Fa-f,]+)')

# Separator for `file --mime-type`, so the type can be taken as the field after
# the LAST occurrence rather than by splitting on ':' (paths contain colons).
MIME_SEP = '<<lint-unicode-mime>>'

# MIME types whose bytes are not reviewable text, so a control character in one
# carries no Trojan Source meaning: the attack works by deceiving a human
# reading source, and nobody reads a JPEG. A DENYLIST, deliberately -- an
# unrecognized type is scanned, so a format missing from this set costs a false
# report rather than a silent blind spot. `image/svg+xml` is absent because SVG
# is XML, and so is exactly the reviewable text this must keep scanning.
BINARY_MIME_PREFIXES = ('audio/', 'video/', 'font/')
BINARY_MIME = frozenset({
    'application/epub+zip', 'application/gzip', 'application/java-archive',
    'application/octet-stream', 'application/pdf', 'application/postscript',
    'application/vnd.ms-opentype', 'application/vnd.tcpdump.pcap',
    'application/x-7z-compressed', 'application/x-archive',
    'application/x-bzip2', 'application/x-dosexec', 'application/x-executable',
    'application/x-lzh-compressed', 'application/x-lzip', 'application/x-lzma',
    'application/x-mach-binary', 'application/x-numpy-data',
    'application/x-object', 'application/x-pie-executable',
    'application/x-rar', 'application/x-sharedlib', 'application/x-stuffit',
    'application/x-tar', 'application/x-xar', 'application/x-xz',
    'application/zip', 'application/zlib', 'application/zstd',
})


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
    should be skipped (unreadable, or binary).

    A NUL byte decides nothing on its own, so the order matters:

    1. UTF-8 first. Anything that decodes as UTF-8 IS UTF-8 text, whatever
       bytes it holds -- NUL included, since U+0000 is a perfectly legal
       UTF-8 codepoint. Return the text and let the Cc sweep flag the NUL
       as the invisible control character it is. Deciding "binary" from
       the presence of a NUL, as this function used to, let a UTF-8 file
       with an embedded NUL skip the scan entirely.
    2. Then a UTF-16/UTF-32 BOM. Those encodings are text that the
       UTF-8-without-BOM policy rejects, so they are a reported violation
       rather than a skip -- but only on the evidence of a real BOM. A
       bare `.decode('utf-16')` attempt is not evidence: almost any
       even-length byte string decodes as UTF-16 into garbage, which
       misreports ordinary binaries as UTF-16 documents.
    3. Then NUL as the binary tiebreak. Undecodable and NUL-bearing is a
       genuine binary: skip, because reporting it would flag every
       tracked image, and RHSB-2021-007 scopes itself to text/* for that
       reason. Undecodable WITHOUT a NUL is a text file in some other
       encoding, which the policy does reject.

    A UTF-8 BOM needs no case here: it decodes, and U+FEFF is category Cf,
    so the ordinary sweep reports it.
    """
    try:
        raw = path.read_bytes()
    except OSError:
        return None, None
    try:
        return raw.decode('utf-8'), None
    except UnicodeDecodeError:
        pass
    # UTF-32's little-endian BOM begins with UTF-16's, so test it first.
    for bom, enc in ((codecs.BOM_UTF32_LE, 'utf-32'), (codecs.BOM_UTF32_BE, 'utf-32'),
                     (codecs.BOM_UTF16_LE, 'utf-16'), (codecs.BOM_UTF16_BE, 'utf-16')):
        if raw.startswith(bom):
            return None, f'{path} (looks like {enc}; project requires UTF-8)'
    return (None, None) if b'\x00' in raw else (None, str(path))


def is_binary_mime(mime):
    if mime.startswith(BINARY_MIME_PREFIXES):
        return True
    if mime.startswith('image/') and mime != 'image/svg+xml':
        return True
    return mime in BINARY_MIME


def mime_types(path):
    """Ask file(1) for path's MIME type(s); empty list on any failure.

    One path per invocation, never a batch. A universal Mach-O binary makes
    file(1) print one line PER ARCHITECTURE, all but the first prefixed with
    the filename and ignoring --separator, so any batched run that matched
    output lines to input paths by position would desync at the first fat
    binary and misclassify everything after it. Asking one path at a time
    cannot desync.
    """
    try:
        proc = subprocess.run(
            ['file', '--mime-type', '--separator', MIME_SEP, '--', str(path)],
            capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return []
    if proc.returncode != 0:
        return []
    types = []
    for line in proc.stdout.decode('utf-8', 'replace').splitlines():
        # The first line carries --separator; the per-architecture lines that
        # follow a fat binary carry a tab instead.
        field = line.rpartition(MIME_SEP)[2] if MIME_SEP in line \
            else line.rpartition('\t')[2]
        field = field.strip()
        if field:
            types.append(field)
    return types


def is_binary_decision(types):
    """True only when every reported type is a known-binary format.

    An empty list (file(1) absent, failing, or unparseable) is False, so
    every error path reports the finding rather than swallowing it.
    """
    return bool(types) and all(is_binary_mime(t) for t in types)


def looks_binary(path):
    """The gate-path check: consulted ONLY for a file that already produced
    a finding, never as a pre-filter over the scan list, so a clean tree
    spawns no subprocess at all. --classify-report mode classifies every
    file instead; that cost is deliberate and confined to the audit."""
    return is_binary_decision(mime_types(path))


def main():
    # The list is written by lint-unicode.sh from git output, which is
    # UTF-8; decoding it in the locale's encoding instead would raise on a
    # non-ASCII path under a C locale.
    with open(sys.argv[1], encoding='utf-8') as fh:
        paths = [line.rstrip('\n') for line in fh if line.strip()]
    report_path = sys.argv[2] if len(sys.argv) > 2 else None

    bidi_failures = []
    utf8_failures = []
    report_rows = []
    for p in paths:
        path = pathlib.Path(p)
        if not path.is_file():
            continue
        # Audit mode classifies EVERY candidate up front and reuses the
        # decision for suppression, so the report and the gate cannot
        # disagree within one run. Gate mode stays lazy (see looks_binary).
        binary = None
        if report_path is not None:
            types = mime_types(path)
            binary = is_binary_decision(types)
            report_rows.append(
                f"{p}\t{','.join(types) or '?'}\t{'skip' if binary else 'scan'}")
        text, issue = read_utf8(path)
        if issue is not None:
            utf8_failures.append(issue)
            continue
        if text is None:
            continue
        allow = parse_allow(text)
        if any(is_suspicious(c, allow) for c in text):
            if binary is None:
                binary = looks_binary(path)
            if not binary:
                bidi_failures.append(str(path))

    if report_path is not None:
        # Sorted, so reports from runners whose find(1) walks in a different
        # order diff cleanly against each other.
        with open(report_path, 'w', encoding='utf-8') as fh:
            for row in sorted(report_rows):
                fh.write(row + '\n')

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
