# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "open3"
require "tmpdir"

# Behavioral tests for the per-language pre-commit plugin masters under
# provides/githooks/pre-commit.d/: 20-go, 20-objc, 20-brew. Same stub pattern
# as the Swift and docs-plugin specs — each plugin runs in a throwaway git
# repository with stub tools prepended to PATH, so no real Go / clang / brew
# toolchain is needed and a stub shadows any installed copy.

LANG_PLUGINS = {
  go:   File.join(REPO_ROOT, "provides", "githooks", "pre-commit.d", "20-go"),
  objc: File.join(REPO_ROOT, "provides", "githooks", "pre-commit.d", "20-objc"),
  brew: File.join(REPO_ROOT, "provides", "githooks", "pre-commit.d", "20-brew"),
}.freeze

module LangPluginHelpers
  # base_path replaces the inherited PATH so an absent tool can be simulated;
  # keep /usr/bin:/bin available so git and the coreutils still resolve.
  def with_lang_plugin(plugin, files, stubs: {}, base_path: ENV.fetch("PATH"))
    Dir.mktmpdir("rf-lang-plugin-test-") do |dir|
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
        out, err, status = Open3.capture3(env, LANG_PLUGINS.fetch(plugin))
        yield(out, err, status, dir)
      end
    end
  end

  def calls
    File.exist?("calls.log") ? File.read("calls.log").split("\n") : []
  end

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

# Stub that logs "name arg1" to ./calls.log and exits as told. append_line, if
# given, is appended to each argument that names a file (to simulate an
# in-place formatter, so a re-stage can be asserted).
def cmd_stub(name, exit_code: 0, append_line: nil)
  body = +"#!/bin/sh\n"
  body << %(printf '#{name} %s\\n' "$1" >> "$PWD/calls.log"\n)
  if append_line
    body << %(for a in "$@"; do [ -f "$a" ] && printf '#{append_line}\\n' >> "$a"; done\n)
  end
  body << "exit #{exit_code}\n"
  body
end

RSpec.describe "language pre-commit plugins" do
  include LangPluginHelpers

  describe "20-go" do
    # staticcheck is optional (command -v gate); stub it so a host install
    # does not run a real analysis against the fake package.
    go_stubs = lambda do |**over|
      {
        "gofmt"       => cmd_stub("gofmt", append_line: "// formatted"),
        "go"          => cmd_stub("go", **over),
        "staticcheck" => cmd_stub("staticcheck"),
      }
    end

    it "gofmt-formats and re-stages staged Go, then vets" do
      with_lang_plugin(:go, { "main.go" => "package main\n" }, stubs: go_stubs.call) do |_o, _e, status|
        expect(status).to be_success
        # gofmt is invoked `gofmt -w <files>`; the re-staged formatting proves
        # it acted on main.go, and the log confirms the -w (in-place) form.
        expect(calls).to include("gofmt -w")
        expect(staged_blob("main.go")).to include("// formatted") # formatted + re-staged
        expect(calls).to include("go mod")   # go mod tidy -diff
        expect(calls).to include("go vet")   # go vet ./...
        expect(calls).to include("staticcheck ./...")
      end
    end

    it "does not run the go toolchain when no Go is staged" do
      with_lang_plugin(:go, { "readme.md" => "hi\n" }, stubs: go_stubs.call) do |_o, _e, status|
        expect(status).to be_success
        expect(calls).to be_empty
      end
    end

    it "fails the commit when go vet fails" do
      with_lang_plugin(:go, { "main.go" => "package main\n" }, stubs: go_stubs.call(exit_code: 1)) do |_o, _e, status|
        expect(status).not_to be_success
      end
    end
  end

  describe "20-objc" do
    # The plugin's two macOS paths are stubbed together so a staged .m
    # exercises both: `xcrun clang-format` (the --find probe plus the format
    # run) and `clang-tidy` (present on PATH, so the plugin's `command -v`
    # probe selects it over the brew-LLVM fallback). Objective-C is macOS-only
    # here, so the cases are gated to darwin (spec.yml runs on macOS).
    def xcrun_stub(format_exit: 0)
      <<~SH
        #!/bin/sh
        case "$1" in
          --find) exit 0 ;;
          clang-format) printf 'clang-format\\n' >> "$PWD/calls.log"; exit #{format_exit} ;;
        esac
        exit 0
      SH
    end

    it "runs clang-format and clang-tidy on a staged .m (macOS)", if: RUBY_PLATFORM.include?("darwin") do
      stubs = { "xcrun" => xcrun_stub, "clang-tidy" => cmd_stub("clang-tidy") }
      with_lang_plugin(:objc, { "a.m" => "int x;\n" }, stubs: stubs) do |_o, _e, status|
        expect(status).to be_success
        expect(calls).to include("clang-format")
        expect(calls).to include("clang-tidy a.m") # ran on the staged .m
      end
    end

    it "fails when clang-format reports a diff (--Werror)", if: RUBY_PLATFORM.include?("darwin") do
      stubs = { "xcrun" => xcrun_stub(format_exit: 1), "clang-tidy" => cmd_stub("clang-tidy") }
      with_lang_plugin(:objc, { "a.m" => "int x;\n" }, stubs: stubs) do |_o, _e, status|
        expect(status).not_to be_success
      end
    end

    it "fails when clang-tidy reports findings on the .m", if: RUBY_PLATFORM.include?("darwin") do
      stubs = { "xcrun" => xcrun_stub, "clang-tidy" => cmd_stub("clang-tidy", exit_code: 1) }
      with_lang_plugin(:objc, { "a.m" => "int x;\n" }, stubs: stubs) do |_o, _e, status|
        expect(status).not_to be_success
      end
    end

    it "runs clang-format but not clang-tidy on a .h-only change (tidy is .m-gated)", if: RUBY_PLATFORM.include?("darwin") do
      stubs = { "xcrun" => xcrun_stub, "clang-tidy" => cmd_stub("clang-tidy") }
      with_lang_plugin(:objc, { "a.h" => "int x;\n" }, stubs: stubs) do |_o, _e, status|
        expect(status).to be_success
        expect(calls).to include("clang-format")
        expect(calls.grep(/clang-tidy/)).to be_empty
      end
    end

    it "does nothing when no Objective-C is staged" do
      with_lang_plugin(:objc, { "readme.md" => "hi\n" }, stubs: {}) do |_o, _e, status|
        expect(status).to be_success
      end
    end
  end

  describe "20-brew" do
    it "brew-style-fixes and re-stages the consumer's own staged Ruby" do
      with_lang_plugin(:brew, { "cmd/x.rb" => "puts 1\n" }, stubs: { "brew" => cmd_stub("brew") }) do |_o, _e, status|
        expect(status).to be_success
        expect(calls).to include("brew style")
      end
    end

    it "never runs brew style on a synced shell script (do-not-modify header)" do
      synced = "#!/bin/sh\n# This file is synced; do not modify it directly.\ntrue\n"
      with_lang_plugin(:brew, { "scripts/x.sh" => synced }, stubs: { "brew" => cmd_stub("brew") }) do |_o, _e, status|
        expect(status).to be_success
        expect(calls).to be_empty
      end
    end

    it "does nothing when neither Ruby nor shell is staged" do
      with_lang_plugin(:brew, { "readme.md" => "hi\n" }, stubs: { "brew" => cmd_stub("brew") }) do |_o, _e, status|
        expect(status).to be_success
        expect(calls).to be_empty
      end
    end
  end
end
