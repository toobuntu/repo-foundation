#!/bin/sh

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# foundation-init.sh — bootstrap a new repo-foundation consumer.
#
# Run from a checkout of repo-foundation, pointing at the new repository's
# working tree. It copies the copy-once scaffolds, seeds the baseline-merge
# targets with an empty managed region for the first sync to fill, seeds the
# Claude settings addenda, and brings the repo into REUSE compliance under its
# own license (ADR 0016): the seeded consumer-owned files take --license, while
# the copied RF scaffolds keep repo-foundation's GPL (they are RF-derived
# templates; a consumer that wants a single license re-annotates them).
#
# Usage: scripts/foundation-init.sh [--license SPDX-ID] <target-repo-dir>
#   --license  SPDX id for the consumer's own files (default GPL-3.0-or-later).

set -eu

usage() {
  printf 'Usage: %s [--license SPDX-ID] <target-repo-dir>\n' "${0##*/}" >&2
}

license="GPL-3.0-or-later"
while [ $# -gt 0 ]; do
  case "$1" in
  --license)
    license="${2:?--license needs an argument}"
    shift 2
    ;;
  --license=*)
    license="${1#--license=}"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  --)
    shift
    break
    ;;
  -*)
    printf 'error: unknown option: %s\n' "$1" >&2
    usage
    exit 2
    ;;
  *) break ;;
  esac
done

target="${1:-}"
[ -n "$target" ] || {
  usage
  exit 2
}
[ -d "$target" ] || {
  printf 'error: target is not a directory: %s\n' "$target" >&2
  exit 1
}

# repo-foundation root = the parent of this script's directory.
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
rf_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
manifest="$rf_root/sync-manifest.yaml"
[ -f "$manifest" ] || {
  printf 'error: manifest not found: %s\n' "$manifest" >&2
  exit 1
}

# Read the managed-region labels from the manifest so the seeded sentinels match
# what sync-files.rb renders (its render_sentinels uses the same labels). If
# these drift, the first sync would not recognize the region and would append a
# second one — so they are read from one source, not hard-coded.
label_begin=$(sed -n 's/^  merge_label_begin: "\(.*\)"$/\1/p' "$manifest")
label_end=$(sed -n 's/^  merge_label_end: "\(.*\)"$/\1/p' "$manifest")
[ -n "$label_begin" ] && [ -n "$label_end" ] || {
  printf 'error: could not read merge labels from %s\n' "$manifest" >&2
  exit 1
}
html_begin="<!-- >>> ${label_begin} >>> -->"
html_end="<!-- <<< ${label_end} <<< -->"
hash_begin="# >>> ${label_begin} >>>"
hash_end="# <<< ${label_end} <<<"

