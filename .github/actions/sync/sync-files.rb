#!/usr/bin/env ruby
# frozen_string_literal: true
#
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# sync-files.rb — push-from-canonical sync engine for repo-foundation.
#
# Reads sync-manifest.yaml, resolves one consumer's component list
# (sets + extra - exclude), and runs in one of four modes of operation:
#
#   (default)   Write each component into a checkout of that consumer. With
#               --emit-dir, record the change list (changes.json: path, status,
#               git mode) and a rendered pull-request body (pr-body.md) for the
#               calling workflow's Git Data commit loop (git-data-commit.rb).
#               The engine itself makes no git commits.
#   --dry-run   Report what would change; write nothing.
#   --audit     Pre-sync freshness audit: one row per (source -> target) pair —
#               same/differs/missing status, consumer and repo-foundation
#               mtimes (a review signal only; content decides), diffstat on
#               mismatch — plus the consumer's exclusions with their reasons.
#               Read-only, always exits 0; the disposition pass is human.
#   --guard X   Foundation guard for consumer pull requests: render every
#               component in memory and compare against the working tree, but
#               flag ONLY files the PR itself touched (merge-base filter
#               against base X — drift that predates the branch belongs to the
#               sync, not the PR author). baseline-merge targets compare the
#               regenerated output, so a direct edit inside a managed region —
#               or to a generated settings.json bypassing the addenda file —
#               fails while consumer-owned content passes. Exits 1 when any
#               managed surface was edited.
#
# Per-component modes (mode: in the manifest):
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
# Under GitHub Actions the default mode appends changed=<bool> to
# GITHUB_OUTPUT for the calling workflow.
#
# Usage: sync-files.rb <consumer_repo_slug> <target_path>
#          [--dry-run | --guard BASE | --audit] [--emit-dir DIR]
# Stdlib only (no bundler), so it runs in CI without a gem install.

require "English"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "rbconfig"
require "tempfile"
require "yaml"

# Treat every file as UTF-8 regardless of the runner's locale, so reading a
# UTF-8 source under a C/US-ASCII LANG does not raise an invalid-byte error.
Encoding.default_external = Encoding::UTF_8

# The floor, enforced rather than assumed. --audit is the one mode an operator
# runs locally against sibling clones, and on macOS a bare `ruby` resolves
# through PATH to the frozen system 2.6 -- which would otherwise fail somewhere
# downstream with a NoMethodError that says nothing about the cause. Stating it
# here means a wrong Ruby is reported at the boundary, once, with the fix.
# 3.0 rather than 2.7 (where filter_map arrived) because that is the floor CI
# exercises: Homebrew's portable Ruby, via Homebrew/actions/setup-ruby.
if RUBY_VERSION < "3.0"
  abort <<~MSG
    error: sync-files.rb needs Ruby 3.0 or newer; this is #{RUBY_VERSION} (#{RbConfig.ruby}).
      On macOS a bare `ruby` is the frozen system 2.6. Run it under Homebrew's
      portable Ruby instead:

        "$(brew --repository)/Library/Homebrew/vendor/portable-ruby/current/bin/ruby" \\
          .github/actions/sync/sync-files.rb <consumer-slug> <target-path> --audit
  MSG
end

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
    if lines[j]
      i = j + 1
      # In Markdown, land BELOW the blank line a frontmatter fence must be
      # followed by, not between the two. Inserting directly after `---`
      # renders a file that fails the org's own markdown gate in every
      # consumer: MD071 (missing blank line after frontmatter), and MD012
      # once the original blank becomes a second consecutive one. Scoped to
      # :html because a hash-comment file whose first line is `---` is YAML,
      # where the blank carries no such rule.
      i += 1 if style == :html && lines[i]&.strip&.empty?
    end
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

    Restore the markers, then re-run the sync. The restore brings back the
    WHOLE file as of #{short} — review the diff first, and if the file changed
    since, re-apply those edits afterward (or reinsert the two marker lines by
    hand instead of restoring):

      git diff #{short} -- #{target_rel}
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
    # Only the document's leading heading area counts: an H1 is accepted only
    # as the first content line after insert_point. An unbounded scan could
    # mistake a "# " line deep in the body (say, a comment inside a code
    # fence) for the title; with no leading H1 the region goes to the top.
    j = i
    j += 1 while lines[j]&.strip&.empty?
    i = j + 1 if lines[j]&.start_with?("# ")
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
options = { dry_run: false, guard_base: nil, audit: false, emit_dir: nil }
parser = OptionParser.new do |p|
  p.banner = "Usage: #{$PROGRAM_NAME} <consumer_repo_slug> <target_path> " \
             "[--dry-run | --guard BASE | --audit] [--emit-dir DIR]"
  p.on("--dry-run", "Report what would change; write nothing") { options[:dry_run] = true }
  p.on("--guard BASE", "Flag PR edits to managed surfaces (merge-base filter against BASE)") do |v|
    options[:guard_base] = v
  end
  p.on("--audit", "Report per-pair freshness (read-only)") { options[:audit] = true }
  p.on("--emit-dir DIR", "Write changes.json and pr-body.md for the commit loop") { |v| options[:emit_dir] = v }
