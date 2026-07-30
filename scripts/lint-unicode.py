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
# A finding is confirmed against file(1) before it is reported, because the Cc
# extension reaches ordinary binary content: a fixture holding a NUL decodes as
# valid UTF-8, so the decode alone calls it text. Red Hat scopes its own
# scanner to text/* for the same reason. Both halves of `file --mime` -- the
# format and the charset -- must agree that a file is binary before a finding
# is dropped: see `is_binary_decision` for why neither suffices alone, and
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

# Separator for `file --mime`, so the answer can be taken as the field after
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


def parse_mime_lines(stdout):
    """{path: [mime, ...]} from file(1) output produced with --separator.

    Only separator-bearing lines are authoritative, and that is what makes
    batching safe: file(1) emits exactly one such line per INPUT file and the
    line carries the path, so the mapping never depends on output position. A
    universal Mach-O binary's extra per-architecture lines use a literal tab
    instead of the separator and are ignored here -- they restate the same
    type. Matching output to input positionally, which an earlier design
    considered, would have desynced at the first fat binary.
    """
    out = {}
    for line in stdout.splitlines():
        if MIME_SEP not in line:
            continue
        path, _, mime = line.rpartition(MIME_SEP)
        mime = mime.strip()
        if mime:
            out.setdefault(path, []).append(mime)
    return out


def split_mime(value):
    """('text/plain', 'us-ascii') from 'text/plain; charset=us-ascii'.

    Returns an empty charset when the field is absent, which the caller then
    fills in with a targeted query. `file --mime` omits it on the summary line
    of a universal Mach-O binary (the charset appears only on the
    per-architecture continuation lines, and on the last of those it is
    duplicated), so absence is a real case rather than a defensive branch.
    """
    mime, sep, charset = value.partition('; charset=')
    return mime.strip(), charset.strip() if sep else ''


def run_file(paths, flag='--mime'):
    """file(1) over one or more paths; {path: [value, ...]}, {} on failure.

    `--mime` answers both questions in one pass -- the format and the charset
    -- which is why there is one batched pass rather than two.
    """
    try:
        proc = subprocess.run(
            ['file', flag, '--separator', MIME_SEP, '--', *paths],
            capture_output=True, timeout=300)
    except (OSError, subprocess.SubprocessError):
        return {}
    if proc.returncode != 0:
        return {}
    return parse_mime_lines(proc.stdout.decode('utf-8', 'replace'))


def encoding_of(path):
    """The charset alone, for a path whose `--mime` line carried none."""
    for values in run_file([str(path)], '--mime-encoding').values():
        return values[0] if values else ''
    return ''


def classify_values(path, values):
    """(types, encoding) from one path's `--mime` values."""
    types, charsets = [], []
    for value in values:
        mime, charset = split_mime(value)
        if mime:
            types.append(mime)
        if charset:
            charsets.append(charset)
    return types, charsets[0] if charsets else encoding_of(path)


def classify(path):
    """(types, encoding) for one path -- the gate's lazy per-finding check.

    Reads the sole parsed entry rather than looking up by key, so it makes no
    assumption about how file(1) echoed the path back.
    """
    for values in run_file([str(path)]).values():
        return classify_values(path, values)
    return [], ''


def classify_all(paths, chunk=400):
    """{path: (types, encoding)} for every path, in batched file(1) passes.

    file(1) startup dominates the per-file cost, so batching is far cheaper
    over a whole tree: ~1.3s against roughly 25s per-file. Chunked well below
    ARG_MAX. Used only by --classify-report; the gate stays lazy.
    """
    raw = {}
    for i in range(0, len(paths), chunk):
        raw.update(run_file(paths[i:i + chunk]))
    return {p: classify_values(p, raw.get(p, [])) for p in paths}


def is_binary_decision(types, encoding):
    """Suppress a finding only when BOTH file(1) queries say so.

    `file --mime` answers two independent questions in one pass, and requiring
    both narrows the suppression:

    - The CHARSET describes the bytes: `binary`, or an encoding. It cannot
      decide alone, because it answers `binary` for a shell script carrying an
      embedded NUL -- exactly a file that must be reported.
    - The TYPE describes the format, the closer proxy for "does a human review
      this as source." It cannot decide alone either, because a format on the
      denylist may still hold plain text: PostScript is
      `application/postscript` and `utf-8`, and suppressing on type alone
      would swallow a bidi override inside a reviewable `.ps` file.

    So: skip only where the bytes are binary AND every reported format is a
    known-binary one. A missing or unreadable answer yields a report, never a
    silent skip.
    """
    return (encoding == 'binary'
            and bool(types)
            and all(is_binary_mime(t) for t in types))


def looks_binary(path):
    """The gate-path check: consulted ONLY for a file that already produced
    a finding, never as a pre-filter over the scan list, so a clean tree
    spawns no subprocess at all. --classify-report mode classifies every
    file instead; that cost is deliberate and confined to the audit."""
    return is_binary_decision(*classify(path))


def main():
    # NUL-delimited, so a path containing a newline survives intact rather than
    # splitting into two nonexistent entries that silently go unscanned.
    #
    # newline='' disables universal-newline translation, and is load-bearing for
    # the same reason: without it Python rewrites a CR inside a FILENAME to LF
    # while reading, so a staged `we\rird.txt` becomes a path that does not
    # exist, drops out at the is_file() check, and its contents are never
    # scanned. Text mode is still wanted for the UTF-8 decode -- the list comes
    # from git and find, and reading it in the locale's encoding would raise on
    # a non-ASCII path under a C locale.
    with open(sys.argv[1], encoding='utf-8', newline='') as fh:
        paths = [p for p in fh.read().split('\0') if p]
    report_path = sys.argv[2] if len(sys.argv) > 2 else None

    candidates = [p for p in paths if pathlib.Path(p).is_file()]

    # Audit mode classifies EVERY candidate up front -- one batched file(1)
    # pass -- and reuses each decision for suppression, so the report and the
    # gate cannot disagree within a run. Gate mode classifies nothing here and
    # stays lazy (see looks_binary), spawning no subprocess on a clean tree.
    classified = classify_all(candidates) if report_path is not None else {}

    bidi_failures = []
    utf8_failures = []
    report_rows = []
    for p in candidates:
        path = pathlib.Path(p)
        binary = None
        if report_path is not None:
            types, encoding = classified.get(p, ([], ''))
            binary = is_binary_decision(types, encoding)
            report_rows.append(f"{p}\t{','.join(types) or '?'}"
                               f"\t{encoding or '?'}\t{'skip' if binary else 'scan'}")
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
