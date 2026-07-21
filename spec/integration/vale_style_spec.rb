# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "open3"
require "tmpdir"

# Regression tests for the Toobuntu Vale style rules under .vale/styles/.
#
# Each rule gets flagged samples (must fire) and clean samples (must not
# fire). The samples are written as one file per case into a throwaway
# directory carrying a minimal .vale.ini that points StylesPath at the
# repository's committed styles, so the rules are tested directly — without
# the per-path relaxations of the repository's own .vale.ini. One vale run
# covers every sample; assertions group its line output by file.
#
# A flagged sample asserts only that its TARGET rule fires (other rules may
# incidentally fire on the same text); a clean sample asserts only that its
# target rule stays silent. This keeps cross-rule interference out of the
# assertions.
#
# Needs the real vale binary (the rules themselves are under test, so there
# is nothing to stub); skips cleanly where vale is absent. The spec.yml CI
# job does not install vale today, so CI exercises the skip path; the
# whole-tree prose.yml job remains the CI gate for the corpus itself.
VALE = ENV.fetch("VALE", "vale")

def vale_available?
  system(VALE, "--version", out: File::NULL, err: File::NULL)
rescue Errno::ENOENT
  false
end

# rule => { flag: [sample, ...], clean: [sample, ...] }
VALE_SAMPLES = {
  "AbbreviationPlurals" => {
    # Plural misuse: acronym + 's followed by a verb or punctuation.
    flag: [
      "Several PR's were merged yesterday.",
      "The team closed many PR's.",
    ],
    # Possessives: followed by a noun, an adjective, or (the 2026-07-14
    # extension) a participial adjective tagged VBG/VBN, an infinitive TO,
    # or a number CD — every one must pass.
    clean: [
      "The PR's base moved.",
      "The PR's old base moved.",
      "RF's existing gh calls work as before.",
      "The PR's synced files landed cleanly.",
      "Each item is RF's to fix.",
      "The PR's 3 commits landed.",
    ],
  },
  "We" => {
    flag: [
      "We should run the linter first.",
      "Let's run the linter first.",
      "The choice is ours to make.",
    ],
    clean: ["The linter runs on every commit."],
  },
  "AmericanSpelling" => {
    flag: [
      "The behaviour changed in this release.",
      "Change the colour of the output.",
    ],
    clean: ["The behavior changed in this release."],
  },
  "SentenceSpacing" => {
    flag: ["It works.  It really does."],
    clean: ["It works. It really does."],
  },
  "NonStandardQuotes" => {
    flag: ["It “works” well."],
    clean: ['It "works" well.'],
  },
  "WordSlashWord" => {
    flag: ["Use tabs and/or spaces."],
    clean: ["Use tabs or spaces."],
  },
  "MergeConflictMarkers" => {
    flag: ["<<<<<<< HEAD\ntheir text\n"],
    clean: ["Seven angle brackets inline <<<<<<<x do not count."],
  },
  "Terms" => {
    flag: ["Hosted on Github today."],
    clean: ["Hosted on GitHub today."],
  },
  "InclusiveLanguage" => {
    flag: ["Add the host to the whitelist."],
    clean: ["Add the host to the allowlist."],
  },
  "Acronyms" => {
    flag: ["The QZX pipeline failed."],
    clean: [
      "The Quality Zone Xchange (QZX) pipeline failed.",
      "The CLI works.",
    ],
  },
}.freeze

RSpec.describe "Toobuntu Vale style rules" do
  before(:all) do
    skip "vale not installed (brew install vale)" unless vale_available?

    @dir = Dir.mktmpdir("rf-vale-test-")
    File.write(File.join(@dir, ".vale.ini"), <<~INI)
      StylesPath = #{File.join(REPO_ROOT, '.vale', 'styles')}
      MinAlertLevel = suggestion

      [*.md]
      BasedOnStyles = Toobuntu
    INI

    # One file per sample; filenames encode the expectation for grouping.
    VALE_SAMPLES.each do |rule, sets|
      sets.each do |kind, samples|
        samples.each_with_index do |text, i|
          File.write(File.join(@dir, "#{rule}_#{kind}_#{i}.md"), "#{text}\n")
        end
      end
    end

    out, _err, _status = Open3.capture3(VALE, "--output=line", ".", chdir: @dir)
    # vale emits UTF-8 (rule messages contain typographic characters), but
    # capture3 tags the string with the locale encoding — US-ASCII in a
    # sandbox with no LANG — so force it before splitting.
    out = out.force_encoding(Encoding::UTF_8).scrub
    # line output: path:line:col:Toobuntu.Rule:message
    @fired = Hash.new { |h, k| h[k] = [] }
    out.each_line do |line|
      path, _line, _col, check, = line.split(":", 5)
      @fired[File.basename(path.to_s)] << check
    end
  end

  after(:all) do
    FileUtils.remove_entry(@dir) if @dir
  end

  VALE_SAMPLES.each do |rule, sets|
    describe "Toobuntu.#{rule}" do
      sets[:flag].each_with_index do |text, i|
        it "flags: #{text.lines.first.strip.inspect}" do
          expect(@fired["#{rule}_flag_#{i}.md"]).to include("Toobuntu.#{rule}")
        end
      end
      sets[:clean].each_with_index do |text, i|
        it "passes: #{text.lines.first.strip.inspect}" do
          expect(@fired["#{rule}_clean_#{i}.md"]).not_to include("Toobuntu.#{rule}")
        end
      end
    end
  end
end