end
begin
  parser.parse!(ARGV)
rescue OptionParser::ParseError => e
  abort "#{e.message}\n#{parser.banner}"
end
consumer_slug, target_arg = ARGV
abort parser.banner if consumer_slug.nil? || target_arg.nil? || ARGV.length > 2
if [options[:dry_run], options[:audit], !options[:guard_base].nil?].count(true) > 1
  abort "pick one of --dry-run, --guard, --audit"
end
if options[:emit_dir] && (options[:dry_run] || options[:audit] || options[:guard_base])
  abort "--emit-dir applies only to the default write mode (it would silently emit nothing here)"
end
dry_run = options[:dry_run]

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

# The manifest's target paths are hub-authored and trusted; the CONSUMER tree
# is not. A committed symlink — an ancestor directory or the target itself —
# would redirect the engine's reads and writes outside the checkout (e.g. a
# .github -> ../.github symlink escaping into the surrounding workspace), so
# refuse to traverse one. Per-component lstat (Pathname#symlink?): the check
# never follows the link it is checking. Nonexistent components pass — mkpath
# then creates real directories.
def assert_no_symlink_traversal!(target_root, target_rel)
  rel = Pathname(target_rel)
  if rel.absolute? || rel.each_filename.include?("..")
    raise SyncError.new("#{target_rel}: unsafe target path (absolute or ..)",
                        annotation: "#{target_rel}: unsafe target path — #{DOC_POINTER}")
  end
  path = target_root
  rel.each_filename do |component|
    path /= component
    next unless path.symlink?

    raise SyncError.new(
      "#{target_rel}: #{path.relative_path_from(target_root)} is a symlink; refusing to sync through it — " \
      "a consumer-committed symlink could redirect the write outside the checkout",
      annotation: "#{target_rel}: symlink in a managed path — #{DOC_POINTER}"
    )
  end
end

# Render one component in memory (no writes). Returns nil for components that
# produce no file of their own; raises SyncError for the loud marker states
# and for a symlinked or unsafe target path.
def render_component(component, target_root, consumer_slug, header_template,
                     merge_label_begin, merge_label_end, fragments_by_target, notes)
  source_rel = component.fetch("source")
  target_rel = component.fetch("target")
  source_file = SOURCE_ROOT / source_rel
  target_file = target_root / target_rel
  assert_no_symlink_traversal!(target_root, target_rel)
  case component.fetch("mode")
  when "canonical", "template"
    [build_copy(source_file, target_file, source_rel, header_template), source_file.stat.mode]
  when "generate"
    [build_generate(source_file, target_root, source_rel, header_template), 0o644]
  when "baseline-merge"
    [build_baseline_merge(source_file, target_file, target_root, target_rel, consumer_slug,
                          merge_label_begin, merge_label_end,
                          fragments: fragments_by_target[target_rel], notes: notes),
     0o644]
  else
    # VALID_MODES is validated up front and callers filter fragments; reaching
    # here means a new mode was added without a renderer.
    raise SyncError.new("#{target_rel}: no renderer for mode '#{component['mode']}'")
  end
end

# Unified diff between the on-disk file and the rendered canon, for guard
# detail. --no-index exits 1 on differences; only >1 is a git failure.
def diff_against_rendered(rendered, target_file)
  Tempfile.create("rendered") do |tmp|
    tmp.write(rendered)
    tmp.flush
    out, _err, status = Open3.capture3("git", "diff", "--no-index", target_file.to_s, tmp.path)
    return "" if status.exitstatus.nil? || status.exitstatus > 1

    out
  end
end

def git_file_mode(mode_bits)
  (mode_bits & 0o111).zero? ? "100644" : "100755"
end

# Shared comparison ladder: how does the on-disk target relate to the rendered
# canon? One order of precedence for the sync, guard, and audit paths, so the
# three cannot drift.
def classify_rendered(target_file, content, expected_mode)
  return :missing unless target_file.exist?
  return :differs if target_file.read != content
  return :mode if git_file_mode(target_file.stat.mode) != git_file_mode(expected_mode)

  :same
end

def numstat_against_rendered(rendered, target_file)
  Tempfile.create("rendered") do |tmp|
    tmp.write(rendered)
    tmp.flush
    out, _err, status = Open3.capture3("git", "diff", "--no-index", "--numstat", target_file.to_s, tmp.path)
    return "" if status.exitstatus.nil? || status.exitstatus > 1

    added, deleted, = out.split
    # numstat columns are target -> rendered, so "added" counts lines the sync
    # would add to the consumer file.
    added && deleted ? "+#{added}/-#{deleted}" : ""
  end
