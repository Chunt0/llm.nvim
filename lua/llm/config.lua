local M = {
  ui = {
    mode = "inline", -- inline|float|split
    throttle_ms = 20,
  },
  memory = {
    enabled = true,
    max_messages = 20,
  },
  network = {
    max_time = 120,
    retry = 2,
  },
  context = {
    max_buffer_bytes = 200 * 1024,
    include_filetypes = nil, -- e.g., { 'lua','ts','tsx','py','go','rs' }
  },
  -- Set via require("llm").setup({ default_keymaps = true }) to register the
  -- built-in <leader> keymaps (see lua/llm/keymaps.lua for the full list).
  default_keymaps = false,
  agent = {
    provider = "ollama", -- default provider for :LLMAgent
    max_turns = 25, -- hard cap on request/tool-execution rounds per task
  },
  tools = {
    enabled = { "read_file", "list_files", "grep", "edit_file", "write_file", "bash" },
    -- Per-tool policy override: "allow" | "review" | "disabled".
    -- Read-only tools default to "allow"; edit_file/write_file default to
    -- "review" (diff accept/reject); bash is review-only — every call must be
    -- confirmed and it can never be set to "allow" (only "disabled").
    policy = {},
    max_result_bytes = 60 * 1024, -- cap on a single tool result sent to the model
  },
  logging = {
    enabled = (os.getenv("LLM_LOG") == "1"),
    redact = true,
    dir = nil, -- defaults to stdpath('data')..'/llm/logs'
  },
  keymaps = {
    diff_accept = "<leader>da",
    diff_reject = "<leader>dr",
  },
}

function M.setup(opts)
  if type(opts) ~= "table" then
    return
  end
  if opts.constants ~= nil then
    require("llm.constants").setup(opts.constants)
  end
  local function merge(dst, src)
    for k, v in pairs(src) do
      if k ~= "constants" then
        if type(v) == "table" and type(dst[k]) == "table" then
          merge(dst[k], v)
        else
          dst[k] = v
        end
      end
    end
  end
  merge(M, opts)
end

return M
