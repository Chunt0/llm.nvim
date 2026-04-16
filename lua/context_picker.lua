-- context_picker.lua
-- Interactive picker to add/remove open buffers from the LLM context.
-- Selected buffers are automatically injected into every prompt.
--
-- Commands wired in llm.lua:
--   :LLMContextAdd   - toggle a buffer into / out of context
--   :LLMContextClear - remove all context buffers
--   :LLMContextList  - print currently selected context buffers

local M = {}
local _selected = {} -- list of buffer numbers

--- Prune stale entries and return the current selection.
function M.get_selected()
  local valid = {}
  for _, bufnr in ipairs(_selected) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      table.insert(valid, bufnr)
    end
  end
  _selected = valid
  return _selected
end

--- Open a vim.ui.select picker; selecting an item toggles it in the list.
--- Only normal file buffers (buftype == "") are shown — no terminals/scratch.
function M.add()
  local candidates = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name and name ~= "" then
        table.insert(candidates, { bufnr = bufnr, name = name })
      end
    end
  end

  if #candidates == 0 then
    vim.notify("LLM: No open buffers available", vim.log.levels.WARN)
    return
  end

  vim.ui.select(candidates, {
    prompt = "Toggle buffer in LLM context ([x] = currently selected):",
    format_item = function(item)
      local display = vim.fn.fnamemodify(item.name, ":~:.")
      local checked = false
      for _, b in ipairs(_selected) do
        if b == item.bufnr then
          checked = true
          break
        end
      end
      return (checked and "[x] " or "[ ] ") .. display
    end,
  }, function(choice)
    if not choice then
      return
    end
    for i, b in ipairs(_selected) do
      if b == choice.bufnr then
        table.remove(_selected, i)
        vim.notify(
          "LLM: Removed from context: " .. vim.fn.fnamemodify(choice.name, ":~:."),
          vim.log.levels.INFO
        )
        return
      end
    end
    table.insert(_selected, choice.bufnr)
    vim.notify(
      "LLM: Added to context: " .. vim.fn.fnamemodify(choice.name, ":~:."),
      vim.log.levels.INFO
    )
  end)
end

--- Remove all buffers from the context list.
function M.clear()
  _selected = {}
  vim.notify("LLM: Context cleared", vim.log.levels.INFO)
end

--- Print the currently selected context buffers.
function M.list()
  local sels = M.get_selected()
  if #sels == 0 then
    vim.notify("LLM: No buffers in context  (use :LLMContextAdd to add)", vim.log.levels.INFO)
    return
  end
  local lines = { "LLM Context buffers:" }
  for i, bufnr in ipairs(sels) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    table.insert(lines, string.format("  %d. %s", i, vim.fn.fnamemodify(name, ":~:.")))
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Return the concatenated text of all selected context buffers, or nil.
function M.get_text()
  local sels = M.get_selected()
  if #sels == 0 then
    return nil
  end
  local Utils = require("utils")
  local parts = {}
  for _, bufnr in ipairs(sels) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if Utils.should_include_file(name) then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      table.insert(parts, "File: " .. name)
      table.insert(parts, table.concat(lines, "\n"))
      table.insert(parts, "---")
    end
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, "\n")
end

return M
