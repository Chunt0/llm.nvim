-- Agent/chat session persistence: one JSON file per session under
-- stdpath("data")/llm/sessions, so a conversation survives restarting Neovim
-- (:LLMAgentResume). dir is injectable for tests.
local M = {}

function M.dir()
  local base = "/tmp"
  pcall(function()
    base = vim.fn.stdpath("data")
  end)
  return base .. "/llm/sessions"
end

local function ensure_dir(dir)
  pcall(function()
    vim.fn.mkdir(dir, "p")
  end)
end

--- Save a session. session.meta = { id, provider, model, title } — id is
--- assigned on first save. Returns the path, or nil + err.
function M.save(session, dir)
  dir = dir or M.dir()
  ensure_dir(dir)
  session.meta = session.meta or {}
  if not session.meta.id then
    -- sequence suffix: two sessions saved within the same second must not
    -- share a file
    M._seq = (M._seq or 0) + 1
    session.meta.id = os.date("%Y%m%d_%H%M%S") .. string.format("_%03d", M._seq % 1000)
  end
  if not session.meta.title then
    local first = session.messages[1]
    local text = first and tostring(first.content) or "session"
    session.meta.title = text:gsub("%s+", " "):sub(1, 60)
  end
  local path = dir .. "/" .. session.meta.id .. ".json"
  local ok, encoded = pcall(vim.json.encode, { meta = session.meta, messages = session.messages })
  if not ok then
    return nil, "session encode failed: " .. tostring(encoded)
  end
  local f = io.open(path, "w")
  if not f then
    return nil, "cannot write " .. path
  end
  f:write(encoded)
  f:close()
  return path
end

--- Load one session file. Returns { meta, messages } or nil + err.
function M.load(path)
  local f = io.open(path, "r")
  if not f then
    return nil, "cannot read " .. path
  end
  local raw = f:read("*a")
  f:close()
  local ok, session = pcall(vim.json.decode, raw)
  if not ok or type(session) ~= "table" or type(session.messages) ~= "table" then
    return nil, "corrupt session file: " .. path
  end
  session.meta = session.meta or {}
  return session
end

--- List saved sessions, newest first: { { path, id, title, provider, model } }.
function M.list(dir)
  dir = dir or M.dir()
  local out = {}
  local ok, names = pcall(function()
    local acc = {}
    for name, kind in vim.fs.dir(dir) do
      if kind == "file" and name:match("%.json$") then
        table.insert(acc, name)
      end
    end
    return acc
  end)
  if not ok or not names then
    return out
  end
  table.sort(names, function(a, b)
    return a > b
  end)
  for _, name in ipairs(names) do
    local session = M.load(dir .. "/" .. name)
    if session then
      table.insert(out, {
        path = dir .. "/" .. name,
        id = session.meta.id or name:gsub("%.json$", ""),
        title = session.meta.title or name,
        provider = session.meta.provider,
        model = session.meta.model,
      })
    end
  end
  return out
end

return M
