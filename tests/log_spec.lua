-- Tests for log.lua path handling.

local Log = require("llm.log")

describe("Log._build_log_path", function()
  -- P12 regression: a configured logging.dir without a trailing slash used to
  -- produce paths like ".../logs2026-07-02.jsonl" (missing separator).
  it("joins dir and date with exactly one slash (no trailing slash on dir)", function()
    assert.are.equal("/tmp/llmlogs/2026-07-03.jsonl", Log._build_log_path("/tmp/llmlogs", "2026-07-03"))
  end)

  it("joins dir and date with exactly one slash (trailing slash on dir)", function()
    assert.are.equal("/tmp/llmlogs/2026-07-03.jsonl", Log._build_log_path("/tmp/llmlogs/", "2026-07-03"))
  end)

  it("collapses multiple trailing slashes", function()
    assert.are.equal("/tmp/llmlogs/2026-07-03.jsonl", Log._build_log_path("/tmp/llmlogs//", "2026-07-03"))
  end)
end)
