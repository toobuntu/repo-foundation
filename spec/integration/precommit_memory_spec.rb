# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "open3"
require "tmpdir"

# The 40-memory plugin enforces the append-only rule for .ai/memory.md and
# .ai/org/memory.md (ADR 0022, amended 2026-07-26). The rule used to be prose,
# and prose is what gets dropped: a queued item was lost in a wholesale rewrite
# on 2026-07-25. .ai/org/memory.md is the file that most needs the gate — it is
# canonical and syncs read-only to every consumer, so a silently dropped org
# fact propagates everywhere at the next sync.
#
# The plugin is driven directly rather than through the runner: it reads only
# the staged diff, so it needs no runner state, and calling it directly keeps
# the failure attributable to this plugin rather than to hook plumbing.
RSpec.describe "pre-commit plugin: .ai memory files are append-only" do
  let(:plugin_src) { File.expand_path("../../.githooks/pre-commit.d/40-memory", __dir__) }

  def sh!(*cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "command failed: #{cmd.inspect}\nstdout: #{out}\nstderr: #{err}" unless status.success?
  end

  # A repo with a committed memory file, plus the plugin at its natural path.
  def with_memory_repo(path)
    Dir.mktmpdir("rf-memory-test-") do |dir|
      Dir.chdir(dir) do
        sh!("git", "init", "--quiet", "--initial-branch=feature/test")
        sh!("git", "config", "user.email", "test@example.invalid")
        sh!("git", "config", "user.name", "Test")
        FileUtils.mkdir_p(".githooks/pre-commit.d")
        FileUtils.cp(plugin_src, ".githooks/pre-commit.d/40-memory")
        File.chmod(0o755, ".githooks/pre-commit.d/40-memory")

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, <<~MD)
          # Memory

          ## 2026-01-01 — First

          An established fact.

          - A bullet fact, whose removed-diff form starts with two hyphens.

          ## 2026-01-02 — Second

          Another established fact.
        MD
        sh!("git", "add", "-A")
        sh!("git", "commit", "--quiet", "--no-gpg-sign", "-m", "seed")
        yield dir
      end
    end
  end

  def run_plugin(env = {})
    Open3.capture3(env, "./.githooks/pre-commit.d/40-memory")
  end

  %w[.ai/memory.md .ai/org/memory.md].each do |path|
    context "for #{path}" do
      it "allows a pure append" do
        with_memory_repo(path) do
          File.write(path, "\n## 2026-01-03 — Third\n\nA new fact.\n", mode: "a")
          sh!("git", "add", path)
          _out, err, status = run_plugin
          expect(status.success?).to eq(true), "stderr=#{err.inspect}"
        end
      end

      it "rejects a removed line and names it" do
        with_memory_repo(path) do
          body = File.read(path).sub("An established fact.\n", "")
          File.write(path, body)
          sh!("git", "add", path)
          _out, err, status = run_plugin
          expect(status.success?).to eq(false)
          expect(err).to include("append-only")
          expect(err).to include("An established fact.")
          expect(err).to include("AI_MEMORY_ALLOW_REWRITE=1")
        end
      end

      it "rejects a removed bullet line, whose diff form begins with --" do
        # Regression: the original implementation excluded the `--- a/…` diff
        # header with the pattern ^-([^-]|$), which also excluded any removed
        # content line that itself begins with `-` — every Markdown bullet.
        with_memory_repo(path) do
          body = File.read(path)
                     .sub("- A bullet fact, whose removed-diff form starts with two hyphens.\n", "")
          File.write(path, body)
          sh!("git", "add", path)
          _out, err, status = run_plugin
          expect(status.success?).to eq(false)
          expect(err).to include("A bullet fact")
        end
      end

      it "is not bypassed by AI_MEMORY_ALLOW_REWRITE values other than 1" do
        # Enforcement gate, not a test seam: someone exporting the variable
        # as 0 to mean "do not bypass" must get enforcement.
        with_memory_repo(path) do
          body = File.read(path).sub("An established fact.\n", "")
          File.write(path, body)
          sh!("git", "add", path)
          _out, _err, status = run_plugin("AI_MEMORY_ALLOW_REWRITE" => "0")
          expect(status.success?).to eq(false)
        end
      end

      it "rejects an in-place edit, which is a removal plus an addition" do
        with_memory_repo(path) do
          body = File.read(path).sub("An established fact.", "A silently reworded fact.")
          File.write(path, body)
          sh!("git", "add", path)
          _out, _err, status = run_plugin
          expect(status.success?).to eq(false)
        end
      end

      it "lets AI_MEMORY_ALLOW_REWRITE through for the consolidation pass" do
        with_memory_repo(path) do
          File.write(path, "# Memory\n\nConsolidated.\n")
          sh!("git", "add", path)
          _out, _err, status = run_plugin("AI_MEMORY_ALLOW_REWRITE" => "1")
          expect(status.success?).to eq(true)
        end
      end
    end
  end

  it "ignores an unrelated staged file" do
    with_memory_repo(".ai/memory.md") do
      File.write("other.md", "unrelated\n")
      sh!("git", "add", "other.md")
      _out, _err, status = run_plugin
      expect(status.success?).to eq(true)
    end
  end

  it "passes when the memory file is newly added, having nothing to remove" do
    Dir.mktmpdir("rf-memory-new-") do |dir|
      Dir.chdir(dir) do
        sh!("git", "init", "--quiet", "--initial-branch=feature/test")
        sh!("git", "config", "user.email", "test@example.invalid")
        sh!("git", "config", "user.name", "Test")
        FileUtils.mkdir_p(".githooks/pre-commit.d")
        FileUtils.cp(plugin_src, ".githooks/pre-commit.d/40-memory")
        File.chmod(0o755, ".githooks/pre-commit.d/40-memory")
        FileUtils.mkdir_p(".ai")
        File.write(".ai/memory.md", "# Memory\n")
        sh!("git", "add", ".ai/memory.md")
        _out, _err, status = run_plugin
        expect(status.success?).to eq(true)
      end
    end
  end
end
