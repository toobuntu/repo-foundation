#!/usr/bin/env ruby

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# frozen_string_literal: true

# git-data-commit.rb — turn a sync change list into per-file chained commits
# on a new branch of a consumer, through the GitHub Git Data API.
#
# Commits minted this way under the sync App's installation token are
# GitHub-signed (web-flow, Verified) and the tree API carries real file modes
# on new AND modified files — no machine user, no SSH signing key
# (rf-upstream-notes § 18i, verified 2026-07-15). Deletions are tree entries
# with sha: null.
#
# Reads changes.json as emitted by sync-files.rb --emit-dir:
#   [{"path": "...", "status": "added|modified|deleted", "mode": "100644|100755"}, ...]
# For each change, in order: blob (except deletions) -> one-entry tree built on
# the previous commit's tree -> commit chained on the previous commit. One ref
# create at the end, so a failed run leaves no branch behind.
#
# Usage: git-data-commit.rb --repo <owner/name> --dir <consumer_checkout>
#          --changes <changes.json> --branch <branch> [--base <sha>]
# --base defaults to the checkout's HEAD. Authentication: `gh` reads GH_TOKEN
# from the environment. Stdlib-only; the API transport is the gh CLI, so token
# custody stays in the calling workflow.

require "json"
require "open3"
require "optparse"

options = { base: nil }
parser = OptionParser.new do |p|
  p.banner = "Usage: #{$PROGRAM_NAME} --repo OWNER/NAME --dir DIR --changes FILE --branch NAME [--base SHA]"
  p.on("--repo SLUG", "Consumer repository (owner/name)") { |v| options[:repo] = v }
  p.on("--dir DIR", "Consumer checkout the rendered files were written to") { |v| options[:dir] = v }
  p.on("--changes FILE", "changes.json from sync-files.rb --emit-dir") { |v| options[:changes] = v }
  p.on("--branch NAME", "Branch to create at the final commit") { |v| options[:branch] = v }
  p.on("--base SHA", "Base commit (default: the checkout's HEAD)") { |v| options[:base] = v }
end
begin
  parser.parse!(ARGV)
rescue OptionParser::ParseError => e
  abort "#{e.message}\n#{parser.banner}"
end
missing = %i[repo dir changes branch].reject { |key| options[key] }
abort "missing #{missing.map { |k| "--#{k}" }.join(', ')}\n#{parser.banner}" unless missing.empty?

# Fail fast at the FIRST error, name the step, and surface GitHub's error body
# — its "message" field says exactly what was rejected (the § 18g lesson).
def gh_api(step, method, path, body = nil)
  cmd = ["gh", "api", "--method", method, path]
  cmd += ["--input", "-"] if body
  out, err, status = Open3.capture3(*cmd, stdin_data: body ? JSON.generate(body) : "")
  abort "git-data-commit: #{step} failed (gh api #{method} #{path}):\n#{err.strip}\n#{out.strip}" unless status.success?

  JSON.parse(out)
end

changes = JSON.parse(File.read(options[:changes]))
if changes.empty?
  puts "git-data-commit: no changes; nothing to commit."
  exit 0
end

repo = options[:repo]
base = options[:base]
if base.nil?
  base, err, status = Open3.capture3("git", "-C", options[:dir], "rev-parse", "HEAD")
  abort "git-data-commit: could not resolve base from #{options[:dir]}: #{err.strip}" unless status.success?

  base = base.strip
end

parent_commit = base
parent_tree = gh_api("read-base-commit", "GET", "repos/#{repo}/git/commits/#{parent_commit}")
              .fetch("tree").fetch("sha")

changes.each do |change|
  path = change.fetch("path")
  entry = { "path" => path, "mode" => change.fetch("mode", "100644"), "type" => "blob" }
  if change["status"] == "deleted"
    entry["sha"] = nil
  else
    content = File.binread(File.join(options[:dir], path))
    blob = gh_api("create-blob #{path}", "POST", "repos/#{repo}/git/blobs",
                  { "content" => [content].pack("m0"), "encoding" => "base64" })
    entry["sha"] = blob.fetch("sha")
  end

  tree = gh_api("create-tree #{path}", "POST", "repos/#{repo}/git/trees",
                { "base_tree" => parent_tree, "tree" => [entry] })
  commit = gh_api("create-commit #{path}", "POST", "repos/#{repo}/git/commits",
                  { "message" => "#{File.basename(path)}: sync from repo-foundation",
                    "tree" => tree.fetch("sha"),
                    "parents" => [parent_commit] })
  parent_commit = commit.fetch("sha")
  parent_tree = tree.fetch("sha")
  puts "  committed #{path} (#{parent_commit[0, 7]})"
end

gh_api("create-ref", "POST", "repos/#{repo}/git/refs",
       { "ref" => "refs/heads/#{options[:branch]}", "sha" => parent_commit })

if ENV["GITHUB_ACTIONS"] && ENV["GITHUB_OUTPUT"]
  File.open(ENV.fetch("GITHUB_OUTPUT"), "a") { |f| f.puts "head_sha=#{parent_commit}" }
end
puts "git-data-commit: #{changes.length} commit(s) on #{options[:branch]} (head #{parent_commit[0, 7]})."
