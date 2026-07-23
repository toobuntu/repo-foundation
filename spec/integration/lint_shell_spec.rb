# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "open3"
require "tmpdir"

# Behavioral tests for scripts/lint-shell.sh — the dialect-aware shell linter
# the 10-shell plugin (--staged) and the shell-lint CI job (--tracked) share.
# The interesting behavior is the dialect split: ksh93 files (a .ksh extension
# or a ksh shebang) get `ksh -n` + `shellcheck --shell=ksh` but NOT shfmt; sh
# and bash files get shfmt + shellcheck with the dialect from the shebang.
#
# Stub ksh / shfmt / shellcheck on PATH (each logs its file argument), so the
# routing is asserted without a real toolchain. The default --tracked mode
# runs over `git ls-files`, so tests init a repo and stage the samples.
LINT_SHELL = File.join(REPO_ROOT, "scripts", "lint-shell.sh")

module LintShellHelpers
  def with_lint_shell(files, args: [], stubs: {}, base_path: ENV.fetch("PATH"))
    Dir.mktmpdir("rf-lint-shell-test-") do |dir|
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
          File.chmod(0o755, relpath) if content.start_with?("#!")
          run!("git", "add", relpath)
        end
        env = { "PATH" => "#{bindir}:#{base_path}" }
        out, err, status = Open3.capture3(env, "sh", LINT_SHELL, *args)
        yield(out, err, status, dir)
      end
    end
  end

  # Lines logged to ./calls.log as "tool arg", one per stub invocation.
  def calls
    File.exist?("calls.log") ? File.read("calls.log").split("\n") : []
  end

  def run!(*cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "command failed: #{cmd.inspect}\nstdout: #{out}\nstderr: #{err}" unless status.success?
    [out, err]
  end
end

# Stub logging each invocation's LAST argument (lint-shell passes the file
# last: `shfmt --diff -- FILE`, `shellcheck … -- FILE`, `ksh -n FILE`).
def lint_stub(name, exit_code: 0)
  <<~SH
    #!/bin/sh
    for last in "$@"; do :; done
    printf '#{name} %s\\n' "$last" >> "$PWD/calls.log"
    exit #{exit_code}
  SH
end

def stubs(**overrides)
  base = {
    "ksh"        => lint_stub("ksh"),
    "shfmt"      => lint_stub("shfmt"),
    "shellcheck" => lint_stub("shellcheck"),
  }
  overrides.each { |k, v| base[k.to_s] = v }
  base
end

RSpec.describe "scripts/lint-shell.sh" do
  include LintShellHelpers

  it "gives sh/bash files shfmt + shellcheck + ksh -n, but never shfmt on ksh" do
    files = {
      "posix.sh" => "#!/bin/sh\ntrue\n",
      "tool.ksh" => "#!/usr/bin/env ksh\ntrue\n",
    }
    with_lint_shell(files, stubs: stubs) do |_o, _e, status|
      expect(status).to be_success
      # shfmt only on the sh file, never on the ksh file.
      expect(calls).to include("shfmt posix.sh")
      expect(calls).not_to include("shfmt tool.ksh")
      # shellcheck on both; ksh syntax pass over both (ksh -n runs on all).
      expect(calls).to include("shellcheck posix.sh")
      expect(calls).to include("shellcheck tool.ksh")
      expect(calls).to include("ksh posix.sh")
      expect(calls).to include("ksh tool.ksh")
    end
  end

  it "detects a ksh dialect from the shebang, not just the extension" do
    files = { "admin" => "#!/bin/ksh\ntrue\n" } # no extension, ksh shebang
    with_lint_shell(files, stubs: stubs) do |_o, _e, status|
      expect(status).to be_success
      expect(calls).not_to include("shfmt admin") # treated as ksh
      expect(calls).to include("ksh admin")
    end
  end

  it "ignores non-shell files" do
    with_lint_shell({ "readme.md" => "hi\n" }, stubs: stubs) do |_o, _e, status|
      expect(status).to be_success
      expect(calls).to be_empty
    end
  end

  it "fails when shellcheck reports a finding" do
    files = { "posix.sh" => "#!/bin/sh\ntrue\n" }
    with_lint_shell(files, stubs: stubs(shellcheck: lint_stub("shellcheck", exit_code: 1))) do |_o, _e, status|
      expect(status).not_to be_success
    end
  end

  it "fails when shfmt reports a diff" do
    files = { "posix.sh" => "#!/bin/sh\ntrue\n" }
    with_lint_shell(files, stubs: stubs(shfmt: lint_stub("shfmt", exit_code: 1))) do |_o, _e, status|
      expect(status).not_to be_success
    end
  end

  it "limits --staged to files in the index diff" do
    files = { "staged.sh" => "#!/bin/sh\ntrue\n" }
    with_lint_shell(files, args: ["--staged"], stubs: stubs) do |_o, _e, status|
      expect(status).to be_success
      expect(calls).to include("shellcheck staged.sh")
    end
  end

  it "skips ksh -n gracefully when ksh is absent (Linux-runner case)" do
    # ksh's location is not fixed (stock /bin on macOS, but a Homebrew or Linux
    # install lives elsewhere), so rather than exclude a path, build a bindir
    # holding symlinks to exactly the externals lint-shell calls — with ksh
    # deliberately NOT among them — and run under PATH=bindir alone. The script
    # is executed directly so its #!/bin/sh shebang resolves absolutely. This
    # guarantees `command -v ksh` fails on any platform.
    externals = %w[git grep head mktemp rm xargs].to_h do |t|
      [t, `command -v #{t}`.strip]
    end
    raise "missing host tool(s): #{externals.select { |_, p| p.empty? }.keys}" if externals.value?("")

    Dir.mktmpdir("rf-lint-shell-noksh-") do |dir|
      bindir = File.join(dir, "bin")
      FileUtils.mkdir_p(bindir)
      externals.each { |name, target| File.symlink(target, File.join(bindir, name)) }
      %w[shfmt shellcheck].each do |name|
        path = File.join(bindir, name)
        File.write(path, lint_stub(name))
        File.chmod(0o755, path)
      end
      Dir.chdir(dir) do
        run!("git", "init", "--quiet", "--initial-branch=feature/test")
        run!("git", "config", "user.email", "test@example.invalid")
        run!("git", "config", "user.name", "Test")
        File.write("posix.sh", "#!/bin/sh\ntrue\n")
        File.chmod(0o755, "posix.sh")
        run!("git", "add", "posix.sh")

        out, err, status = Open3.capture3({ "PATH" => bindir }, LINT_SHELL)
        expect(status).to be_success, "stdout: #{out}\nstderr: #{err}"
        expect(err).to include("ksh not found")
        log = File.exist?("calls.log") ? File.read("calls.log") : ""
        expect(log).to include("shfmt posix.sh")
        expect(log).to include("shellcheck posix.sh")
      end
    end
  end
end
