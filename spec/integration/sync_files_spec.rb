# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "json"
require "open3"
require "tmpdir"

# The engine reads and writes UTF-8 (it sets Encoding.default_external). Match
# that here so reading a merged file that carries non-ASCII consumer content
# (e.g. an em-dash in a heading) does not raise under a C / US-ASCII test
# locale. Assigning Encoding.default_external emits a warning under $VERBOSE
# (config.warnings = true); silence just this deliberate global.
begin
  _verbose = $VERBOSE
  $VERBOSE = nil
  Encoding.default_external = Encoding::UTF_8
ensure
  $VERBOSE = _verbose
end

# Behavioral tests for the push-from-canonical engine
# .github/actions/sync/sync-files.rb. The engine resolves SOURCE_ROOT from
# SYNC_SOURCE_ROOT (test override) and the manifest from SYNC_MANIFEST, so each
# example drives it against a fixture source tree + a throwaway consumer repo.
RSpec.describe "sync-files.rb engine" do
  let(:engine) { File.join(REPO_ROOT, ".github/actions/sync/sync-files.rb") }

  def sh!(*cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "command failed: #{cmd.inspect}\nstdout: #{out}\nstderr: #{err}" unless status.success?

    out
  end

  # Fixture canonical files + a manifest covering every mode the engine applies.
  def write_source(dir)
    FileUtils.mkdir_p("#{dir}/scripts")
    File.write("#{dir}/scripts/tool.sh", <<~SH)
      #!/bin/sh
      # SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
      #
      # SPDX-License-Identifier: GPL-3.0-or-later

      echo hi
    SH
    File.chmod(0o755, "#{dir}/scripts/tool.sh")

    # A file repo-foundation relays from an upstream: it already carries a
    # "do not modify it directly" header the engine must replace (not duplicate).
    FileUtils.mkdir_p("#{dir}/.github")
    File.write("#{dir}/.github/relayed.yml", <<~YML)
      # SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
      #
      # SPDX-License-Identifier: GPL-3.0-or-later

      # This file is synced from `Homebrew/.github` by `x`, do not modify it directly.

      rules:
        foo: bar
    YML

    File.write("#{dir}/.github/matcher.json", "{\n  \"x\": 1\n}\n")
    File.write("#{dir}/.github/matcher.json.license",
               "SPDX-FileCopyrightText: Copyright 2026 Todd Schulman\n\nSPDX-License-Identifier: GPL-3.0-or-later\n")

    FileUtils.mkdir_p("#{dir}/.github/actions/sync")
    File.write("#{dir}/.github/actions/sync/dependabot.template.yml", <<~YML)
      # SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
      #
      # SPDX-License-Identifier: GPL-3.0-or-later
      version: 2
      updates:
        - package-ecosystem: bundler
          directory: /
        - package-ecosystem: gomod
          directory: /
        - package-ecosystem: github-actions
          directory: /
    YML

    File.write("#{dir}/sync-manifest.yaml", <<~YML)
      version: 1
      defaults:
        synced_header: >-
          This file is synced from toobuntu/repo-foundation (%<source>s) by
          sync-to-consumers.yml; do not modify it directly.
        merge_begin: "# >>> repo-foundation managed >>>"
        merge_end: "# <<< repo-foundation managed <<<"
      component_sets:
        core:
          - { source: scripts/tool.sh, target: scripts/tool.sh, mode: canonical }
          - { source: .github/relayed.yml, target: .github/relayed.yml, mode: canonical }
          - { source: .github/matcher.json, target: .github/matcher.json, mode: canonical }
          - { source: .github/matcher.json.license, target: .github/matcher.json.license, mode: canonical }
          - { source: .github/actions/sync/dependabot.template.yml, target: .github/dependabot.yml, mode: generate }
      consumers:
        - repo: toobuntu/test-consumer
          sets: [core]
    YML
  end

  # Seed a consumer that has a Gemfile (bundler) and a workflow (github-actions)
  # but no go.mod, so the generate mode must drop the gomod stanza.
  def init_target(dir)
    sh!("git", "init", "--quiet", "--initial-branch=main", dir)
    sh!("git", "-C", dir, "config", "user.email", "t@example.invalid")
    sh!("git", "-C", dir, "config", "user.name", "Test")
    sh!("git", "-C", dir, "config", "commit.gpgsign", "false")
    File.write("#{dir}/Gemfile", "source 'https://rubygems.org'\n")
    FileUtils.mkdir_p("#{dir}/.github/workflows")
    File.write("#{dir}/.github/workflows/x.yml", "name: x\n")
    sh!("git", "-C", dir, "add", "-A")
    sh!("git", "-C", dir, "commit", "--quiet", "-m", "seed")
  end

  def run_engine(source, target, *extra)
    # Strip the bundler environment inherited from `bundle exec rspec` so the
    # engine runs as a plain stdlib script (as it does in CI under the composite
    # action), not under this suite's bundler/Ruby. Without this the spawned
    # `ruby` tries to load the parent's bundler and dies with a cross-version
    # NameError. nil values unset the variable for the child.
    env = {
      "SYNC_SOURCE_ROOT" => source,
      "SYNC_MANIFEST" => "#{source}/sync-manifest.yaml",
      "RUBYOPT" => nil, "RUBYLIB" => nil,
      "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil,
      "GEM_HOME" => nil, "GEM_PATH" => nil,
    }
    Open3.capture3(env, "ruby", engine, "toobuntu/test-consumer", target, *extra)
  end

  # Fixture for the baseline-merge modes: a Markdown region, a .gitignore region,
  # and a JSON baseline the engine deep-merges with the consumer's addenda.
  def write_baseline_source(dir)
    FileUtils.mkdir_p("#{dir}/provides/repo")
    File.write("#{dir}/provides/repo/AGENTS.baseline.md", <<~MD)
      @docs/agent-principles.md

      Org-wide managed agent context.
    MD
    File.write("#{dir}/provides/repo/gitignore.baseline", <<~TXT)
      .DS_Store
      vendor/bundle/
    TXT
    File.write("#{dir}/provides/repo/settings.baseline.json", <<~JSON)
      {
        "permissions": {
          "allow": ["Bash(git status:*)"],
          "deny": ["Bash(git push:*)", "Bash(sudo:*)"]
        },
        "hooks": {
          "PreToolUse": [{ "matcher": "Edit", "hooks": [{ "type": "command", "command": "block-main" }] }]
        }
      }
    JSON
    # A class fragment (ADR 0016): an RF-owned delta folded between the
    # baseline and the consumer's addenda. FOO also appears in the addenda, so
    # the merge ORDER is observable: addenda must win over the fragment.
    File.write("#{dir}/provides/repo/settings.classfrag.json", <<~JSON)
      {
        "permissions": {
          "deny": ["Bash(frag-only:*)"]
        },
        "env": { "FOO": "fragment-loses" }
      }
    JSON
    File.write("#{dir}/sync-manifest.yaml", <<~YML)
      version: 1
      defaults:
        synced_header: >-
          synced from %<source>s; do not modify it directly.
        merge_label_begin: "repo-foundation managed baseline (edit outside this block)"
        merge_label_end: "end repo-foundation managed baseline"
      component_sets:
        baselines:
          - { source: provides/repo/AGENTS.baseline.md, target: AGENTS.md, mode: baseline-merge }
          - { source: provides/repo/gitignore.baseline, target: .gitignore, mode: baseline-merge }
          - { source: provides/repo/settings.baseline.json, target: .claude/settings.json, mode: baseline-merge }
        class_fragment:
          - { source: provides/repo/settings.classfrag.json, target: .claude/settings.json, mode: fragment }
      consumers:
        - repo: toobuntu/test-consumer
          sets: [baselines, class_fragment]
    YML
  end

  # Consumer with pre-existing content the merge must preserve, plus a JSON
  # addenda file the deep-merge must fold into the baseline.
  def init_baseline_target(dir)
    sh!("git", "init", "--quiet", "--initial-branch=main", dir)
    sh!("git", "-C", dir, "config", "user.email", "t@example.invalid")
    sh!("git", "-C", dir, "config", "user.name", "Test")
    sh!("git", "-C", dir, "config", "commit.gpgsign", "false")
    File.write("#{dir}/AGENTS.md", "# AGENTS.md — test-consumer\n\nRepo-specific intro.\n")
    File.write("#{dir}/.gitignore", "# repo-specific\nbuild/\n")
    FileUtils.mkdir_p("#{dir}/.claude")
    File.write("#{dir}/.claude/settings.addenda.json", <<~JSON)
      {
        "permissions": {
          "allow": ["Bash(make:*)"],
          "deny": ["Bash(certbot:*)"]
        },
        "env": { "FOO": "bar" }
      }
    JSON
    sh!("git", "-C", dir, "add", "-A")
    sh!("git", "-C", dir, "commit", "--quiet", "-m", "seed")
  end

  it "applies modes, rewrites the relay header, filters dependabot, commits per file" do
    Dir.mktmpdir("rf-sync-src-") do |source|
      write_source(source)
      Dir.mktmpdir("rf-sync-tgt-") do |target|
        init_target(target)
        out, err, status = run_engine(source, target)
        expect(status.success?).to eq(true), "stdout=#{out}\nstderr=#{err}"

        # canonical: header lands after the SPDX block; exec bit preserved.
        tool = File.read("#{target}/scripts/tool.sh")
        expect(tool).to include("toobuntu/repo-foundation")
        expect(tool).to include("do not modify it directly")
        expect(tool.index("SPDX-License-Identifier")).to be < tool.index("do not modify it directly")
        expect(File.stat("#{target}/scripts/tool.sh").mode & 0o777).to eq(0o755)

        # relayed: the upstream header is replaced, not stacked.
        relayed = File.read("#{target}/.github/relayed.yml")
        expect(relayed).not_to include("Homebrew")
        expect(relayed).to include("toobuntu/repo-foundation")
        expect(relayed.scan("do not modify it directly").length).to eq(1)

        # generate: bundler + github-actions kept, gomod dropped; SPDX re-added.
        dependabot = File.read("#{target}/.github/dependabot.yml")
        expect(dependabot).to include("bundler")
        expect(dependabot).to include("github-actions")
        expect(dependabot).not_to include("gomod")
        expect(dependabot).to include("SPDX-License-Identifier")

        # JSON copied verbatim (no comment header); sidecar present.
        expect(File.read("#{target}/.github/matcher.json")).to eq("{\n  \"x\": 1\n}\n")
        expect(File.exist?("#{target}/.github/matcher.json.license")).to eq(true)

        # one commit per changed file.
        log = sh!("git", "-C", target, "log", "--format=%s")
        expect(log).to include("tool.sh: sync from repo-foundation")
        expect(log).to include("dependabot.yml: sync from repo-foundation")
      end
    end
  end

  it "writes nothing under --dry-run" do
    Dir.mktmpdir("rf-sync-src-") do |source|
      write_source(source)
      Dir.mktmpdir("rf-sync-tgt-") do |target|
        init_target(target)
        out, _err, status = run_engine(source, target, "--dry-run")
        expect(status.success?).to eq(true)
        expect(out).to include("would update")
        expect(File.exist?("#{target}/.github/dependabot.yml")).to eq(false)
        porcelain, = Open3.capture3("git", "-C", target, "status", "--porcelain")
        expect(porcelain.strip).to eq("")
      end
    end
  end

  it "aborts on an invalid component mode" do
    Dir.mktmpdir("rf-sync-src-") do |source|
      write_source(source)
      manifest = File.read("#{source}/sync-manifest.yaml")
      File.write("#{source}/sync-manifest.yaml", manifest.sub("mode: canonical }", "mode: bogus }"))
      Dir.mktmpdir("rf-sync-tgt-") do |target|
        init_target(target)
        _out, err, status = run_engine(source, target)
        expect(status.success?).to eq(false)
        expect(err).to include("invalid mode")
      end
    end
  end

  it "merges text regions in the target's comment syntax and deep-merges JSON" do
    Dir.mktmpdir("rf-sync-src-") do |source|
      write_baseline_source(source)
      Dir.mktmpdir("rf-sync-tgt-") do |target|
        init_baseline_target(target)
        out, err, status = run_engine(source, target)
        expect(status.success?).to eq(true), "stdout=#{out}\nstderr=#{err}"

        # Markdown: HTML-comment sentinels (never a '#' heading), region content
        # present, pre-existing repo content preserved.
        agents = File.read("#{target}/AGENTS.md")
        expect(agents).to include("<!-- >>> repo-foundation managed baseline")
        expect(agents).to include("<!-- <<< end repo-foundation managed baseline")
        expect(agents).to include("@docs/agent-principles.md")
        expect(agents).to include("Repo-specific intro.")
        expect(agents).not_to match(/^# >>> repo-foundation/)

        # .gitignore: hash-comment sentinels; region and pre-existing both kept.
        gitignore = File.read("#{target}/.gitignore")
        expect(gitignore).to include("# >>> repo-foundation managed baseline")
        expect(gitignore).to include("vendor/bundle/")
        expect(gitignore).to include("build/")

        # JSON: deep-merge — arrays union (baseline + addenda), objects merge,
        # the consumer can only ADD to the deny rail, env comes from the addenda.
        settings = JSON.parse(File.read("#{target}/.claude/settings.json"))
        expect(settings["permissions"]["allow"]).to include("Bash(git status:*)", "Bash(make:*)")
        expect(settings["permissions"]["deny"]).to include("Bash(git push:*)", "Bash(sudo:*)", "Bash(certbot:*)")
        # Class fragment folded between baseline and addenda: its array entry
        # unions in, and the addenda's FOO beats the fragment's (layer order).
        expect(settings["permissions"]["deny"]).to include("Bash(frag-only:*)")
        expect(settings["env"]).to eq("FOO" => "bar")
        expect(settings["hooks"]["PreToolUse"]).not_to be_empty
        # The addenda file is the consumer's edit surface, not the generated target.
        expect(File.exist?("#{target}/.claude/settings.addenda.json")).to eq(true)
      end
    end
  end

  it "is idempotent: a second baseline-merge run detects no changes" do
    Dir.mktmpdir("rf-sync-src-") do |source|
      write_baseline_source(source)
      Dir.mktmpdir("rf-sync-tgt-") do |target|
        init_baseline_target(target)
        _out, _err, status = run_engine(source, target)
        expect(status.success?).to eq(true)

        out2, err2, status2 = run_engine(source, target)
        expect(status2.success?).to eq(true), "stdout=#{out2}\nstderr=#{err2}"
        expect(out2).to include("No changes to commit.")
        porcelain, = Open3.capture3("git", "-C", target, "status", "--porcelain")
        expect(porcelain.strip).to eq("")
      end
    end
  end
end
