# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "json"
require "open3"
require "tmpdir"

# scripts/ai/guard-main.sh is the PostToolUse half of the main-branch guard: the
# PreToolUse half matches Edit/Write/MultiEdit, so every shell write bypasses
# it, and this one watches the EFFECT instead. A guard nobody has made fire is
# a guard that may not fire at all (repo-foundation has shipped two that did
# not), so each case below drives the script and asserts the exit status the
# hook contract depends on: 2 to surface stderr to the agent, 0 to stay quiet.
#
# The script is run with the throwaway repository as its working directory
# rather than copied into it — it resolves the repository from the CWD, the
# same way scripts/ai/ai-session.sh does, and running the committed file is what
# the hook will run.
RSpec.describe "scripts/ai/guard-main.sh" do
  let(:script) { File.expand_path("../../scripts/ai/guard-main.sh", __dir__) }

  def sh!(dir, *cmd)
    out, err, status = Open3.capture3(*cmd, chdir: dir)
    raise "command failed: #{cmd.inspect}\nstdout: #{out}\nstderr: #{err}" unless status.success?
  end

  def guard(dir, subcommand)
    Open3.capture3(script, subcommand, chdir: dir)
  end

  # A repository on `main` with one committed file, and nothing dirty.
  def with_repo
    Dir.mktmpdir("rf-main-guard-") do |dir|
      sh!(dir, "git", "init", "--quiet", "--initial-branch=main")
      sh!(dir, "git", "config", "user.email", "test@example.invalid")
      sh!(dir, "git", "config", "user.name", "Test")
      File.write(File.join(dir, "tracked.txt"), "original\n")
      sh!(dir, "git", "add", "-A")
      sh!(dir, "git", "commit", "--quiet", "--no-gpg-sign", "-m", "seed")
      yield dir
    end
  end

  it "reports a tracked file modified after the seed" do
    with_repo do |dir|
      guard(dir, "seed")
      File.write(File.join(dir, "tracked.txt"), "changed by a shell write\n")

      _out, err, status = guard(dir, "check")

      expect(status.exitstatus).to eq(2)
      expect(err).to include("tracked.txt")
      expect(err).to include("git switch -c")
    end
  end

  # The bypass that motivated the guard wrote a NEW file through a heredoc, so
  # untracked content has to count as dirty; `git status --porcelain` reports
  # it as `??` and the guard must not filter that away.
  it "reports a file created after the seed" do
    with_repo do |dir|
      guard(dir, "seed")
      File.write(File.join(dir, "created.txt"), "written through a shell\n")

      _out, err, status = guard(dir, "check")

      expect(status.exitstatus).to eq(2)
      expect(err).to include("created.txt")
    end
  end

  # `git status --porcelain` honors status.showUntrackedFiles, so a repository
  # configured to hide untracked files would hide the exact bypass this guard
  # exists to catch. The flag is passed explicitly; this proves it wins.
  it "still reports a new file when the repository hides untracked files" do
    with_repo do |dir|
      sh!(dir, "git", "config", "status.showUntrackedFiles", "no")
      guard(dir, "seed")
      File.write(File.join(dir, "created.txt"), "written through a shell\n")

      _out, err, status = guard(dir, "check")

      expect(status.exitstatus).to eq(2)
      expect(err).to include("created.txt")
    end
  end

  it "stays silent about changes that were already there at the seed" do
    with_repo do |dir|
      File.write(File.join(dir, "tracked.txt"), "the maintainer's own work in progress\n")
      guard(dir, "seed")

      _out, err, status = guard(dir, "check")

      expect(status.exitstatus).to eq(0)
      expect(err).to be_empty
    end
  end

  it "stays silent on a branch that is not main" do
    with_repo do |dir|
      guard(dir, "seed")
      sh!(dir, "git", "switch", "--quiet", "-c", "feature/topic")
      File.write(File.join(dir, "tracked.txt"), "edited on a branch, which is the point\n")

      _out, err, status = guard(dir, "check")

      expect(status.exitstatus).to eq(0)
      expect(err).to be_empty
    end
  end

  # PostToolUse fires after every Bash call. A finding that repeated until the
  # tree went clean would bury the recovery it is asking for, so the record
  # absorbs the finding and the second check is quiet.
  it "reports a given path once, not after every later call" do
    with_repo do |dir|
      guard(dir, "seed")
      File.write(File.join(dir, "tracked.txt"), "changed\n")

      expect(guard(dir, "check").last.exitstatus).to eq(2)
      expect(guard(dir, "check").last.exitstatus).to eq(0)
    end
  end

  it "reports a second path dirtied after the first was absorbed" do
    with_repo do |dir|
      guard(dir, "seed")
      File.write(File.join(dir, "tracked.txt"), "changed\n")
      guard(dir, "check")
      File.write(File.join(dir, "second.txt"), "also changed\n")

      _out, err, status = guard(dir, "check")

      expect(status.exitstatus).to eq(2)
      expect(err).to include("second.txt")
      expect(err).not_to include("tracked.txt")
    end
  end

  # Without a seed the guard cannot tell this call's damage from what was
  # already there, so it adopts the state rather than blaming the caller.
  it "adopts the current state when no seed exists, and reports afterwards" do
    with_repo do |dir|
      File.write(File.join(dir, "tracked.txt"), "pre-existing\n")

      expect(guard(dir, "check").last.exitstatus).to eq(0)

      File.write(File.join(dir, "later.txt"), "written after the adoption\n")
      _out, err, status = guard(dir, "check")

      expect(status.exitstatus).to eq(2)
      expect(err).to include("later.txt")
    end
  end

  # The record is a plain file in .git/ — never reported by `git status`, so it
  # cannot become a finding of its own, and needing no .gitignore entry in any
  # consumer.
  it "keeps its record inside .git/ and out of git status" do
    with_repo do |dir|
      guard(dir, "seed")

      expect(File).to exist(File.join(dir, ".git", "claude-main-guard"))
      porcelain, = Open3.capture3("git", "status", "--porcelain", chdir: dir)
      expect(porcelain).to be_empty
    end
  end

  it "is a no-op outside a git repository" do
    Dir.mktmpdir("rf-main-guard-bare-") do |dir|
      expect(guard(dir, "seed").last.exitstatus).to eq(0)
      expect(guard(dir, "check").last.exitstatus).to eq(0)
    end
  end

  it "rejects an unknown subcommand with usage" do
    with_repo do |dir|
      _out, err, status = guard(dir, "sniff")

      expect(status.exitstatus).to eq(2)
      expect(err).to include("Usage:")
    end
  end

  # The PreToolUse half. Exemption rationale: branches do not version
  # untracked files, so refusing .ai/progress.md on main protected nothing —
  # but the exemption must stay path-scoped and each exempted write must be
  # logged, or the visibility the old ceremony gave is silently lost.
  describe "pre" do
    def pre(dir, file_path)
      payload = JSON.generate({ tool_input: { file_path: file_path } })
      Open3.capture3({ "CLAUDE_PROJECT_DIR" => dir }, script, "pre",
                     chdir: dir, stdin_data: payload)
    end

    it "refuses a tracked-file edit on main" do
      with_repo do |dir|
        _out, err, status = pre(dir, File.join(dir, "tracked.txt"))
        expect(status.exitstatus).to eq(2)
        expect(err).to include("git switch -c")
      end
    end

    it "exempts the continuity files on main, and logs each write" do
      with_repo do |dir|
        FileUtils.mkdir_p(File.join(dir, ".ai", "scratchpad"))
        [".ai/progress.md", ".ai/scratchpad/commit-msg-x.md"].each do |rel|
          _out, _err, status = pre(dir, File.join(dir, rel))
          expect(status.exitstatus).to eq(0), "#{rel} must be exempt on main"
        end
        log = File.read(File.join(dir, ".git", "claude-exempt-writes"))
        expect(log).to include(".ai/progress.md")
        expect(log).to include(".ai/scratchpad/commit-msg-x.md")
      end
    end

    it "allows everything on a feature branch without logging" do
      with_repo do |dir|
        sh!(dir, "git", "switch", "--quiet", "-c", "feature/x")
        _out, _err, status = pre(dir, File.join(dir, "tracked.txt"))
        expect(status.exitstatus).to eq(0)
        expect(File).not_to exist(File.join(dir, ".git", "claude-exempt-writes"))
      end
    end

    it "leaves paths outside the project tree alone" do
      with_repo do |dir|
        _out, _err, status = pre(dir, "/somewhere/else.txt")
        expect(status.exitstatus).to eq(0)
      end
    end
  end
end
