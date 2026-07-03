local M = {}

-- Very small helpers to parse streaming outputs

-- SSE parser: feeds complete logical lines to a callback table
-- state: { buf = "", event = nil } — the current event name lives in the state
-- so an event:/data: pair split across two chunks stays paired.
-- chunk: string (may contain multiple lines)
-- cb: { on_event(name), on_data(json_or_text, event_name), on_comment(text), on_line(line) }
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
    if line == "" then
      -- Blank line terminates an SSE event; the event name does not carry over.
      state.event = nil
    elseif line:match("^:%s?") then
      if cb and cb.on_comment then
        cb.on_comment(line:sub(2))
      end
    elseif line:match("^event:%s*") then
      local ev = line:match("^event:%s*(.-)%s*$") or ""
      state.event = ev
      if cb and cb.on_event then
        cb.on_event(ev)
      end
    elseif line:match("^data:%s*") then
      local data = line:gsub("^data:%s*", "")
      if cb and cb.on_data then
        cb.on_data(data, state.event)
      end
    end
  end
end

-- ===== Normalized stream events (llm.Sink) ==================================
-- sink: { on_text(delta), on_thinking(delta)?, on_tool_call({id,name,input}),
--         on_stop(reason, detail?), on_error({code?, message}) }
-- Reasons: "end_turn" | "tool_use" | "max_tokens" | "refusal" | "error"

local function emit(sink, name, ...)
  if sink and sink[name] then
    sink[name](...)
  end
end

--- Anthropic Messages API SSE → Sink events.
--- state: { buf, event, blocks = {}, stop_reason } — reusable across chunks.
--- Streamed tool calls arrive as a content_block_start (type tool_use) plus
--- input_json_delta fragments that are accumulated per block index and JSON-
--- decoded at content_block_stop, so fragments split at any byte boundary or
--- across curl chunks reassemble correctly.
function M.anthropic_events(state, chunk, sink)
  state.blocks = state.blocks or {}
  M.parse_sse_chunk(state, chunk, {
    on_data = function(payload, event_name)
      local ok, obj = pcall(vim.json.decode, payload)
      if not ok or type(obj) ~= "table" then
        return
      end
      local t = obj.type or event_name
      if t == "error" then
        emit(sink, "on_error", {
          message = (obj.error and obj.error.message) or "unknown stream error",
        })
      elseif t == "content_block_start" and obj.content_block then
        local cb = obj.content_block
        state.blocks[obj.index or 0] = { type = cb.type, id = cb.id, name = cb.name, json = "" }
      elseif t == "content_block_delta" and obj.delta then
        local d = obj.delta
        if d.type == "text_delta" and d.text then
          emit(sink, "on_text", d.text)
        elseif d.type == "thinking_delta" and d.thinking then
          emit(sink, "on_thinking", d.thinking)
        elseif d.type == "input_json_delta" and d.partial_json then
          local block = state.blocks[obj.index or 0]
          if block then
            block.json = block.json .. d.partial_json
          end
        end
      elseif t == "content_block_stop" then
        local block = state.blocks[obj.index or 0]
        if block and block.type == "tool_use" then
          local input = {}
          if block.json ~= "" then
            local ok_in, decoded = pcall(vim.json.decode, block.json)
            if ok_in and type(decoded) == "table" then
              input = decoded
            else
              emit(sink, "on_error", { message = "tool call " .. tostring(block.name) .. ": malformed input JSON" })
            end
          end
          emit(sink, "on_tool_call", { id = block.id, name = block.name, input = input })
        end
        state.blocks[obj.index or 0] = nil
      elseif t == "message_delta" and obj.delta and obj.delta.stop_reason then
        state.stop_reason = obj.delta.stop_reason
      elseif t == "message_stop" then
        emit(sink, "on_stop", state.stop_reason or "end_turn")
        state.stop_reason = nil
      end
    end,
  })
end

