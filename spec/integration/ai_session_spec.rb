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
        # The status assertion is load-bearing: an empty vault also results
        # from the script erroring out, so without it this example would pass
        # for the wrong reason.
        _out, _err, status = run_ai(repo, state, "vault", "--session=abcd1234", "tracked.txt")
        expect(status.exitstatus).to eq(0)
        expect(vault_files(state)).to be_empty
      end
    end

    it "vaults a NESTED scratchpad path and round-trips its name" do
      with_repo do |repo, state|
        nested = File.join(repo, ".ai", "scratchpad", "tb-coordination", "dispatch.md")
        FileUtils.mkdir_p(File.dirname(nested))
        File.write(nested, "row\n")
        run_ai(repo, state, "vault", "--session=abcd1234",
               ".ai/scratchpad/tb-coordination/dispatch.md")
        copy = vault_files(state).find { |f| f.include?("tb-coordination") }
        expect(copy).not_to be_nil, "a nested scratchpad path must still be vaulted"
        expect(File.basename(copy)).to end_with("scratchpad__tb-coordination__dispatch.md")

        # And the sweep must decode that name back to the live source rather
        # than treating it as gone (which would start its expiry clock).
        run_ai(repo, state, "vault", "--session=abcd1234", ".ai/progress.md")
        gone = Dir.glob(File.join(state, "ai-history", "**", ".gone-noticed")).first
        expect(gone.nil? || !File.read(gone).include?("tb-coordination")).to be(true)
      end
    end

    # Awkward names get ESCAPED, never skipped. Refusing to copy a file
    # because its name is awkward would convert a naming inconvenience into
    # the data loss this whole mechanism exists to prevent.
    [
      ["a name carrying the separator", "foo__bar.md"],
      ["a name carrying a single underscore", "foo_bar.md"],
      ["a name carrying a space", "has space.md"],
      ["a name carrying both markers literally", "_S_U__literal.md"],
    ].each do |label, basename|
      it "vaults #{label}, and the sweep reads it back to the live source" do
        with_repo do |repo, state|
          File.write(File.join(repo, ".ai", "scratchpad", basename), "x\n")
          _out, _err, status = run_ai(repo, state, "vault", "--session=abcd1234",
                                      ".ai/scratchpad/#{basename}")
          expect(status.exitstatus).to eq(0)
          expect(vault_files(state).length).to eq(1)

          # Decoding is what proves the escape reversible: the sweep resolves
          # each copy back to a source path, and a source it still finds on
          # disk must NOT be recorded as gone.
          run_ai(repo, state, "vault", "--session=abcd1234", ".ai/progress.md")
          gone = Dir.glob(File.join(state, "ai-history", "**", ".gone-noticed")).first
          expect(gone).to be_nil,
                          "the escaped name decoded to the wrong path: #{gone && File.read(gone)}"
        end
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

  describe "vault-hook" do
    def vault_hook(repo, state, payload)
      run_ai(repo, state, "vault-hook", stdin: payload.to_json)
    end

    it "vaults an Edit/Write target from the hook JSON" do
      with_repo do |repo, state|
        File.write(File.join(repo, ".ai", "scratchpad", "pr-body-h.md"), "body\n")
        out, _err, status = vault_hook(repo, state,
                                       { session_id: "abcd1234-x", tool_name: "Write",
                                         tool_input: { file_path: File.join(repo, ".ai", "scratchpad", "pr-body-h.md") } })
        expect(status.exitstatus).to eq(0)
        expect(JSON.parse(out)["systemMessage"]).to include("Snapshotting")
        expect(vault_files(state).any? { |f| f.include?("pr-body-h") }).to be(true)
      end
    end

    it "vaults the scratchpad paths named by a Bash rm command" do
      with_repo do |repo, state|
        File.write(File.join(repo, ".ai", "scratchpad", "commit-msg-r.md"), "feat: r\n")
        out, _err, status = vault_hook(repo, state,
                                       { session_id: "abcd1234-x", tool_name: "Bash",
                                         tool_input: { command: "rm -f .ai/scratchpad/commit-msg-r.md" } })
        expect(status.exitstatus).to eq(0)
        expect(JSON.parse(out)["systemMessage"]).to include("commit-msg-r")
      end
    end

    it "ignores a Bash command that deletes nothing" do
      with_repo do |repo, state|
        File.write(File.join(repo, ".ai", "scratchpad", "commit-msg-r.md"), "feat: r\n")
        out, _err, status = vault_hook(repo, state,
                                       { session_id: "abcd1234-x", tool_name: "Bash",
                                         tool_input: { command: "cat .ai/scratchpad/commit-msg-r.md" } })
        expect(status.exitstatus).to eq(0)
        expect(out).to eq("")
        expect(vault_files(state)).to be_empty
      end
    end

    it "defaults to progress.md when the event carries no tool_input" do
      with_repo do |repo, state|
        out, _err, status = vault_hook(repo, state, { session_id: "abcd1234-x" })
        expect(status.exitstatus).to eq(0)
        expect(JSON.parse(out)["systemMessage"]).to include("progress.md")
      end
    end
  end

  # hook-run.sh is the validator every settings hook runs through. It exists
  # because a syntax error in a hooked script exits 2, and exit 2 from
  # PreToolUse/Stop BLOCKS — so on 2026-08-07 a broken ai-session.sh refused
  # every Edit, Write, and Bash call at once, including the edit that would
  # have fixed it. A guard whose own code is broken must fail OPEN.
  describe "hook-run.sh" do
    let(:runner) { File.expand_path("../../scripts/ai/hook-run.sh", __dir__) }

    def run_hook(dir, *args)
      Open3.capture3({ "CLAUDE_PROJECT_DIR" => dir }, runner, *args, chdir: dir)
    end

    around do |example|
      Dir.mktmpdir("rf-hook-run-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "scripts", "ai"))
        FileUtils.cp(File.expand_path("../../scripts/ai/hook-run.sh", __dir__),
                     File.join(dir, "scripts", "ai"))
        @dir = dir
        example.run
      end
    end

    def write_script(name, body)
      path = File.join(@dir, "scripts", "ai", name)
      File.write(path, body)
      FileUtils.chmod(0o755, path)
      path
    end

    it "runs a valid script and passes its arguments through" do
      write_script("good.sh", "#!/bin/sh\nprintf 'ran:%s\\n' \"$1\"\n")
      out, _err, status = run_hook(@dir, "good.sh", "verb")
      expect(status.exitstatus).to eq(0)
      expect(out).to include("ran:verb")
    end

    it "fails OPEN on a script with a syntax error, silently" do
      write_script("bad.sh", "#!/bin/sh\nprintf 'unterminated\n")
      out, err, status = run_hook(@dir, "bad.sh")
      expect(status.exitstatus).to eq(0), "a broken hook script must not block the tool call"
      expect(err).to be_empty, "the parse diagnostic must not reach the agent"
      expect(out).to be_empty
    end

    it "fails open on a missing or non-executable script, and on no argument" do
      File.write(File.join(@dir, "scripts", "ai", "plain.sh"), "#!/bin/sh\ntrue\n")
      expect(run_hook(@dir, "absent.sh").last.exitstatus).to eq(0)
      expect(run_hook(@dir, "plain.sh").last.exitstatus).to eq(0)
      expect(run_hook(@dir).last.exitstatus).to eq(0)
    end

    it "propagates a valid script's own blocking exit" do
      write_script("blocker.sh", "#!/bin/sh\necho nope >&2\nexit 2\n")
      _out, err, status = run_hook(@dir, "blocker.sh")
      expect(status.exitstatus).to eq(2), "a working guard must still be able to refuse"
      expect(err).to include("nope")
    end
  end

  describe "compact-check" do
    def compact(repo, state, session: "sess-c")
      payload = { session_id: session, trigger: "auto" }.to_json
      out, _err, status = run_ai(repo, state, "compact-check", stdin: payload)
      expect(status.exitstatus).to eq(0)
      out.empty? ? {} : JSON.parse(out)
    end

    it "blocks when progress.md predates work done since it was written" do
      with_repo do |repo, state|
        run_ai(repo, state, "start", "--session=sess-c")
        # progress.md rewritten, THEN more work lands — the case a plain
        # newer-than-session-start test would wrongly pass.
        sleep 1
        File.write(File.join(repo, ".ai", "progress.md"), "# written early\n")
        sleep 1
        File.write(File.join(repo, ".ai", "scratchpad", "commit-msg-later.md"), "feat: later\n")

        result = compact(repo, state)
        expect(result["decision"]).to eq("block")
        expect(result["reason"]).to include("compacted")
        expect(result["reason"]).to include(".ai/memory.md")
      end
    end

    it "passes once progress.md is brought current, and vaults regardless" do
      with_repo do |repo, state|
        run_ai(repo, state, "start", "--session=sess-c")
        File.write(File.join(repo, ".ai", "scratchpad", "commit-msg-x.md"), "feat: x\n")
        expect(compact(repo, state)["decision"]).to eq("block")
        # The copy happens before the block, so a block never costs a snapshot.
        expect(vault_files(state).any? { |f| f.end_with?("progress.md") }).to be(true)

        sleep 1
        File.write(File.join(repo, ".ai", "progress.md"), "# now current\n")
        expect(compact(repo, state)).to eq({})
      end
    end

    it "gives a fresh prompt budget after the agent complies once" do
      with_repo do |repo, state|
        run_ai(repo, state, "start", "--session=sess-c")
        sleep 1
        File.write(File.join(repo, ".ai", "scratchpad", "a.md"), "x\n")
        expect(compact(repo, state)["decision"]).to eq("block")
        expect(compact(repo, state)["decision"]).to eq("block")

        sleep 1
        File.write(File.join(repo, ".ai", "progress.md"), "# complied\n")
        expect(compact(repo, state)).to eq({})

        # Stale again later: the cap counts CONSECUTIVE stale checks, so this
        # must block rather than inherit the spent counter.
        sleep 1
        File.write(File.join(repo, ".ai", "scratchpad", "b.md"), "y\n")
        expect(compact(repo, state)["decision"]).to eq("block")
      end
    end

    it "stops blocking after two attempts so a session cannot wedge" do
      with_repo do |repo, state|
        run_ai(repo, state, "start", "--session=sess-c")
        sleep 1
        File.write(File.join(repo, ".ai", "scratchpad", "stubborn.md"), "x\n")
        expect(compact(repo, state)["decision"]).to eq("block")
        expect(compact(repo, state)["decision"]).to eq("block")
        third = compact(repo, state)
        expect(third["decision"]).to be_nil
        expect(third["systemMessage"]).to include("still stale")
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
