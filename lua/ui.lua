local M = {}

local function setup_buffer(bufnr)
  vim.bo[bufnr].buftype   = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile  = false
end

function M.open(mode)
  if mode == "float" then
    local bufnr = vim.api.nvim_create_buf(false, true)
    setup_buffer(bufnr)
    local width  = math.floor(vim.o.columns * 0.7)
    local height = math.floor(vim.o.lines * 0.6)
    local row    = math.floor((vim.o.lines - height) * 0.5)
    local col    = math.floor((vim.o.columns - width) * 0.5)
    local win = vim.api.nvim_open_win(bufnr, false, {
      relative = "editor",
      row      = row,
      col      = col,
      width    = width,
      height   = height,
      style    = "minimal",
      border   = "rounded",
    })
    return { bufnr = bufnr, win = win }
  end

  if mode == "split" then
    vim.cmd("split")
    local win   = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_create_buf(false, true)
    setup_buffer(bufnr)
    vim.api.nvim_win_set_buf(win, bufnr)
    return { bufnr = bufnr, win = win }
  end

  -- inline
  return { bufnr = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win() }
end

--- Open a vertical split to the right of original_win for diff streaming.
--- The scratch buffer starts empty; caller streams into it, then calls diffthis.
function M.open_diff(original_win)
  vim.api.nvim_set_current_win(original_win)
  vim.cmd("vsplit")
  local scratch_win   = vim.api.nvim_get_current_win()
  local scratch_bufnr = vim.api.nvim_create_buf(false, true)
  setup_buffer(scratch_bufnr)
  vim.api.nvim_win_set_buf(scratch_win, scratch_bufnr)
  vim.api.nvim_buf_set_lines(scratch_bufnr, 0, -1, false, { "" })
  return { bufnr = scratch_bufnr, win = scratch_win }
end

return M
