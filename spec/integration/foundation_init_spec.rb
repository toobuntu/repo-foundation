# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "open3"
require "tmpdir"

# Behavioral tests for scripts/foundation-init.sh, run against a throwaway
# target repo. reuse is deliberately kept off PATH so the annotation step
# skips (no network, no license downloads) — the layout seeding under test is
# independent of it.
RSpec.describe "foundation-init.sh" do
  let(:script) { File.join(REPO_ROOT, "scripts/foundation-init.sh") }

  def sh!(*cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "command failed: #{cmd.inspect}\nstdout: #{out}\nstderr: #{err}" unless status.success?

    out
  end

  it "seeds the .ai layer with the volatile files ignored before the first commit" do
    Dir.mktmpdir("rf-init-tgt-") do |target|
      sh!("git", "init", "--quiet", "--initial-branch=main", target)
      out, err, status = Open3.capture3({ "PATH" => "/usr/bin:/bin" }, script, target)
      expect(status.success?).to eq(true), "stdout=#{out}\nstderr=#{err}"

      expect(File.exist?("#{target}/.ai/memory.md")).to eq(true)
      expect(File.exist?("#{target}/.ai/progress.md")).to eq(true)

      # The volatile lines sit INSIDE the managed region, so the first sync's
      # wholesale region replacement (whose baseline carries the same lines)
      # self-heals rather than duplicating them.
      gitignore = File.read("#{target}/.gitignore")
      region_begin = gitignore.index(">>>")
      region_end = gitignore.index("<<<")
      %w[.ai/progress.md .ai/scratchpad.md .ai/org/relay.md].each do |line|
        expect(gitignore).to include(line)
        expect(gitignore.index(line)).to be_between(region_begin, region_end)
      end

      # The runbook's next step is review-commit-push: `git add -A` must
      # track the committed memory file but never the volatile progress file.
      _, _, ignored = Open3.capture3("git", "-C", target, "check-ignore", "-q", ".ai/progress.md")
      expect(ignored.success?).to eq(true)
      sh!("git", "-C", target, "add", "-A")
      staged = sh!("git", "-C", target, "diff", "--cached", "--name-only").split("\n")
      expect(staged).to include(".ai/memory.md")
      expect(staged).not_to include(".ai/progress.md")
    end
  end

  it "inserts the seeded lines into the appended region of a pre-existing .gitignore" do
    Dir.mktmpdir("rf-init-tgt-") do |target|
      sh!("git", "init", "--quiet", "--initial-branch=main", target)
      File.write("#{target}/.gitignore", "# repo-specific\nbuild/\n")
      _, err, status = Open3.capture3({ "PATH" => "/usr/bin:/bin" }, script, target)
      expect(status.success?).to eq(true), err

      gitignore = File.read("#{target}/.gitignore")
      expect(gitignore).to start_with("# repo-specific\nbuild/\n")
      expect(gitignore.index(".ai/progress.md")).to be > gitignore.index(">>>")
      _, _, ignored = Open3.capture3("git", "-C", target, "check-ignore", "-q", ".ai/progress.md")
      expect(ignored.success?).to eq(true)
    end
  end
end
