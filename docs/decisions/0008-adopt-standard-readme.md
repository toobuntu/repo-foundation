---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

number: 8
title: Adopt the standard-readme specification for README files
status: accepted
date: 2026-05-20
decision-makers:
  - toobuntu
---

# Adopt the standard-readme specification for README files

## Context and Problem Statement

This scaffolding governs shared conventions for a family of personal repos.
README files had been written ad hoc, with inconsistent section sets and
ordering across repos. A consistent, externally-defined structure makes any
repo navigable on sight and gives contributors (human or agent) a single
citable rule to follow instead of per-repo bikeshedding.

## Decision Drivers

* Consistency across the repo family.
* A published, citable spec rather than a house style to maintain.
* Low overhead; works for CLI tools and daemons, not just libraries.
* Compatible with the REUSE/SPDX practice already in force (License section
  last aligns with the SPDX license footer).

## Considered Options

* **A — [standard-readme](https://github.com/RichardLitt/standard-readme)**:
  a versioned spec with required sections in a fixed order, plus a generator
  and linter.
* **B — GitHub community-profile / `.github` README templates**: convention by
  template, no formal spec.
* **C — Informal guides** (Make a README, readme-best-practices): advice, not a
  conformance spec.
* **D — No standard**: each repo decides.

## Decision Outcome

Chosen option: **A, standard-readme**. It is the only option that is a
*specification* — required sections, fixed order, a definition of "compliant" —
so conformance is reviewable and self-documenting. Its License-last requirement
matches the SPDX footer already used, and its Contributing section carries a
self-propagating "conform to standard-readme" note.

### Consequences

* Good: every consumer README shares one skeleton; reviewers and agents have a
  single rule; the spec absorbs questions like section order and where License
  goes.
* Good: the short-description-mirrors-the-repo-description rule keeps the GitHub
  "About" blurb and the README in sync.
* Constraint: the spec is written for OSS libraries. For CLI/daemon repos the
  `API` section is omitted and a `Usage`/`CLI` subsection carries the load
  (the spec explicitly allows this).
* Constraint: where the title cannot match the repository/folder name, a
  parenthetical title plus a Long Description note is required — for example a
  README whose H1 cannot match the repository's `owner/name` slug. (This
  repository's own README was once titled `scaffolding` under the
  `repo-foundation` directory; the build-out retitled it to `repo-foundation`,
  so it now matches and needs no parenthetical.)
* Constraint: full structural compliance is not automatable, but the bulk of
  it is: `standard-readme-preset` (a `remark-lint` plugin) checks section
  presence and ordering and runs cleanly in CI (see Confirmation).
* The `inject_edid` README is the first conforming reference implementation.

### Confirmation

A README passes a structure review: required sections present, in spec order,
with License last and a sub-120-character single-line description. Enforce the
structural part in CI with `remark` + `standard-readme-preset` (a GitHub Action
running `remark --use remark-preset-lint-standard-readme`); residual judgment
(description quality, accurate Usage) stays with review. New repos created from
this scaffolding adopt the structure; existing repos are brought into
compliance opportunistically.

## More Information

Specification: <https://github.com/RichardLitt/standard-readme/blob/main/spec.md>.
Linter: <https://github.com/RichardLitt/standard-readme-preset> (a WIP
`remark-lint` preset; <https://github.com/remarkjs/remark-lint>), linked from
the standard-readme README. Note the spec's own caveat that it was made for
Node/npm libraries but applies to other languages and project types. Propagate
the requirement (and the CI lint) via `project/AGENTS.md` /
`agent-principles.md` and `project/workflows/` alongside the existing
conventions.
