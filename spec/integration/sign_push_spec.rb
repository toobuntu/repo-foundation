# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "English"
require "fileutils"
require "open3"
require "tmpdir"

# Behavioral tests for scripts/sign-push.sh — signs the unpushed unsigned
# commits an agent left behind, then pushes what was signed when the push is
# safe. Ported from the former scripts/sign-push-test.sh; real signing via a
# throwaway SSH key and real pushes to a local bare "origin" (no network),
# the same real-git approach sync_files_spec uses.
#
# The interactive diverged-origin confirm needs a pty; it is exercised
# manually and here only in its non-interactive form (stdin closed -> exit 3).
SIGN_PUSH = File.join(REPO_ROOT, "scripts", "sign-push.sh")

module SignPushHelpers
  # git in the given repo with an isolated identity and signing config; the
  # env keys neutralize the developer's real ~/.gitconfig so %G? is
  # deterministic (KEY / ALLOWED are set once for the suite).
  def git(repo, *args)
    out, err, status = Open3.capture3(git_env, "git", "-C", repo, *args)
    [out, err, status]
  end

  def git!(repo, *args)
    out, err, status = git(repo, *args)
    raise "git #{args.inspect} failed in #{repo}:\n#{err}#{out}" unless status.success?
    out
  end

  def git_env
    {
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_CONFIG_SYSTEM" => "/dev/null",
    }
  end

  # Fresh repo on branch main configured for headless SSH signing.
  def make_repo
    dir = Dir.mktmpdir("repo.", @work)
    git!(dir, "init", "--quiet", "-b", "main")
    git!(dir, "config", "user.email", "me@test")
    git!(dir, "config", "user.name", "Me")
    git!(dir, "config", "commit.gpgsign", "false")
    git!(dir, "config", "gpg.format", "ssh")
    git!(dir, "config", "user.signingkey", "#{@key}.pub")
    git!(dir, "config", "gpg.ssh.allowedSignersFile", @allowed)
    dir
  end

  # Append <msg> to ./file, stage, commit. signed: adds --gpg-sign.
  def commit(repo, msg, signed: false, author: nil)
    File.open(File.join(repo, "file"), "a") { |f| f.puts(msg) }
    git!(repo, "add", "file")
    args = ["commit", "--quiet", "-m", msg]
    args << "--gpg-sign" if signed
    if author
      git!(repo, "-c", "user.email=#{author}", "-c", "user.name=Other", *args)
    else
      git!(repo, *args)
    end
  end

  # Wire a bare repo as origin. -b main so its HEAD is main (else a clone of
  # it checks out an unborn default branch, breaking advance_origin).
  def mk_origin(repo)
    bare = File.join(Dir.mktmpdir("bare.", @work), "o.git")
    _o, err, status = Open3.capture3(git_env, "git", "init", "--quiet", "--bare", "-b", "main", bare)
    raise "bare init failed: #{err}" unless status.success?
    git!(repo, "remote", "add", "origin", bare)
    bare
  end

  # Run the script under test in <repo>; returns [combined_output, exit].
  def sign_push(repo, *flags, stdin_data: "")
    out, status = Open3.capture2e(git_env, "sh", SIGN_PUSH, *flags, repo, stdin_data: stdin_data)
    [out, status.exitstatus]
  end

  # Advance the bare origin from a throwaway second clone, so a later local
  # rewrite genuinely diverges from a real remote (the lease then matches).
  def advance_origin(bare)
    c2 = Dir.mktmpdir("adv.", @work)
    _o, err, st = Open3.capture3(git_env, "git", "clone", "--quiet", bare, c2)
    raise "clone bare failed: #{err}" unless st.success?
    git!(c2, "config", "user.email", "other@test")
    git!(c2, "config", "user.name", "Other")
    File.write(File.join(c2, "other"), "x\n")
    git!(c2, "add", "other")
    git!(c2, "commit", "-qm", "other from elsewhere")
    git!(c2, "push", "-q", "origin", "HEAD:main")
  end

  def bare_main(bare)
    _o, _e, _s = git(bare, "rev-parse", "main") # bare is a git dir; -C works
    git!(bare, "rev-parse", "main").strip
  end

  # Drive the interactive diverged-origin confirm under a pty, answering the
  # [y/N] prompt with <answer>. Returns the script's exit status.
  def sign_push_confirm(repo, answer)
    require "pty"
    require "expect"
    exitstatus = nil
    # PTY.spawn does not take an env hash like Kernel#spawn, so set the
    # isolating git vars through the `env` command instead.
    env_args = git_env.map { |k, v| "#{k}=#{v}" }
    PTY.spawn("env", *env_args, "sh", SIGN_PUSH, repo) do |r_out, w_in, pid|
      raise "confirm prompt not seen" unless r_out.expect(%r{\[y/N\]}, 30)

      w_in.puts answer
      begin
        r_out.read # drain to EOF; the child exiting raises EIO on the pty
      rescue Errno::EIO
        # expected: child has exited
      end
      _p, st = Process.wait2(pid)
      exitstatus = st.exitstatus
    end
    exitstatus
  end

  # True if any commit in <range> is unsigned (%G? == N).
  def unsigned_in?(repo, range)
    git!(repo, "log", "--format=%G?", range).lines.map(&:strip).include?("N")
  end

  def sha(repo, rev)
    git!(repo, "rev-parse", rev).strip
  end