# 1. Copy the copy-once scaffolds, stripping the .template infix.
mkdir -p "$target/.github/workflows"
for tpl in "$rf_root"/provides/github/workflows/*.template.yml; do
  [ -e "$tpl" ] || continue
  out=$(basename "$tpl" | sed 's/\.template\././')
  dest="$target/.github/workflows/$out"
  if [ -e "$dest" ]; then
    printf 'skip (exists): %s\n' "$dest"
  else
    cp "$tpl" "$dest"
    printf 'copied: %s\n' "$dest"
  fi
done
if [ -e "$rf_root/provides/vale/vale.ini.template" ] && [ ! -e "$target/.vale.ini" ]; then
  cp "$rf_root/provides/vale/vale.ini.template" "$target/.vale.ini"
  printf 'copied: %s\n' "$target/.vale.ini"
fi

# 2. Seed the baseline-merge targets with an empty managed region. The first
#    sync replaces the region between the sentinels with the canonical baseline.
seed_md_region() {
  f="$1"
  title="$2"
  if [ -e "$f" ]; then
    printf 'skip (exists): %s\n' "$f"
    return 0
  fi
  {
    printf '# %s\n\n' "$title"
    printf 'This repository'\''s own context lives outside the managed block below.\n\n'
    printf '%s\n\n%s\n' "$html_begin" "$html_end"
  } > "$f"
  printf 'seeded: %s\n' "$f"
}
seed_md_region "$target/AGENTS.md" "AGENTS.md — $(basename "$target")"
seed_md_region "$target/CONTRIBUTING.md" "Contributing"

# The managed region is seeded WITH the volatile .ai ignore lines rather than
# empty: init creates .ai/progress.md below (after this block), and the
# runbook's next step is review-commit-push — an empty region would let
# `git add -A` track the volatile file before the first sync delivers the
# baseline (and a tracked file stays tracked when its ignore line later
# arrives). Placing the lines inside the region is self-healing: the first
# sync replaces the region wholesale with the full baseline, which carries
# these same lines.
ai_ignores='.ai/progress.md
.ai/scratchpad/
.ai/org/relay.md'
if [ ! -e "$target/.gitignore" ]; then
  printf '%s\n%s\n%s\n' "$hash_begin" "$ai_ignores" "$hash_end" > "$target/.gitignore"
  printf 'seeded: %s\n' "$target/.gitignore"
elif ! grep -qF "$hash_begin" "$target/.gitignore"; then
  printf '\n%s\n%s\n%s\n' "$hash_begin" "$ai_ignores" "$hash_end" >> "$target/.gitignore"
  printf 'appended managed region: %s\n' "$target/.gitignore"
else
  # Region already present (an older init, or a hand-seeded file): insert any
  # missing volatile entries just inside the begin marker, preserving both
  # markers and everything else.
  missing=""
  for entry in $ai_ignores; do
    grep -qxF "$entry" "$target/.gitignore" || missing="${missing}${entry}
"
  done
  if [ -n "$missing" ]; then
    # BSD awk rejects -v values containing newlines, so the multi-line
    # insertion rides the environment instead.
    ADD="$missing" awk -v begin="$hash_begin" \
      '{ print } $0 == begin { printf "%s", ENVIRON["ADD"] }' \
      "$target/.gitignore" > "$target/.gitignore.tmp"
    mv "$target/.gitignore.tmp" "$target/.gitignore"
    printf 'inserted missing .ai ignore entries: %s\n' "$target/.gitignore"
  fi
fi

[ -e "$target/CLAUDE.md" ] || {
  printf '@AGENTS.md\n' > "$target/CLAUDE.md"
  printf 'seeded: %s\n' "$target/CLAUDE.md"
}

# Agent continuity layer (ADR 0022): seed the consumer-owned .ai/memory.md
# from the template, and give the developer a starting .ai/progress.md (the
# gitignored per-developer instance; the committed .ai/progress.template.md
# and .ai/org/memory.md arrive via the sync, not init). This block runs AFTER
# the .gitignore seeding above so .ai/progress.md is ignored from the moment
# it exists — even an interrupted run never leaves it trackable.
mkdir -p "$target/.ai"
if [ -e "$rf_root/provides/ai/memory.template.md" ] && [ ! -e "$target/.ai/memory.md" ]; then
  cp "$rf_root/provides/ai/memory.template.md" "$target/.ai/memory.md"
  printf 'copied: %s\n' "$target/.ai/memory.md"
fi
if [ -e "$rf_root/.ai/progress.template.md" ] && [ ! -e "$target/.ai/progress.md" ]; then
  cp "$rf_root/.ai/progress.template.md" "$target/.ai/progress.md"
  printf 'seeded (gitignored): %s\n' "$target/.ai/progress.md"
fi

# 3. Seed the Claude settings addenda (the consumer's deep-merge input).
mkdir -p "$target/.claude"
if [ ! -e "$target/.claude/settings.addenda.json" ]; then
  printf '{\n}\n' > "$target/.claude/settings.addenda.json"
  printf 'seeded: %s\n' "$target/.claude/settings.addenda.json"
fi

# 4. REUSE compliance (ADR 0016). annotate.sh skips the already-headered
#    scaffolds and stamps the seeded files with --license, then the two license
#    texts the bootstrap introduces are fetched into LICENSES/: the consumer's
#    --license and GPL-3.0-or-later (the kept RF scaffolds). `reuse download
#    --all` is avoided — it crashes in reuse 6.2.0 — so the licenses are named
#    explicitly; a consumer that later adds another license runs reuse download
#    for it (reuse lint names the missing one).
if command -v reuse > /dev/null 2>&1; then
  (cd "$target" && ANNOTATE_LICENSE="$license" "$rf_root/scripts/annotate.sh")
  (cd "$target" && reuse download "$license" GPL-3.0-or-later > /dev/null 2>&1 || true)
  printf 'annotated under %s and downloaded license texts\n' "$license"
else
  printf 'warning: reuse not found — skipping annotation (brew install reuse)\n' >&2
fi

printf '\nDone. Next:\n  cd %s\n  git config core.hooksPath .githooks\n' "$target"
printf 'Then: review + commit + push; add the consumer entry to sync-manifest.yaml;\n'
printf 'install the sync App on the repo; dispatch sync-to-consumers; merge the PR.\n'
printf 'Full runbook: docs/adding-a-repo.md in repo-foundation.\n'