end

# --- audit mode ---------------------------------------------------------------
# One row per (source -> target) pair: what the sync would impose vs what the
# consumer carries. mtimes are a review signal only (they lie after cp/clone);
# the content comparison decides. Always exits 0 — the disposition pass
# (adopt-into-RF / keep-RF / record an exclude with a reason) is human.
def run_audit(components, target_root, consumer_slug, excludes, header_template,
              merge_label_begin, merge_label_end, fragments_by_target)
  mtime = ->(path) { path.exist? ? path.mtime.strftime("%Y-%m-%d %H:%M") : "-" }
  rows = components.filter_map do |component|
    next if component["mode"] == "fragment"

    target_rel = component.fetch("target")
    source_file = SOURCE_ROOT / component.fetch("source")
    target_file = target_root / target_rel
    row = { target: target_rel, consumer_mtime: mtime.call(target_file), rf_mtime: mtime.call(source_file), detail: "" }
    next row.merge(status: "no-source") unless source_file.exist?

    begin
      content, expected_mode = render_component(component, target_root, consumer_slug, header_template,
                                                merge_label_begin, merge_label_end, fragments_by_target, {})
    rescue SyncError => e
      # The annotation is the one-line form of the failure; fall back to the
      # message's first line for SyncErrors that carry none.
      next row.merge(status: "error", detail: (e.annotation || e.message.lines.first.to_s).strip)
    end
    next row.merge(status: "skipped") if content.nil?

    case classify_rendered(target_file, content, expected_mode)
    when :missing
      row.merge(status: "missing")
    when :differs
      row.merge(status: "differs", detail: numstat_against_rendered(content, target_file))
    when :mode
      row.merge(status: "mode", detail: "mode #{git_file_mode(target_file.stat.mode)}, " \
                                        "expected #{git_file_mode(expected_mode)}")
    else
      row.merge(status: "same")
    end
  end

  puts "Audit: #{consumer_slug} -> #{target_root} (#{rows.length} pairs)"
  width = rows.map { |r| r[:target].length }.max.to_i.clamp(6, 60)
  puts format("%-9s %-#{width}s %-17s %-17s %s", "status", "target", "consumer-mtime", "rf-mtime", "detail")
  rows.each do |row|
    puts format("%-9s %-#{width}s %-17s %-17s %s",
                row[:status], row[:target], row[:consumer_mtime], row[:rf_mtime], row[:detail])
  end
  counts = rows.group_by { |r| r[:status] }.transform_values(&:length)
  puts "Summary: #{counts.sort.map { |status, n| "#{n} #{status}" }.join(', ')}"
  unless excludes.empty?
    puts "Exclusions:"
    excludes.each { |entry| puts "  #{entry['target']} — #{entry['reason']}" }
  end
  exit 0
end

# --- guard mode ---------------------------------------------------------------
# Render the consumer's components and flag only those the PR touched whose
# content diverges from the canon. Exits 1 with a single-line annotation when
# any managed surface was edited; the per-file detail (including the diff, or
# the marker-state recovery recipe) goes to the step log.
def run_guard(components, target_root, consumer_slug, guard_base, header_template,
              merge_label_begin, merge_label_end, fragments_by_target)
  merge_base, err, status = Open3.capture3("git", "-C", target_root.to_s, "merge-base", guard_base, "HEAD")
  abort "could not resolve guard base #{guard_base}: #{err.strip}" unless status.success?

  # --no-renames: with rename detection a moved file surfaces only at its NEW
  # path, so a managed target renamed away would drop out of the touched set
  # and its disappearance would go unguarded. Delete+add keeps both paths.
  out, err, status = Open3.capture3("git", "-C", target_root.to_s,
                                    "diff", "--name-only", "-z", "--no-renames", merge_base.strip, "HEAD")
  abort "could not diff against merge base: #{err.strip}" unless status.success?

  touched = out.split("\0").reject(&:empty?)
  flagged = []
  components.each do |component|
    next if component["mode"] == "fragment"

    target_rel = component.fetch("target")
    next unless touched.include?(target_rel)

    source_file = SOURCE_ROOT / component.fetch("source")
    next warn("  skip (source missing): #{component['source']}") unless source_file.exist?

    target_file = target_root / target_rel
    begin
      content, expected_mode = render_component(component, target_root, consumer_slug, header_template,
                                                merge_label_begin, merge_label_end, fragments_by_target, {})
    rescue SyncError => e
      flagged << [target_rel, e.message]
      next
    end
    next if content.nil?

    case classify_rendered(target_file, content, expected_mode)
    when :missing
      flagged << [target_rel, "deleted in this PR, but it is repo-foundation-managed"]
    when :differs
      flagged << [target_rel, "diverges from the rendered canon:\n#{diff_against_rendered(content, target_file)}"]
    when :mode
      flagged << [target_rel, "file mode changed (expected #{git_file_mode(expected_mode)}, " \
                              "found #{git_file_mode(target_file.stat.mode)})"]
    end
  end

  if flagged.empty?
    puts "foundation-guard: no managed surface edited by this PR."
    exit 0
  end

  flagged.each do |target_rel, detail|
    warn "foundation-guard: #{target_rel}: #{detail}"
  end
  names = flagged.map(&:first).join(", ")
  raise SyncError.new(
    "foundation-guard: managed surface edited (#{names}); change these in toobuntu/repo-foundation instead",
    annotation: "PR edits repo-foundation-managed content (#{names}) — change it in toobuntu/repo-foundation; " \
                "see toobuntu/repo-foundation docs/maintaining-a-repo.md"
  )
