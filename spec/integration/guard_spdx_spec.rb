# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "json"
require "open3"
require "tmpdir"

# scripts/ai/guard-spdx.sh refuses a Write that CREATES a file whose head
# carries a hand-written SPDX header — the executable form of the org's
# "annotate.sh writes headers, never by hand" rule. The guard is matched on
# the Write tool only, so the edit path is structurally out of scope; the
# cases here pin the creation/overwrite boundary and the ten-line window.
RSpec.describe "scripts/ai/guard-spdx.sh" do
  let(:script) { File.expand_path("../../scripts/ai/guard-spdx.sh", __dir__) }

  def guard(dir, file_path, content)
    payload = { tool_input: { file_path: file_path, content: content } }.to_json
    Open3.capture3({ "CLAUDE_PROJECT_DIR" => dir }, script,
                   chdir: dir, stdin_data: payload)
  end

  around do |example|
    Dir.mktmpdir("rf-guard-spdx-") { |dir| @dir = dir and example.run }
  end

  it "refuses a new file opening with a copyright tag" do
    _out, err, status = guard(@dir, "new.sh",
                              "#!/bin/sh\n# SPDX-FileCopyrightText: Copyright 2026 X\n")
    expect(status.exitstatus).to eq(2)
    expect(err).to include("annotate.sh")
  end

  it "refuses a new file opening with a license tag alone" do
    _out, err, status = guard(@dir, "new.c",
                              "// SPDX-License-Identifier: GPL-3.0-or-later\n")
    expect(status.exitstatus).to eq(2)
    expect(err).to include("Hand-written SPDX header refused")
  end

  it "refuses a hand-written .license sidecar" do
    _out, _err, status = guard(@dir, "asset.png.license",
                               "SPDX-FileCopyrightText: Copyright 2026 X\n\nSPDX-License-Identifier: GPL-3.0-or-later\n")
    expect(status.exitstatus).to eq(2)
  end

  it "refuses the snippet tag form too" do
    _out, _err, status = guard(@dir, "snip.py",
                               "# SPDX-SnippetCopyrightText: 2026 X\n")
    expect(status.exitstatus).to eq(2)
  end

  it "allows a headerless creation — the annotate.sh workflow" do
    _out, _err, status = guard(@dir, "plain.sh", "#!/bin/sh\necho hi\n")
    expect(status.exitstatus).to eq(0)
  end

  it "allows overwriting an existing annotated file" do
    path = File.join(@dir, "existing.md")
    File.write(path, "seed\n")
    _out, _err, status = guard(@dir, path,
                               "<!--\nSPDX-FileCopyrightText: Copyright 2026 X\n-->\nbody\n")
    expect(status.exitstatus).to eq(0)
  end

  it "allows a new file that merely mentions a tag past the ten-line head" do
    body = ("prose line\n" * 12) + "the SPDX-License-Identifier tag is documented here\n"
    _out, _err, status = guard(@dir, "docs.md", body)
    expect(status.exitstatus).to eq(0)
  end

  it "stays silent on input with no file path" do
    _out, _err, status = guard(@dir, nil, nil)
    expect(status.exitstatus).to eq(0)
  end
end
