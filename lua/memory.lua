local Config = require("llm_config")

local M = {}
local store = {}

local function get_bufnr(bufnr)
  return bufnr or vim.api.nvim_get_current_buf()
end

function M.clear(bufnr)
  store[get_bufnr(bufnr)] = {}
end

function M.append(bufnr, role, content)
  if not role or not content then return end
  bufnr = get_bufnr(bufnr)
  store[bufnr] = store[bufnr] or {}
  table.insert(store[bufnr], { role = role, content = content })
  local max = (Config.memory and Config.memory.max_messages) or 20
  if #store[bufnr] > max then
    local cut = #store[bufnr] - max
    for _ = 1, cut do
      table.remove(store[bufnr], 1)
    end
  end
end

function M.messages(bufnr)
  bufnr = get_bufnr(bufnr)
  store[bufnr] = store[bufnr] or {}
  return store[bufnr]
end

function M.build_messages(bufnr, system_prompt, prompt)
  local msgs = {}
  if system_prompt and system_prompt ~= "" then
    table.insert(msgs, { role = "system", content = system_prompt })
  end
  for _, m in ipairs(M.messages(bufnr)) do
    table.insert(msgs, m)
  end
  table.insert(msgs, { role = "user", content = prompt })
  return msgs
end

return M