end

if options[:guard_base]
  begin
    run_guard(components, target_root, consumer_slug, options[:guard_base], header_template,
              merge_label_begin, merge_label_end, fragments_by_target)
  rescue SyncError => e
    fail_sync(e)
  end
elsif options[:audit]
  run_audit(components, target_root, consumer_slug, excludes, header_template,
            merge_label_begin, merge_label_end, fragments_by_target)
end

# --- apply each component ----------------------------------------------------
puts "Syncing #{consumer_slug} -> #{target_root}#{dry_run ? ' (dry run)' : ''}"
changes = []
notes = {}
components.each do |component|
  target_rel = component.fetch("target")
  mode = component.fetch("mode")
  source_file = SOURCE_ROOT / component.fetch("source")
  target_file = target_root / target_rel

  next if mode == "fragment" # folded into the matching baseline-merge target

  unless source_file.exist?
    warn "  skip (source missing): #{component['source']} [#{mode}]"
    next
  end

  begin
    new_content, mode_bits = render_component(component, target_root, consumer_slug, header_template,
                                              merge_label_begin, merge_label_end, fragments_by_target, notes)
  rescue SyncError => e
    fail_sync(e)
  end

  next if new_content.nil? # e.g. a region-less target, deferred

  # Content AND git file mode both count, so exec-bit drift on a consumer copy
  # of a canonical script self-heals on the next sync instead of persisting.
  classification = classify_rendered(target_file, new_content, mode_bits)
  next if classification == :same

  status = { missing: "added", differs: "modified", mode: "mode" }.fetch(classification)
  change = { "path" => target_rel, "status" => status, "mode" => git_file_mode(mode_bits) }
  change["note"] = notes[target_rel] if notes[target_rel]
  changes << change
  note = notes[target_rel] ? " — #{notes[target_rel]}" : ""
  note = " — file mode restored to #{git_file_mode(mode_bits)}" if status == "mode"
  puts "  #{dry_run ? 'would update' : 'updated'}: #{target_rel} [#{mode}]#{note}"
  next if dry_run

  target_file.dirname.mkpath
  target_file.write(new_content) unless classification == :mode
  target_file.chmod(mode_bits)
end

if dry_run
  puts(changes.any? ? "Dry run: changes detected (nothing written)." : "Dry run: no changes.")
  exit
end

# --- emit the change list for the workflow's Git Data commit loop -------------
# The engine makes no git commits: the workflow turns changes.json into
# per-file chained commits through the GitHub Git Data API (git-data-commit.rb)
# so they arrive GitHub-signed with real file modes (rf-upstream-notes § 18i).
if options[:emit_dir]
  emit_dir = Pathname(options[:emit_dir]).expand_path
  emit_dir.mkpath
  (emit_dir / "changes.json").write("#{JSON.pretty_generate(changes)}\n")
  if changes.any?
    body = +"Automated sync from [toobuntu/repo-foundation](https://github.com/toobuntu/repo-foundation). " \
            "Do not edit synced files here; change them in repo-foundation and re-sync.\n" \
            "\n## Converged surfaces\n\n"
    changes.each do |change|
      line = "- `#{change['path']}` (#{change['status']}"
      line += ", #{change['mode']}" if change["mode"] == "100755" || change["status"] == "mode"
      line += ")"
      line += " — #{change['note']}" if change["note"]
      body << line << "\n"
    end
    unless excludes.empty?
      body << "\n## Exclusions\n\n"
      excludes.each { |entry| body << "- `#{entry['target']}` — #{entry['reason']}\n" }
    end
    (emit_dir / "pr-body.md").write(body)
  end
end

if ENV["GITHUB_ACTIONS"] && ENV["GITHUB_OUTPUT"]
  File.open(ENV.fetch("GITHUB_OUTPUT"), "a") { |f| f.puts "changed=#{changes.any?}" }
end
puts(changes.any? ? "Updated #{changes.length} file(s)." : "No changes.")
