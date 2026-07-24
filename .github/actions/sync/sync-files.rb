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
#                   manifest's merge_label_begin / merge_label_end; Markdown
#                   regions are padded with a blank line inside each sentinel.
#                   Marker handling is stateful and loud: an inverted or
#                   duplicated marker pair aborts; markers absent from an
#                   existing file trigger the history split (see
#                   region_last_present_in): never in the file's history means
#                   bootstrap — the region is prepended (after the H1 for
#                   Markdown, after the leading comment block for hash targets;
#                   position is consumer-owned afterward) — while a region that
#                   WAS in history aborts with a ready-to-run restore command
#                   and a paste-ready exclude entry. A comment-less JSON target
#                   (e.g. .claude/settings.json) is instead deep-merged:
#                   baseline -> class fragments -> the consumer's
#                   <stem>.addenda.json.
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

VALID_MODES = %w[canonical template generate baseline-merge fragment].freeze
HEADER_SIGNATURE = "do not modify it directly"
DOC_POINTER = "see toobuntu/repo-foundation docs/adding-a-repo.md"

# A recoverable engine failure. `annotation` is the single-line GitHub Actions
# annotation (annotations render no newlines); the full message — command
# sequences included — goes to the step log via the exception message.
class SyncError < StandardError
  attr_reader :annotation

  def initialize(message, annotation: nil)
    super(message)
    @annotation = annotation
  end
end

def fail_sync(error)
  puts "::error::#{error.annotation}" if ENV["GITHUB_ACTIONS"] && error.annotation
  abort error.message
end

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

# The managed region between (and including) the sentinels. Markdown regions
# get a blank line inside each sentinel — Markdown structure linters flag
# content adjacent to comment lines — while hash-comment regions stay tight.
def render_region(style, begin_line, end_line, source)
  pad = style == :html ? "\n" : ""
  "#{begin_line}\n#{pad}#{source.chomp}\n#{pad}#{end_line}\n"
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
# Layers, in order (a later layer wins scalars; arrays union; objects merge):
#   baseline -> class fragments (RF-owned, shared by a class of consumers,
#   ADR 0016) -> the consumer's own <stem>.addenda.json.
def build_json_merge(source_file, target_file, fragments = [])
  base = JSON.parse(source_file.read)
  merged = fragments.reduce(base) { |acc, fragment| deep_merge(acc, JSON.parse(fragment.read)) }
  addenda_file = target_file.dirname / "#{target_file.basename(target_file.extname)}.addenda.json"
  merged = deep_merge(merged, JSON.parse(addenda_file.read)) if addenda_file.file?
  "#{JSON.pretty_generate(merged)}\n"
end

# The history split (rf-upstream-notes § 18c/18d, blessed 2026-07-23): when an
# existing target carries no markers, `git log -S<begin marker> -- <path>`
# decides between mechanically-certain bootstrap and a human decision. Returns
# nil when the marker was never in the file's history (bootstrap: self-heal by
# prepending); returns "<short-sha> (YYYY-MM-DD)" of the last commit that still
# carried the region when it was deleted (abort: intent is not determinable).
# A shallow or unborn history cannot answer "never existed", so shallow aborts
# and unborn (no commits yet) counts as never-existed.
def region_last_present_in(target_root, target_rel, begin_line)
  shallow, _err, status = Open3.capture3("git", "-C", target_root.to_s, "rev-parse", "--is-shallow-repository")
  if !status.success? || shallow.strip == "true"
    raise SyncError.new(
      "#{target_rel}: cannot verify managed-region history in a shallow clone; " \
      "fetch full history (fetch-depth: 0) and re-run",
      annotation: "#{target_rel}: managed region missing and history is shallow — #{DOC_POINTER}"
    )
  end

  _out, _err, status = Open3.capture3("git", "-C", target_root.to_s, "rev-parse", "--quiet", "--verify", "HEAD")
  return nil unless status.success? # unborn branch: no history to consult

  removal, err, status = Open3.capture3("git", "-C", target_root.to_s,
                                        "log", "--max-count=1", "--format=%H", "-S", begin_line, "--", target_rel)
  raise SyncError.new("#{target_rel}: git log failed while checking marker history: #{err.strip}") unless status.success?
  return nil if removal.strip.empty?

  # The most recent occurrence-count change with the marker absent now is its
  # removal; the region was last present at that commit's parent.
  stamp, err, status = Open3.capture3("git", "-C", target_root.to_s,
                                      "log", "--max-count=1", "--format=%h %cs", "#{removal.strip}^")
  raise SyncError.new("#{target_rel}: git log failed on #{removal.strip}^: #{err.strip}") unless status.success?

  short, date = stamp.split
  "#{short} (#{date})"
