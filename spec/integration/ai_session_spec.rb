# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "json"
require "open3"
require "tmpdir"

# scripts/ai/ai-session.sh grew three enforcement mechanisms in the
# session-hygiene work: the vault (pre-write copies of the volatile .ai/
# files, one-way by sandbox construction), unclean-close detection (a session
# that skipped the end ritual is the first thing the next session hears
# about), and close-check (the Stop-hook gate that blocks a defective closing
# recipe). A guard nobody has made fire may not fire at all — repo-foundation
# has shipped two that did not — so every blocking path below is driven to a
# real block, and every silence path to real silence.
#
# The vault writes under XDG_STATE_HOME, which each example points into its
# own tmpdir so the developer's real vault is never touched.
RSpec.describe "scripts/ai/ai-session.sh" do
  let(:script) { File.expand_path("../../scripts/ai/ai-session.sh", __dir__) }

  def sh!(dir, *cmd)
    out, err, status = Open3.capture3(*cmd, chdir: dir)
    raise "command failed: #{cmd.inspect}\nstdout: #{out}\nstderr: #{err}" unless status.success?

    out
  end

  def run_ai(dir, state, *args, stdin: nil)
    env = { "XDG_STATE_HOME" => state, "CLAUDE_PROJECT_DIR" => nil }
    Open3.capture3(env, script, *args, chdir: dir, stdin_data: stdin || "")
  end

  # A repository on main with the .ai layer, ignored the way org repos ignore
  # it (so the tree reads clean to `git status`), plus an origin/main ref so
  # the ahead-of-upstream close shape is testable without a network remote.
  def with_repo
    Dir.mktmpdir("rf-ai-session-") do |dir|
      state = File.join(dir, "state")
      repo = File.join(dir, "repo")
      FileUtils.mkdir_p(repo)
      sh!(repo, "git", "init", "--quiet", "--initial-branch=main")
      sh!(repo, "git", "config", "user.email", "test@example.invalid")
      sh!(repo, "git", "config", "user.name", "Test")
      File.write(File.join(repo, ".gitignore"), ".ai/\n")
      File.write(File.join(repo, "tracked.txt"), "seed\n")
      sh!(repo, "git", "add", "-A")
      sh!(repo, "git", "commit", "--quiet", "--no-gpg-sign", "-m", "seed")
      FileUtils.mkdir_p(File.join(repo, ".ai", "scratchpad"))
      File.write(File.join(repo, ".ai", "progress.md"), "# progress\n")
      ref_dir = File.join(repo, ".git", "refs", "remotes", "origin")
      FileUtils.mkdir_p(ref_dir)
      File.write(File.join(ref_dir, "main"), sh!(repo, "git", "rev-parse", "main"))
      yield repo, state
    end
  end

  def vault_files(state)
    Dir.glob(File.join(state, "ai-history", "**", "*")).select { |f| File.file?(f) }
  end

  def close_check(repo, state, message, session: "sess-1", active: false)
    payload = { session_id: session, stop_hook_active: active,
                last_assistant_message: message }.to_json
    out, err, status = run_ai(repo, state, "close-check", stdin: payload)
    expect(status.exitstatus).to eq(0), "close-check must always exit 0; got #{status.exitstatus}: #{err}"
    out.empty? ? {} : JSON.parse(out)
  end

  describe "vault" do
    it "copies a draft in, announces both paths, and dedupes identical content" do
      with_repo do |repo, state|
        draft = File.join(repo, ".ai", "scratchpad", "commit-msg-x.md")
        File.write(draft, "feat: x\n\nbody\n")

        out, _err, status = run_ai(repo, state, "vault", "--session=abcd1234",
                                   ".ai/scratchpad/commit-msg-x.md")
        expect(status.exitstatus).to eq(0)
        expect(out).to include("Snapshotting .ai/scratchpad/commit-msg-x.md")
        expect(vault_files(state).length).to eq(1)

        out2, = run_ai(repo, state, "vault", "--session=abcd1234",
                       ".ai/scratchpad/commit-msg-x.md")
        expect(out2).to eq("")
        expect(vault_files(state).length).to eq(1)
      end
    end

    it "emits a systemMessage JSON under --json, for the hook shims" do
      with_repo do |repo, state|
        File.write(File.join(repo, ".ai", "scratchpad", "pr-body-y.md"), "body\n")
        out, = run_ai(repo, state, "vault", "--json", "--session=abcd1234",
                      ".ai/scratchpad/pr-body-y.md")
        msg = JSON.parse(out)
        expect(msg["systemMessage"]).to include("Snapshotting .ai/scratchpad/pr-body-y.md")
      end
    end

    it "refuses files outside the volatile continuity set" do
      with_repo do |repo, state|
        run_ai(repo, state, "vault", "--session=abcd1234", "tracked.txt")
        expect(vault_files(state)).to be_empty
      end
    end

    it "caps progress.md copies at the newest 10" do
      with_repo do |repo, state|
        progress = File.join(repo, ".ai", "progress.md")
        12.times do |i|
          File.write(progress, "# progress #{i}\n")
          _out, _err, status = run_ai(repo, state, "vault", "--session=s#{format('%02d', i)}",
                                      ".ai/progress.md")
          expect(status.exitstatus).to eq(0)
        end
        copies = vault_files(state).select { |f| File.basename(f).end_with?("-progress.md") }
        expect(copies.length).to eq(10)
        # The survivors are the NEWEST ten: the s00/s01 copies are gone.
        expect(copies.map { |f| File.basename(f) }.sort.first).to include("-s02-")
      end
    end

    it "auto-prunes a gone draft only on full-message landing evidence" do
      with_repo do |repo, state|
        draft = File.join(repo, ".ai", "scratchpad", "commit-msg-z.md")
        File.write(draft, "feat: z thing\n\nreal body\n")
        run_ai(repo, state, "vault", "--session=abcd1234", ".ai/scratchpad/commit-msg-z.md")

        # Landed with the SAME subject but a DIFFERENT body: not evidence.
        sh!(repo, "git", "commit", "--quiet", "--allow-empty", "--no-gpg-sign",
            "-m", "feat: z thing\n\nother body")
        FileUtils.rm(draft)
        run_ai(repo, state, "vault", "--session=abcd1234", ".ai/progress.md")
        expect(vault_files(state).any? { |f| f.include?("commit-msg-z") }).to be(true),
                                                                             "subject-only match must not prune"

        # Landed with the full message: evidence; the copies go.
        sh!(repo, "git", "commit", "--quiet", "--allow-empty", "--no-gpg-sign",
            "-m", "feat: z thing\n\nreal body")
        File.write(File.join(repo, ".ai", "progress.md"), "# progress moved\n")
        run_ai(repo, state, "vault", "--session=abcd1234", ".ai/progress.md")
        expect(vault_files(state).any? { |f| f.include?("commit-msg-z") }).to be(false)
      end
    end

    it "reports the no-evidence class after 30 noticed days and vault-gc removes it" do
      with_repo do |repo, state|
        issue = File.join(repo, ".ai", "scratchpad", "issue-upstream.md")
        File.write(issue, "an issue draft\n")
        run_ai(repo, state, "vault", "--session=abcd1234", ".ai/scratchpad/issue-upstream.md")
        FileUtils.rm(issue)
        run_ai(repo, state, "vault", "--session=abcd1234", ".ai/progress.md")

        gone = Dir.glob(File.join(state, "ai-history", "**", ".gone-noticed")).first
        expect(gone).not_to be_nil, "the sweep must record the gone draft"
        # Backdate the noticing 31 days; the TTL runs from noticing, so this
        # is the only clock to move.
        File.write(gone, File.read(gone).gsub(/ \d+$/, " #{Time.now.to_i - (31 * 86_400)}"))

        out, _err, status = run_ai(repo, state, "start")
        expect(status.exitstatus).to eq(0)
        expect(out).to include("gone 30+ days")
        expect(out).to include("vault-gc")
        expect(vault_files(state).any? { |f| f.include?("issue-upstream") }).to be(true),
                                                                               "start only reports; it must not delete"

        run_ai(repo, state, "vault-gc")
        expect(vault_files(state).any? { |f| f.include?("issue-upstream") }).to be(false)
      end
    end
  end

  describe "init" do
    it "creates the layer once and is a no-op after" do
      Dir.mktmpdir("rf-ai-init-") do |dir|
        state = File.join(dir, "state")
        plain = File.join(dir, "plain")
        FileUtils.mkdir_p(plain)
        out, _err, status = run_ai(plain, state, "init")
        expect(status.exitstatus).to eq(0)
        expect(out).to include("created")
        expect(File).to exist(File.join(plain, ".ai", "progress.md"))

        out2, = run_ai(plain, state, "init")
        expect(out2).to include("already has")
      end
    end
  end

  describe "unclean-close detection" do
    it "warns the next session, with the resume command, when end never ran" do
      with_repo do |repo, state|
        run_ai(repo, state, "start", "--session=aaaa-1111")
        out, _err, status = run_ai(repo, state, "start", "--session=bbbb-2222")
        expect(status.exitstatus).to eq(0)
        expect(out).to include("did NOT complete its close ritual")
        expect(out).to include("claude --resume aaaa-1111")
        expect(out).to include("/tb-session-close")
      end
    end

    it "stays quiet after a clean end, and a resume keeps the snapshot" do
      with_repo do |repo, state|
        run_ai(repo, state, "start", "--session=aaaa-1111")
        run_ai(repo, state, "end", "--session=aaaa-1111")
        out, = run_ai(repo, state, "start", "--session=bbbb-2222")
        expect(out).not_to include("did NOT complete")

        # Same session firing start again (Claude Code fires SessionStart on
        # resume): the snapshot must survive as the end ritual's diff base.
        snapshot = File.join(repo, ".ai", ".progress.session-start")
        before = File.mtime(snapshot)
        File.write(File.join(repo, ".ai", "progress.md"), "# changed mid-session\n")
        out2, = run_ai(repo, state, "start", "--session=bbbb-2222")
        expect(out2).to include("same session resumed")
        expect(File.mtime(snapshot)).to eq(before)
      end
    end
  end

  describe "close-check" do
    it "blocks a recipe naming a path that does not exist" do
      with_repo do |repo, state|
        FileUtils.touch(File.join(repo, ".ai", "progress.md"))
        result = close_check(repo, state,
                             "Closing recipe:\n```sh\ngh pr create --body-file .ai/scratchpad/pr-body-gone.md\n```")
        expect(result["decision"]).to eq("block")
        expect(result["reason"]).to include("pr-body-gone.md")
        expect(result["reason"]).to include("re-derive the recipe")
      end
    end

    it "blocks an rm of an already-absent path as a stale step" do
      with_repo do |repo, state|
        result = close_check(repo, state,
                             "Closing recipe:\n```sh\nrm -f .ai/scratchpad/already-gone.md\n```")
        expect(result["decision"]).to eq("block")
        expect(result["reason"]).to include("stale recipe step")
      end
    end

    it "blocks a cp whose endpoints already compare equal" do
      with_repo do |repo, state|
        src = File.join(repo, ".ai", "scratchpad", "mirror.md")
        File.write(src, "same\n")
        result = close_check(repo, state,
                             "```sh\ncp -p .ai/scratchpad/mirror.md .ai/scratchpad/mirror.md\n```")
        expect(result["reason"]).to include("already done")
      end
    end

    it "never parses prose outside fences" do
      with_repo do |repo, state|
        FileUtils.touch(File.join(repo, ".ai", "progress.md"))
        result = close_check(repo, state,
                             "Earlier I deleted .ai/scratchpad/pr-body-gone.md as planned.")
        expect(result).to eq({})
      end
    end

    it "blocks the same finding set only once, then downgrades visibly" do
      with_repo do |repo, state|
        msg = "Closing recipe:\n```sh\ncat .ai/scratchpad/nope.md\n```"
        first = close_check(repo, state, msg)
        expect(first["decision"]).to eq("block")

        second = close_check(repo, state, msg)
        expect(second["decision"]).to be_nil
        expect(second["systemMessage"]).to include("persists after one retry")
      end
    end

    it "never blocks when the harness reports the stop hook already active" do
      with_repo do |repo, state|
        msg = "Closing recipe:\n```sh\ncat .ai/scratchpad/nope.md\n```"
        result = close_check(repo, state, msg, active: true)
        expect(result["decision"]).to be_nil
        expect(result["systemMessage"]).to include("persists")
      end
    end

    it "blocks a close claim over a progress.md older than the snapshot" do
      with_repo do |repo, state|
        run_ai(repo, state, "start", "--session=cccc-3333")
        # progress.md untouched since the snapshot; claim a close.
        result = close_check(repo, state, "All wrapped up — run sign-push.sh and merge.")
        expect(result["decision"]).to eq("block")
        expect(result["reason"]).to include("progress.md has not been rewritten")
      end
    end

    it "blocks a spent commit-msg draft and lets an unlanded one sit" do
      with_repo do |repo, state|
        FileUtils.touch(File.join(repo, ".ai", "progress.md"))
        draft = File.join(repo, ".ai", "scratchpad", "commit-msg-w.md")
        File.write(draft, "feat: w\n\nw body\n")

        expect(close_check(repo, state, "nothing to see")).to eq({})

        sh!(repo, "git", "commit", "--quiet", "--allow-empty", "--no-gpg-sign",
            "-m", "feat: w\n\nw body")
        result = close_check(repo, state, "nothing to see", session: "sess-2")
        expect(result["decision"]).to eq("block")
        expect(result["reason"]).to include("spent draft")
      end
    end

    it "notes, without blocking, a draft whose subject landed with a different body" do
      with_repo do |repo, state|
        FileUtils.touch(File.join(repo, ".ai", "progress.md"))
        File.write(File.join(repo, ".ai", "scratchpad", "commit-msg-v.md"),
                   "feat: v\n\ndraft body\n")
        sh!(repo, "git", "commit", "--quiet", "--allow-empty", "--no-gpg-sign",
            "-m", "feat: v\n\nlanded body")
        # Advance the fake origin so the close-shaped check (a different
        # finding) cannot fire and mask this one.
        File.write(File.join(repo, ".git", "refs", "remotes", "origin", "main"),
                   sh!(repo, "git", "rev-parse", "HEAD"))
        result = close_check(repo, state, "nothing to see")
        expect(result["decision"]).to be_nil
        expect(result["systemMessage"]).to include("pending --amend")
      end
    end

    it "blocks a pr draft whose parked merged/prNN branch proves the merge" do
      with_repo do |repo, state|
        FileUtils.touch(File.join(repo, ".ai", "progress.md"))
        File.write(File.join(repo, ".ai", "scratchpad", "pr12-comment-x.md"), "text\n")
        sh!(repo, "git", "branch", "merged/pr012/feature/x")
        result = close_check(repo, state, "nothing to see")
        expect(result["decision"]).to eq("block")
        expect(result["reason"]).to include("parked merged/prNN")
      end
    end

    it "demands a recipe (or a reasoned decline) on a close-shaped turn" do
      with_repo do |repo, state|
        FileUtils.touch(File.join(repo, ".ai", "progress.md"))
        sh!(repo, "git", "commit", "--quiet", "--allow-empty", "--no-gpg-sign", "-m", "wip: ahead")
        result = close_check(repo, state, "That is all for today.")
        expect(result["decision"]).to eq("block")
        expect(result["reason"]).to include("closing recipe")

        touch_progress = File.join(repo, ".ai", "progress.md")
        File.write(touch_progress, "# rewritten\n")
        declined = close_check(repo, state,
                               "Closing recipe: none — docs-only artifact turn.", session: "sess-3")
        expect(declined).to eq({})
      end
    end

    it "is silent and exits 0 outside a git repository" do
      Dir.mktmpdir("rf-ai-nongit-") do |dir|
        state = File.join(dir, "state")
        plain = File.join(dir, "plain")
        FileUtils.mkdir_p(File.join(plain, ".ai", "scratchpad"))
        File.write(File.join(plain, ".ai", "progress.md"), "# p\n")
        payload = { session_id: "s", stop_hook_active: false,
                    last_assistant_message: "bye" }.to_json
        out, _err, status = run_ai(plain, state, "close-check", stdin: payload)
        expect(status.exitstatus).to eq(0)
        expect(out).to eq("")
      end
    end
  end

  # The vault's no-evidence class is deleted by vault-gc ALONE, and vault-gc
  # is maintainer-run: the settings must never wire it into a hook. This is
  # the executable half of that promise — re-adding it is a failing test,
  # not a quiet drift.
  it "keeps vault-gc out of every settings hook" do
    [
      ".claude/settings.json",
      "provides/repo/settings.baseline.json",
      "provides/claude-user/settings.json",
    ].each do |rel|
      settings = File.read(File.expand_path("../../#{rel}", __dir__))
      hooks = JSON.parse(settings)["hooks"] or next
      expect(hooks.to_json).not_to include("vault-gc"),
                                   "#{rel} wires vault-gc into a hook; that class is maintainer-deleted only"
    end
  end
end
