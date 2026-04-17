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
    ignore_dirs = { 'node_modules', '.git', 'dist', 'build' },
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
  if type(opts) ~= 'table' then return end
  if opts.constants ~= nil then
    require("constants").setup(opts.constants)
  end
  local function merge(dst, src)
    for k, v in pairs(src) do
      if k ~= 'constants' then
        if type(v) == 'table' and type(dst[k]) == 'table' then
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
