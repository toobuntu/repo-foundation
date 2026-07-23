# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "open3"
require "tmpdir"

# Behavioral tests for scripts/promote-from-isolated.sh — cherry-picks the
# genuinely-new commits from an isolated clone into the live repo, filtering by
# patch-id so already-promoted work (under re-signed SHAs) is not duplicated.
# Ported from the former scripts/promote-from-isolated-test.sh; real git,
# throwaway live/clone pairs, the re-sign SHA divergence simulated with
# unsigned rewrites (same patch-ids, new SHAs).
#
# The promote lifecycle is inherently cumulative — each stage mutates the same
# live/clone pair and the next asserts on the result — so the sequence runs in
# one example with a per-stage aggregate_failures block, mirroring the shell
# harness's linear execution rather than fighting random example ordering.
PROMOTE = File.join(REPO_ROOT, "scripts", "promote-from-isolated.sh")

module PromoteHelpers
  def genv
    { "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null" }
  end

  # git with an isolated, unsigned identity (matches the shell harness's g()).
  def g(repo, *args)
    out, err, status =
      Open3.capture3(genv, "git", "-C", repo,
                     "-c", "commit.gpgsign=false",
                     "-c", "user.name=t", "-c", "user.email=t@example.com", *args)
    [out, err, status]
  end

  def g!(repo, *args)
    out, err, status = g(repo, *args)
    raise "git #{args.inspect} failed in #{repo}:\n#{err}#{out}" unless status.success?
    out
  end

  def commit(repo, file, msg)
    File.open(File.join(repo, file), "a") { |f| f.puts(msg) }
    g!(repo, "add", file)
    g!(repo, "commit", "--quiet", "--no-gpg-sign", "-m", msg)
  end

  # Run promote from inside <live>; returns [combined_output, exit]. The script
  # is bash (process substitution), so it is executed directly to pick up its
  # own #!/usr/bin/env bash shebang rather than being forced through sh.
  def promote(live, clone, branch, *flags, stdin_data: "")
    out, status = Open3.capture2e(genv, PROMOTE, *flags, clone, branch,
                                  chdir: live, stdin_data: stdin_data)
    [out, status.exitstatus]
  end

  def count(repo, range)
    g!(repo, "rev-list", "--count", range).strip
  end

  def clone_noremote(src, dst)
    _o, err, status = Open3.capture3(genv, "git", "clone", "--quiet", "--no-hardlinks", src, dst)
    raise "clone failed: #{err}" unless status.success?
    g!(dst, "remote", "remove", "origin")
  end
end

