# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "open3"
require "tmpdir"

# Behavioral tests for the three documentation pre-commit plugins mastered at
# the natural path: 15-prose (vale), 10-markdown (rumdl), and 50-adrs
# (adrs doctor). Same pattern as the Swift plugin spec: each plugin runs in a
# throwaway git repository with stub executables prepended to PATH, so the
# tests need no real vale/rumdl/adrs and shadow any installed copy.

DOCS_PLUGINS = {
  prose:    File.join(REPO_ROOT, ".githooks", "pre-commit.d", "15-prose"),
  markdown: File.join(REPO_ROOT, ".githooks", "pre-commit.d", "10-markdown"),
  adrs:     File.join(REPO_ROOT, ".githooks", "pre-commit.d", "50-adrs"),
}.freeze

module DocsPluginHelpers
  # Create a temp git repo on a feature branch, prepend a stub bin dir to
  # PATH, write and stage the given files, run the plugin, and yield its
  # result plus the working directory. base_path: replaces the inherited
  # PATH (default keeps it), so a test can genuinely hide a host-installed
  # tool while git and the coreutils still resolve from /usr/bin:/bin.
  def with_docs_plugin(plugin, files, stubs: {}, base_path: ENV.fetch("PATH"))
    Dir.mktmpdir("rf-docs-plugin-test-") do |dir|
      bindir = File.join(dir, "bin")
      FileUtils.mkdir_p(bindir)
      stubs.each do |name, body|
        path = File.join(bindir, name)
        File.write(path, body)
        File.chmod(0o755, path)
      end
      Dir.chdir(dir) do
        run!("git", "init", "--quiet", "--initial-branch=feature/test")
        run!("git", "config", "user.email", "test@example.invalid")
        run!("git", "config", "user.name",  "Test")
        files.each do |relpath, content|
          FileUtils.mkdir_p(File.dirname(relpath))
          File.write(relpath, content)
          run!("git", "add", relpath)
        end
        env = { "PATH" => "#{bindir}:#{base_path}" }
        out, err, status = Open3.capture3(env, DOCS_PLUGINS.fetch(plugin))
        yield(out, err, status, dir)
      end
    end
  end

  def calls
    File.exist?("calls.log") ? File.read("calls.log").split("\n") : []
  end

  def run!(*cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "command failed: #{cmd.inspect}\nstdout: #{out}\nstderr: #{err}" unless status.success?
    [out, err]
  end
end

# A stub that appends "<name> <argv0>" to ./calls.log and exits as told, so a
# test can assert which tool (and which subcommand) ran.
def tool_stub(name, exit_code: 0)
  <<~SH
    #!/bin/sh
    printf '#{name} %s\\n' "$1" >> "$PWD/calls.log"
    exit #{exit_code}
  SH
end

RSpec.describe "documentation pre-commit plugins" do
  include DocsPluginHelpers

  describe "15-prose (vale)" do
    it "runs vale on staged Markdown when .vale.ini is present" do
      files = { ".vale.ini" => "MinAlertLevel = error\n", "doc.md" => "text\n" }
      with_docs_plugin(:prose, files, stubs: { "vale" => tool_stub("vale") }) do |_out, _err, status|
        expect(status).to be_success
        expect(calls).to include("vale doc.md")
      end
    end

    it "fails the commit when vale reports errors" do
      files = { ".vale.ini" => "MinAlertLevel = error\n", "doc.md" => "text\n" }
      with_docs_plugin(:prose, files, stubs: { "vale" => tool_stub("vale", exit_code: 1) }) do |_out, _err, status|
        expect(status).not_to be_success
      end
    end

    it "does not run vale when no Markdown is staged" do
      files = { ".vale.ini" => "MinAlertLevel = error\n", "code.sh" => "true\n" }
      with_docs_plugin(:prose, files, stubs: { "vale" => tool_stub("vale") }) do |_out, _err, status|
        expect(status).to be_success
        expect(calls).to be_empty
      end
    end

    it "warns and skips when .vale.ini is absent" do
      with_docs_plugin(:prose, { "doc.md" => "text\n" }, stubs: { "vale" => tool_stub("vale") }) do |_out, err, status|
        expect(status).to be_success
        expect(err).to include(".vale.ini not found")
        expect(calls).to be_empty
      end
    end

    it "warns and skips when vale is not installed" do
      # No vale stub and a PATH of only /usr/bin:/bin (git, grep — but no
      # Homebrew tools), so `command -v vale` genuinely fails.
      files = { ".vale.ini" => "MinAlertLevel = error\n", "doc.md" => "text\n" }
      with_docs_plugin(:prose, files, base_path: "/usr/bin:/bin") do |_out, err, status|
        expect(status).to be_success
        expect(err).to include("vale not found")
      end
    end
  end

  describe "10-markdown (rumdl)" do
    it "formats, re-stages, and checks staged Markdown" do
      files = { "doc.md" => "text\n" }
      with_docs_plugin(:markdown, files, stubs: { "rumdl" => tool_stub("rumdl") }) do |_out, _err, status|
        expect(status).to be_success
        expect(calls).to eq(["rumdl fmt", "rumdl check"])
      end
    end

    it "fails the commit when rumdl check fails" do
      # fmt is piped to /dev/null with `|| true`, so only check's exit
      # gates; a stub that always fails exercises exactly that path.
      files = { "doc.md" => "text\n" }
      with_docs_plugin(:markdown, files, stubs: { "rumdl" => tool_stub("rumdl", exit_code: 1) }) do |_out, _err, status|
        expect(status).not_to be_success
      end
    end

    it "never reformats a synced file (the do-not-modify header)" do
      files = { "synced.md" => "<!-- This file is synced; do not modify it directly. -->\ntext\n" }
      with_docs_plugin(:markdown, files, stubs: { "rumdl" => tool_stub("rumdl") }) do |_out, _err, status|
        expect(status).to be_success
        expect(calls).to be_empty
      end
    end

    it "does not run rumdl when no Markdown is staged" do
      with_docs_plugin(:markdown, { "code.sh" => "true\n" }, stubs: { "rumdl" => tool_stub("rumdl") }) do |_out, _err, status|
        expect(status).to be_success
        expect(calls).to be_empty
      end
    end
  end

  describe "50-adrs (adrs doctor)" do
    it "runs adrs doctor when an ADR is staged" do
      files = { "docs/decisions/0001-x.md" => "---\nnumber: 1\n---\n# X\n" }
      with_docs_plugin(:adrs, files, stubs: { "adrs" => tool_stub("adrs") }) do |_out, _err, status|
        expect(status).to be_success
        expect(calls).to include("adrs doctor")
      end
    end

    it "runs adrs doctor when adrs.toml is staged" do
      files = { "adrs.toml" => "adr_dir = \"docs/decisions\"\n" }
      with_docs_plugin(:adrs, files, stubs: { "adrs" => tool_stub("adrs") }) do |_out, _err, status|
        expect(status).to be_success
        expect(calls).to include("adrs doctor")
      end
    end

    it "stays inert when no ADR file is staged" do
      with_docs_plugin(:adrs, { "doc.md" => "text\n" }, stubs: { "adrs" => tool_stub("adrs") }) do |_out, _err, status|
        expect(status).to be_success
        expect(calls).to be_empty
      end
    end

    it "fails the commit when doctor reports errors" do
      files = { "docs/decisions/0001-x.md" => "---\nnumber: 1\n---\n# X\n" }
      with_docs_plugin(:adrs, files, stubs: { "adrs" => tool_stub("adrs", exit_code: 1) }) do |_out, _err, status|
        expect(status).not_to be_success
      end
    end
  end
end
