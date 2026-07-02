#!/usr/bin/env ruby
# frozen_string_literal: true
#
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# sync-files.rb — push-from-canonical sync engine for repo-foundation.
#
# Reads sync-manifest.yaml, resolves one consumer's component list
# (sets + extra - exclude), and writes each component into a checkout of that
# consumer, applying the component's mode:
#
#   canonical       Copy the source and insert a "synced from repo-foundation,
#                   do not modify it directly" header in the target's comment
#                   syntax, placed after any shebang / YAML frontmatter / SPDX
#                   block. If the source already carries a "do not modify it
#                   directly" header (a file repo-foundation relays from an
#                   upstream such as Homebrew), that header is stripped first so
#                   the consumer sees a single repo-foundation header. Files with
#                   no comment syntax (JSON, .license, lockfiles, .rspec) are
#                   copied verbatim.
#   template        Same as canonical; the source merely carries a `.template`
#                   infix the manifest's `target` has already stripped.
#   generate        Build the target per consumer. Currently dependabot.yml:
#                   keep only the ecosystems whose manifest file exists in the
#                   target. The result is regenerated YAML (template comments are
#                   intentionally not propagated — they describe the generator,
#                   not the consumer file); SPDX + the synced header are added.
#   baseline-merge  Regenerate only the repo-foundation-managed slice of the
#                   target, preserving the consumer's own content. A text target
#                   gets a sentinel-delimited region rendered in its own comment
#                   syntax (# for .gitignore, <!-- --> for Markdown) from the
#                   manifest's merge_label_begin / merge_label_end. A comment-less
#                   JSON target (e.g. .claude/settings.json) is deep-merged with
#                   the consumer's <stem>.addenda.json and regenerated.
#
# After writing, commits one file per change in the target and, under GitHub
# Actions, sets pull_request=true on GITHUB_OUTPUT for the calling workflow.
#
# Usage: sync-files.rb <consumer_repo_slug> <target_path> [--dry-run]
# Stdlib only (no bundler), so it runs in CI without a gem install.

require "English"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "yaml"

# Treat every file as UTF-8 regardless of the runner's locale, so reading a
# UTF-8 source under a C/US-ASCII LANG does not raise an invalid-byte error.
Encoding.default_external = Encoding::UTF_8

# repo-foundation checkout root: this file lives at .github/actions/sync/.
# SYNC_SOURCE_ROOT overrides it for the test suite (fixture sources); production
# never sets it.
SOURCE_ROOT = Pathname(ENV.fetch("SYNC_SOURCE_ROOT") { Pathname(__dir__).join("..", "..", "..").to_s }).expand_path

VALID_MODES = %w[canonical template generate baseline-merge].freeze
HEADER_SIGNATURE = "do not modify it directly"

# SPDX block prepended to generated files (which are not copied from a source
# that already carries one). Hash-comment form; dependabot.yml is RF-authored.
SPDX_HASH = <<~SPDX
  # SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
  #
  # SPDX-License-Identifier: GPL-3.0-or-later
SPDX

# Ecosystem -> manifest file(s) that, if present in the target, keep that
# Dependabot stanza. Either of a pair is sufficient (e.g. Gemfile or its lock).
ECOSYSTEM_PATHS = {
  "bundler"       => ["Gemfile", "Gemfile.lock"],
  "pip"           => ["requirements.txt", "pyproject.toml"],
  "gomod"         => ["go.mod"],
  "cargo"         => ["Cargo.toml", "Cargo.lock"],
  "npm"           => ["package.json"],
  "docker"        => ["Dockerfile"],
  "devcontainers" => [".devcontainer/devcontainer.json"],
}.freeze

def usage!
  abort "Usage: #{$PROGRAM_NAME} <consumer_repo_slug> <target_path> [--dry-run]"
end

def git!(target_root, *cmd)
  return if system("git", "-C", target_root.to_s, *cmd)

  abort "git #{cmd.join(' ')} failed in #{target_root}"
end

def load_yaml(path)
  # safe_load (no arbitrary object instantiation); our YAML is plain data.
  YAML.safe_load(File.read(path))
end

