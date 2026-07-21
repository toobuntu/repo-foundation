# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "open3"
require "tmpdir"

# Behavioral tests for provides/githooks/pre-commit.d/20-swift, the Swift
# pre-commit plugin (swiftformat auto-fix + re-stage, then swiftlint).
#
# The plugin is invoked directly in a throwaway git repository with stub
# swiftformat / swiftlint executables prepended to PATH, so the tests are
# self-contained and need no real Swift toolchain. The stubs shadow any real
# install, keeping the present-tool cases deterministic on any machine.

SWIFT_PLUGIN_PATH = File.join(REPO_ROOT, "provides", "githooks", "pre-commit.d", "20-swift")

module SwiftPluginHelpers
  # Create a temp git repo on a feature branch, prepend a stub bin dir to PATH,
  # write and stage the given files, run the plugin, and yield its result plus
  # the working directory for post-hoc index inspection.
  #
  # stubs: { "swiftformat" => "<sh script body>", ... } — each becomes an
  # executable on PATH ahead of any real tool. Omit a tool to simulate its
  # absence (the plugin then warns and skips that step).
  # The stub bindir is prepended to the inherited PATH, so a stub shadows any
  # real tool of the same name and the present-tool cases stay deterministic on
  # any host; git and the coreutils still resolve from the inherited PATH.
  def with_plugin(files, stubs: {})
    Dir.mktmpdir("rf-swift-test-") do |dir|
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
        env = { "PATH" => "#{bindir}:#{ENV.fetch('PATH')}" }
        out, err, status = Open3.capture3(env, SWIFT_PLUGIN_PATH)
        yield(out, err, status, dir)
      end
    end
  end

  # The staged (index) content of a path, for asserting a re-stage happened.
  def staged_blob(path)
    out, _, status = Open3.capture3("git", "show", ":#{path}")
    status.success? ? out : nil
  end

  def run!(*cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "command failed: #{cmd.inspect}\nstdout: #{out}\nstderr: #{err}" unless status.success?
    [out, err]
  end
end

# A stub that records each invocation by appending its name to ./calls.log,
# so a test can assert a tool was (or was not) run.
def logging_stub(name, exit_code: 0, append_to_args: nil)
  body = +"#!/bin/sh\n"
  body << "printf '#{name}\\n' >> \"$PWD/calls.log\"\n"
  body << "for f in \"$@\"; do case \"$f\" in *.swift) printf '#{append_to_args}\\n' >> \"$f\" ;; esac; done\n" if append_to_args
  body << "exit #{exit_code}\n"
  body
end

RSpec.describe "pre-commit plugin: 20-swift" do
  include SwiftPluginHelpers

  it "is a no-op (exit 0) when no .swift files are staged" do
    stubs = { "swiftformat" => logging_stub("swiftformat"),
              "swiftlint"   => logging_stub("swiftlint") }
    with_plugin({ "README.md" => "# hi\n" }, stubs: stubs) do |_out, err, status, dir|
      expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      expect(File.exist?(File.join(dir, "calls.log"))).to eq(false)
    end
  end

  it "passes when swiftformat and swiftlint both succeed" do
    stubs = { "swiftformat" => logging_stub("swiftformat"),
              "swiftlint"   => logging_stub("swiftlint") }
    with_plugin({ "a.swift" => "let x = 1\n" }, stubs: stubs) do |_out, err, status, dir|
      expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      log = File.read(File.join(dir, "calls.log"))
      expect(log).to include("swiftformat")
      expect(log).to include("swiftlint")
    end
  end

  it "fails the commit when swiftlint reports a violation" do
    stubs = { "swiftformat" => logging_stub("swiftformat"),
              "swiftlint"   => logging_stub("swiftlint", exit_code: 1) }
    with_plugin({ "a.swift" => "let x=1\n" }, stubs: stubs) do |_out, _err, status, _dir|
      expect(status.success?).to eq(false)
    end
  end

  it "re-stages a file that swiftformat reformats" do
    stubs = { "swiftformat" => logging_stub("swiftformat", append_to_args: "// formatted"),
              "swiftlint"   => logging_stub("swiftlint") }
    with_plugin({ "a.swift" => "let x = 1\n" }, stubs: stubs) do |_out, err, status, _dir|
      expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      expect(staged_blob("a.swift")).to include("// formatted")
    end
  end

  # The swiftformat/swiftlint-absent path (command -v … || print a hint, skip)
  # mirrors the base hook's actionlint/zizmor handling and is not re-tested here:
  # forcing tool-absence needs a controlled PATH, which breaks the symlinked git
  # the throwaway repo relies on. The four cases above pin the meaningful logic
  # (gate on staged .swift, run both tools, fail on a violation, re-stage a fix).
end
