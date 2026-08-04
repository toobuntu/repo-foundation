# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "open3"
require "tmpdir"

# Behavioral tests for scripts/foundation-init.sh, run against a throwaway
# target repo. The script is run with PATH set to a constructed directory
# holding only the tools it needs, so `command -v reuse` fails by
# construction and the annotation/download step skips (no network, no
# license downloads) — deterministic even on images that ship reuse in
# /usr/bin. The layout seeding under test is independent of that step.
RSpec.describe "foundation-init.sh" do
  let(:script) { File.join(REPO_ROOT, "scripts/foundation-init.sh") }

  def sh!(*cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "command failed: #{cmd.inspect}\nstdout: #{out}\nstderr: #{err}" unless status.success?

    out
  end

  # A PATH dir with exactly the external tools foundation-init.sh uses
  # (everything else it needs is a shell builtin).
  def restricted_path(dir)
    bin = File.join(dir, "toolbin")
    FileUtils.mkdir_p(bin)
    %w[sed cp mkdir grep dirname basename awk mv].each do |tool|
      src = ["/usr/bin/#{tool}", "/bin/#{tool}"].find { |p| File.executable?(p) }
      raise "required tool not found on this host: #{tool}" unless src

      File.symlink(src, File.join(bin, tool))
    end
    bin
  end

  it "seeds the .ai layer with the volatile files ignored before the first commit" do
    Dir.mktmpdir("rf-init-tgt-") do |target|
      sh!("git", "init", "--quiet", "--initial-branch=main", target)
      out, err, status = Dir.mktmpdir("rf-init-bin-") do |bindir|
        Open3.capture3({ "PATH" => restricted_path(bindir) }, script, target)
      end
      expect(status.success?).to eq(true), "stdout=#{out}\nstderr=#{err}"

      expect(File.exist?("#{target}/.ai/memory.md")).to eq(true)
      expect(File.exist?("#{target}/.ai/progress.md")).to eq(true)

      # The volatile lines sit INSIDE the managed region, so the first sync's
      # wholesale region replacement (whose baseline carries the same lines)
      # self-heals rather than duplicating them.
      gitignore = File.read("#{target}/.gitignore")
      region_begin = gitignore.index(">>>")
      region_end = gitignore.index("<<<")
      %w[.ai/progress.md .ai/scratchpad/ .ai/.progress.session-start].each do |line|
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

  # The seeded .vale.ini names two vocabularies, and vale treats a vocabulary
  # it cannot find as a runtime error (E100) that lints nothing at all — so the
  # local one has to arrive as a TRACKED file, not just a directory: git does
  # not track an empty directory, and the layer would evaporate on the next
  # clone, turning the prose gate into a config failure.
  it "seeds a tracked local vocabulary for the .vale.ini it writes" do
    Dir.mktmpdir("rf-init-tgt-") do |target|
      sh!("git", "init", "--quiet", "--initial-branch=main", target)
      out, err, status = Dir.mktmpdir("rf-init-bin-") do |bindir|
        Open3.capture3({ "PATH" => restricted_path(bindir) }, script, target)
      end
      expect(status.success?).to eq(true), "stdout=#{out}\nstderr=#{err}"

      vocab = "#{target}/.vale/styles/config/vocabularies/Local/accept.txt"
      expect(File.exist?(vocab)).to eq(true)
      expect(File.read(vocab)).to be_empty
      expect(File.exist?("#{vocab}.license")).to eq(true)
      expect(File.read("#{vocab}.license")).to include("SPDX-License-Identifier")

      config = File.read("#{target}/.vale.ini")
      expect(config).to match(/^Vocab = Toobuntu, Local$/)

      sh!("git", "-C", target, "add", "-A")
      staged = sh!("git", "-C", target, "diff", "--cached", "--name-only").split("\n")
      expect(staged).to include(".vale/styles/config/vocabularies/Local/accept.txt")
      expect(staged).to include(".vale/styles/config/vocabularies/Local/accept.txt.license")
    end
  end

  it "inserts the seeded lines into the appended region of a pre-existing .gitignore" do
    Dir.mktmpdir("rf-init-tgt-") do |target|
      sh!("git", "init", "--quiet", "--initial-branch=main", target)
      File.write("#{target}/.gitignore", "# repo-specific\nbuild/\n")
      _, err, status = Dir.mktmpdir("rf-init-bin-") do |bindir|
        Open3.capture3({ "PATH" => restricted_path(bindir) }, script, target)
      end
      expect(status.success?).to eq(true), err

      gitignore = File.read("#{target}/.gitignore")
      expect(gitignore).to start_with("# repo-specific\nbuild/\n")
      expect(gitignore.index(".ai/progress.md")).to be > gitignore.index(">>>")
      _, _, ignored = Open3.capture3("git", "-C", target, "check-ignore", "-q", ".ai/progress.md")
      expect(ignored.success?).to eq(true)
    end
  end

  it "appends a real region when the marker text appears only inside a comment" do
    Dir.mktmpdir("rf-init-tgt-") do |target|
      sh!("git", "init", "--quiet", "--initial-branch=main", target)
      manifest = File.read(File.join(REPO_ROOT, "sync-manifest.yaml"))
      label = manifest[/^  merge_label_begin: "(.*)"$/, 1]
      # A substring mention, not a marker line: must not count as a region.
      File.write("#{target}/.gitignore", "# see '# >>> #{label} >>>' below\nbuild/\n")
      _, err, status = Dir.mktmpdir("rf-init-bin-") do |bindir|
        Open3.capture3({ "PATH" => restricted_path(bindir) }, script, target)
      end
      expect(status.success?).to eq(true), err

      _, _, ignored = Open3.capture3("git", "-C", target, "check-ignore", "-q", ".ai/progress.md")
      expect(ignored.success?).to eq(true)
    end
  end

  it "inserts missing entries into an already-present managed region" do
    Dir.mktmpdir("rf-init-tgt-") do |target|
      sh!("git", "init", "--quiet", "--initial-branch=main", target)
      # An empty region, as an older init would have left it. The markers must
      # match what the script derives from the manifest labels.
      manifest = File.read(File.join(REPO_ROOT, "sync-manifest.yaml"))
      label = manifest[/^  merge_label_begin: "(.*)"$/, 1]
      label_end = manifest[/^  merge_label_end: "(.*)"$/, 1]
      File.write("#{target}/.gitignore", <<~TXT)
        build/
        # >>> #{label} >>>
        # <<< #{label_end} <<<
      TXT
      _, err, status = Dir.mktmpdir("rf-init-bin-") do |bindir|
        Open3.capture3({ "PATH" => restricted_path(bindir) }, script, target)
      end
      expect(status.success?).to eq(true), err

      lines = File.readlines("#{target}/.gitignore", chomp: true)
      # Pre-existing content is preserved, and the region is inserted into (not
      # duplicated): exactly one begin and one end marker, begin before end.
      expect(lines).to include("build/")
      begin_i = lines.index("# >>> #{label} >>>")
      end_i = lines.index("# <<< #{label_end} <<<")
      expect(lines.count("# >>> #{label} >>>")).to eq(1)
      expect(lines.count("# <<< #{label_end} <<<")).to eq(1)
      expect(begin_i).not_to be_nil
      expect(end_i).to be > begin_i
      # The seeded entries land as full lines strictly between the markers
      # (relay.md is deliberately absent: tracked since the ADR 0022 amendment).
      %w[.ai/progress.md .ai/scratchpad/ .ai/.progress.session-start].each do |entry|
        entry_i = lines.index(entry)
        expect(entry_i).not_to(be_nil, "#{entry} missing from .gitignore")
        expect(entry_i).to be_between(begin_i + 1, end_i - 1)
      end
      sh!("git", "-C", target, "add", "-A")
      staged = sh!("git", "-C", target, "diff", "--cached", "--name-only").split("\n")
      expect(staged).not_to include(".ai/progress.md")
    end
  end
end
