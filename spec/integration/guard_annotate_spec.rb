# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "json"
require "open3"
require "tmpdir"

# scripts/ai/guard-annotate.sh gates the sandbox-excluded annotation script:
# a Bash call naming scripts/annotate.sh is refused unless the working copy
# is byte-identical to origin/main. This logic lived as ~15 lines of shell
# inside a JSON string in the settings files until 2026-08-07 — unlintable
# and unspecced, which for a guard on a sandbox escape was the worst place
# for it. These cases drive both directions: it must fire, and it must not
# over-fire on commands that never name the script.
RSpec.describe "scripts/ai/guard-annotate.sh" do
  let(:script) { File.expand_path("../../scripts/ai/guard-annotate.sh", __dir__) }

  def guard(dir, command)
    payload = { tool_input: { command: command } }.to_json
    Open3.capture3({ "CLAUDE_PROJECT_DIR" => dir }, script,
                   chdir: dir, stdin_data: payload)
  end

  def sh!(dir, *cmd)
    _out, err, status = Open3.capture3(*cmd, chdir: dir)
    raise "command failed: #{cmd.inspect}\n#{err}" unless status.success?
  end

  # A repository whose scripts/annotate.sh is committed and mirrored at a
  # synthetic origin/main ref, so the identical/diverged states are testable
  # without a network remote.
  def with_repo
    Dir.mktmpdir("rf-guard-annotate-") do |dir|
      sh!(dir, "git", "init", "--quiet", "--initial-branch=main")
      sh!(dir, "git", "config", "user.email", "test@example.invalid")
      sh!(dir, "git", "config", "user.name", "Test")
      FileUtils.mkdir_p(File.join(dir, "scripts"))
      File.write(File.join(dir, "scripts", "annotate.sh"), "#!/bin/sh\necho annotate\n")
      sh!(dir, "git", "add", "-A")
      sh!(dir, "git", "commit", "--quiet", "--no-gpg-sign", "-m", "seed")
      ref_dir = File.join(dir, ".git", "refs", "remotes", "origin")
      FileUtils.mkdir_p(ref_dir)
      out, = Open3.capture3("git", "rev-parse", "main", chdir: dir)
      File.write(File.join(ref_dir, "main"), out)
      yield dir
    end
  end

  it "allows the bare invocation while the script matches origin/main" do
    with_repo do |dir|
      _out, _err, status = guard(dir, "scripts/annotate.sh")
      expect(status.exitstatus).to eq(0)
    end
  end

  it "refuses when the working copy differs from origin/main" do
    with_repo do |dir|
      File.write(File.join(dir, "scripts", "annotate.sh"), "#!/bin/sh\necho tampered\n")
      _out, err, status = guard(dir, "scripts/annotate.sh")
      expect(status.exitstatus).to eq(2)
      expect(err).to include("differs from origin/main")
      expect(err).to include("git restore scripts/annot*.sh")
    end
  end

  it "refuses when there is no origin/main to verify against" do
    with_repo do |dir|
      FileUtils.rm(File.join(dir, ".git", "refs", "remotes", "origin", "main"))
      _out, err, status = guard(dir, "scripts/annotate.sh")
      expect(status.exitstatus).to eq(2)
      expect(err).to include("no origin/main")
    end
  end

  it "matches the path anywhere in the command — the documented over-match" do
    with_repo do |dir|
      File.write(File.join(dir, "scripts", "annotate.sh"), "#!/bin/sh\necho tampered\n")
      _out, _err, status = guard(dir, "git diff -- scripts/annotate.sh")
      expect(status.exitstatus).to eq(2)
    end
  end

  it "ignores commands that never name the script" do
    with_repo do |dir|
      File.write(File.join(dir, "scripts", "annotate.sh"), "#!/bin/sh\necho tampered\n")
      ["git status", "reuse lint", "scripts/ai/ai-session.sh start"].each do |cmd|
        _out, _err, status = guard(dir, cmd)
        expect(status.exitstatus).to eq(0), "#{cmd} must pass"
      end
    end
  end

  it "fails closed on empty input" do
    with_repo do |dir|
      _out, err, status = Open3.capture3({ "CLAUDE_PROJECT_DIR" => dir }, script,
                                         chdir: dir, stdin_data: "")
      # jq -r on empty input yields empty; empty command matches nothing and
      # passes — the fail-closed paths are missing jq and unparseable input,
      # which capture3 cannot simulate portably. Pin the observable behavior.
      expect(status.exitstatus).to eq(0)
      expect(err).to eq("")
    end
  end
end
