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

  def run_engine(source, target, *extra, env: {})
    # Strip the bundler environment inherited from `bundle exec rspec` so the
    # engine runs as a plain stdlib script (as it does in CI under the composite
    # action), not under this suite's bundler/Ruby. Without this the spawned
    # `ruby` tries to load the parent's bundler and dies with a cross-version
    # NameError. nil values unset the variable for the child. GITHUB_ACTIONS /
    # GITHUB_OUTPUT are unset so a CI run of this suite does not leak engine
    # annotations and outputs into the spec job; the annotation examples set
    # them deliberately via `env:`.
    base_env = {
      "SYNC_SOURCE_ROOT" => source,
      "SYNC_MANIFEST" => "#{source}/sync-manifest.yaml",
      "RUBYOPT" => nil, "RUBYLIB" => nil,
      "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil,
      "GEM_HOME" => nil, "GEM_PATH" => nil,
      "GITHUB_ACTIONS" => nil, "GITHUB_OUTPUT" => nil,
    }
    # RbConfig.ruby, not bare "ruby": a bare name resolves through PATH, which
    # on macOS finds the frozen system Ruby 2.6 (BSD `env -P` locates only the
    # utility; it does not export the modified PATH to children). The engine
    # should run under the same modern Ruby as this suite.
    Open3.capture3(base_env.merge(env), RbConfig.ruby, engine, "toobuntu/test-consumer", target, *extra)
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

  it "applies modes, rewrites the relay header, filters dependabot, emits the change list" do
    Dir.mktmpdir("rf-sync-src-") do |source|
      write_source(source)
      Dir.mktmpdir("rf-sync-tgt-") do |target|
        init_target(target)
        emit = File.join(target, ".sync-emit")
        out, err, status = run_engine(source, target, "--emit-dir", emit)
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

        # The engine makes no git commits; it emits the change list (with git
        # modes) and a PR body for the workflow's Git Data commit loop.
        log = sh!("git", "-C", target, "log", "--format=%s")
        expect(log.strip).to eq("seed")
        changes = JSON.parse(File.read("#{emit}/changes.json"))
        tool = changes.find { |c| c["path"] == "scripts/tool.sh" }
        expect(tool).to include("status" => "added", "mode" => "100755")
        dependabot = changes.find { |c| c["path"] == ".github/dependabot.yml" }
        expect(dependabot).to include("status" => "added", "mode" => "100644")
        body = File.read("#{emit}/pr-body.md")
        expect(body).to include("## Converged surfaces")
        expect(body).to include("- `scripts/tool.sh` (added, 100755)")
        expect(body).to include("- `.github/dependabot.yml` (added)")
      end
    end
  end

  it "emits modified statuses, bootstrap notes, and exclusion reasons in the PR body" do
    Dir.mktmpdir("rf-sync-src-") do |source|
      write_baseline_source(source)
      manifest = File.read("#{source}/sync-manifest.yaml")
      File.write("#{source}/sync-manifest.yaml", manifest.sub(
                   "sets: [baselines, class_fragment]",
                   "sets: [baselines, class_fragment]\n    exclude:\n      " \
                   "- { target: .gitignore, reason: \"this repo keeps a bespoke ignore file\" }"
                 ))
      Dir.mktmpdir("rf-sync-tgt-") do |target|
        init_baseline_target(target)
        emit = File.join(target, ".sync-emit")
        out, err, status = run_engine(source, target, "--emit-dir", emit)
        expect(status.success?).to eq(true), "stdout=#{out}\nstderr=#{err}"

        changes = JSON.parse(File.read("#{emit}/changes.json"))
        agents = changes.find { |c| c["path"] == "AGENTS.md" }
        expect(agents["status"]).to eq("modified")
        expect(agents["note"]).to include("bootstrapped")
        expect(changes.map { |c| c["path"] }).not_to include(".gitignore")

        body = File.read("#{emit}/pr-body.md")
        expect(body).to include("- `AGENTS.md` (modified) — managed region bootstrapped")
        expect(body).to include("## Exclusions")
        expect(body).to include("- `.gitignore` — this repo keeps a bespoke ignore file")
      end
    end
  end

  it "mirrors the .ai continuity files with a Markdown synced header (ADR 0022)" do
    Dir.mktmpdir("rf-sync-src-") do |source|
      FileUtils.mkdir_p("#{source}/.ai/org")
      File.write("#{source}/.ai/org/memory.md", <<~MD)
        <!--
        SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

        SPDX-License-Identifier: GPL-3.0-or-later
        -->

        # Org memory — toobuntu

        ## 2026-07-23 — A durable fact
      MD
      File.write("#{source}/.ai/progress.template.md", "# Session progress\n\n## Handoff\n")
      File.write("#{source}/sync-manifest.yaml", <<~YML)
        version: 1
        defaults:
          synced_header: >-
            This file is synced from toobuntu/repo-foundation (%<source>s) by
            sync-to-consumers.yml; do not modify it directly.
        component_sets:
          ai_continuity:
            - { source: .ai/progress.template.md, target: .ai/progress.template.md, mode: canonical }
            - { source: .ai/org/memory.md,        target: .ai/org/memory.md,        mode: canonical }
        consumers:
          - repo: toobuntu/test-consumer
            sets: [ai_continuity]
      YML
      Dir.mktmpdir("rf-sync-tgt-") do |target|
        init_target(target)
        out, err, status = run_engine(source, target)
        expect(status.success?).to eq(true), "stdout=#{out}\nstderr=#{err}"

        # The engine word-wraps the rendered header, so match across the wrap.
        header = /do not modify it\s+directly/
        org = File.read("#{target}/.ai/org/memory.md")
        expect(org).to match(header)
        expect(org.scan(header).length).to eq(1)
        expect(org).to include("## 2026-07-23 — A durable fact")

        template = File.read("#{target}/.ai/progress.template.md")
        expect(template.scan(header).length).to eq(1)
        expect(template).to include("## Handoff")
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

  it "resolves exclude-with-reason entries and rejects bare-string excludes" do
    Dir.mktmpdir("rf-sync-src-") do |source|
      write_source(source)
      manifest = File.read("#{source}/sync-manifest.yaml")
      with_exclude = manifest.sub(
        "sets: [core]",
        "sets: [core]\n    exclude:\n      - { target: scripts/tool.sh, " \
        "reason: \"this repo builds tool.sh from source\" }"
      )
      File.write("#{source}/sync-manifest.yaml", with_exclude)
      Dir.mktmpdir("rf-sync-tgt-") do |target|
        init_target(target)
        out, err, status = run_engine(source, target)
        expect(status.success?).to eq(true), "stdout=#{out}\nstderr=#{err}"
        expect(File.exist?("#{target}/scripts/tool.sh")).to eq(false)
        expect(File.exist?("#{target}/.github/relayed.yml")).to eq(true)

        # A bare-string exclude (the pre-§ 18.3 form) is a manifest bug.
        File.write("#{source}/sync-manifest.yaml",
                   manifest.sub("sets: [core]", "sets: [core]\n    exclude: [scripts/tool.sh]"))
        _out, err, status = run_engine(source, target)
        expect(status.success?).to eq(false)
        expect(err).to include("exclude entries must be mappings with target and reason")
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
        # present and padded with a blank line inside each sentinel, pre-existing
        # repo content preserved.
        agents = File.read("#{target}/AGENTS.md")
        expect(agents).to include("<!-- >>> repo-foundation managed baseline")
        expect(agents).to include("<!-- <<< end repo-foundation managed baseline")
        expect(agents).to match(/>>> -->\n\n@docs\/agent-principles\.md/)
        expect(agents).to match(/managed agent context\.\n\n<!-- <<</)
        expect(agents).to include("Repo-specific intro.")
        expect(agents).not_to match(/^# >>> repo-foundation/)

        # .gitignore: hash-comment sentinels stay tight (no padding); region and
        # pre-existing both kept.
        gitignore = File.read("#{target}/.gitignore")
        expect(gitignore).to match(/# >>> repo-foundation managed baseline.*>>>\n\.DS_Store/)
        expect(gitignore).to match(%r{vendor/bundle/\n# <<<})
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

  # Sentinel lines as the engine renders them for the write_baseline_source
  # labels, used by the marker-state examples below.
  def md_sentinels
    ["<!-- >>> repo-foundation managed baseline (edit outside this block) >>> -->",
     "<!-- <<< end repo-foundation managed baseline <<< -->"]
  end

  def commit_all(dir, message)
    sh!("git", "-C", dir, "add", "-A")
    sh!("git", "-C", dir, "commit", "--quiet", "-m", message)
  end

  it "prepends a bootstrapped region after the H1 (Markdown) and after leading comments (hash)" do
    Dir.mktmpdir("rf-sync-src-") do |source|
      write_baseline_source(source)
      Dir.mktmpdir("rf-sync-tgt-") do |target|
        init_baseline_target(target)
        out, err, status = run_engine(source, target)
        expect(status.success?).to eq(true), "stdout=#{out}\nstderr=#{err}"
        expect(out).to include("managed region bootstrapped")

        agents = File.read("#{target}/AGENTS.md")
        h1 = agents.index("# AGENTS.md — test-consumer")
        marker = agents.index(md_sentinels.first)
        intro = agents.index("Repo-specific intro.")
        expect(h1).to be < marker
        expect(marker).to be < intro

        gitignore = File.read("#{target}/.gitignore")
        comment = gitignore.index("# repo-specific")
        marker = gitignore.index("# >>> repo-foundation managed baseline")
        build = gitignore.index("build/")
        expect(comment).to be < marker
        expect(marker).to be < build
      end
    end
  end

  it "aborts on an inverted marker pair instead of silently reporting no change" do
    Dir.mktmpdir("rf-sync-src-") do |source|
      write_baseline_source(source)
      Dir.mktmpdir("rf-sync-tgt-") do |target|
        init_baseline_target(target)
        begin_line, end_line = md_sentinels
        File.write("#{target}/AGENTS.md",
                   "# AGENTS.md — test-consumer\n\n#{end_line}\nstale\n#{begin_line}\n")
        commit_all(target, "invert markers")
        _out, err, status = run_engine(source, target)
        expect(status.success?).to eq(false)
        expect(err).to include("inverted")
      end
    end
  end

  it "aborts with a ready-to-run recovery when a managed region was deleted from history" do
    Dir.mktmpdir("rf-sync-src-") do |source|
      write_baseline_source(source)
      Dir.mktmpdir("rf-sync-tgt-") do |target|
        init_baseline_target(target)
        begin_line, end_line = md_sentinels
        File.write("#{target}/AGENTS.md",
                   "# AGENTS.md — test-consumer\n\n#{begin_line}\n\nregion\n\n#{end_line}\n\nRepo-specific intro.\n")
        commit_all(target, "add region")
        last_present = sh!("git", "-C", target, "rev-parse", "--short", "HEAD").strip
        File.write("#{target}/AGENTS.md", "# AGENTS.md — test-consumer\n\nRepo-specific intro.\n")
        commit_all(target, "remove region")

        _out, err, status = run_engine(source, target)
        expect(status.success?).to eq(false)
        # The step log carries the exact restore command (pointing at the last
        # commit that still had the region) and a paste-ready exclude entry.
        expect(err).to include("last present at #{last_present}")
        expect(err).to include("git restore --source=#{last_present} -- AGENTS.md")
        expect(err).to include('- { target: AGENTS.md, reason: "<fill in>" }')
      end
    end
  end

  it "aborts rather than self-healing when the consumer history is shallow" do
    Dir.mktmpdir("rf-sync-src-") do |source|
      write_baseline_source(source)
      Dir.mktmpdir("rf-sync-tgt-") do |target|
        init_baseline_target(target)
        Dir.mktmpdir("rf-sync-shallow-") do |parent|
          shallow = "#{parent}/clone"
          sh!("git", "clone", "--quiet", "--depth=1", "file://#{target}", shallow)
          _out, err, status = run_engine(source, shallow)
          expect(status.success?).to eq(false)
          expect(err).to include("shallow")
        end
      end
    end
  end

  describe "--guard" do
    it "passes a PR that does not touch managed surfaces, ignoring pre-branch drift" do
      Dir.mktmpdir("rf-sync-src-") do |source|
        write_source(source)
        Dir.mktmpdir("rf-sync-tgt-") do |target|
          init_target(target)
          _out, _err, status = run_engine(source, target)
          expect(status.success?).to eq(true)
          commit_all(target, "apply sync")

          # Drift committed to main BEFORE the branch: belongs to the sync, not
          # to this PR's author (the merge-base filter).
          File.write("#{target}/scripts/tool.sh", "#!/bin/sh\necho drifted\n")
          commit_all(target, "hand-edit a canonical (pre-branch drift)")
          sh!("git", "-C", target, "switch", "--quiet", "--create", "feature")
          File.write("#{target}/README.md", "consumer-owned content\n")
          commit_all(target, "consumer-owned change")

          out, err, status = run_engine(source, target, "--guard", "main")
          expect(status.success?).to eq(true), "stdout=#{out}\nstderr=#{err}"
          expect(out).to include("no managed surface")
        end
      end
    end

    it "fails a PR that edits a canonical file, with a single-line annotation" do
      Dir.mktmpdir("rf-sync-src-") do |source|
        write_source(source)
        Dir.mktmpdir("rf-sync-tgt-") do |target|
          init_target(target)
          _out, _err, status = run_engine(source, target)
          expect(status.success?).to eq(true)
          commit_all(target, "apply sync")

          sh!("git", "-C", target, "switch", "--quiet", "--create", "feature")
          File.write("#{target}/scripts/tool.sh", "#!/bin/sh\necho tampered\n")
          commit_all(target, "edit a canonical")

          out, err, status = run_engine(source, target, "--guard", "main",
                                        env: { "GITHUB_ACTIONS" => "true" })
          expect(status.success?).to eq(false)
          expect(err).to include("scripts/tool.sh")
          expect(err).to include("change these in toobuntu/repo-foundation")
          annotation = out.lines.grep(/\A::error::/)
          expect(annotation.length).to eq(1)
          expect(annotation.first).to include("docs/maintaining-a-repo.md")
        end
      end
    end

    it "compares baseline-merge targets by regenerated output (region-only edits fail)" do
      Dir.mktmpdir("rf-sync-src-") do |source|
        write_baseline_source(source)
        Dir.mktmpdir("rf-sync-tgt-") do |target|
          init_baseline_target(target)
          _out, _err, status = run_engine(source, target)
          expect(status.success?).to eq(true)
          commit_all(target, "apply sync")

          # Consumer-owned edit OUTSIDE the managed region: passes even though
          # the file itself was touched.
          sh!("git", "-C", target, "switch", "--quiet", "--create", "feature")
          File.write("#{target}/AGENTS.md", "#{File.read("#{target}/AGENTS.md")}\nMore repo-specific prose.\n")
          commit_all(target, "edit outside the region")
          out, err, status = run_engine(source, target, "--guard", "main")
          expect(status.success?).to eq(true), "stdout=#{out}\nstderr=#{err}"

          # Edit INSIDE the managed region: fails.
          tampered = File.read("#{target}/AGENTS.md").sub("Org-wide managed agent context.", "Tampered.")
          File.write("#{target}/AGENTS.md", tampered)
          commit_all(target, "edit inside the region")
          _out, err, status = run_engine(source, target, "--guard", "main")
          expect(status.success?).to eq(false)
          expect(err).to include("AGENTS.md")
        end
      end
    end

    it "flags a deleted managed region with the restore recipe" do
      Dir.mktmpdir("rf-sync-src-") do |source|
        write_baseline_source(source)
        Dir.mktmpdir("rf-sync-tgt-") do |target|
          init_baseline_target(target)
          _out, _err, status = run_engine(source, target)
          expect(status.success?).to eq(true)
          commit_all(target, "apply sync")

          sh!("git", "-C", target, "switch", "--quiet", "--create", "feature")
          File.write("#{target}/AGENTS.md", "# AGENTS.md — test-consumer\n\nRepo-specific intro.\n")
          commit_all(target, "delete the managed region")
          _out, err, status = run_engine(source, target, "--guard", "main")
          expect(status.success?).to eq(false)
          expect(err).to include("git restore --source=")
          expect(err).to include('- { target: AGENTS.md, reason: "<fill in>" }')
        end
      end
    end
  end

  describe "--audit" do
    it "reports per-pair freshness rows, a summary, and exclusion reasons, read-only" do
      Dir.mktmpdir("rf-sync-src-") do |source|
        write_source(source)
        manifest = File.read("#{source}/sync-manifest.yaml")
        File.write("#{source}/sync-manifest.yaml", manifest.sub(
                     "sets: [core]",
                     "sets: [core]\n    exclude:\n      - { target: .github/matcher.json.license, " \
                     "reason: \"sidecar owned locally\" }"
                   ))
        Dir.mktmpdir("rf-sync-tgt-") do |target|
          init_target(target)
          _out, _err, status = run_engine(source, target)
          expect(status.success?).to eq(true)
          commit_all(target, "apply sync")

          File.write("#{target}/scripts/tool.sh", "#!/bin/sh\necho drifted\n")
          FileUtils.rm("#{target}/.github/relayed.yml")

          out, err, status = run_engine(source, target, "--audit")
          expect(status.success?).to eq(true), "stdout=#{out}\nstderr=#{err}"
          expect(out).to match(%r{differs\s+scripts/tool\.sh.*\+\d+/-\d+})
          expect(out).to match(%r{missing\s+\.github/relayed\.yml})
          expect(out).to match(%r{same\s+\.github/matcher\.json})
          expect(out).to include("Summary:")
          expect(out).to include("Exclusions:")
          expect(out).to include(".github/matcher.json.license — sidecar owned locally")

          # Read-only: the audit neither restores the deleted file nor
          # rewrites the drifted one.
          expect(File.exist?("#{target}/.github/relayed.yml")).to eq(false)
          expect(File.read("#{target}/scripts/tool.sh")).to include("drifted")
        end
      end
    end

    it "reports marker damage as an error row instead of aborting the audit" do
      Dir.mktmpdir("rf-sync-src-") do |source|
        write_baseline_source(source)
        Dir.mktmpdir("rf-sync-tgt-") do |target|
          init_baseline_target(target)
          _out, _err, status = run_engine(source, target)
          expect(status.success?).to eq(true)
          commit_all(target, "apply sync")

          File.write("#{target}/AGENTS.md", "# AGENTS.md — test-consumer\n\nRepo-specific intro.\n")
          commit_all(target, "delete the managed region")

          out, err, status = run_engine(source, target, "--audit")
          expect(status.success?).to eq(true), "stdout=#{out}\nstderr=#{err}"
          expect(out).to match(/error\s+AGENTS\.md/)
          expect(out).to include("last present at")
          expect(out).to match(%r{same\s+\.gitignore})
        end
      end
    end
  end

  describe "git-data-commit.rb" do
    let(:helper) { File.join(REPO_ROOT, ".github/actions/sync/git-data-commit.rb") }

    # A fake `gh` on PATH: logs every call (argv + stdin JSON) and answers with
    # canned, call-numbered shas, so the examples can assert the exact Git Data
    # API sequence without network.
    def write_fake_gh(bin_dir)
      fake = File.join(bin_dir, "gh")
      File.write(fake, <<~'RUBY')
        #!/usr/bin/env ruby
        require "json"
        log_dir = ENV.fetch("FAKE_GH_LOG")
        stdin = $stdin.read
        n = Dir.glob(File.join(log_dir, "call-*.json")).length + 1
        File.write(File.join(log_dir, format("call-%03d.json", n)),
                   JSON.generate("argv" => ARGV, "stdin" => stdin))
        method = ARGV[2]
        path = ARGV[3]
        res =
          if method == "GET" && path.include?("/git/commits/")
            { "sha" => "base", "tree" => { "sha" => "tree-base" } }
          elsif path.end_with?("/git/blobs")
            { "sha" => "blob-#{n}" }
          elsif path.end_with?("/git/trees")
            { "sha" => "tree-#{n}" }
          elsif path.end_with?("/git/commits")
            { "sha" => "commit-#{n}" }
          elsif path.end_with?("/git/refs")
            { "ref" => "created" }
          else
            abort "fake gh: unexpected call #{ARGV.inspect}"
          end
        puts JSON.generate(res)
      RUBY
      File.chmod(0o755, fake)
    end

    it "chains per-file Git Data commits with modes and sha:null deletions" do
      Dir.mktmpdir("rf-gitdata-") do |dir|
        bin = File.join(dir, "bin")
        log = File.join(dir, "log")
        consumer = File.join(dir, "consumer")
        FileUtils.mkdir_p([bin, log, File.join(consumer, "scripts")])
        write_fake_gh(bin)
        File.write(File.join(consumer, "scripts/run.sh"), "#!/bin/sh\necho ok\n")
        File.write(File.join(consumer, "notes.md"), "notes\n")
        changes = [
          { "path" => "scripts/run.sh", "status" => "added", "mode" => "100755" },
          { "path" => "notes.md", "status" => "modified", "mode" => "100644" },
          { "path" => "old.txt", "status" => "deleted", "mode" => "100644" },
        ]
        File.write(File.join(dir, "changes.json"), JSON.generate(changes))

        env = {
          "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "FAKE_GH_LOG" => log,
          "RUBYOPT" => nil, "RUBYLIB" => nil,
          "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil,
          "GEM_HOME" => nil, "GEM_PATH" => nil,
          "GITHUB_ACTIONS" => nil, "GITHUB_OUTPUT" => nil,
        }
        out, err, status = Open3.capture3(env, RbConfig.ruby, helper,
                                          "--repo", "toobuntu/consumer", "--dir", consumer,
                                          "--changes", File.join(dir, "changes.json"),
                                          "--branch", "sync/123", "--base", "basesha")
        expect(status.success?).to eq(true), "stdout=#{out}\nstderr=#{err}"

        calls = Dir.glob(File.join(log, "call-*.json")).sort.map { |f| JSON.parse(File.read(f)) }
        expect(calls.length).to eq(10)

        # Base commit resolved once, for its tree.
        expect(calls[0]["argv"][2..3]).to eq(["GET", "repos/toobuntu/consumer/git/commits/basesha"])

        # First file: blob carries the base64 content; tree builds on the base
        # tree with the executable mode; commit chains on the base sha.
        blob1 = JSON.parse(calls[1]["stdin"])
        expect(blob1["encoding"]).to eq("base64")
        expect(blob1["content"]).to eq(["#!/bin/sh\necho ok\n"].pack("m0"))
        tree1 = JSON.parse(calls[2]["stdin"])
        expect(tree1["base_tree"]).to eq("tree-base")
        expect(tree1["tree"]).to eq([{ "path" => "scripts/run.sh", "mode" => "100755",
                                       "type" => "blob", "sha" => "blob-2" }])
        commit1 = JSON.parse(calls[3]["stdin"])
        expect(commit1["message"]).to eq("run.sh: sync from repo-foundation")
        expect(commit1["parents"]).to eq(["basesha"])
        expect(commit1["tree"]).to eq("tree-3")

        # Second file chains on the first commit and its tree.
        tree2 = JSON.parse(calls[5]["stdin"])
        expect(tree2["base_tree"]).to eq("tree-3")
        commit2 = JSON.parse(calls[6]["stdin"])
        expect(commit2["parents"]).to eq(["commit-4"])

        # Deletion: no blob call; the tree entry carries sha: null.
        tree3 = JSON.parse(calls[7]["stdin"])
        expect(tree3["tree"]).to eq([{ "path" => "old.txt", "mode" => "100644",
                                       "type" => "blob", "sha" => nil }])
        commit3 = JSON.parse(calls[8]["stdin"])
        expect(commit3["parents"]).to eq(["commit-7"])

        # One ref create at the end, pointing at the final commit.
        ref = calls[9]
        expect(ref["argv"][2..3]).to eq(["POST", "repos/toobuntu/consumer/git/refs"])
        expect(JSON.parse(ref["stdin"])).to eq("ref" => "refs/heads/sync/123", "sha" => "commit-9")
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
        commit_all(target, "apply sync")

        out2, err2, status2 = run_engine(source, target)
        expect(status2.success?).to eq(true), "stdout=#{out2}\nstderr=#{err2}"
        expect(out2).to include("No changes.")
        porcelain, = Open3.capture3("git", "-C", target, "status", "--porcelain")
        expect(porcelain.strip).to eq("")
      end
    end
  end
end
