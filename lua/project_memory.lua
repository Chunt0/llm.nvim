-- project_memory.lua
-- Loads llm_memory.md from the project root (cwd) and injects it as
-- persistent LLM context.  Create/edit the file with :LLMMemoryEdit.

local M = {}

local function get_path()
  return vim.fn.getcwd() .. "/llm_memory.md"
end

--- Read llm_memory.md; returns content string or nil if absent/empty.
function M.load()
  local path = get_path()
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  if content and #content > 0 then
    return content
  end
  return nil
end

--- Open llm_memory.md in a horizontal split for editing.
--- Creates the file if it does not exist.
function M.edit()
  local path = get_path()
  local f = io.open(path, "a")
  if f then
    f:close()
  end
  vim.cmd("split " .. vim.fn.fnameescape(path))
end

--- Return the absolute path to llm_memory.md.
function M.path()
  return get_path()
end

return M
