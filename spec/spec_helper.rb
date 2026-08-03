# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Repo root shared by the integration specs. Defined once here — each
# spec previously defined its own copy, tripping Ruby's
# already-initialized-constant warning under config.warnings.
REPO_ROOT = File.expand_path("..", __dir__)

# Read files as UTF-8 whatever the ambient locale is. Ruby derives
# Encoding.default_external from LANG/LC_ALL, and a shell with neither set —
# the Claude Code sandbox is one — leaves it US-ASCII, so `File.read` on any
# repository file containing a non-ASCII byte raises `invalid byte sequence in
# US-ASCII`. The codepoint-table specs read `scripts/lint-unicode.sh`, which by
# its nature holds such bytes. UTF-8 is not a guess here: CONTRIBUTING requires
# every tracked file to be valid UTF-8 without a BOM, and the unicode gate
# enforces it. Specs that mean to inspect raw bytes use `File.binread`.
Encoding.default_external = Encoding::UTF_8

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.warnings = true
  config.default_formatter = "doc" if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed
end
