# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "open3"
require "tmpdir"

# Behavioral tests for scripts/pr-body-update.sh. `gh` is stubbed on PATH: it
# serves body.txt for `gh pr view` and records `gh pr edit --body-file` into
# edited.txt, so the whole read-modify-write round trip runs with no network,
# no authentication, and no real pull request.

PR_BODY_UPDATE = File.join(REPO_ROOT, "scripts", "pr-body-update.sh")

BEGIN_MARK = "<!-- pr-body:begin - managed by pr-body-update.sh; text outside is preserved -->"
END_MARK = "<!-- pr-body:end -->"

GH_STUB = <<~SH
  #!/bin/sh
  printf '%s\\n' "$*" >> "$PWD/calls.log"
  case "$2" in
  view) cat "$PWD/body.txt" ;;
  edit)
    while [ $# -gt 0 ]; do
      [ "$1" = --body-file ] && cp "$2" "$PWD/edited.txt"
      shift
    done
    ;;
  esac
  exit 0
SH

module PrBodyHelpers
  # body: the description `gh pr view` returns. replacement: the new managed
  # region. base_path replaces the inherited PATH so an absent gh can be
  # simulated; /usr/bin:/bin keeps awk, grep, mktemp, and cut resolvable.
  def with_pr_body(body, replacement, args: %w[12 new.md], base_path: "/usr/bin:/bin", stub: GH_STUB)
    Dir.mktmpdir("rf-pr-body-") do |dir|
      bindir = File.join(dir, "bin")
      FileUtils.mkdir_p(bindir)
      if stub
        File.write(File.join(bindir, "gh"), stub)
        File.chmod(0o755, File.join(bindir, "gh"))
      end
      Dir.chdir(dir) do
        File.write("body.txt", body)
        File.write("new.md", replacement)
        env = { "PATH" => "#{bindir}:#{base_path}" }
        out, err, status = Open3.capture3(env, PR_BODY_UPDATE, *args)
        yield(out, err, status, dir)
      end
    end
  end

  def edited
    File.exist?("edited.txt") ? File.read("edited.txt") : nil
  end

  def calls
    File.exist?("calls.log") ? File.read("calls.log").split("\n") : []
  end
end

RSpec.describe "pr-body-update.sh" do
  include PrBodyHelpers

  # A body shaped like the real case: the maintainer's region between the
  # markers, and a bot's summary appended after it by CodeRabbit.
  def bot_body(managed: "Old summary.\n")
    "# What changed\n\n#{BEGIN_MARK}\n#{managed}#{END_MARK}\n\n" \
      "## Summary by CodeRabbit\n\n- Refactored the widget.\n"
  end

  it "replaces the managed region and preserves the bot's section" do
    with_pr_body(bot_body, "Fresh summary.\n") do |_o, err, status|
      expect(status).to be_success, "stderr=#{err.inspect}"
      expect(edited).to include("Fresh summary.")
      expect(edited).not_to include("Old summary.")
      expect(edited).to include("## Summary by CodeRabbit")
      expect(edited).to include("- Refactored the widget.")
      expect(edited).to include("# What changed") # text before the region too
    end
  end

  it "keeps the marker lines verbatim so the region can be replaced again" do
    with_pr_body(bot_body, "Fresh.\n") do |_o, _e, status|
      expect(status).to be_success
      expect(edited).to include(BEGIN_MARK)
      expect(edited).to include(END_MARK)
    end
  end

  it "treats the replacement as data, not as program text" do
    # A replacement full of characters that would matter if it were
    # interpolated into the awk program or re-parsed by the shell.
    hostile = %(Backslash \\n, quote ", brace }, $(id), `id`, ENVIRON["x"]\n)
    with_pr_body(bot_body, hostile) do |_o, _e, status|
      expect(status).to be_success
      expect(edited).to include(hostile.chomp)
    end
  end

  it "drops markers carried in the replacement instead of nesting them" do
    # One draft file serves both `gh pr create` (which needs the markers in
    # the body it uploads) and this script. Copying them through would nest a
    # second pair, and the next run would refuse the body it just wrote.
    wrapped = "#{BEGIN_MARK}\nFresh.\n#{END_MARK}\n"
    with_pr_body(bot_body, wrapped) do |_o, _e, status|
      expect(status).to be_success
      expect(edited.scan(BEGIN_MARK).length).to eq(1)
      expect(edited.scan(END_MARK).length).to eq(1)
      expect(edited).to include("Fresh.")
    end
  end

  it "matches markers under CRLF line endings" do
    # GitHub returns CRLF for a description edited in the web UI, which an
    # equality test on the marker line would silently fail to match.
    with_pr_body(bot_body.gsub("\n", "\r\n"), "Fresh.\n") do |_o, err, status|
      expect(status).to be_success, "stderr=#{err.inspect}"
      expect(edited).to include("Fresh.")
      expect(edited).to include("## Summary by CodeRabbit")
    end
  end

  it "refuses a body with no markers and prints the lines to add" do
    with_pr_body("Just prose.\n", "Fresh.\n") do |_o, err, status|
      expect(status.exitstatus).to eq(3)
      expect(err).to include("exactly one marker pair")
      expect(err).to include("pr-body:begin")
      expect(err).to include("pr-body:end")
      expect(edited).to be_nil # nothing written
    end
  end

  it "refuses a duplicated marker pair" do
    with_pr_body(bot_body + bot_body, "Fresh.\n") do |_o, err, status|
      expect(status.exitstatus).to eq(3)
      expect(err).to include("found 2 begin, 2 end")
      expect(edited).to be_nil
    end
  end

  it "refuses an inverted marker pair" do
    inverted = "#{END_MARK}\nstray\n#{BEGIN_MARK}\n"
    with_pr_body(inverted, "Fresh.\n") do |_o, err, status|
      expect(status.exitstatus).to eq(3)
      expect(err).to include("end marker precedes")
      expect(edited).to be_nil
    end
  end

  it "--dry-run prints the merged body and edits nothing" do
    with_pr_body(bot_body, "Fresh.\n", args: %w[--dry-run 12 new.md]) do |out, _e, status|
      expect(status).to be_success
      expect(out).to include("Fresh.")
      expect(out).to include("## Summary by CodeRabbit")
      expect(edited).to be_nil
      expect(calls.grep(/pr edit/)).to be_empty
    end
  end

  it "rejects a non-numeric pull-request number before touching gh" do
    with_pr_body(bot_body, "Fresh.\n", args: %w[not-a-number new.md]) do |_o, err, status|
      expect(status.exitstatus).to eq(2)
      expect(err).to include("must be digits")
      expect(calls).to be_empty
    end
  end

  it "rejects an unreadable replacement file" do
    with_pr_body(bot_body, "Fresh.\n", args: %w[12 absent.md]) do |_o, err, status|
      expect(status.exitstatus).to eq(2)
      expect(err).to include("cannot read replacement file")
    end
  end

  it "aborts with 127 when gh is absent" do
    with_pr_body(bot_body, "Fresh.\n", stub: nil) do |_o, err, status|
      expect(status.exitstatus).to eq(127)
      expect(err).to include("gh not found")
    end
  end
end