--- Ollama /api/chat JSONL → Sink events.
--- state: { buf, call_count, saw_tool_call } — reusable across chunks.
--- Tool-call arguments arrive as a decoded object (not a JSON string); Ollama
--- provides no call ids, so stable synthetic ones are generated per response.
function M.ollama_events(state, chunk, sink)
  M.parse_jsonl_chunk(state, chunk, {
    on_json = function(obj)
      if obj.error then
        emit(sink, "on_error", { message = tostring(obj.error) })
        return
      end
      local msg = obj.message
      if msg then
        if msg.content and msg.content ~= "" then
          emit(sink, "on_text", tostring(msg.content))
        end
        if type(msg.tool_calls) == "table" then
          for _, tc in ipairs(msg.tool_calls) do
            local fn = tc["function"] or {}
            state.call_count = (state.call_count or 0) + 1
            state.saw_tool_call = true
            local input = fn.arguments
            if type(input) == "string" then
              local ok, decoded = pcall(vim.json.decode, input)
              input = (ok and type(decoded) == "table") and decoded or {}
            elseif type(input) ~= "table" then
              input = {}
            end
            emit(sink, "on_tool_call", {
              id = tc.id or ("call_" .. state.call_count),
              name = fn.name,
              input = input,
            })
          end
        end
      end
      if obj.done and obj.done ~= vim.NIL then
        local reason
        if state.saw_tool_call then
          reason = "tool_use"
        elseif obj.done_reason == "length" then
          reason = "max_tokens"
        else
          reason = "end_turn"
        end
        state.saw_tool_call = false
        emit(sink, "on_stop", reason)
      end
    end,
  })
end

--- OpenAI Responses API SSE → Sink events (agent mode).
--- state: { buf, event, calls = {}, saw_call, incomplete } — reusable across chunks.
--- Function calls stream as an output_item.added (type function_call, carrying
--- call_id/name) plus function_call_arguments.delta fragments accumulated per
--- output_index; the call is emitted at output_item.done.
function M.openai_events(state, chunk, sink)
  state.calls = state.calls or {}
  M.parse_sse_chunk(state, chunk, {
    on_data = function(payload, _)
      if payload:match("^%[DONE%]") then
        return
      end
      local ok, obj = pcall(vim.json.decode, payload)
      if not ok or type(obj) ~= "table" then
        return
      end
      local t = tostring(obj.type or "")
      if t == "response.output_text.delta" and obj.delta then
        emit(sink, "on_text", obj.delta)
      elseif t == "response.reasoning_summary_text.delta" and obj.delta then
        emit(sink, "on_thinking", obj.delta)
      elseif t == "response.output_item.added" and obj.item and obj.item.type == "function_call" then
        state.calls[obj.output_index or 0] = {
          id = obj.item.call_id,
          name = obj.item.name,
          args = obj.item.arguments or "",
        }
      elseif t == "response.function_call_arguments.delta" and obj.delta then
        local call = state.calls[obj.output_index or 0]
        if call then
          call.args = call.args .. obj.delta
        end
      elseif t == "response.output_item.done" and obj.item and obj.item.type == "function_call" then
        local call = state.calls[obj.output_index or 0] or { id = obj.item.call_id, name = obj.item.name, args = "" }
        -- the done item carries the full arguments; prefer it over our accumulation
        local raw = (obj.item.arguments and obj.item.arguments ~= "") and obj.item.arguments or call.args
        local input = {}
        if raw and raw ~= "" then
          local ok_in, decoded = pcall(vim.json.decode, raw)
          if ok_in and type(decoded) == "table" then
            input = decoded
          else
            emit(sink, "on_error", { message = "tool call " .. tostring(call.name) .. ": malformed arguments JSON" })
          end
        end
        state.saw_call = true
        emit(
          sink,
          "on_tool_call",
          { id = call.id or obj.item.call_id, name = call.name or obj.item.name, input = input }
        )
        state.calls[obj.output_index or 0] = nil
      elseif t == "response.completed" or t == "response.incomplete" then
        local reason
        local resp = obj.response or {}
        local inc = resp.incomplete_details or {}
        if state.saw_call then
          reason = "tool_use"
        elseif inc.reason == "max_output_tokens" or t == "response.incomplete" then
          reason = "max_tokens"
        else
          reason = "end_turn"
        end
        state.saw_call = false
        emit(sink, "on_stop", reason)
      elseif t == "response.failed" or t == "error" or t == "response.error" then
        local msg = (obj.error and obj.error.message)
          or (obj.response and obj.response.error and obj.response.error.message)
          or obj.message
          or "unknown error"
        emit(sink, "on_error", { message = msg })
      end
    end,
  })
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
