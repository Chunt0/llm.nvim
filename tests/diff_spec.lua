-- Tests for diff mode: _build_patched, get_visual_info, llm_config keymaps,
-- provider.create code_diff, and invoke_llm_and_stream_into_diff smoke tests.

local llm    = require("llm")
local utils  = require("utils")
local Config = require("llm_config")

-- ── _build_patched ────────────────────────────────────────────────────────────
-- Pure function: splice new_lines into orig at [start_row, end_row).
-- Indices are 0-based (matching nvim_buf_set_lines convention).

describe("llm._build_patched", function()
  it("replaces a middle range with new lines", function()
    local orig    = { "a", "b", "c", "d", "e" }
    local patched = llm._build_patched(orig, { "X", "Y" }, 1, 3)
    assert.are.same({ "a", "X", "Y", "d", "e" }, patched)
  end)

  it("replaces at the start of the file", function()
    local patched = llm._build_patched({ "a", "b", "c" }, { "NEW" }, 0, 2)
    assert.are.same({ "NEW", "c" }, patched)
  end)

  it("replaces at the end of the file", function()
    local patched = llm._build_patched({ "a", "b", "c" }, { "NEW" }, 2, 3)
    assert.are.same({ "a", "b", "NEW" }, patched)
  end)

  it("replaces the entire file", function()
    local patched = llm._build_patched({ "a", "b", "c" }, { "X", "Y", "Z" }, 0, 3)
    assert.are.same({ "X", "Y", "Z" }, patched)
  end)

  it("preserves context lines above and below the selection", function()
    local orig    = { "before1", "before2", "sel1", "sel2", "after1", "after2" }
    local patched = llm._build_patched(orig, { "new1" }, 2, 4)
    assert.are.same({ "before1", "before2", "new1", "after1", "after2" }, patched)
  end)

  it("handles more new lines than the original selection (expansion)", function()
    local patched = llm._build_patched({ "a", "b", "c" }, { "x", "y", "z" }, 1, 2)
    assert.are.same({ "a", "x", "y", "z", "c" }, patched)
  end)

  it("handles fewer new lines than the original selection (contraction)", function()
    local patched = llm._build_patched({ "a", "b", "c", "d", "e" }, { "X" }, 1, 4)
    assert.are.same({ "a", "X", "e" }, patched)
  end)

  it("does not mutate the original table", function()
    local orig   = { "a", "b", "c" }
    local _      = llm._build_patched(orig, { "NEW" }, 1, 2)
    assert.are.same({ "a", "b", "c" }, orig)
  end)

  it("handles a single-line file replaced by a single line", function()
    local patched = llm._build_patched({ "only" }, { "replaced" }, 0, 1)
    assert.are.same({ "replaced" }, patched)
  end)

  it("works with an empty replacement (deletion)", function()
    local patched = llm._build_patched({ "a", "b", "c" }, {}, 1, 2)
    assert.are.same({ "a", "c" }, patched)
  end)
end)

-- ── get_visual_info ───────────────────────────────────────────────────────────