end

def region_removed_error(target_rel, consumer_slug, last_present)
  short = last_present.split.first
  message = <<~MSG
    #{target_rel}: the managed region's markers are missing, but they existed in
    this file's history — last present at #{last_present}. Two dispositions:

    Restore the markers, then re-run the sync:

      git restore --source=#{short} -- #{target_rel}

    Or record a deliberate opt-out in sync-manifest.yaml (under consumers ->
    "#{consumer_slug}" -> exclude), then re-run:

      - { target: #{target_rel}, reason: "<fill in>" }
  MSG
  SyncError.new(message,
                annotation: "#{target_rel}: managed region removed (last present at #{last_present}) — #{DOC_POINTER}")
end

# Bootstrap a managed region into an existing file that never carried one:
# PREPEND it — after the H1 (skipping frontmatter/SPDX) in Markdown, after the
# leading comment block in hash-comment targets — so the org baseline meets a
# top-down reader first. Position is consumer-owned afterward: later syncs
# replace the region wherever it sits.
def prepend_region(current, region, style)
  lines = current.lines
  i = insert_point(lines, style)
  if style == :html
    h1 = lines[i..].find_index { |l| l.start_with?("# ") }
    i += h1 + 1 unless h1.nil?
  else
    # insert_point stops at a leading comment block only when it carries SPDX;
    # skip any remaining plain comment block too (the shebang was index 0).
    i += 1 while lines[i]&.lstrip&.start_with?("#")
  end
  insertion = []
  insertion << "\n" if i.positive? && !lines[i - 1].to_s.strip.empty?
  insertion << region
  insertion << "\n" if lines[i] && !lines[i].strip.empty?
  lines.insert(i, *insertion)
  lines.join
end

# baseline-merge: regenerate only the repo-foundation-managed slice of the
# target, preserving everything the consumer owns. A comment-less JSON target
# takes the deep-merge path; every other target gets a sentinel-delimited region
# rendered in its own comment syntax.
def build_baseline_merge(source_file, target_file, target_root, target_rel, consumer_slug,
                         label_begin, label_end, fragments: [], notes: {})
  return build_json_merge(source_file, target_file, fragments) if target_file.extname == ".json" || source_file.extname == ".json"

  source = source_file.read
  style = comment_style(target_file, source)
  begin_line, end_line = render_sentinels(style, label_begin, label_end)
  return nil if begin_line.nil? # target cannot carry a leading-comment region

  region = render_region(style, begin_line, end_line, source)
  return region unless target_file.exist?

  current = target_file.read
  begins = current.scan(/#{Regexp.escape(begin_line)}/).length
  ends = current.scan(/#{Regexp.escape(end_line)}/).length
  if begins == 1 && ends == 1
    if current.index(end_line) < current.index(begin_line)
      raise SyncError.new(
        "#{target_rel}: managed-region markers are inverted (end marker precedes begin marker); " \
        "restore the begin/end order, then re-run",
        annotation: "#{target_rel}: inverted managed-region markers — #{DOC_POINTER}"
      )
    end
    region_re = /#{Regexp.escape(begin_line)}.*?#{Regexp.escape(end_line)}[ \t]*\n?/m
    unless current.match?(region_re)
      raise SyncError.new(
        "#{target_rel}: managed-region markers present but the region did not match " \
        "(mangled marker lines?); restore both marker lines, then re-run",
        annotation: "#{target_rel}: unmatched managed-region markers — #{DOC_POINTER}"
      )
    end
    current.sub(region_re, region)
  elsif begins.zero? && ends.zero?
    last_present = region_last_present_in(target_root, target_rel, begin_line)
    raise region_removed_error(target_rel, consumer_slug, last_present) if last_present

    notes[target_rel] = "managed region bootstrapped into the existing file"
    prepend_region(current, region, style)
  else
    raise SyncError.new(
      "#{target_rel}: malformed managed region: #{begins} begin / #{ends} end markers (expect 0 or 1 each)",
      annotation: "#{target_rel}: malformed managed-region markers — #{DOC_POINTER}"
    )
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

# Exclusions are mappings with a cited reason ({target: ..., reason: "..."} —
# rf-upstream-notes § 18.3): structured, so the audit report and the sync PR
# body can print every exception. A bare string is a manifest bug.
excludes = Array(consumer["exclude"]).map do |entry|
  unless entry.is_a?(Hash) && !entry["target"].to_s.strip.empty? && !entry["reason"].to_s.strip.empty?
    abort "consumer #{consumer_slug}: exclude entries must be mappings with target and reason, got #{entry.inspect}"
  end
  entry
end
excluded_targets = excludes.map { |entry| entry["target"] }
components.reject! { |component| excluded_targets.include?(component["target"]) }

components.each do |component|
  missing = %w[source target mode].reject { |key| component[key] }
  abort "component missing #{missing.join(', ')}: #{component.inspect}" unless missing.empty?

  mode = component["mode"]
  abort "invalid mode '#{mode}' for #{component['source']}" unless VALID_MODES.include?(mode)
end

# --- collect class fragments (ADR 0016) ---------------------------------------
# A fragment is an RF-owned shared delta for a class of consumers. It writes no
# file of its own; the baseline-merge for the same JSON target folds it in
# between the baseline and the consumer's addenda. Fail fast on a fragment that
# nothing consumes, a non-JSON pairing, or a missing source -- each is a
# manifest bug, not a per-consumer condition.
fragments_by_target = Hash.new { |hash, key| hash[key] = [] }
components.each do |component|
  next unless component["mode"] == "fragment"

  source_file = SOURCE_ROOT / component.fetch("source")
  target_rel = component.fetch("target")
  abort "fragment source missing: #{component['source']}" unless source_file.file?
  abort "fragment must be JSON: #{component['source']} -> #{target_rel}" unless source_file.extname == ".json" && target_rel.end_with?(".json")
  unless components.any? { |c| c["mode"] == "baseline-merge" && c["target"] == target_rel }
    abort "fragment #{component['source']} targets #{target_rel}, but no baseline-merge component in this consumer's sets generates it"
  end
  fragments_by_target[target_rel] << source_file
end

# --- apply each component ----------------------------------------------------
puts "Syncing #{consumer_slug} -> #{target_root}#{dry_run ? ' (dry run)' : ''}"
changed_any = false
notes = {}
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

  begin
    new_content, mode_bits =
      case mode
      when "canonical", "template"
        [build_copy(source_file, target_file, source_rel, header_template), source_file.stat.mode]
      when "generate"
        [build_generate(source_file, target_root, source_rel, header_template), 0o644]
      when "baseline-merge"
        [build_baseline_merge(source_file, target_file, target_root, target_rel, consumer_slug,
                              merge_label_begin, merge_label_end,
                              fragments: fragments_by_target[target_rel], notes: notes), 0o644]
      when "fragment"
        next # folded into the matching baseline-merge target above
      end
  rescue SyncError => e
    fail_sync(e)
  end

  next if new_content.nil? # e.g. baseline-merge JSON, deferred
  next if target_file.exist? && target_file.read == new_content

  changed_any = true
  note = notes[target_rel] ? " — #{notes[target_rel]}" : ""
  puts "  #{dry_run ? 'would update' : 'updated'}: #{target_rel} [#{mode}]#{note}"
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