# Comment syntax for the synced header, chosen from the TARGET name (where the
# header lands) with a shebang sniff and a small allow-list of extension-less
# config names. :none means "cannot carry a leading comment safely" — copy as-is.
def comment_style(target_file, content)
  hash_basenames = %w[.gitignore .dockerignore .clang-format .clang-tidy]
  case target_file.extname
  when ".sh", ".bash", ".zsh", ".ksh", ".rb", ".yml", ".yaml", ".toml", ".ini", ".cfg", ".conf"
    :hash
  when ".md", ".markdown", ".html", ".htm"
    :html
  when ".c", ".m", ".h", ".mm", ".cc", ".cpp", ".hpp", ".swift"
    :c
  when ".json", ".license", ".lock", ".rspec"
    :none
  else
    if content.start_with?("#!") || hash_basenames.include?(target_file.basename.to_s)
      :hash
    else
      :none
    end
  end
end

def wrap_words(text, width = 74)
  lines = []
  current = +""
  text.split(/\s+/).each do |word|
    if current.empty?
      current = word.dup
    elsif current.length + 1 + word.length <= width
      current << " " << word
    else
      lines << current
      current = word.dup
    end
  end
  lines << current unless current.empty?
  lines
end

def render_header(style, source_rel, template)
  return nil if style == :none || template.nil? || template.empty?

  lines = wrap_words(format(template, source: source_rel))
  case style
  when :hash then "#{lines.map { |l| "# #{l}".rstrip }.join("\n")}\n\n"
  when :c    then "#{lines.map { |l| "// #{l}".rstrip }.join("\n")}\n\n"
  when :html then "<!--\n#{lines.join("\n")}\n-->\n\n"
  end
end

# Index after the shebang, YAML frontmatter, and a leading SPDX comment block —
# i.e. where the synced header belongs.
def insert_point(lines, style)
  i = 0
  i += 1 if lines[0]&.start_with?("#!")
  if lines[i]&.match?(/\A---\s*$/)
    j = i + 1
    j += 1 while lines[j] && !lines[j].match?(/\A---\s*$/)
    i = j + 1 if lines[j]
  end
  if style == :html
    if lines[i]&.lstrip&.start_with?("<!--")
      j = i
      j += 1 while lines[j] && !lines[j].include?("-->")
      if lines[j] && lines[i..j].any? { |l| l.include?("SPDX-") }
        i = j + 1
        i += 1 if lines[i]&.strip&.empty?
      end
    end
  else
    prefix = style == :c ? "//" : "#"
    if lines[i]&.lstrip&.start_with?(prefix)
      j = i
      j += 1 while lines[j]&.lstrip&.start_with?(prefix)
      if lines[i...j].any? { |l| l.include?("SPDX-") }
        i = j
        i += 1 if lines[i]&.strip&.empty?
      end
    end
  end
  i
end

# Remove a synced-from header block beginning at index i (if any), so a relayed
# file does not accumulate one header per hop.
def strip_synced_header!(lines, i, style)
  return unless lines[i]

  if style == :html
    return unless lines[i].lstrip.start_with?("<!--")

    j = i
    j += 1 while lines[j] && !lines[j].include?("-->")
    return unless lines[j]

    last = j
  else
    prefix = style == :c ? "//" : "#"
    return unless lines[i].lstrip.start_with?(prefix)

    j = i
    j += 1 while lines[j]&.lstrip&.start_with?(prefix)
    last = j - 1
  end
  return unless lines[i..last].any? { |l| l.downcase.include?(HEADER_SIGNATURE) }

  count = last - i + 1
  count += 1 if lines[last + 1]&.strip&.empty?
  lines.slice!(i, count)
end

def apply_header(content, style, header)
  return content if style == :none || header.nil?

  lines = content.lines
  i = insert_point(lines, style)
  strip_synced_header!(lines, i, style)
  lines.insert(i, header)
  lines.join
end

def build_copy(source_file, target_file, source_rel, template)
  content = source_file.read
  style = comment_style(target_file, content)
  apply_header(content, style, render_header(style, source_rel, template))
end

def ecosystem_present?(ecosystem, directory, target_root)
  if ecosystem == "github-actions"
    workflows = target_root / ".github/workflows"
    return workflows.directory? && workflows.children.any? { |c| c.extname.match?(/\A\.ya?ml\z/) }
  end

  base = target_root / directory.to_s.sub(%r{\A/}, "")
  Array(ECOSYSTEM_PATHS[ecosystem]).any? { |name| (base / name).exist? }
