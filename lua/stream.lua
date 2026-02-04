local M = {}

-- Very small helpers to parse streaming outputs

-- SSE parser: feeds complete logical lines to a callback table
-- state: { buf = "" }
-- chunk: string (may contain multiple lines)
-- cb: { on_event(name), on_data(json_or_text), on_comment(text), on_line(line) }
function M.parse_sse_chunk(state, chunk, cb)
  if not chunk or chunk == "" then
    return
  end
  state.buf = (state.buf or "") .. chunk
  local lines = {}
  for line in state.buf:gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  state.buf = state.buf:match("([^\n]*)$") or ""

  for _, line in ipairs(lines) do
    if cb and cb.on_line then
      cb.on_line(line)
    end
    if line:match("^:%s?") then
      if cb and cb.on_comment then
        cb.on_comment(line:sub(2))
      end
    elseif line:match("^event:%s*") then
      local ev = line:match("^event:%s*(.-)%s*$") or ""
      if cb and cb.on_event then
        cb.on_event(ev)
      end
    elseif line:match("^data:%s*") then
      local data = line:gsub("^data:%s*", "")
      if cb and cb.on_data then
        cb.on_data(data)
      end
    end
  end
end

-- JSONL parser: each line should be a JSON object
-- state: { buf = "" }
-- cb: { on_json(table) }
function M.parse_jsonl_chunk(state, chunk, cb)
  if not chunk or chunk == "" then
    return
  end
  state.buf = (state.buf or "") .. chunk
  local start = 1
  while true do
    local nl = state.buf:find("\n", start, true)
    if not nl then
      -- keep remainder
      state.buf = state.buf:sub(start)
      break
    end
    local line = state.buf:sub(start, nl - 1)
    start = nl + 1
    if line ~= "" then
      local ok, obj = pcall(vim.json.decode, line)
      if ok and obj and cb and cb.on_json then
        cb.on_json(obj)
      end
    end
  end
end

return M
