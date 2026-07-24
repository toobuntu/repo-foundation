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

  it "mirrors both continuity files at their natural .ai paths" do
    components = sets.fetch("ai_continuity")
    expect(components.map { |c| c.values_at("source", "target", "mode") }).to contain_exactly(
      [".ai/progress.template.md", ".ai/progress.template.md", "canonical"],
      [".ai/org/memory.md", ".ai/org/memory.md", "canonical"]
    )
  end

  it "ignores the volatile .ai files in gitignore.baseline and RF's own .gitignore" do
    volatile = [".ai/progress.md", ".ai/scratchpad/", ".ai/org/relay.md"]
    [File.join(REPO_ROOT, "provides/repo/gitignore.baseline"),
     File.join(REPO_ROOT, ".gitignore")].each do |path|
      lines = File.readlines(path, chomp: true)
      missing = volatile - lines
      expect(missing).to be_empty, "#{path} lacks ignore lines: #{missing.join(", ")}"
    end
  end

  it "sends markdown_lint to every hook-carrying consumer" do
    without = consumers.select { |c| c["sets"].include?("git_hooks") }
                       .reject { |c| c["sets"].include?("markdown_lint") }
                       .map { |c| c["repo"] }
    expect(without).to be_empty, "git_hooks consumers without markdown_lint: #{without.join(", ")}"
  end
end