end

RSpec.describe "scripts/sign-push.sh" do
  include SignPushHelpers

  before(:all) do
    @work = Dir.mktmpdir("rf-sign-push-")
    @key = File.join(@work, "key")
    @allowed = File.join(@work, "allowed")
    system("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", @key) or
      raise "ssh-keygen failed"
    # Pin verification locally so ssh signatures read as good without the
    # developer's global signing config.
    File.write(@allowed, "me@test,other@test #{File.read("#{@key}.pub")}")

    # The interactive confirm tests need a pty; the Seatbelt sandbox denies
    # /dev/ptmx, so probe once and skip those cases there. They run for real on
    # a developer machine and the CI runner (both unsandboxed).
    @pty_ok = begin
      require "pty"
      PTY.spawn("true") { |_r, _w, pid| Process.wait(pid) }
      true
    rescue StandardError
      false
    end
  end

  after(:all) { FileUtils.remove_entry(@work) if @work }

  it "no-ops on an empty repo" do
    r = make_repo
    out, code = sign_push(r)
    expect(code).to eq(0)
    expect(out).to include("no commits yet")
  end

  it "skips a detached HEAD with a note" do
    r = make_repo
    commit(r, "one")
    git!(r, "switch", "--quiet", "--detach", "HEAD")
    out, code = sign_push(r)
    expect(code).to eq(0)
    expect(out).to include("detached HEAD")
  end

  it "signs a local-only repo but pushes nothing" do
    r = make_repo
    commit(r, "one")
    commit(r, "two")
    out, code = sign_push(r)
    expect(code).to eq(0)
    expect(out).to include("local-only repo")
    expect(unsigned_in?(r, "HEAD")).to be(false)
  end

  it "signs then set-upstream pushes when origin does not know the branch" do
    r = make_repo
    commit(r, "one")
    mk_origin(r)
    out, code = sign_push(r)
    expect(code).to eq(0)
    expect(out).to include("pushing with --set-upstream")
    expect(unsigned_in?(r, "HEAD")).to be(false)
    expect(sha(r, "HEAD")).to eq(sha(r, "origin/main"))
  end

  it "signs then fast-forward pushes on top of pushed history" do
    r = make_repo
    commit(r, "one")
    mk_origin(r)
    sign_push(r) # publish "one"
    commit(r, "two")
    out, code = sign_push(r)
    expect(code).to eq(0)
    expect(out).to include("fast-forward")
    expect(sha(r, "HEAD")).to eq(sha(r, "origin/main"))
  end

  it "reports current and pushes nothing when fully signed and up to date" do
    r = make_repo
    commit(r, "one")
    mk_origin(r)
    sign_push(r)
    out, code = sign_push(r)
    expect(code).to eq(0)
    expect(out).to include("origin/main is current")
  end

  it "exits 2 with a push hint when a signed commit is ahead" do
    r = make_repo
    commit(r, "one")
    mk_origin(r)
    sign_push(r)
    commit(r, "two", signed: true)
    out, code = sign_push(r)
    expect(code).to eq(2)
    expect(out).to include("To push: git -C")
  end

  it "exits 2 with a set-upstream hint for a signed unborn branch" do
    r = make_repo
    commit(r, "one")
    mk_origin(r)
    sign_push(r)
    git!(r, "switch", "--quiet", "-c", "topic")
    commit(r, "t1", signed: true)
    out, code = sign_push(r)
    expect(code).to eq(2)
    expect(out).to include("push --set-upstream origin topic")
  end

  it "refuses (exit 3) and hands over the lease command on a diverged origin" do
    r = make_repo
    commit(r, "one")
    mk_origin(r)
    git!(r, "push", "-q", "-u", "origin", "main")
    alt = git!(r, "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "alt").strip
    git!(r, "update-ref", "refs/remotes/origin/main", alt) # origin moved elsewhere
    commit(r, "two")
    out, code = sign_push(r)
    expect(code).to eq(3)
    expect(out).to include("DIVERGED; not force-pushing")
    expect(out).to include("force-with-lease")
  end

  it "rebuilds the spine preserving a merge, its author, topology, and content" do
    r = make_repo
    commit(r, "base")
    mk_origin(r)
    git!(r, "push", "-q", "-u", "origin", "main")
    git!(r, "switch", "-qc", "side")
    File.write(File.join(r, "s"), "s\n")
    git!(r, "add", "s")
    git!(r, "commit", "-qm", "sidework")
    git!(r, "push", "-q", "-u", "origin", "side")
    git!(r, "switch", "-q", "main")
    commit(r, "spine1")
    git!(r, "merge", "-q", "--no-ff", "--no-edit", "side")
    commit(r, "spine2")
    orig = sha(r, "HEAD")
    merge = git!(r, "rev-list", "--merges", "--max-count=1", "HEAD").strip
    author_before = git!(r, "log", "-1", "--format=%an <%ae> %aD", merge).strip

    out, code = sign_push(r)
    expect(code).to eq(0)
    expect(out).to include("rebuilding spine")

    merge_after = git!(r, "rev-list", "--merges", "--max-count=1", "HEAD").strip
    author_after = git!(r, "log", "-1", "--format=%an <%ae> %aD", merge_after).strip
    expect(author_after).to eq(author_before)                              # author preserved
    expect(git!(r, "rev-list", "--merges", "--count", "HEAD").strip).to eq("1") # topology
    _o, _e, st = git(r, "diff", "--quiet", orig, "HEAD")
    expect(st).to be_success                                               # content identical
    expect(sha(r, "HEAD")).to eq(sha(r, "origin/main"))                    # pushed
    expect(unsigned_in?(r, "origin/side..HEAD")).to be(false)              # signed, side excluded
  end

  it "refuses (exit 4) when a merge brings in the committer's own unsigned side" do
    r = make_repo
    commit(r, "one")
    git!(r, "switch", "-qc", "side")
    File.write(File.join(r, "s"), "s\n")
    git!(r, "add", "s")
    git!(r, "commit", "-qm", "sidework")
    git!(r, "switch", "-q", "main")
    commit(r, "three")
    git!(r, "merge", "-q", "--no-ff", "--no-edit", "side")
    orig = sha(r, "HEAD")
    out, code = sign_push(r)
    expect(code).to eq(4)
    expect(out).to match(/git -C .* switch side/)      # recipe names the side branch
    expect(sha(r, "HEAD")).to eq(orig)                 # repo untouched
  end

  it "tolerates a foreign unsigned side with a note and proceeds" do
    r = make_repo
    commit(r, "one", signed: true) # signed base, else the exit-4 refusal fires
    git!(r, "switch", "-qc", "side")
    File.write(File.join(r, "s"), "s\n")
    git!(r, "add", "s")
    git!(r, "-c", "user.email=other@test", "-c", "user.name=Other", "commit", "-qm", "foreignwork")
    git!(r, "switch", "-q", "main")
    commit(r, "three")
    git!(r, "merge", "-q", "--no-ff", "--no-edit", "side")
    out, code = sign_push(r)
    expect(code).to eq(0)
    expect(out).to include("leaving it (only the tip is gated)")
    expect(out).to include("rebuilding spine")
  end

  it "--no-push signs without pushing and prints the push command" do
    r = make_repo
    commit(r, "one")
    mk_origin(r)
    git!(r, "push", "-q", "-u", "origin", "main")
    commit(r, "two")
    out, code = sign_push(r, "--no-push")
    expect(code).to eq(0)
    expect(out).to include("NOT pushing")
    expect(out).to include("To push: git -C")
    expect(unsigned_in?(r, "origin/main..HEAD")).to be(false) # unpushed range signed
    expect(sha(r, "origin/main")).not_to eq(sha(r, "HEAD"))   # origin untouched
  end

  it "prints usage and exits 0 for --help" do
    out, code = sign_push("--help") # no repo arg needed
    expect(code).to eq(0)
    expect(out).to include("Usage:")
    expect(out).to include("--no-push")
  end

  it "rejects an unknown option with exit 2" do
    out, code = sign_push("--bogus")
    expect(code).to eq(2)
    expect(out).to include("unknown option")
  end

  # A genuine divergence (origin advanced from another clone, then a local
  # rewrite) so the lease matches and the confirmed force push can succeed.
  def diverged_repo
    r = make_repo
    commit(r, "one")
    bare = mk_origin(r)
    git!(r, "push", "-q", "-u", "origin", "main")
    advance_origin(bare)   # bare/main = one -> other
    git!(r, "fetch", "-q") # r's origin/main tracking now = one -> other
    commit(r, "two")       # r HEAD = one -> two, unsigned/unpushed -> diverges
    [r, bare]
  end

  it "runs the lease-pinned force push when the diverged-origin confirm is y" do
    skip "pty unavailable (sandbox denies /dev/ptmx)" unless @pty_ok
    r, bare = diverged_repo
    expect(sign_push_confirm(r, "y")).to eq(0)
    expect(unsigned_in?(r, "origin/main..HEAD")).to be(false) # signed
    expect(bare_main(bare)).to eq(sha(r, "HEAD"))             # force push landed
  end

  it "does not force push when the diverged-origin confirm is declined" do
    skip "pty unavailable (sandbox denies /dev/ptmx)" unless @pty_ok
    r, bare = diverged_repo
    before = bare_main(bare)
    expect(sign_push_confirm(r, "n")).to eq(3)
    expect(bare_main(bare)).to eq(before) # origin untouched
  end
end
