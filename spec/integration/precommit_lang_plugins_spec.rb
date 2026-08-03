# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "open3"
require "tmpdir"

# Behavioral tests for the per-language pre-commit plugin masters: 20-go,
# 20-objc, and 20-brew under provides/githooks/pre-commit.d/, and 20-ruby at
# the natural path (repo-foundation is itself a Ruby repository and runs it on
# its own commits — ADR 0001). Same stub pattern as the Swift and docs-plugin
# specs — each plugin runs in a throwaway git repository with stub tools
# prepended to PATH, so no real Go / clang / brew toolchain is needed and a
# stub shadows any installed copy. 20-ruby is the exception that uses the real
# interpreter: a syntax check stubbed out would assert nothing.

LANG_PLUGINS = {
  go:   File.join(REPO_ROOT, "provides", "githooks", "pre-commit.d", "20-go"),
  objc: File.join(REPO_ROOT, "provides", "githooks", "pre-commit.d", "20-objc"),
  brew: File.join(REPO_ROOT, "provides", "githooks", "pre-commit.d", "20-brew"),
  ruby: File.join(REPO_ROOT, ".githooks", "pre-commit.d", "20-ruby"),
}.freeze

module LangPluginHelpers
  # base_path replaces the inherited PATH so an absent tool can be simulated;
  # keep /usr/bin:/bin available so git and the coreutils still resolve.
  # unstaged: content written AFTER staging, so the path carries staged +
  # unstaged edits — the partial-staging case the auto-fix guard refuses.
  def with_lang_plugin(plugin, files, stubs: {}, base_path: ENV.fetch("PATH"), unstaged: {})
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
          # `--`: a fixture path may itself look like an option (`-e.rb`),
          # which is one of the cases 20-ruby exists to survive.
          run!("git", "add", "--", relpath)
        end
        unstaged.each { |relpath, content| File.write(relpath, content) }
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

    it "refuses a staged Go file that also has unstaged edits (guard before gofmt)" do
      with_lang_plugin(:go, { "main.go" => "package main\n" }, stubs: go_stubs.call,
                             unstaged: { "main.go" => "package main\n// withheld\n" }) do |_o, err, status|
        expect(status).not_to be_success
        expect(err).to include("unstaged edits")
        expect(err).to include("main.go")
        expect(calls).to be_empty # guard fires before gofmt runs
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

    it "refuses staged Ruby that also has unstaged edits (guard before brew style)" do
      with_lang_plugin(:brew, { "cmd/x.rb" => "puts 1\n" }, stubs: { "brew" => cmd_stub("brew") },
                              unstaged: { "cmd/x.rb" => "puts 1\nputs 2\n" }) do |_o, err, status|
        expect(status).not_to be_success
        expect(err).to include("unstaged edits")
        expect(calls).to be_empty # guard fires before brew style runs
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

  describe "20-ruby" do
    VALID_RB   = "# frozen_string_literal: true\n\ndef ok = 1\n"
    BROKEN_RB  = "def broken(\n"

    # A PATH holding only these — as shims, so the real tools still work — has
    # no `ruby` and no `brew`, which is how the warn-and-skip path is reached.
    # `ruby` cannot simply be shadowed by a stub: a stub that exists is a ruby
    # that `command -v` finds.
    def shim(target)
      "#!/bin/sh\nexec #{target} \"$@\"\n"
    end

    def bare_shims
      %w[git wc xargs].to_h { |t| [t, shim(`command -v #{t}`.strip)] }
    end

    it "passes a syntactically valid Ruby file" do
      with_lang_plugin(:ruby, { "lib/a.rb" => VALID_RB }) do |_o, err, status|
        expect(status).to be_success, "stderr=#{err.inspect}"
      end
    end

    it "fails a syntax error and names the file" do
      with_lang_plugin(:ruby, { "lib/bad.rb" => BROKEN_RB }) do |_o, err, status|
        expect(status).not_to be_success
        expect(err).to include("lib/bad.rb")
        expect(err).to include("20-ruby")
      end
    end

    it "checks every staged file, not only the first" do
      # `ruby -c a.rb b.rb` checks a.rb and puts b.rb in ARGV, exiting 0. The
      # plugin's xargs -n1 is what makes the second file gate; batching would
      # be a guard that cannot fire.
      files = { "lib/a.rb" => VALID_RB, "lib/z_bad.rb" => BROKEN_RB }
      with_lang_plugin(:ruby, files) do |_o, err, status|
        expect(status).not_to be_success
        expect(err).to include("z_bad.rb")
      end
    end

    it "does nothing when no Ruby is staged" do
      with_lang_plugin(:ruby, { "readme.md" => "hi\n" }) do |_o, err, status|
        expect(status).to be_success
        expect(err).to be_empty
      end
    end

    it "prefers Homebrew's portable Ruby over the one on PATH" do
      # brew reports a prefix whose portable-ruby is a logging stub; the plugin
      # must run that, not the `ruby` sitting earlier on PATH.
      Dir.mktmpdir("rf-portable-") do |prefix|
        bin = File.join(prefix, "Library/Homebrew/vendor/portable-ruby/current/bin")
        FileUtils.mkdir_p(bin)
        File.write(File.join(bin, "ruby"), cmd_stub("portable-ruby"))
        File.chmod(0o755, File.join(bin, "ruby"))
        stubs = { "brew" => "#!/bin/sh\nprintf '#{prefix}\\n'\n", "ruby" => cmd_stub("path-ruby") }
        with_lang_plugin(:ruby, { "lib/a.rb" => VALID_RB }, stubs: stubs) do |_o, _e, status|
          expect(status).to be_success
          expect(calls.grep(/^portable-ruby/)).not_to be_empty
          expect(calls.grep(/^path-ruby/)).to be_empty
        end
      end
    end

    it "falls back to the PATH ruby when Homebrew has no portable ruby" do
      Dir.mktmpdir("rf-noportable-") do |prefix|
        stubs = { "brew" => "#!/bin/sh\nprintf '#{prefix}\\n'\n", "ruby" => cmd_stub("path-ruby") }
        with_lang_plugin(:ruby, { "lib/a.rb" => VALID_RB }, stubs: stubs) do |_o, _e, status|
          expect(status).to be_success
          expect(calls.grep(/^path-ruby/)).not_to be_empty
        end
      end
    end

    it "warns and skips when no ruby is available at all" do
      with_lang_plugin(:ruby, { "lib/a.rb" => VALID_RB },
                       stubs: bare_shims, base_path: "/nonexistent") do |_o, err, status|
        expect(status).to be_success
        expect(err).to include("ruby not found")
        expect(err).to include("skipping")
      end
    end

    it "warns and skips when the only ruby predates the floor" do
      # The PATH fallback can find macOS system Ruby 2.6, whose parser rejects
      # syntax every current Ruby accepts -- so it would fail a valid file and
      # block a correct commit. The stub fails the version probe (-e) the way
      # a pre-3 interpreter does, and passes anything else.
      old = "#!/bin/sh\n[ \"$1\" = -e ] && exit 1\nprintf 'old-ruby\\n' >> \"$PWD/calls.log\"\nexit 0\n"
      Dir.mktmpdir("rf-oldruby-") do |prefix|
        stubs = { "brew" => "#!/bin/sh\nprintf '#{prefix}\\n'\n", "ruby" => old }
        with_lang_plugin(:ruby, { "lib/a.rb" => VALID_RB }, stubs: stubs) do |_o, err, status|
          expect(status).to be_success
          expect(err).to include("predates Ruby 3")
          expect(calls).to be_empty # never reached the syntax check
        end
      end
    end

    it "treats an option-looking filename as a path, not a flag" do
      # Without `--`, `ruby -c -e.rb` is parsed as `-e .rb`: ruby evaluates the
      # string ".rb" and reports a syntax error in a file that is fine.
      with_lang_plugin(:ruby, { "-e.rb" => VALID_RB }) do |_o, err, status|
        expect(status).to be_success, "stderr=#{err.inspect}"
      end
    end

    it "checks the extension-less Ruby files too" do
      with_lang_plugin(:ruby, { "Gemfile" => BROKEN_RB }) do |_o, err, status|
        expect(status).not_to be_success
        expect(err).to include("Gemfile")
      end
    end

    it "skips vendored trees" do
      # A dependency's syntax is upstream's business, and a vendor directory
      # can hold thousands of files.
      with_lang_plugin(:ruby, { "vendor/bundle/dep.rb" => BROKEN_RB }) do |_o, err, status|
        expect(status).to be_success, "stderr=#{err.inspect}"
      end
    end
  end
end