end

# dependabot.yml: filter the superset template to the target's real ecosystems,
# then re-add SPDX + the synced header (Psych drops the template's comments — by
# design; they describe the generator, not the consumer file).
def build_generate(source_file, target_root, source_rel, template)
  config = load_yaml(source_file)
  config["updates"] = Array(config["updates"]).select do |update|
    ecosystem_present?(update["package-ecosystem"], update["directory"] || "/", target_root)
  end
  content = "#{SPDX_HASH}\n#{config.to_yaml}"
  apply_header(content, :hash, render_header(:hash, source_rel, template))
end

# Render the begin/end sentinel lines for a baseline-merge target in the
# target's own comment syntax, from the comment-agnostic labels in the manifest
# defaults. The same labels then work for a hash-commented .gitignore and an
# HTML-commented Markdown file; a :none target (no safe leading comment) returns
# nils and cannot carry a text region.
def render_sentinels(style, label_begin, label_end)
  case style
  when :hash then ["# >>> #{label_begin} >>>", "# <<< #{label_end} <<<"]
  when :c    then ["// >>> #{label_begin} >>>", "// <<< #{label_end} <<<"]
  when :html then ["<!-- >>> #{label_begin} >>> -->", "<!-- <<< #{label_end} <<< -->"]
  else [nil, nil]
  end
end

# Deep-merge for the JSON baseline-merge path. Objects merge key by key; arrays
# union (dedup, baseline order first) so a consumer can only ADD to the org-wide
# permission rails, never silently drop one; a scalar or type mismatch takes the
# consumer's value where the consumer supplies one. Pure and order-stable, so
# re-running yields byte-identical output (idempotent), and a removal from the
# baseline propagates because the result is rebuilt from both inputs each run.
def deep_merge(base, addenda)
  if base.is_a?(Hash) && addenda.is_a?(Hash)
    (base.keys | addenda.keys).each_with_object({}) do |key, out|
      out[key] = if base.key?(key) && addenda.key?(key)
                   deep_merge(base[key], addenda[key])
                 else
                   base.fetch(key) { addenda[key] }
                 end
    end
  elsif base.is_a?(Array) && addenda.is_a?(Array)
    (base + addenda).uniq
  elsif addenda.nil?
    base
  else
    addenda
  end
end

# baseline-merge for a comment-less JSON target (e.g. .claude/settings.json):
# deep-merge the repo-foundation baseline with the consumer's own
# <stem>.addenda.json sitting beside the target, and regenerate the target. The
# target is generated, not hand-edited — JSON carries no comment for a "do not
# edit" header, so the boundary is the file split: repo-foundation owns the
# baseline, the consumer owns the addenda, the target is the merge of the two.
def build_json_merge(source_file, target_file)
  base = JSON.parse(source_file.read)
  addenda_file = target_file.dirname / "#{target_file.basename(target_file.extname)}.addenda.json"
  merged = addenda_file.file? ? deep_merge(base, JSON.parse(addenda_file.read)) : base
  "#{JSON.pretty_generate(merged)}\n"
end

