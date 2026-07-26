# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "open3"
require "tmpdir"

# Behavioral tests for the .githooks/pre-commit RUNNER itself, as distinct
# from the checks it runs. Since the runner refactor the base hook performs
# no checks of its own: it blocks commits to main, computes the staged-file
# list once, and runs the pre-commit.d plugins. The contract that every
# plugin depends on is PRE_COMMIT_STAGED_LIST -- the path to a NUL-delimited
# list of staged paths -- so these pin it with a recording plugin rather than
# a real check.
RSpec.describe "pre-commit runner" do
  RUNNER_SRC = File.join(REPO_ROOT, ".githooks", "pre-commit")

  def run!(*cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "command failed: #{cmd.inspect}\nstdout: #{out}\nstderr: #{err}" unless status.success?
    [out, err]
  end

  # A throwaway repo carrying the real runner plus whatever plugins the
  # example installs. `plugins` maps a run-parts name to its script body.
  def with_runner(plugins, files: { "staged.txt" => "content\n" }, branch: "feature/test")
    Dir.mktmpdir("rf-runner-test-") do |dir|
      Dir.chdir(dir) do
        run!("git", "init", "--quiet", "--initial-branch=#{branch}")
        run!("git", "config", "user.email", "test@example.invalid")
        run!("git", "config", "user.name", "Test")
        FileUtils.mkdir_p(".githooks/pre-commit.d")
        FileUtils.cp(RUNNER_SRC, ".githooks/pre-commit")
        File.chmod(0o755, ".githooks/pre-commit")
        plugins.each do |name, body|
          path = ".githooks/pre-commit.d/#{name}"
          File.write(path, body)
          File.chmod(0o755, path)
        end
        run!("git", "config", "core.hooksPath", ".githooks")
        files.each do |relpath, content|
          FileUtils.mkdir_p(File.dirname(relpath))
          File.write(relpath, content)
          run!("git", "add", relpath)
        end
        out, err, status = Open3.capture3(
          { "GIT_DIR" => ".git", "GIT_INDEX_FILE" => ".git/index" },
          "./.githooks/pre-commit"
        )
        yield dir, out, err, status
      end
    end
  end

  # Records the exported variable and the list's contents, with NULs turned
  # into newlines so the expectation can read them.
  RECORDER = <<~SH
    #!/bin/sh
    printf 'VAR=%s\\n' "${PRE_COMMIT_STAGED_LIST:-UNSET}" > recorded.txt
    if [ -r "${PRE_COMMIT_STAGED_LIST:-/nonexistent}" ]; then
      tr '\\0' '\\n' < "$PRE_COMMIT_STAGED_LIST" >> recorded.txt
    fi
  SH

  it "exports PRE_COMMIT_STAGED_LIST and a plugin receives the staged set" do
    with_runner({ "10-recorder" => RECORDER },
                files: { "alpha.txt" => "a\n", "nested/beta.md" => "b\n" }) do |_dir, _out, err, status|
      expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      recorded = File.read("recorded.txt")
      expect(recorded).not_to include("VAR=UNSET")
      expect(recorded).to include("alpha.txt")
      expect(recorded).to include("nested/beta.md")
    end
  end

  it "removes the staged-list temp file when the hook exits" do
    with_runner({ "10-recorder" => RECORDER }) do |_dir, _out, err, status|
      expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      path = File.read("recorded.txt")[/VAR=(.*)/, 1]
      expect(path).not_to be_nil
      expect(File.exist?(path)).to eq(false)
    end
  end

  it "surfaces a failing plugin's exit code and stops there" do
    plugins = {
      "10-fails" => "#!/bin/sh\nprintf 'plugin said no\\n' >&2\nexit 3\n",
      "20-later" => "#!/bin/sh\n: > later-ran.txt\n"
    }
    with_runner(plugins) do |_dir, _out, err, status|
      expect(status.exitstatus).to eq(3)
      expect(err).to include("plugin said no")
      expect(File.exist?("later-ran.txt")).to eq(false)
    end
  end

  it "runs plugins in sorted order, so the verifier tier follows the format tier" do
    plugins = {
      "10-first" => "#!/bin/sh\nprintf '10\\n' >> order.txt\n",
      "80-third" => "#!/bin/sh\nprintf '80\\n' >> order.txt\n",
      "20-second" => "#!/bin/sh\nprintf '20\\n' >> order.txt\n",
      "85-fourth" => "#!/bin/sh\nprintf '85\\n' >> order.txt\n"
    }
    with_runner(plugins) do |_dir, _out, err, status|
      expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      expect(File.read("order.txt").split).to eq(%w[10 20 80 85])
    end
  end

  it "skips a plugin disabled by a dot suffix, per run-parts" do
    plugins = {
      "10-on" => "#!/bin/sh\n: > on-ran.txt\n",
      "10-off.disabled" => "#!/bin/sh\n: > off-ran.txt\n"
    }
    with_runner(plugins) do |_dir, _out, err, status|
      expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      expect(File.exist?("on-ran.txt")).to eq(true)
      expect(File.exist?("off-ran.txt")).to eq(false)
    end
  end

  it "blocks a commit on main before running any plugin" do
    with_runner({ "10-recorder" => RECORDER }, branch: "main") do |_dir, _out, err, status|
      expect(status.success?).to eq(false)
      expect(err).to include("direct commits to main are not allowed")
      expect(File.exist?("recorded.txt")).to eq(false)
    end
  end
end
