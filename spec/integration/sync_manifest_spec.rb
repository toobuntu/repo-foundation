# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Contract tests for the REAL sync-manifest.yaml (sync_files_spec.rb exercises
# the engine against fixture manifests; this file pins the live catalog). The
# checks are the ones a rename or a forgotten manifest edit would break:
# every declared source file actually exists, every set a consumer names is
# defined, and configs that must travel with their hook do.
require "yaml"

RSpec.describe "sync-manifest.yaml contract" do
  manifest = YAML.safe_load(File.read(File.join(REPO_ROOT, "sync-manifest.yaml")))
  sets = manifest.fetch("component_sets")
  consumers = manifest.fetch("consumers")

  it "declares only source files that exist (canonical/template/baseline-merge)" do
    missing = sets.flat_map do |name, components|
      components.reject { |c| c["mode"] == "generate" }
                .reject { |c| File.exist?(File.join(REPO_ROOT, c.fetch("source"))) }
                .map { |c| "#{name}: #{c["source"]}" }
    end
    expect(missing).to be_empty, "manifest sources missing on disk:\n  #{missing.join("\n  ")}"
  end

  it "maps every consumer set name to a defined component set" do
    unknown = consumers.flat_map do |c|
      (c.fetch("sets") - sets.keys).map { |s| "#{c["repo"]}: #{s}" }
    end
    expect(unknown).to be_empty, "consumers name undefined sets:\n  #{unknown.join("\n  ")}"
  end

  it "ships both rumdl configs and the plugin in markdown_lint" do
    sources = sets.fetch("markdown_lint").map { |c| c.fetch("source") }
    expect(sources).to include(".rumdl.toml",
                               "docs/decisions/.rumdl.toml",
                               ".githooks/pre-commit.d/10-markdown")
  end

  # The reference doc travels with the rules it documents. A consumer that got
  # the style, the vocabulary and prose.yml but not the page explaining the one
  # rule that never gates is the state this set was in before 2026-08-02: the
  # machinery ran everywhere and every word about it stayed in RF.
  it "ships the prose reference alongside the rules in prose_lint" do
    sources = sets.fetch("prose_lint").map { |c| c.fetch("source") }
    expect(sources).to include(".vale/styles/Toobuntu/AbbreviationPluralsAmbiguous.yml",
                               ".github/workflows/prose.yml",
                               "docs/prose-linting.md")
  end

  # prose-linting.md documents the 15-prose plugin's behavior (it prints the
  # ambiguity findings after the error gate passes). A consumer holding the
  # rules and the page but not the plugin would carry a document describing
  # machinery it does not have, so the two sets travel together.
  it "gives every prose_lint consumer prose_plugin too" do
    offenders = consumers.select { |c| c["sets"].include?("prose_lint") }
                         .reject { |c| c["sets"].include?("prose_plugin") }
                         .map { |c| c.fetch("repo") }
    expect(offenders).to be_empty
  end

  # The 80-unicode plugin runs scripts/lint-unicode.sh --scope=staged and fails
  # the commit when it is absent (ADR 0006, amended 2026-07-29), exactly as
  # 80-perms relies on scripts/lint-perms.sh. A consumer taking the hooks
  # without the scripts would receive a gate that refuses every commit.
  it "gives every git_hooks consumer scripts_core too" do
    missing = consumers.select do |c|
      c["sets"].include?("git_hooks") && !c["sets"].include?("scripts_core")
    end.map { |c| c["repo"] }
    expect(missing).to be_empty,
                       "git_hooks without scripts_core (80-unicode and 80-perms would fail closed):\n" \
                       "  #{missing.join("\n  ")}"
  end

  # settings.baseline.json wires hooks that shell out to repo scripts — today
  # ai-session.sh (SessionStart/SessionEnd) and main-guard.sh (SessionStart
  # seed, PostToolUse check). scripts_core is what delivers those. Both hooks
  # no-op when their script is missing, which is the reason to test it: the
  # failure is a guard that silently never runs, not a visible error.
  it "delivers every script the settings baseline's hooks invoke" do
    baseline = File.read(File.join(REPO_ROOT, "provides/repo/settings.baseline.json"))
    invoked = baseline.scan(%r{scripts/[A-Za-z0-9._-]+\.sh}).uniq
    expect(invoked).not_to be_empty, "no scripts referenced — did the hook wiring change shape?"

    shipped = sets.fetch("scripts_core").map { |c| c.fetch("target") }
    expect(invoked - shipped).to be_empty,
                                 "settings.baseline.json invokes scripts that scripts_core does not ship:\n" \
                                 "  #{(invoked - shipped).join("\n  ")}"

    orphaned = consumers.select { |c| c["sets"].include?("repo_baseline") }
                        .reject { |c| c["sets"].include?("scripts_core") }
                        .map { |c| c.fetch("repo") }
    expect(orphaned).to be_empty,
                        "repo_baseline without scripts_core (hooks would silently no-op):\n" \
                        "  #{orphaned.join("\n  ")}"
  end

  it "maps the homebrew_sandbox class fragment only to Homebrew-aligned consumers" do
    with_fragment = consumers.select { |c| c["sets"].include?("homebrew_sandbox") }.map { |c| c["repo"] }
    expect(with_fragment).to contain_exactly("toobuntu/homebrew-cask-tools", "toobuntu/homebrew-babble")
  end

  it "pairs every fragment with a baseline-merge for the same target in each consumer" do
    consumers.each do |consumer|
      resolved = consumer["sets"].flat_map { |name| sets.fetch(name) }
      resolved.select { |c| c["mode"] == "fragment" }.each do |fragment|
        generated = resolved.any? { |c| c["mode"] == "baseline-merge" && c["target"] == fragment["target"] }
        expect(generated).to be(true),
                             "#{consumer['repo']}: fragment #{fragment['source']} has no baseline-merge generating #{fragment['target']}"
      end
    end
  end

  it "keeps RF's own dependabot.yml equal to the template's kept ecosystems" do
    template = YAML.safe_load(File.read(File.join(REPO_ROOT, ".github/actions/sync/dependabot.template.yml")))
    own = YAML.safe_load(File.read(File.join(REPO_ROOT, ".github/dependabot.yml")))
    # RF has a Gemfile.lock and .github/workflows, but no requirements/pyproject
    # or go.mod, so the generate engine keeps exactly bundler + github-actions.
    # RF runs the files it ships: its own copy is the template filtered to those,
    # stanzas verbatim. If RF gains go.mod/pip, the guard below fails first.
    expect(File.exist?(File.join(REPO_ROOT, "go.mod"))).to be(false)
    expect(File.exist?(File.join(REPO_ROOT, "requirements.txt"))).to be(false)
    expect(File.exist?(File.join(REPO_ROOT, "pyproject.toml"))).to be(false)
    expected = template["updates"].select { |u| %w[bundler github-actions].include?(u["package-ecosystem"]) }
    expect(own["updates"]).to eq(expected)
  end

  it "pairs ai_continuity with repo_baseline in every consumer (ADR 0022)" do
    # The volatile-file ignore lines ride gitignore.baseline (repo_baseline),
    # so a consumer receiving the .ai mirrors without the baseline would track
    # its per-developer progress file; the reverse would ship ignore lines for
    # files that never arrive.
    with_ai = consumers.select { |c| c["sets"].include?("ai_continuity") }.map { |c| c["repo"] }
    with_baseline = consumers.select { |c| c["sets"].include?("repo_baseline") }.map { |c| c["repo"] }
    expect(with_ai).to match_array(with_baseline)
  end

  # ADR 0025. The three org-generic skills go to the repo_baseline consumers and
  # nowhere else: toobuntu/.github hosts served community-health files rather
  # than development work, so a session-ritual skill there would document
  # machinery it does not have. The `tb-` prefix is the marker, so a set member
  # without it is either a repo-specific skill promoted by mistake or a rename
  # that lost the signal.
  it "sends the tb-* skills to exactly the repo_baseline consumers" do
    sources = sets.fetch("claude_skills").map { |c| c.fetch("source") }
    expect(sources).to contain_exactly(
      ".claude/skills/tb-issue-draft/SKILL.md",
      ".claude/skills/tb-review-triage/SKILL.md",
      ".claude/skills/tb-session-close/SKILL.md",
    )
    expect(sources.all? { |s| s.include?("/skills/tb-") }).to eq(true)
    expect(sets.fetch("claude_skills").map { |c| c.fetch("mode") }.uniq).to eq(["canonical"])

    with_skills = consumers.select { |c| c["sets"].include?("claude_skills") }.map { |c| c["repo"] }
    with_baseline = consumers.select { |c| c["sets"].include?("repo_baseline") }.map { |c| c["repo"] }
    expect(with_skills).to match_array(with_baseline)
  end

  it "mirrors both continuity files at their natural .ai paths" do
    components = sets.fetch("ai_continuity")
    expect(components.map { |c| c.values_at("source", "target", "mode") }).to contain_exactly(
      [".ai/progress.template.md", ".ai/progress.template.md", "canonical"],
      [".ai/org/memory.md", ".ai/org/memory.md", "canonical"]
    )
  end

  it "ignores the volatile .ai files in gitignore.baseline and RF's own .gitignore" do
    # The snapshot line is a glob: the session-id sidecar
    # (.progress.session-start.sid) rides the same prefix.
    volatile = [".ai/progress.md", ".ai/scratchpad/",
                ".ai/.progress.session-start*", ".ai/.session-closed",
                ".ai/.close-check-state", ".ai/org/relay.consumed-*.md"]
    [File.join(REPO_ROOT, "provides/repo/gitignore.baseline"),
     File.join(REPO_ROOT, ".gitignore")].each do |path|
      lines = File.readlines(path, chomp: true)
      missing = volatile - lines
      expect(missing).to be_empty, "#{path} lacks ignore lines: #{missing.join(", ")}"
      # The relay is deliberately TRACKED (ADR 0022, 2026-07-26): it carries
      # org knowledge in transit, and ignoring it stranded that knowledge on
      # whichever machine wrote it. Guard the inversion so the line does not
      # creep back with a future ignore-list edit.
      expect(lines).not_to include(".ai/org/relay.md"),
                           "#{path} re-ignores the relay, which must stay tracked"
    end
  end

  it "sends markdown_lint to every hook-carrying consumer" do
    without = consumers.select { |c| c["sets"].include?("git_hooks") }
                       .reject { |c| c["sets"].include?("markdown_lint") }
                       .map { |c| c["repo"] }
    expect(without).to be_empty, "git_hooks consumers without markdown_lint: #{without.join(", ")}"
  end
end