# baseline-merge: regenerate only the repo-foundation-managed slice of the
# target, preserving everything the consumer owns. A comment-less JSON target
# takes the deep-merge path; every other target gets a sentinel-delimited region
# rendered in its own comment syntax.
def build_baseline_merge(source_file, target_file, label_begin, label_end)
  return build_json_merge(source_file, target_file) if target_file.extname == ".json" || source_file.extname == ".json"

  source = source_file.read
  style = comment_style(target_file, source)
  begin_line, end_line = render_sentinels(style, label_begin, label_end)
  return nil if begin_line.nil? # target cannot carry a leading-comment region

  region = "#{begin_line}\n#{source.chomp}\n#{end_line}\n"
  return region unless target_file.exist?

  current = target_file.read
  begins = current.scan(/#{Regexp.escape(begin_line)}/).length
  ends = current.scan(/#{Regexp.escape(end_line)}/).length
  if begins.zero? && ends.zero?
    "#{current.chomp}\n\n#{region}"
  elsif begins == 1 && ends == 1
    current.sub(/#{Regexp.escape(begin_line)}.*?#{Regexp.escape(end_line)}\n/m, region)
  else
    abort "malformed managed region in #{target_file}: #{begins} begin / #{ends} end markers (expect 0 or 1 each)"
  end
end

# --- parse arguments ---------------------------------------------------------
args = ARGV.dup
dry_run = !args.delete("--dry-run").nil?
consumer_slug = args.shift
target_arg = args.shift
usage! if consumer_slug.nil? || target_arg.nil? || !args.empty?

target_root = Pathname(target_arg).expand_path
abort "target path is not a directory: #{target_root}" unless target_root.directory?

manifest_path = Pathname(ENV.fetch("SYNC_MANIFEST", (SOURCE_ROOT / "sync-manifest.yaml").to_s))
abort "manifest not found: #{manifest_path}" unless manifest_path.file?
manifest = load_yaml(manifest_path)

defaults = manifest.fetch("defaults", {})
header_template = defaults["synced_header"].to_s
merge_label_begin = defaults["merge_label_begin"].to_s
merge_label_end = defaults["merge_label_end"].to_s

consumer = Array(manifest["consumers"]).find { |c| c["repo"] == consumer_slug }
abort "no consumer entry for #{consumer_slug} in #{manifest_path}" unless consumer

# --- resolve sets + extra - exclude into a flat, validated component list -----
component_sets = manifest.fetch("component_sets", {})
components = []
Array(consumer["sets"]).each do |set_name|
  set = component_sets[set_name] or abort "consumer #{consumer_slug}: unknown set '#{set_name}'"
  components.concat(set)
end
components.concat(Array(consumer["extra"]))
excludes = Array(consumer["exclude"])
components.reject! { |component| excludes.include?(component["target"]) }

components.each do |component|
  missing = %w[source target mode].reject { |key| component[key] }
  abort "component missing #{missing.join(', ')}: #{component.inspect}" unless missing.empty?

  mode = component["mode"]
  abort "invalid mode '#{mode}' for #{component['source']}" unless VALID_MODES.include?(mode)
end

# --- apply each component ----------------------------------------------------
puts "Syncing #{consumer_slug} -> #{target_root}#{dry_run ? ' (dry run)' : ''}"
changed_any = false
components.each do |component|
  source_rel = component.fetch("source")
  target_rel = component.fetch("target")
  mode = component.fetch("mode")
  source_file = SOURCE_ROOT / source_rel
  target_file = target_root / target_rel

  unless source_file.exist?
    warn "  skip (source missing): #{source_rel} [#{mode}]"
    next
  end

  new_content, mode_bits =
    case mode
    when "canonical", "template"
      [build_copy(source_file, target_file, source_rel, header_template), source_file.stat.mode]
    when "generate"
      [build_generate(source_file, target_root, source_rel, header_template), 0o644]
    when "baseline-merge"
      [build_baseline_merge(source_file, target_file, merge_label_begin, merge_label_end), 0o644]
    end

  next if new_content.nil? # e.g. baseline-merge JSON, deferred
  next if target_file.exist? && target_file.read == new_content

  changed_any = true
  puts "  #{dry_run ? 'would update' : 'updated'}: #{target_rel} [#{mode}]"
  next if dry_run

  target_file.dirname.mkpath
  target_file.write(new_content)
  target_file.chmod(mode_bits)
end

if dry_run
  puts(changed_any ? "Dry run: changes detected (nothing written)." : "Dry run: no changes.")
  exit
end

# --- commit one file per change ----------------------------------------------
out, err, status = Open3.capture3("git", "-C", target_root.to_s, "status", "--porcelain")
abort err unless status.success?

if out.strip.empty?
  puts "No changes to commit."
  exit
end

# Stage everything (captures new files and deletions), then commit each path
# individually: `git commit <path>` records only that pathspec from the index,
# giving one auditable commit per synced file.
git!(target_root, "add", "--all")
staged, _, status = Open3.capture3("git", "-C", target_root.to_s, "diff", "--name-only", "--staged")
abort "git diff failed" unless status.success?

staged.lines.map(&:chomp).reject(&:empty?).each do |path|
  git!(target_root, "commit", path, "--message", "#{File.basename(path)}: sync from repo-foundation")
end

if ENV["GITHUB_ACTIONS"] && ENV["GITHUB_OUTPUT"]
  File.open(ENV.fetch("GITHUB_OUTPUT"), "a") { |f| f.puts "pull_request=true" }
end
puts "Committed #{staged.lines.count} file(s)."
