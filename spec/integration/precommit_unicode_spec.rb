# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Disable REUSE linting to prevent SPDX-like substrings in test fixtures
# from being misinterpreted as malformed license metadata.
# REUSE-IgnoreStart

require "fileutils"
require "open3"
require "tmpdir"

# Behavioral tests for the supply-chain hardening checks added in v0.2:
#
#   - .githooks/pre-commit invisible-Unicode check (RedHat grep approach)
#   - scripts/lint-unicode.sh, the shared repo-wide scanner that the CI
#     lint-unicode job and `make lint` both invoke
#
# Both layers also support a per-file `invisible-allow:` opt-out annotation
# placed anywhere in the file.
#
# The hook is exercised by setting up a throwaway git repository, staging
# planted files, and invoking the hook directly from the source tree. The
# shared scanner is exercised by running scripts/lint-unicode.sh against a
# planted directory tree — both its python3 path and its POSIX-sh fallback
# (forced with LINT_UNICODE_NO_PYTHON=1). This keeps the tests
# self-contained and avoids requiring the actual GitHub Actions runtime.

HOOK_PATH = File.join(REPO_ROOT, ".githooks", "pre-commit")
UNICODE_PLUGIN_PATH = File.join(REPO_ROOT, ".githooks", "pre-commit.d", "80-unicode")
LINT_PERMS_PATH = File.join(REPO_ROOT, "scripts", "lint-perms.sh")
LINT_UNICODE_PATH = File.join(REPO_ROOT, "scripts", "lint-unicode.sh")

# Bidi/zero-width/BOM codepoints that must trigger the check.
BIDI_OVERRIDE_RLO = "\u202E"  # right-to-left override
BIDI_ISOLATE_RLI  = "\u2067"  # right-to-left isolate
ZERO_WIDTH_SPACE  = "\u200B"
ARABIC_LETTER_MK  = "\u061C"
LRM               = "\u200E"  # left-to-right mark (legitimate use case)
RLM               = "\u200F"  # right-to-left mark (legitimate use case)
UTF8_BOM          = "\uFEFF"

# Codepoints that must NOT trigger the check (legitimate Unicode).
LATIN_E_GRAVE     = "\u00E8"  # è
GREEK_ALPHA       = "\u03B1"  # α
EM_DASH           = "\u2014"  # —