describe("utils.get_visual_info", function()
  local saved_mode, saved_getpos, saved_get_lines

  before_each(function()
    saved_mode      = vim.fn.mode
    saved_getpos    = vim.fn.getpos
    saved_get_lines = vim.api.nvim_buf_get_lines
  end)

  after_each(function()
    vim.fn.mode                = saved_mode
    vim.fn.getpos              = saved_getpos
    vim.api.nvim_buf_get_lines = saved_get_lines
  end)

  it("returns nil in normal mode", function()
    vim.fn.mode = function() return "n" end
    assert.is_nil(utils.get_visual_info())
  end)

  it("returns nil in insert mode", function()
    vim.fn.mode = function() return "i" end
    assert.is_nil(utils.get_visual_info())
  end)

  it("returns nil in command mode", function()
    vim.fn.mode = function() return "c" end
    assert.is_nil(utils.get_visual_info())
  end)

  it("returns a table with the correct fields in line-visual mode", function()
    vim.fn.mode   = function() return "V" end
    vim.fn.getpos = function(mark)
      return mark == "v" and { 0, 3, 0, 0 } or { 0, 5, 0, 0 }
    end
    vim.api.nvim_buf_get_lines = function(_, s, e, _)
      local out = {}
      for i = s + 1, e do out[#out + 1] = "line" .. i end
      return out
    end

    local info = utils.get_visual_info()
    assert.is_table(info)
    assert.are.equal(2,  info.start_row)  -- srow - 1 = 3 - 1
    assert.are.equal(5,  info.end_row)    -- erow = 5
    assert.are.equal(3, #info.lines)      -- lines 3, 4, 5
  end)

  it("normalises a bottom-up selection (cursor above anchor)", function()
    vim.fn.mode   = function() return "V" end
    vim.fn.getpos = function(mark)
      -- visual mark at row 6, cursor at row 2 (selection made upward)
      return mark == "v" and { 0, 6, 0, 0 } or { 0, 2, 0, 0 }
    end
    vim.api.nvim_buf_get_lines = function(_, s, e, _)
      local out = {}
      for i = s + 1, e do out[#out + 1] = "x" end
      return out
    end

    local info = utils.get_visual_info()
    assert.is_table(info)
    assert.are.equal(1, info.start_row)  -- min(2, 6) - 1
    assert.are.equal(6, info.end_row)    -- max(2, 6)
  end)

  it("returns nil when buf_get_lines returns an empty table", function()
    vim.fn.mode   = function() return "V" end
    vim.fn.getpos = function(_) return { 0, 1, 0, 0 } end
    vim.api.nvim_buf_get_lines = function() return {} end
    assert.is_nil(utils.get_visual_info())
  end)

  it("works in char-visual mode", function()
    vim.fn.mode   = function() return "v" end
    vim.fn.getpos = function(mark)
      return mark == "v" and { 0, 2, 0, 0 } or { 0, 4, 0, 0 }
    end
    vim.api.nvim_buf_get_lines = function(_, s, e, _)
      local out = {}
      for i = s + 1, e do out[#out + 1] = "line" end
      return out
    end

    local info = utils.get_visual_info()
    assert.is_table(info)
    assert.are.equal(1, info.start_row)
    assert.are.equal(4, info.end_row)
  end)

  it("start_row and end_row are suitable for nvim_buf_set_lines", function()
    -- nvim_buf_set_lines(buf, start, end, ...) replaces lines [start, end).
    -- For a selection of rows 3-5 (1-indexed), the correct 0-indexed args are
    -- start=2 (inclusive), end=5 (exclusive).
    vim.fn.mode   = function() return "V" end
    vim.fn.getpos = function(mark)
      return mark == "v" and { 0, 3, 0, 0 } or { 0, 5, 0, 0 }
    end
    vim.api.nvim_buf_get_lines = function(_, s, e, _)
      local out = {}
      for i = s + 1, e do out[#out + 1] = "line" end
      return out
    end

    local info    = utils.get_visual_info()
    local orig    = { "pre1", "pre2", "sel1", "sel2", "sel3", "post1" }
    local patched = llm._build_patched(orig, { "new" }, info.start_row, info.end_row)
    -- selection was rows 3-5 (orig[3..5]); they should be replaced by "new"
    assert.are.same({ "pre1", "pre2", "new", "post1" }, patched)
  end)
end)

-- ── llm_config keymaps ────────────────────────────────────────────────────────

describe("llm_config keymaps", function()
  before_each(function()
    -- always start each test from defaults
    Config.setup({ keymaps = { diff_accept = "<leader>da", diff_reject = "<leader>dr" } })
  end)

  after_each(function()
    Config.setup({ keymaps = { diff_accept = "<leader>da", diff_reject = "<leader>dr" } })
  end)

  it("has a keymaps table", function()
    assert.is_table(Config.keymaps)
  end)

  it("default diff_accept is <leader>da", function()
    assert.are.equal("<leader>da", Config.keymaps.diff_accept)
  end)

  it("default diff_reject is <leader>dr", function()
    assert.are.equal("<leader>dr", Config.keymaps.diff_reject)
  end)

  it("setup() overrides diff_accept", function()
    Config.setup({ keymaps = { diff_accept = "<C-y>" } })
    assert.are.equal("<C-y>", Config.keymaps.diff_accept)
  end)

  it("setup() overrides diff_reject", function()
    Config.setup({ keymaps = { diff_reject = "<C-n>" } })
    assert.are.equal("<C-n>", Config.keymaps.diff_reject)
  end)

  it("overriding diff_accept leaves diff_reject untouched", function()
    Config.setup({ keymaps = { diff_accept = "<C-y>" } })
    assert.are.equal("<leader>dr", Config.keymaps.diff_reject)
  end)

  it("overriding diff_reject leaves diff_accept untouched", function()
    Config.setup({ keymaps = { diff_reject = "<C-n>" } })
    assert.are.equal("<leader>da", Config.keymaps.diff_accept)
  end)

  it("both keys can be overridden together", function()
    Config.setup({ keymaps = { diff_accept = "ga", diff_reject = "gr" } })
    assert.are.equal("ga", Config.keymaps.diff_accept)
    assert.are.equal("gr", Config.keymaps.diff_reject)
  end)
end)

-- ── provider.create exposes code_diff ─────────────────────────────────────────

describe("provider.create", function()
  local P, M

  before_each(function()
    P = require("provider")
    M = P.create({
      url         = "http://test.local/api",
      model       = "test-model",
      framework   = "TEST",
      prompts     = { system_prompt = "sys", code_prompt = "code" },
      vars        = { temp = 1 },
      make_curl   = llm.make_ollama_spec_curl_args,
      handle_data = llm.handle_ollama_spec_data,
    })
  end)

  it("exposes code_diff as a function", function()
    assert.is_function(M.code_diff)
  end)

  it("exposes all six modes", function()
    local modes = { "invoke", "code", "code_all_buf", "code_chat", "code_chat_all_buf", "code_diff" }
    for _, name in ipairs(modes) do
      assert.is_function(M[name], name .. " must be a function")
    end
  end)
end)

-- ── invoke_llm_and_stream_into_diff smoke tests ───────────────────────────────

describe("invoke_llm_and_stream_into_diff", function()
  it("is a function on the llm module", function()
    assert.is_function(llm.invoke_llm_and_stream_into_diff)
  end)

  it("returns nil without error when not in visual mode (no selection)", function()
    -- Default mode stub returns "n", so get_visual_info() returns nil → early exit.
    local result
    assert.has_no.errors(function()
      result = llm.invoke_llm_and_stream_into_diff(
        { model = "test", framework = "OLLAMA" },
        llm.make_ollama_spec_curl_args,
        llm.handle_ollama_spec_data
      )
    end)
    assert.is_nil(result)
  end)

  it("does not error with the Anthropic builder", function()
    assert.has_no.errors(function()
      llm.invoke_llm_and_stream_into_diff(
        { model = "claude-test", framework = "ANTHROPIC" },
        llm.make_anthropic_spec_curl_args,
        llm.handle_anthropic_spec_data
      )
    end)
  end)

  it("does not error with the OpenAI builder", function()
    assert.has_no.errors(function()
      llm.invoke_llm_and_stream_into_diff(
        { model = "gpt-test", framework = "OPENAI" },
        llm.make_openai_spec_curl_args,
        llm.handle_openai_spec_data
      )
    end)
  end)

  it("does not start a job when called without a visual selection", function()
    -- active_job stays nil because we exit early
    llm.invoke_llm_and_stream_into_diff(
      { model = "test", framework = "OLLAMA" },
      llm.make_ollama_spec_curl_args,
      llm.handle_ollama_spec_data
    )
    -- reset state so other tests are not affected
    llm.reset_message_buffers()
  end)
end)
