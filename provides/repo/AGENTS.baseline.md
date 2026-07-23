@docs/agent-principles.md

The import above pulls in the **operating principles** that apply to every toobuntu repository: pre-action discipline, modern git verbs, the sandbox model, the universal denied operations, and the agent commit-and-signing procedure. They are committed to this repository (in `docs/agent-principles.md`) and synced from `toobuntu/repo-foundation`, so every contributor — human or agent — has them on checkout, without depending on any one maintainer's machine.

**Session continuity ritual** (details in the imported principles): at the start of a session, read `.ai/org/memory.md`, `.ai/memory.md`, and `.ai/progress.md` (seed the latter from `.ai/progress.template.md` if absent). At the end, append durable learnings to `.ai/memory.md` and rewrite `.ai/progress.md`; org-wide facts go to the gitignored `.ai/org/relay.md` for promotion.

Everything in this block is managed by repo-foundation and is refreshed on each sync. Put this repository's own context — what it is, how to build and test it, its safety invariants, and its project-specific tools — outside the block, in the surrounding `AGENTS.md`.