RSpec.describe "scripts/promote-from-isolated.sh" do
  include PromoteHelpers

  around(:each) do |example|
    Dir.mktmpdir("rf-promote-") { |root| @root = root; example.run }
  end

  it "promotes new work, stays idempotent across re-sign divergence, and gates the rest" do
    live = File.join(@root, "live")
    clone = File.join(@root, "clone")
    FileUtils.mkdir_p(live)
    g!(live, "init", "--quiet", "-b", "main")
    commit(live, "base.txt", "base")
    clone_noremote(live, clone)
    g!(clone, "switch", "--quiet", "-c", "feat")
    commit(clone, "a.txt", "feat: add a")
    commit(clone, "b.txt", "feat: add b")

    # 1. first promotion picks both commits, oldest first
    g!(live, "switch", "--quiet", "-c", "feat")
    aggregate_failures "first promotion" do
      out, code = promote(live, clone, "feat", "--yes")
      expect(code).to eq(0), out
      expect(count(live, "main..feat")).to eq("2")
      order = g!(live, "log", "--reverse", "--format=%s", "main..feat").strip.tr("\n", "|")
      expect(order).to eq("feat: add a|feat: add b")
    end

    # 2. simulate re-sign: rewrite live feat with the same patches, new SHAs
    c1 = g!(live, "rev-parse", "feat~1").strip
    c2 = g!(live, "rev-parse", "feat").strip
    g!(live, "reset", "--quiet", "--hard", "main")
    g!(live, "cherry-pick", "--quiet", "--no-gpg-sign", c1, c2)
    expect(g!(live, "rev-parse", "feat").strip).not_to eq(c2), "re-sign simulation must change SHAs"

    # 3. idempotent: nothing to promote after divergence
    aggregate_failures "idempotent run" do
      out, code = promote(live, clone, "feat", "--yes")
      expect(code).to eq(0), out
      expect(out).to include("Nothing to promote")
    end

    # 4. follow-up batch: clone adds c3; only c3 is picked
    commit(clone, "c.txt", "feat: add c")
    aggregate_failures "follow-up promotion" do
      out, code = promote(live, clone, "feat", "--yes")
      expect(code).to eq(0), out
      expect(count(live, "main..feat")).to eq("3")   # no duplicates
      expect(out).to include("Promoted 1 commit")
    end

    # 4b. dependent commits (both edit dep.txt): a newest-first replay cannot
    #     apply, so order bugs would fail here
    commit(clone, "dep.txt", "feat: dep line1")
    commit(clone, "dep.txt", "feat: dep line2")
    aggregate_failures "dependent-commit promotion" do
      out, code = promote(live, clone, "feat", "--yes")
      expect(code).to eq(0), out
      expect(File.read(File.join(live, "dep.txt")).strip.tr("\n", "|"))
        .to eq("feat: dep line1|feat: dep line2")
      expect(count(live, "main..feat")).to eq("5")
    end

    # 5. subject collision: amend the promoted tip in live (its patch-id now
    #    differs from the clone copy), clone adds d
    File.open(File.join(live, "c.txt"), "a") { |f| f.puts("tweak") }
    g!(live, "add", "c.txt")
    g!(live, "commit", "--quiet", "--no-gpg-sign", "--amend", "--no-edit")
    commit(clone, "d.txt", "feat: add d")
    aggregate_failures "amended-pair collision" do
      out, code = promote(live, clone, "feat", "--yes")
      expect(code).to eq(1), out
      expect(out).to include("subject collision")
      expect(count(live, "main..feat")).to eq("5") # nothing applied
    end
  end

  it "gates a merge commit, a no-TTY run without --yes, and a wrong branch" do
    live = File.join(@root, "live2")
    clone = File.join(@root, "clone2")
    FileUtils.mkdir_p(live)
    g!(live, "init", "--quiet", "-b", "main")
    commit(live, "base.txt", "base")
    clone_noremote(live, clone)

    # 6. merge-commit gate
    g!(clone, "switch", "--quiet", "-c", "feat")
    commit(clone, "a.txt", "feat: add a")
    g!(clone, "switch", "--quiet", "-c", "side", "main")
    commit(clone, "s.txt", "side work")
    g!(clone, "switch", "--quiet", "feat")
    g!(clone, "merge", "--quiet", "--no-gpg-sign", "--no-edit", "side")
    g!(live, "switch", "--quiet", "-c", "feat")
    aggregate_failures "merge-commit gate" do
      out, code = promote(live, clone, "feat", "--yes")
      expect(code).to eq(1), out
      expect(out).to include("must be linear")
    end

    # 7. no TTY and no --yes: abort before applying (fresh linear branch)
    g!(clone, "switch", "--quiet", "-c", "feat2", "main")
    commit(clone, "b.txt", "feat: add b")
    g!(live, "switch", "--quiet", "-c", "feat2", "main")
    aggregate_failures "no-TTY without --yes" do
      out, code = promote(live, clone, "feat2") # stdin closed by capture2e
      expect(code).to eq(1), out
      expect(out).to include("re-run with --yes")
    end

    # 8. wrong-branch guard
    g!(live, "switch", "--quiet", "main")
    aggregate_failures "wrong-branch guard" do
      out, code = promote(live, clone, "feat", "--yes")
      expect(code).to eq(1), out
      expect(out).to include("git switch feat")
    end
  end
end
