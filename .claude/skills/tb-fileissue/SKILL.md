---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

name: tb-fileissue
description: >-
  Draft an upstream bug report or issue for another project, in the house style — short,
  factual, no speculation. Use when the maintainer says to file a bug upstream, report
  something to a project, write it up for an issue, or asks for an issue draft. Produces a
  titled draft under .ai/scratchpad/ (the maintainer files it), plus the search terms for
  checking whether it is already known. Do not open the issue; drafting and filing are
  separate steps.
---

# Upstream issue drafts

The maintainer files the issue. This skill produces the text and the prior-art search terms. Write the draft to `.ai/scratchpad/issue-<slug>.md` and delete it once it has been filed.

## Establish the facts first

Never draft from a theory.

- Pin the versions and the platform: tool version, OS version and build, architecture.
- Capture the exact command and its exact output. Quote it; do not paraphrase.
- **Read the authoritative artifact before proposing a cause.** For a crash that means the crash report (`~/Library/Logs/DiagnosticReports/*.ips` on macOS — JSON after a one-line header, so `tail -n +2 file.ips | jq`), whose faulting-thread frames settle in one step what reading source only narrows. For a behavior claim it means the source at the released tag, not at `main` and not from memory.
- Distinguish what was observed from what is inferred. Only name a cause if the source supports it, and cite the file and symbol when you do.

## House style, which is narrower than it sounds

- **Short.** The reader is triaging. Facts, in order, then stop.
- **No lengthy prose.** No scene-setting, no restating the project's purpose back to them.
- **No speculation.** If the mechanism is not established, report the observation and say what is unverified. Do not guess at causes in an issue.
- **No bullet lists** for the body's argument. Short paragraphs and fenced evidence blocks. A list is acceptable only for genuinely enumerable items such as reproduction steps.
- **Few em dashes.** Plain sentences.
- **Observations and actionable facts only.** Anything that does not help someone reproduce or fix it comes out.

## Shape

An `# Title` that names the defect and its mechanism, not just the symptom. Then the environment in one line. Then the reproduction and the exact output in a fenced block. Then the cause, if established, naming the commit or symbol. Then a `## Proposed fix` if there is an obvious one.

Additional smaller findings from the same session go in their own short `##` sections after the main one, so a maintainer can split them.

**Disclose AI assistance** at the end, and say what was verified rather than only that a tool was involved: which claims were measured on which machine, and against which tag or commit.

## Then give the search terms

Before the maintainer files, hand them the specific queries for checking whether it is already known or planned: the distinctive symbol or assertion names from the crash frames, the error string, and a scoped `is:issue` query for the repository. Distinctive internal identifiers find duplicates that a symptom description misses.