module HookSpecHelpers
  # Creates a temp git repo, configures the local pre-commit runner and the
  # 80-unicode plugin that now carries the scan, writes the given files,
  # stages them, and yields the working dir.
  #
  # scripts/lint-perms.sh is also copied in (and staged 0755) because it is
  # what the fixtures' own execute bits are checked against; 80-perms is
  # deliberately NOT installed here, so a perms finding cannot mask the
  # Unicode check under test (it has its own coverage in lint_perms_spec.rb).
  def with_git_repo(files)
    Dir.mktmpdir("rf-hook-test-") do |dir|
      Dir.chdir(dir) do
        run!("git", "init", "--quiet", "--initial-branch=feature/test")
        run!("git", "config", "user.email", "test@example.invalid")
        run!("git", "config", "user.name",  "Test")
        # Copy the project's runner and the Unicode plugin into this
        # throwaway repo.
        FileUtils.mkdir_p(".githooks/pre-commit.d")
        FileUtils.cp(HOOK_PATH, ".githooks/pre-commit")
        File.chmod(0o755, ".githooks/pre-commit")
        FileUtils.cp(UNICODE_PLUGIN_PATH, ".githooks/pre-commit.d/80-unicode")
        File.chmod(0o755, ".githooks/pre-commit.d/80-unicode")
        run!("git", "config", "core.hooksPath", ".githooks")
        FileUtils.mkdir_p("scripts")
        # The plugin delegates to the scanner (ADR 0006, amended 2026-07-29),
        # so the fixture needs the script pair the sync would deliver.
        FileUtils.cp(LINT_UNICODE_PATH, "scripts/lint-unicode.sh")
        File.chmod(0o755, "scripts/lint-unicode.sh")
        FileUtils.cp(File.join(REPO_ROOT, "scripts", "lint-unicode.py"),
                     "scripts/lint-unicode.py")
        FileUtils.cp(LINT_PERMS_PATH, "scripts/lint-perms.sh")
        File.chmod(0o755, "scripts/lint-perms.sh")
        run!("git", "add", "scripts/lint-perms.sh")
        run!("git", "update-index", "--chmod=+x", "scripts/lint-perms.sh")
        # Write planted content and stage.
        files.each do |relpath, content|
          FileUtils.mkdir_p(File.dirname(relpath))
          File.binwrite(relpath, content)
          run!("git", "add", relpath)
        end
        yield dir
      end
    end
  end

  # Runs the hook directly (not through `git commit`) so the test can
  # observe its exit status and stderr without committing.
  #
  # REUSE_LINT_SKIP=1: these specs target the Unicode scanner, not the
  # REUSE gate. The throwaway repos carry no SPDX headers, so with reuse
  # installed the 85-reuse plugin would reject every fixture and mask the
  # check under test. Still required after the runner refactor -- the seam
  # moved from the base hook into 85-reuse, which the runner still runs.
  # The REUSE path has its own coverage (precommit_reuse_spec.rb and the
  # lint-reuse CI job).
  def run_hook
    Open3.capture3({ "REUSE_LINT_SKIP" => "1", "GIT_DIR" => ".git", "GIT_INDEX_FILE" => ".git/index" },
                   "./.githooks/pre-commit")
  end

  def run!(*cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "command failed: #{cmd.inspect}\nstdout: #{out}\nstderr: #{err}" unless status.success?
    [out, err]
  end
end

RSpec.describe "pre-commit hook: invisible Unicode detection" do
  include HookSpecHelpers

  it "rejects a file containing a bidi override character" do
    with_git_repo("evil.c" => "int main(){#{BIDI_OVERRIDE_RLO}return 0;}\n") do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(false), "hook should fail; stderr=#{stderr.inspect}"
      expect(stderr).to include("evil.c")
      expect(stderr).to match(/invisible Unicode/i)
    end
  end

  it "rejects a file containing a bidi isolate character" do
    with_git_repo("evil.txt" => "hello#{BIDI_ISOLATE_RLI}world") do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(false)
      expect(stderr).to include("evil.txt")
    end
  end

  it "rejects a file containing a zero-width space" do
    with_git_repo("zwsp.md" => "Look#{ZERO_WIDTH_SPACE}here\n") do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(false)
      expect(stderr).to include("zwsp.md")
    end
  end

  it "rejects a file containing an Arabic letter mark" do
    with_git_repo("alm.txt" => "x#{ARABIC_LETTER_MK}y") do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(false)
      expect(stderr).to include("alm.txt")
    end
  end

  it "rejects a file beginning with a UTF-8 BOM" do
    with_git_repo("bom.txt" => "#{UTF8_BOM}content\n") do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(false)
      expect(stderr).to include("bom.txt")
    end
  end

  it "passes a clean ASCII file" do
    with_git_repo("clean.c" => "int main(void) { return 0; }\n") do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(true), "hook should pass; stderr=#{stderr.inspect}"
    end
  end

  it "passes a file containing legitimate non-ASCII Unicode" do
    text = "café #{LATIN_E_GRAVE} #{GREEK_ALPHA} dash #{EM_DASH}\n"
    with_git_repo("ok.md" => text) do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(true), "stderr=#{stderr.inspect}"
    end
  end

  it "skips binary blobs (NUL bytes present)" do
    # A blob with NUL bytes that also happens to contain the byte sequence
    # for U+202E. The file(1) confirmation must classify it binary and skip.
    binary = "PNG\0\0\0".dup.force_encoding(Encoding::ASCII_8BIT)
    binary << "\xE2\x80\xAE".dup.force_encoding(Encoding::ASCII_8BIT)
    binary << "\0trailing".dup.force_encoding(Encoding::ASCII_8BIT)
    with_git_repo("blob.bin" => binary) do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(true), "stderr=#{stderr.inspect}"
    end
  end

  # The unification promoted the commit-time gate from the sixteen-codepoint
  # grep table to the script's python3 path: full Cf/Cc plus encoding
  # enforcement. These two commits passed the old plugin and must not pass
  # now (ADR 0006, amended 2026-07-29).
  it "rejects a NUL embedded in staged text (Cc, beyond the old grep table)" do
    with_git_repo("script.sh" => "#!/bin/sh\necho hi\n\0\nmore\n") do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(false), "stderr=#{stderr.inspect}"
      expect(stderr).to include("script.sh")
    end
  end

  it "rejects staged non-UTF-8 text (encoding gate now at commit time)" do
    with_git_repo("latin1.txt" => "caf\xE9\n".dup.force_encoding(Encoding::ASCII_8BIT)) do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(false), "stderr=#{stderr.inspect}"
      expect(stderr).to include("latin1.txt")
    end
  end

  it "rejects only the offending file when multiple are staged" do
    files = {
      "ok.txt"   => "fine\n",
      "evil.txt" => "bad#{BIDI_OVERRIDE_RLO}\n",
    }
    with_git_repo(files) do
      _stdout, stderr, status = run_hook
      expect(status.success?).to eq(false)
      expect(stderr).to include("evil.txt")
      expect(stderr).not_to include("ok.txt")
    end
  end

  describe "per-file opt-out via invisible-allow annotation" do
    it "passes a file with invisible-allow: U+200E and a real LRM character" do
      content = "// invisible-allow: U+200E\n" \
                "package main\n" \
                "var rtl = \"#{LRM}time\"\n"
      with_git_repo("rtl.go" => content) do
        _stdout, stderr, status = run_hook
        expect(status.success?).to eq(true), "stderr=#{stderr.inspect}"
      end
    end

    it "passes a file allowing two codepoints" do
      content = "// invisible-allow: U+200E,U+200F\n" \
                "var s = \"#{LRM}#{RLM}\"\n"
      with_git_repo("rtl.go" => content) do
        _stdout, stderr, status = run_hook
        expect(status.success?).to eq(true), "stderr=#{stderr.inspect}"
      end
    end

    it "still rejects codepoints not in the allow list" do
      # U+200E is allowed but U+202E (RLO) is not.
      content = "// invisible-allow: U+200E\n" \
                "// hidden: #{BIDI_OVERRIDE_RLO} payload\n"
      with_git_repo("evil.go" => content) do
        _stdout, stderr, status = run_hook
        expect(status.success?).to eq(false), "should fail; stderr=#{stderr.inspect}"
        expect(stderr).to include("evil.go")
      end
    end

    it "does not recognize the retired bidi-allow spelling" do
      # Renamed 2026-08-03 (ADR 0006 amendment). The old token grants
      # nothing, so a file still carrying it fails rather than silently
      # keeping an exemption the gate no longer parses.
      content = "// bidi-allow: U+200E\n" \
                "var rtl = \"#{LRM}time\"\n"
      with_git_repo("stale.go" => content) do
        _stdout, stderr, status = run_hook
        expect(status.success?).to eq(false), "should fail; stderr=#{stderr.inspect}"
        expect(stderr).to include("stale.go")
      end
    end

    it "honors annotations placed deep in the file" do
      # Headers (REUSE SPDX, magic comments, encoding decls) plus a
      # blank line and the SPDX block can easily push real code past
      # line 5, so the annotation must work anywhere in the file.
      content = "# typed: true\n" \
                "# frozen_string_literal: true\n" \
                "\n" \
                "# SPDX-FileCopyrightText: Copyright 2026 Test\n" \
                "#\n" \
                "# SPDX-License-Identifier: GPL-3.0-or-later\n" \
                "\n" \
                "# invisible-allow: U+200E\n" \
                "x = \"#{LRM}content\"\n"
      with_git_repo("deep.rb" => content) do
        _stdout, stderr, status = run_hook
        expect(status.success?).to eq(true), "stderr=#{stderr.inspect}"
      end
    end
  end
end

RSpec.describe "CI lint-unicode scanner" do
  include HookSpecHelpers # run! for the staged-scope fixture repos
  # Exercise the shared scanner directly — the same scripts/lint-unicode.sh
  # that the CI lint-unicode job and `make lint` invoke. Passing "." makes
  # the script walk the planted directory tree (no git repo required), so
  # these tests stay self-contained.
  def run_scanner_in(dir, env = {})
    Open3.capture3(env, LINT_UNICODE_PATH, ".", chdir: dir)
  end

  it "rejects a file with a bidi override character" do
    Dir.mktmpdir("rf-ci-test-") do |dir|
      File.write(File.join(dir, "evil.c"), "int x;#{BIDI_OVERRIDE_RLO}\n")
      _out, err, status = run_scanner_in(dir)
      expect(status.success?).to eq(false), "stderr=#{err.inspect}"
      expect(err).to match(/Invisible Unicode|CVE-2021-42574/)
      expect(err).to include("evil.c")
    end
  end

  it "rejects a file containing a UTF-8 BOM" do
    Dir.mktmpdir("rf-ci-test-") do |dir|
      File.write(File.join(dir, "bom.txt"), "#{UTF8_BOM}content\n")
      _out, err, status = run_scanner_in(dir)
      expect(status.success?).to eq(false)
      expect(err).to include("bom.txt")
    end
  end

  it "rejects UTF-16-encoded text" do
    Dir.mktmpdir("rf-ci-test-") do |dir|
      utf16 = "hello world\n".encode(Encoding::UTF_16LE)
      File.binwrite(File.join(dir, "u16.txt"), "\xFF\xFE".b + utf16.b)
      _out, err, status = run_scanner_in(dir)
      expect(status.success?).to eq(false), "stderr=#{err.inspect}"
      expect(err).to include("u16.txt")
      expect(err).to match(/UTF-8/)
    end
  end

  it "rejects non-UTF-8 single-byte encoded text" do
    Dir.mktmpdir("rf-ci-test-") do |dir|
      # Latin-1 byte 0xE9 is é but is invalid UTF-8 if not in a multi-byte
      # sequence.
      File.binwrite(File.join(dir, "latin1.txt"), "caf\xE9\n".b)
      _out, err, status = run_scanner_in(dir)
      expect(status.success?).to eq(false)
      expect(err).to include("latin1.txt")
    end
  end

  it "passes a clean repository tree" do
    Dir.mktmpdir("rf-ci-test-") do |dir|
      File.write(File.join(dir, "ok.md"), "# Hello\n\nClean content.\n")
      File.write(File.join(dir, "ok.c"),  "int main(void) { return 0; }\n")
      _out, err, status = run_scanner_in(dir)
      expect(status.success?).to eq(true), "stderr=#{err.inspect}"
    end
  end

  # ADR 0006, amended 2026-07-29: scope is a named argument, not an implication
  # of which git event happened to invoke the script.
  describe "explicit scope selection" do
    # The staged scope scans INDEX content -- what a commit records -- via
    # `git checkout-index`, not the working-tree copy at the same path. The
    # two cases below are the semantic, in both directions.
    def in_fixture_repo
      Dir.mktmpdir("rf-staged-test-") do |dir|
        Dir.chdir(dir) do
          run!("git", "init", "--quiet", "--initial-branch=feature/test")
          run!("git", "config", "user.email", "test@example.invalid")
          run!("git", "config", "user.name",  "Test")
          yield dir
        end
      end
    end

    it "catches a staged bidi blob even when the worktree copy is clean" do
      in_fixture_repo do
        File.write("f.txt", "evil #{BIDI_OVERRIDE_RLO} staged\n")
        run!("git", "add", "f.txt")
        File.write("f.txt", "clean now\n")
        _out, err, status = Open3.capture3(LINT_UNICODE_PATH, "--scope=staged")
        expect(status.success?).to eq(false), "stderr=#{err.inspect}"
        expect(err).to include("f.txt")
      end
    end

    it "passes a clean index even when the worktree copy is dirty" do
      in_fixture_repo do
        File.write("f.txt", "clean staged\n")
        run!("git", "add", "f.txt")
        File.write("f.txt", "evil #{BIDI_OVERRIDE_RLO} dirty\n")
        _out, err, status = Open3.capture3(LINT_UNICODE_PATH, "--scope=staged")
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end

    it "reads the invisible-allow annotation from the blob, not the worktree" do
      in_fixture_repo do
        # Blob has the codepoint and no annotation; the worktree adds the
        # annotation AFTER staging. Exempting from the worktree copy would
        # let an unstaged edit waive a staged finding.
        File.write("f.txt", "mark #{LRM} here\n")
        run!("git", "add", "f.txt")
        File.write("f.txt", "// invisible-allow: U+200E\nmark #{LRM} here\n")
        _out, err, status = Open3.capture3(LINT_UNICODE_PATH, "--scope=staged")
        expect(status.success?).to eq(false), "stderr=#{err.inspect}"
      end
    end

    # The path list is NUL-delimited end to end. A newline-delimited pipeline
    # split this filename into two nonexistent entries and passed silently;
    # both detector paths must catch it now. The POSIX fallback reaches NUL
    # records through `xargs -0` re-entering the script in --scan-batch mode,
    # since a POSIX shell cannot iterate them in-process.
    {
      "python3 detector" => {},
      "POSIX-sh fallback" => { "LINT_UNICODE_NO_PYTHON" => "1" },
    }.each do |label, env|
      it "scans a staged path containing a newline (#{label})" do
        in_fixture_repo do |dir|
          File.write(File.join(dir, "we\nird.txt"), "evil #{BIDI_OVERRIDE_RLO} here\n")
          run!("git", "add", "-A")
          _out, err, status = Open3.capture3(env, LINT_UNICODE_PATH, "--scope=staged")
          expect(status.success?).to eq(false), "stderr=#{err.inspect}"
          expect(err).to match(/Invisible Unicode/)
        end
      end

      # The same bypass one layer up: Python's universal-newline translation
      # rewrites a CR inside the FILENAME while reading the NUL-delimited list,
      # yielding a path that does not exist. Before `newline=''` this exited 0.
      it "scans a staged path containing a carriage return (#{label})" do
        in_fixture_repo do |dir|
          File.write(File.join(dir, "we\rird.txt"), "evil #{BIDI_OVERRIDE_RLO} here\n")
          run!("git", "add", "-A")
          _out, err, status = Open3.capture3(env, LINT_UNICODE_PATH, "--scope=staged")
          expect(status.success?).to eq(false), "stderr=#{err.inspect}"
          expect(err).to match(/Invisible Unicode/)
        end
      end
    end

    it "rejects paths combined with --scope=staged" do
      _out, err, status = Open3.capture3(LINT_UNICODE_PATH, "--scope=staged", "x")
      expect(status.exitstatus).to eq(2)
      expect(err).to match(/takes no paths/)
    end

    it "rejects an unknown scope rather than falling back to a default" do
      _out, err, status = Open3.capture3(LINT_UNICODE_PATH, "--scope=everything")
      expect(status.exitstatus).to eq(2)
      expect(err).to match(/unknown scope/)
    end

    it "finds an untracked file under --scope=tree" do
      Dir.mktmpdir("rf-scope-test-") do |dir|
        run!("git", "init", "--quiet", dir)
        File.write(File.join(dir, "evil.c"), "int x;#{BIDI_OVERRIDE_RLO}\n")
        _out, err, status = Open3.capture3(LINT_UNICODE_PATH, "--scope=tree", chdir: dir)
        expect(status.success?).to eq(false), "stderr=#{err.inspect}"
        expect(err).to include("evil.c")
      end
    end

    # The complement, and the reason scope 3 needed its own automation: the
    # default scope cannot see a file git does not track.
    it "misses that same untracked file under the default scope" do
      Dir.mktmpdir("rf-scope-test-") do |dir|
        run!("git", "init", "--quiet", dir)
        File.write(File.join(dir, "evil.c"), "int x;#{BIDI_OVERRIDE_RLO}\n")
        _out, err, status = Open3.capture3(LINT_UNICODE_PATH, chdir: dir)
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end
  end

  # ADR 0006, amended 2026-07-29. The Cc extension reaches ordinary binary
  # content, because a fixture holding a NUL decodes as valid UTF-8 and so
  # looks like text to the encoding check. Each finding is confirmed against
  # file(1) before it is reported.
  describe "binary content is confirmed against file(1) before reporting" do
    it "passes a binary fixture whose only control character is a NUL" do
      Dir.mktmpdir("rf-ci-test-") do |dir|
        File.binwrite(File.join(dir, "fixture.bin"), "hello\x00".b)
        _out, err, status = run_scanner_in(dir)
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end

    it "passes a binary holding bidi bytes, which no reviewer reads as source" do
      Dir.mktmpdir("rf-ci-test-") do |dir|
        File.binwrite(File.join(dir, "blob.bin"),
                      "#{BIDI_OVERRIDE_RLO}\x00\x00\x00junk\x00".b)
        _out, err, status = run_scanner_in(dir)
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end

    # The guard against re-opening the hole the encoding check closed: a NUL
    # embedded in real source must still be reported. file(1) identifies a
    # script by its shebang even with a NUL in it, so the type stays text/*.
    it "still rejects a NUL embedded in real source" do
      Dir.mktmpdir("rf-ci-test-") do |dir|
        File.binwrite(File.join(dir, "script.sh"),
                      "#!/bin/sh\necho hi\n\x00\nmore code\n".b)
        _out, err, status = run_scanner_in(dir)
        expect(status.success?).to eq(false), "stderr=#{err.inspect}"
        expect(err).to include("script.sh")
      end
    end

    # Suppression needs BOTH file(1) queries to say binary. PostScript is the
    # case that proves the AND is load-bearing: application/postscript is on
    # the binary denylist, but a .ps file is plain reviewable text, so
    # type alone would swallow this finding.
    it "rejects a bidi override in PostScript, whose type is denylisted but whose bytes are text" do
      Dir.mktmpdir("rf-ci-test-") do |dir|
        File.write(File.join(dir, "doc.ps"),
                   "%!PS-Adobe-3.0\n/Helvetica findfont 12 scalefont setfont\n" \
                   "100 100 moveto (evil #{BIDI_OVERRIDE_RLO} here) show\nshowpage\n")
        _out, err, status = run_scanner_in(dir)
        expect(status.success?).to eq(false), "stderr=#{err.inspect}"
        expect(err).to include("doc.ps")
      end
    end

    # A denylist, not an allowlist: file(1) reports application/json for JSON,
    # which a literal text/* allowlist would have stopped scanning. Seven
    # tracked files in this repository alone are that type.
    it "still rejects a bidi override in JSON, which file(1) calls application/json" do
      Dir.mktmpdir("rf-ci-test-") do |dir|
        File.write(File.join(dir, "config.json"),
                   %({\n  "name": "x#{BIDI_OVERRIDE_RLO}"\n}\n))
        _out, err, status = run_scanner_in(dir)
        expect(status.success?).to eq(false), "stderr=#{err.inspect}"
        expect(err).to include("config.json")
      end
    end
  end

  # The audit diagnostic (--classify-report): every candidate file gets a
  # sorted `path<TAB>mime<TAB>encoding<TAB>scan|skip` row -- both halves of the
  # decision, so a cross-OS comparison shows WHICH axis a runner disagrees on.
  describe "--classify-report" do
    it "records the MIME type, encoding, and decision for every candidate" do
      Dir.mktmpdir("rf-ci-test-") do |dir|
        File.write(File.join(dir, "a.txt"), "hello\n")
        File.binwrite(File.join(dir, "b.bin"), "hello\x00junk\x00\x01\x02".b)
        report = File.join(dir, "report.tsv")
        _out, err, status = Open3.capture3(
          LINT_UNICODE_PATH, "--scope=tree", "--classify-report=#{report}",
          chdir: dir)
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
        rows = File.readlines(report, chomp: true).map { |l| l.split("\t") }
        expect(rows.first.length).to eq(4), "expected path/type/encoding/decision"
        decisions = rows.to_h { |path, _t, _e, decision| [File.basename(path), decision] }
        expect(decisions).to include("a.txt" => "scan", "b.bin" => "skip")
        expect(rows.map(&:first)).to eq(rows.map(&:first).sort)
      end
    end

    # `file --mime` omits the charset from a universal Mach-O's summary line,
    # so a path whose charset comes back empty gets one targeted
    # --mime-encoding query. Without it a fat binary would classify `scan`.
    it "fills a missing charset so a universal binary still classifies as binary" do
      # Homebrew's own Mach-O test fixture, located through `brew --repository`
      # rather than any assumed layout. Two rejected alternatives, both for
      # durability: thinning /bin/sh with lipo works today but Apple ends Intel
      # support in 2027, so a system binary will not stay universal; and
      # committing a fat binary here would ship it to every consumer through
      # the synced spec/ tree for one example's sake.
      brew = Open3.capture3("brew", "--repository")
      skip "Homebrew not available" unless brew.last.success?
      fat = File.join(brew.first.strip, "Library", "Homebrew", "test",
                      "support", "fixtures", "mach", "fat.dylib")
      skip "Homebrew's Mach-O fixture is not present" unless File.exist?(fat)

      Dir.mktmpdir("rf-ci-test-") do |dir|
        report = File.join(dir, "report.tsv")
        _out, err, status = Open3.capture3(
          LINT_UNICODE_PATH, "--scope=tree", "--classify-report=#{report}", fat)
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
        row = File.readlines(report, chomp: true).map { |l| l.split("\t") }
                  .find { |r| r.first == fat }
        expect(row).not_to be_nil, "no row for the fat binary in #{File.read(report)}"
        _path, mime, encoding, decision = row
        expect(mime).to eq("application/x-mach-binary")
        expect(encoding).to eq("binary"), "the charset fallback did not fill in"
        expect(decision).to eq("skip")
      end
    end

    it "refuses the flag on the sh fallback rather than writing an empty report" do
      _out, err, status = Open3.capture3(
        { "LINT_UNICODE_NO_PYTHON" => "1" },
        LINT_UNICODE_PATH, "--classify-report=x.tsv")
      expect(status.exitstatus).to eq(2)
      expect(err).to match(/python3/)
    end
  end

  describe "POSIX-sh fallback (LINT_UNICODE_NO_PYTHON=1)" do
    # The shell path covers the fixed bidi/zero-width/BOM set only — the
    # accepted floor when python3 is unavailable (repo-foundation ADR 0006).
    it "rejects a file with a bidi override character" do
      Dir.mktmpdir("rf-ci-test-") do |dir|
        File.write(File.join(dir, "evil.c"), "int x;#{BIDI_OVERRIDE_RLO}\n")
        _out, err, status = run_scanner_in(dir, "LINT_UNICODE_NO_PYTHON" => "1")
        expect(status.success?).to eq(false), "stderr=#{err.inspect}"
        expect(err).to include("evil.c")
      end
    end

    it "honors the invisible-allow opt-out" do
      Dir.mktmpdir("rf-ci-test-") do |dir|
        File.write(File.join(dir, "rtl.go"),
                   "// invisible-allow: U+200E\nvar rtl = \"#{LRM}time\"\n")
        _out, err, status = run_scanner_in(dir, "LINT_UNICODE_NO_PYTHON" => "1")
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end
  end

  describe "per-file opt-out via invisible-allow annotation" do
    it "passes a file with invisible-allow: U+200E and a real LRM character" do
      Dir.mktmpdir("rf-ci-test-") do |dir|
        content = "// invisible-allow: U+200E\n" \
                  "package main\n" \
                  "var rtl = \"#{LRM}time\"\n"
        File.write(File.join(dir, "rtl.go"), content)
        _out, err, status = run_scanner_in(dir)
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end

    it "still rejects codepoints not in the allow list" do
      Dir.mktmpdir("rf-ci-test-") do |dir|
        content = "// invisible-allow: U+200E\n" \
                  "// hidden: #{BIDI_OVERRIDE_RLO} payload\n"
        File.write(File.join(dir, "evil.go"), content)
        _out, err, status = run_scanner_in(dir)
        expect(status.success?).to eq(false), "stderr=#{err.inspect}"
        expect(err).to include("evil.go")
      end
    end

    it "honors annotations placed deep in the file" do
      Dir.mktmpdir("rf-ci-test-") do |dir|
        content = "# typed: true\n" \
                  "# frozen_string_literal: true\n" \
                  "\n" \
                  "# SPDX-FileCopyrightText: Copyright 2026 Test\n" \
                  "#\n" \
                  "# SPDX-License-Identifier: GPL-3.0-or-later\n" \
                  "\n" \
                  "# invisible-allow: U+200E\n" \
                  "x = \"#{LRM}content\"\n"
        File.write(File.join(dir, "deep.rb"), content)
        _out, err, status = run_scanner_in(dir)
        expect(status.success?).to eq(true), "stderr=#{err.inspect}"
      end
    end
  end

  # The codepoint table and its pattern builder exist twice on purpose: the
  # plugin scans staged BLOBS and must stay dependency-free (a consumer can
  # receive the hook without scripts/), while lint-unicode.sh scans the
  # working tree for CI and `make lint`. Neither can source the other without
  # giving up one of those properties, so the duplication stays -- but nothing
  # structural stops the two from drifting, and a codepoint added to only one
  # would leave a gate that passes what its twin rejects. These examples are
  # that guard: they compare the two copies directly and fail on divergence.
  describe "the detector exists once, in the script" do
    PLUGIN = ".githooks/pre-commit.d/80-unicode"
    SCRIPT = "scripts/lint-unicode.sh"

    # Everything between `_bidi_table='` and the closing quote.
    def bidi_table(path)
      body = File.read(path)[/_bidi_table='(.*?)'/m, 1]
      expect(body).not_to be_nil, "no _bidi_table found in #{path}"
      body.lines.map(&:strip).reject(&:empty?).sort
    end

    it "keeps a single codepoint table: the plugin delegates, only the script carries one" do
      # The unification (ADR 0006, amended 2026-07-29) removed the plugin's
      # duplicate detector. A table reappearing there is the drift this spec
      # existed to catch, coming back by the front door.
      expect(File.read(PLUGIN)).not_to include("_bidi_table")
      expect(File.read(PLUGIN)).to include("--scope=staged")
    end

    it "covers every codepoint RHSB-2021-007 names, plus the project's own" do
      required = %w[U+061C U+200B U+200C U+200D U+200E U+200F U+202A U+202B
                    U+202C U+202D U+202E U+2066 U+2067 U+2068 U+2069 U+FEFF]
      present = bidi_table(SCRIPT).map { |row| row.split(":").first }
      expect(present).to match_array(required)
    end

    it "builds its patterns as fixed strings, never a bracket expression" do
      # A bracket expression is a set of CHARACTERS and needs a UTF-8 locale;
      # without one it degrades to a set of BYTES and matches the E2 lead byte
      # shared by every U+2xxx character, so an em dash trips the gate. Fixed
      # strings under LC_ALL=C compare exact bytes and need no locale.
      body = File.read(SCRIPT)
      expect(body).to include("--fixed-strings"), "#{SCRIPT} lost --fixed-strings"
      expect(body).not_to match(/LC_ALL=\S*UTF-8\s+\S*grep/),
                          "#{SCRIPT} reintroduced a locale-dependent grep"
    end
  end
end
# REUSE-IgnoreEnd
