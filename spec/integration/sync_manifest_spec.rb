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

  it "sends markdown_lint to every hook-carrying consumer" do
    without = consumers.select { |c| c["sets"].include?("git_hooks") }
                       .reject { |c| c["sets"].include?("markdown_lint") }
                       .map { |c| c["repo"] }
    expect(without).to be_empty, "git_hooks consumers without markdown_lint: #{without.join(", ")}"
  end
end
