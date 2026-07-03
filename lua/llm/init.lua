local M = {}
-- Neovim's LuaJIT has the 5.1 global; CI's Lua 5.4 only has table.unpack.
local unpack = unpack or table.unpack
local Job = require("plenary.job")
local Log = require("llm.log")
local Utils = require("llm.utils")
local Stream = require("llm.stream")
local Config = require("llm.config")
local Memory = require("llm.memory")
local UI = require("llm.ui")
local Constants = require("llm.constants")

-- ===== Debug toggle =====
local DEBUG = false -- set true to spam :messages
local function dbg(msg)
  if not DEBUG then
    return
  end
  msg = "[llm] " .. tostring(msg)
  vim.schedule(function()
    pcall(vim.notify, msg, vim.log.levels.INFO)
  end)
  pcall(vim.api.nvim_echo, { { msg, "None" } }, true, {})
end
function M.set_debug(on)
  DEBUG = not not on
  dbg("DEBUG=" .. tostring(DEBUG))
end

-- ===== Per-invocation stream context (fixes P13) =====
-- All mutable stream state (extmark anchor, UTF-8 carry, pending flush text,
-- response accumulator, final assistant message) lives on a context object
-- created fresh per invocation, so a cancelled or superseded stream's late
-- callbacks can never write into the next stream's buffer or transcript.
local NS = vim.api.nvim_create_namespace("LLMStream")

local function split_complete_utf8(s)
  if s == "" then
    return "", ""
  end
  local len, i = #s, #s
  while i > 0 do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then
      break
    end
    i = i - 1
  end
  if i == 0 then
    return "", s
  end
  local lead = s:byte(i)
  -- ASCII needs no continuation bytes: without the < 0x80 case the final
  -- character of every chunk was held in the carry, and chat history built at
  -- message_stop (before the exit flush) stored replies missing their last
  -- character.
  local need = (lead < 0x80 and 0) or (lead < 0xE0 and 1) or (lead < 0xF0 and 2) or (lead < 0xF8 and 3) or 0
  local have = len - i
  if have < need then
    return s:sub(1, i - 1), s:sub(i)
  else
    return s, ""
  end
end

local StreamCtx = {}
StreamCtx.__index = StreamCtx

local function new_stream_ctx()
  return setmetatable({
    anchor = nil, -- { bufnr, id }
    carry = "", -- incomplete UTF-8 sequence held between chunks
    pending = "", -- text batched for the next throttled flush
    accum = "", -- whole response so far
    flush_scheduled = false,
    assistant_message = nil,
  }, StreamCtx)
end

function StreamCtx:start_anchor(bufnr, winid)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local win = winid or vim.api.nvim_get_current_win()
  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  local id = vim.api.nvim_buf_set_extmark(bufnr, NS, row - 1, col, { right_gravity = false })
  self.anchor = { bufnr = bufnr, id = id }
  dbg(("anchor start buf=%d row=%d col=%d"):format(bufnr, row - 1, col))
end

function StreamCtx:append_at_anchor(txt)
  if not txt or txt == "" then
    return
  end
  txt = txt:gsub("[\r\b]", "")
  local sa = self.anchor and { bufnr = self.anchor.bufnr, id = self.anchor.id } or nil
  vim.schedule(function()
    if not sa or not sa.bufnr or not sa.id or not vim.api.nvim_buf_is_loaded(sa.bufnr) then
      local bufnr = vim.api.nvim_get_current_buf()
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      local id = vim.api.nvim_buf_set_extmark(bufnr, NS, row - 1, col, { right_gravity = false })
      self.anchor = { bufnr = bufnr, id = id }
      sa = { bufnr = bufnr, id = id }
      dbg("anchor recreated")
    end
    local ok_pos, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, sa.bufnr, NS, sa.id, {})
    local row, col
    if ok_pos and pos and pos[1] ~= nil then
      row, col = pos[1], pos[2]
    else
      local last_row = vim.api.nvim_buf_line_count(sa.bufnr) - 1
      local last_line = vim.api.nvim_buf_get_lines(sa.bufnr, last_row, last_row + 1, false)[1] or ""
      row, col = last_row, #last_line
      pcall(vim.api.nvim_buf_set_extmark, sa.bufnr, NS, row, col, { id = sa.id, right_gravity = false })
      dbg("anchor moved to EOF")
    end
    local lines = vim.split(txt, "\n", { plain = true })
    pcall(vim.api.nvim_buf_set_text, sa.bufnr, row, col, row, col, lines)
    local last = lines[#lines]
    local new_row = row + (#lines - 1)
    local new_col = (#lines == 1) and (col + #last) or #last
    pcall(vim.api.nvim_buf_set_extmark, sa.bufnr, NS, new_row, new_col, { id = sa.id, right_gravity = false })
  end)
end

function StreamCtx:end_anchor()
  self.anchor = nil
  dbg("anchor cleared")
end

function StreamCtx:flush()
  if self.pending ~= "" then
    self:append_at_anchor(self.pending)
    self.pending = ""
  end
  self.flush_scheduled = false
end

function StreamCtx:write(chunk)
  if not chunk or chunk == "" then
    return
  end
  if self.carry ~= "" then
    chunk = self.carry .. chunk
    self.carry = ""
  end
  chunk = chunk:gsub("\r\n", "\n"):gsub("[\r\b]", "")
  local complete, tail = split_complete_utf8(chunk)
  self.carry = tail
  if complete ~= "" then
    self.accum = self.accum .. complete
    self.pending = self.pending .. complete
    if not self.flush_scheduled then
      self.flush_scheduled = true
      local t = (Config.ui and Config.ui.throttle_ms) or 20
      vim.defer_fn(function()
        self:flush()
      end, t)
    end
  end
end

--- Flush the carry (end of stream) then any pending text.
function StreamCtx:finalize()
  if self.carry ~= "" then
    local tail = self.carry
    self.carry = ""
    self:write(tail)
  end
  self:flush()
end

-- Exported so integrations/tests can create isolated stream contexts and pass
-- them via the parser state ({ buf = "", ctx = ... }).
M.new_stream_ctx = new_stream_ctx

-- Handlers called without a parser state (bare/legacy usage, tests) share one
-- module-level context — the old behavior. Handlers wired through the invoke
-- functions below always carry a fresh per-invocation context instead.
local fallback_ctx = new_stream_ctx()
local function ctx_of(state)
  if type(state) == "table" then
    state.ctx = state.ctx or fallback_ctx
    return state.ctx
  end
  return fallback_ctx
end

-- ===== State =====
local provider_state = {
  OPENAI = { response_id = "" },
}

-- Stream handlers run on the job's luv thread where vim.notify is not allowed.
local function notify_async(msg, level)
  vim.schedule(function()
    vim.notify(msg, level or vim.log.levels.WARN)
  end)
end

local function curl_common_args()
  local args = { "-sS", "-N", "--no-buffer", "--fail-with-body", "-K", "-" }
  local net = Config.network or {}
  if net.max_time then
    table.insert(args, "--max-time")
    table.insert(args, tostring(net.max_time))
  end
  if net.retry and tonumber(net.retry) and tonumber(net.retry) > 0 then
    table.insert(args, "--retry")
    table.insert(args, tostring(net.retry))
    table.insert(args, "--retry-all-errors")
    table.insert(args, "--retry-delay")
    table.insert(args, "1")
  end
  return args
end

local function extract_error_message(err)
  -- Matches both verbose-style status lines ("HTTP/1.1 401") and the message
  -- curl actually prints with --fail-with-body ("… returned error: 401").
  local code = err:match("HTTP/%d+%.?%d*%s+(%d%d%d)") or err:match("returned error:%s*(%d%d%d)")
  local msg = nil
  local json_blob = err:match("({.*})")
  if json_blob then
    local ok, obj = pcall(vim.json.decode, json_blob)
    if ok and obj then
      if obj.error and obj.error.message then
        msg = obj.error.message
      elseif obj.message then
        msg = obj.message
      end
    end
  end
  return code, msg
end

local function notify_http_error(err)
  local code, msg = extract_error_message(err)
  if not code then
    return
  end
  local hint = msg or "HTTP error"
  if code == "401" or code == "403" then
    hint = "Authentication failed (check API key)"
  elseif code == "429" then
    hint = "Rate limited; try again later"
  elseif tonumber(code) and tonumber(code) >= 500 then
    hint = "Server error; try again later"
  end
  vim.notify("LLM: " .. hint .. " (HTTP " .. code .. ")", vim.log.levels.ERROR)
end

local function build_messages(opts, prompt, system_prompt)
  if opts.messages then
    return opts.messages
  end
  return {
    { role = "system", content = system_prompt or "" },
    { role = "user", content = prompt },
  }
end

local function split_system(messages)
  local system = nil
  local rest = {}
  for _, m in ipairs(messages) do
    if m.role == "system" and not system then
      system = m.content
    else
      table.insert(rest, m)
    end
  end
  return system, rest
end

-- ===== Provider: Anthropic (Messages API SSE) =====
function M.make_anthropic_spec_curl_args(opts, prompt, system_prompt)
  local model = opts.model
  local url = (opts.url and #opts.url > 0) and opts.url or "https://api.anthropic.com/v1/messages"
  local api_key = opts.api_key_name and Utils.get_api_key(opts.api_key_name) or os.getenv("ANTHROPIC_API_KEY")
  local messages = build_messages(opts, prompt, system_prompt)
  local system, rest = split_system(messages)
  -- No temperature/top_p: current Claude models (Opus 4.7+, Sonnet 5) reject
  -- sampling parameters with a 400. Steer behavior via the prompts instead.
  local data = {
    model = model,
    stream = true,
    system = system or system_prompt,
    messages = rest,
    max_tokens = opts.max_tokens or 16000,
  }
  local json = vim.json.encode(data)
  local args = curl_common_args()
  local cfg = {
    string.format('url = "%s"', url),
    'request = "POST"',
    'header = "Content-Type: application/json"',
    'header = "Accept: text/event-stream"',
    'header = "anthropic-version: 2023-06-01"',
  }
  if api_key and #api_key > 0 then
    table.insert(cfg, string.format('header = "x-api-key: %s"', api_key))
  else
    dbg("WARNING: no ANTHROPIC_API_KEY found")
  end
  table.insert(cfg, string.format("data = %q", json))
  return { args = args, config = table.concat(cfg, "\n") }
end

function M.handle_anthropic_spec_data(chunk, state)
  state = state or { buf = "" }
  local ctx = ctx_of(state)
  Stream.parse_sse_chunk(state, chunk, {
    -- The event name arrives as the second argument, carried in the parser
    -- state, so event:/data: pairs split across curl chunks stay paired.
    on_data = function(payload, event_name)
      local ok, obj = pcall(vim.json.decode, payload)
      if not ok or not obj then
        return
      end
      if obj.type == "error" or event_name == "error" then
        local msg = (obj.error and obj.error.message) or "unknown stream error"
        notify_async("LLM (anthropic): " .. msg, vim.log.levels.ERROR)
        return
      end
      if (event_name and event_name:match("content_block")) or obj.delta then
        local text = (obj.delta and obj.delta.text) or (obj.delta and obj.delta[1] and obj.delta[1].text)
        if text and #text > 0 then
          ctx:write(text)
        end
      end
      if obj.type == "message_delta" and obj.delta and obj.delta.stop_reason then
        local reason = obj.delta.stop_reason
        if reason == "max_tokens" then
          notify_async("LLM: response truncated (max_tokens reached) — raise max_tokens in setup()")
        elseif reason == "refusal" then
          notify_async("LLM: the model declined this request (stop_reason=refusal)")
        end
      end
      if obj.type == "message_stop" or event_name == "message_stop" then
        ctx.assistant_message = { role = "assistant", content = ctx.accum }
      end
    end,
  })
end

-- ===== Provider: Ollama (Chat API — JSONL) =====
-- Uses /api/chat with messages[] for proper multi-turn support.
function M.make_ollama_spec_curl_args(opts, prompt, system_prompt)
  local url = (opts.url and #opts.url > 0) and opts.url or "http://localhost:11434/api/chat"
  local messages
  if opts.messages then
    messages = opts.messages
  else
    messages = {}
    if system_prompt and system_prompt ~= "" then
      table.insert(messages, { role = "system", content = system_prompt })
    end
    table.insert(messages, { role = "user", content = prompt })
  end
  local data = {
    model = opts.model,
    messages = messages,
    stream = true,
  }
  local json = vim.json.encode(data)
  local args = curl_common_args()
  local cfg = {
    string.format('url = "%s"', url),
    'request = "POST"',
    'header = "Content-Type: application/json"',
    'header = "Accept: application/x-ndjson"',
    string.format("data = %q", json),
  }
  return { args = args, config = table.concat(cfg, "\n") }
end

function M.handle_ollama_spec_data(chunk, state)
  state = state or { buf = "" }
  local ctx = ctx_of(state)
  Stream.parse_jsonl_chunk(state, chunk, {
    on_json = function(obj)
      if obj.error then
        notify_async("LLM (ollama): " .. tostring(obj.error), vim.log.levels.ERROR)
        return
      end
      if obj.message and obj.message.content then
        ctx:write(tostring(obj.message.content))
      end
      if obj.done and obj.done ~= vim.NIL then
        ctx.assistant_message = { role = "assistant", content = ctx.accum }
      end
    end,
  })
end

-- ===== Provider: OpenAI (Responses API) =====
function M.make_openai_spec_curl_args(opts, prompt, system_prompt)
  local model = opts.model
  local url = (opts.url and #opts.url > 0) and opts.url or "https://api.openai.com/v1/responses"
  local api_key = opts.api_key_name and Utils.get_api_key(opts.api_key_name) or os.getenv("OPENAI_API_KEY")
  local reasoning_effort = opts.reasoning_effort or "low"

  local oai = provider_state.OPENAI

  local instructions = system_prompt
  if opts.messages then
    instructions = nil
  end
  local data = {
    model = model,
    stream = true,
    input = opts.messages or prompt,
    instructions = instructions,
    reasoning = { effort = reasoning_effort },
    store = true,
  }
  -- Chain onto the previous response only when we actually captured its id —
  -- a failed request must not leave an empty/stale id in the chain.
  if oai.response_id and oai.response_id ~= "" then
    data.previous_response_id = oai.response_id
  end
  local json = vim.json.encode(data)
  dbg(("openai req: url=%s model=%s bytes=%d"):format(url, tostring(model), #json))

  local args = curl_common_args()
  local config_lines = {
    string.format('url = "%s"', url),
    'request = "POST"',
    'header = "Content-Type: application/json"',
    'header = "Accept: text/event-stream"',
  }
  if api_key and #api_key > 0 then
    table.insert(config_lines, string.format('header = "Authorization: Bearer %s"', api_key))
  else
    dbg("WARNING: no OPENAI_API_KEY found")
  end
  table.insert(config_lines, string.format("data = %q", json))

  return { args = args, config = table.concat(config_lines, "\n") }
end

function M.handle_openai_spec_data(line, state)
  if not line then
    return
  end
  local ctx = ctx_of(state)

  if line:match("^:%s?.*") or line:match("^event:%s*[%w%._-]+%s*$") then
    return
  end
  if line:match("^data:%s*%[DONE%]") then
    return
  end

  local payload = line:gsub("^data:%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if payload == "" then
    return
  end

  local ok, json = pcall(vim.json.decode, payload)
  if not ok or not json then
    dbg("JSON decode fail: " .. payload)
    return
  end

  if json.response and json.response.id then
    provider_state.OPENAI.response_id = json.response.id
    dbg("response.id=" .. provider_state.OPENAI.response_id)
  end

  local t = tostring(json.type or "")

  if (t == "response.output_text.delta" or t:match("%.output_text%.delta$")) and json.delta then
    ctx:write(json.delta)
    return
  end

  if t == "response.output_text.done" or t:match("%.output_text%.done$") then
    if json.text then
      ctx.assistant_message = { role = "assistant", content = json.text }
      dbg("Assistant Message: " .. json.text)
    end
    return
  end

  if t == "response.completed" then
    dbg("response.completed")
    return
  end

  if t == "response.error" or t == "response.failed" or t == "error" then
    local emsg = (json.error and json.error.message)
      or (json.response and json.response.error and json.response.error.message)
      or "unknown error"
    notify_async("LLM (openai): " .. emsg, vim.log.levels.ERROR)
    return
  end
end

-- ===== DALL·E (Images) =====
local function decode_base64(data)
  if vim.base64 and vim.base64.decode then
    return vim.base64.decode(data)
  end
  local tmp = vim.fn.tempname()
  local f = io.open(tmp, "w")
  if f then
    f:write(data)
    f:close()
  end
  local out = vim.fn.system({ "base64", "-d", tmp })
  os.remove(tmp)
  return out
end

function M.make_dalle_spec_curl_args(opts, prompt)
  local url = (opts.url and #opts.url > 0) and opts.url or "https://api.openai.com/v1/images/generations"
  local api_key = opts.api_key_name and Utils.get_api_key(opts.api_key_name) or os.getenv("OPENAI_API_KEY")
  local data = {
    model = opts.model or "gpt-image-1",
    prompt = prompt,
    size = opts.size or "1024x1024",
    response_format = "b64_json",
  }
  local json = vim.json.encode(data)
  local args = curl_common_args()
  local cfg = {
    string.format('url = "%s"', url),
    'request = "POST"',
    'header = "Content-Type: application/json"',
  }
  if api_key and #api_key > 0 then
    table.insert(cfg, string.format('header = "Authorization: Bearer %s"', api_key))
  else
    dbg("WARNING: no OPENAI_API_KEY found")
  end
  table.insert(cfg, string.format("data = %q", json))
  return { args = args, config = table.concat(cfg, "\n") }
end

function M.handle_dalle_spec_data(chunk, state)
  state = state or { buf = "", done = false }
  if state.done then
    return
  end
  state.buf = (state.buf or "") .. chunk
  local ok, obj = pcall(vim.json.decode, state.buf)
  if not ok or not obj then
    return
  end
  state.done = true
  local img = obj.data and obj.data[1]
  if not img then
    vim.notify("LLM: no image data returned", vim.log.levels.WARN)
    return
  end
  local b64 = img.b64_json
  if not b64 then
    vim.notify("LLM: image response missing b64_json", vim.log.levels.WARN)
    return
  end
  local bytes = decode_base64(b64)
  local dir = vim.fn.stdpath("data") .. "/llm/images"
  vim.fn.mkdir(dir, "p")
  local path = string.format("%s/image_%s.png", dir, os.date("%Y%m%d_%H%M%S"))
  local f = io.open(path, "wb")
  if not f then
    vim.notify("LLM: failed to write image", vim.log.levels.ERROR)
    return
  end
  f:write(bytes)
  f:close()
  vim.notify("LLM: image saved to " .. path, vim.log.levels.INFO)
end

-- ===== Invoke =====
local group = vim.api.nvim_create_augroup("LLM_AutoGroup", { clear = true })
local active_job = nil

function M.invoke_llm_and_stream_into_editor(opts, make_curl_args_fn, handle_spec_data_fn)
  vim.api.nvim_clear_autocmds({ group = group })

  local ui_mode = (Config.ui and Config.ui.mode) or "inline"
  opts.ui_mode = ui_mode

  local prompt = Utils.get_prompt(opts)
  if not prompt or prompt == "" then
    dbg("no prompt from Utils.get_prompt(opts)")
    return
  end

  local framework = opts.framework
  local model = opts.model
  vim.notify("[llm] Calling " .. tostring(model), vim.log.levels.INFO)

  -- Build system prompt, then prepend project memory if available
  local system_prompt = opts.system_prompt or ""
  local ok_pm, pm = pcall(require, "llm.project_memory")
  if ok_pm then
    local mem = pm.load()
    if mem and mem ~= "" then
      local mem_header = "# Project Memory (persistent codebase context):\n" .. mem
      system_prompt = mem_header .. (system_prompt ~= "" and ("\n\n" .. system_prompt) or "")
    end
  end

  local target = UI.open(ui_mode)
  local target_bufnr = target and target.bufnr or vim.api.nvim_get_current_buf()
  local target_win = target and target.win or vim.api.nvim_get_current_win()
  if ui_mode ~= "inline" and target and target.win then
    if vim.api.nvim_buf_line_count(target.bufnr) == 0 then
      vim.api.nvim_buf_set_lines(target.bufnr, 0, -1, false, { "" })
    end
    vim.api.nvim_win_set_cursor(target.win, { 1, 0 })
  end

  local use_memory = (Config.memory and Config.memory.enabled) and opts.code_chat
  local mem_bufnr = vim.api.nvim_get_current_buf()
  if use_memory then
    -- The user turn is stored only after a successful reply (see on_exit):
    -- appending it up-front leaves consecutive user messages behind when a
    -- request fails, which Anthropic rejects on every following request.
    opts.messages = Memory.build_messages(mem_bufnr, system_prompt, prompt)
  end

  local ctx = new_stream_ctx()
  local req = make_curl_args_fn(opts, prompt, system_prompt)
  local args, kconfig
  if type(req) == "table" and req.args then
    args = req.args
    kconfig = req.config
  else
    args = req
  end
  if not args or (type(args) == "table" and #args == 0) then
    vim.notify("LLM: request builder returned no arguments; skipping invocation", vim.log.levels.WARN)
    return
  end

  if active_job then
    dbg("shutting down previous job")
    active_job:shutdown()
    active_job = nil
  end

  ctx:start_anchor(target_bufnr, target_win)

  local function normalize_chunk(out)
    if type(out) == "table" then
      out = table.concat(out, "\n")
    end
    return (out or ""):gsub("\r\n", "\n")
  end

  local parser_state = { buf = "", ctx = ctx }
  local error_notified = false
  local stderr_buf = {}
  local stdout_buf = {} -- collects raw lines for error reporting
  local function on_stdout(_, out)
    local chunk = normalize_chunk(out)
    if chunk == "" then
      return
    end
    if #stdout_buf < 6 then
      table.insert(stdout_buf, chunk)
    end
    -- plenary.job strips newlines; re-add so SSE/JSONL stream parsers can
    -- detect line boundaries and dispatch on_event/on_data/on_json callbacks.
    chunk = chunk .. "\n"
    local ok = pcall(handle_spec_data_fn, chunk, parser_state)
    if not ok then
      pcall(handle_spec_data_fn, chunk)
    end
  end

  local esc_bufnr = vim.api.nvim_get_current_buf()
  local function remove_esc_keymap()
    pcall(vim.keymap.del, "n", "<Esc>", { buffer = esc_bufnr })
  end

  local on_exit_common = vim.schedule_wrap(function(_, code)
    if framework ~= "OPENAI" then
      -- switching away from OpenAI breaks the response chain; reset its state
      provider_state.OPENAI = { response_id = "" }
    end

    -- Flush the carry and any pending text now so their vim.schedule writes
    -- are queued first. Then wrap the separator insertion in another
    -- vim.schedule so it runs after the text write (scheduled FIFO).
    ctx:finalize()

    vim.schedule(function()
      local bufnr = target_bufnr
      local last_line = vim.api.nvim_buf_line_count(bufnr) - 1
      local insert_at = last_line + 1
      local user_line = "---------------------------User---------------------------"
      vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, { "", user_line, "" })
      pcall(vim.api.nvim_win_set_cursor, target_win, { insert_at + 3, 0 })

      if not ctx.assistant_message and ctx.accum ~= "" then
        ctx.assistant_message = { role = "assistant", content = ctx.accum }
      end
      local succeeded = (code == 0 or code == nil)
      if
        succeeded
        and use_memory
        and ctx.assistant_message
        and ctx.assistant_message.content
        and ctx.assistant_message.content ~= ""
      then
        -- Store the turn as a user/assistant pair so roles always alternate.
        Memory.append(mem_bufnr, "user", prompt)
        Memory.append(mem_bufnr, "assistant", ctx.assistant_message.content)
      end

      local user_message = { role = "user", content = prompt }
      local time = os.date("%Y-%m-%dT%H:%M:%S")
      local log_entry = {
        time = time,
        framework = framework,
        model = model,
        user = user_message,
        assistant = ctx.assistant_message,
      }
      pcall(Log.log, log_entry)
      active_job = nil
      ctx:end_anchor()
      remove_esc_keymap()
      if not succeeded then
        local body = table.concat(stdout_buf, " ")
        local _, api_msg = extract_error_message(body)
        local detail = api_msg and (": " .. api_msg) or (#body > 0 and ("\nResponse: " .. body) or "")
        vim.notify("LLM: request failed (curl " .. tostring(code) .. ")" .. detail, vim.log.levels.ERROR)
      end
      dbg("job closed")
    end)
  end)

  active_job = Job:new({
    command = "curl",
    args = args,
    on_stdout = on_stdout,
    on_stderr = function(_, err)
      if err and err ~= "" then
        dbg("STDERR: " .. err:gsub("\r", "\\r"))
        table.insert(stderr_buf, err)
        if not error_notified then
          local code = extract_error_message(err)
          if code then
            error_notified = true
            notify_http_error(err)
          end
        end
      end
    end,
    on_exit = on_exit_common,
    enable_handlers = true,
    writer = kconfig,
  })

  dbg("starting curl job…")
  active_job:start()

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "LLM_Escape",
    callback = function()
      if active_job then
        active_job:shutdown()
        vim.notify("LLM streaming cancelled", vim.log.levels.INFO)
        active_job = nil
        ctx:end_anchor()
        remove_esc_keymap()
        dbg("cancelled by user")
      end
    end,
  })

  pcall(
    vim.keymap.set,
    "n",
    "<Esc>",
    ":doautocmd User LLM_Escape<CR>",
    { buffer = esc_bufnr, noremap = true, silent = true }
  )
  return active_job
end

-- ===== Diff helpers (exported for testing) =====

--- Splice new_lines into orig at [start_row, end_row) (0-indexed, exclusive end).
--- Returns a new table — orig is never mutated.
function M._build_patched(orig, new_lines, start_row, end_row)
  local out = {}
  for i = 1, start_row do
    out[#out + 1] = orig[i]
  end
  for _, l in ipairs(new_lines) do
    out[#out + 1] = l
  end
  for i = end_row + 1, #orig do
    out[#out + 1] = orig[i]
  end
  return out
end

-- ===== Diff / replace mode =====
-- Streams the LLM response into a scratch vsplit. The original buffer is never
-- touched while the request is in flight, so a failure or cancel leaves the
-- user's code exactly as it was.
--   opts.auto_apply = false (code_diff): enables Neovim's native diff between
--     the original and the proposed replacement; the keys from
--     Config.keymaps.diff_accept / diff_reject (default <leader>da / <leader>dr)
--     accept or reject it.
--   opts.auto_apply = true (code / code_all_buf): applies the replacement to
--     the selection as soon as the stream completes successfully and closes
--     the scratch window.
function M.invoke_llm_and_stream_into_diff(opts, make_curl_args_fn, handle_spec_data_fn)
  vim.api.nvim_clear_autocmds({ group = group })

  local sel = Utils.get_visual_info()
  if not sel then
    vim.notify("LLM: highlight the code you want rewritten.", vim.log.levels.ERROR)
    return
  end

  -- Exit visual mode before splitting.
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", false, true, true), "nx", false)

  local original_bufnr = vim.api.nvim_get_current_buf()
  local original_win = vim.api.nvim_get_current_win()
  local framework = opts.framework
  local model = opts.model

  local mode_label = opts.auto_apply and "replace mode" or "diff mode"
  vim.notify("[llm] Calling " .. tostring(model) .. " (" .. mode_label .. ")", vim.log.levels.INFO)

  local system_prompt = opts.system_prompt or ""
  local ok_pm, pm = pcall(require, "llm.project_memory")
  if ok_pm then
    local mem = pm.load()
    if mem and mem ~= "" then
      system_prompt = "# Project Memory (persistent codebase context):\n"
        .. mem
        .. (system_prompt ~= "" and ("\n\n" .. system_prompt) or "")
    end
  end

  local sel_text = table.concat(sel.lines, "\n")
  local ctx_text
  if opts.all_buffers then
    -- get_all_buffers_text already folds in the context-picker selection.
    local all = Utils.get_all_buffers_text(opts)
    ctx_text = (all ~= "" and all) or nil
  else
    local ok_cp, ContextPicker = pcall(require, "llm.context_picker")
    ctx_text = ok_cp and ContextPicker.get_text() or nil
  end
  local code_instruction = Constants.prompts.code_instruction .. sel_text
  local prompt = ctx_text and ("# Code Context:\n" .. ctx_text .. "\n\n" .. code_instruction) or code_instruction

  local target = UI.open_diff(original_win)
  local scratch_bufnr = target.bufnr
  local scratch_win = target.win

  local ctx = new_stream_ctx()
  ctx:start_anchor(scratch_bufnr, scratch_win)

  local req = make_curl_args_fn(opts, prompt, system_prompt)
  local args, kconfig
  if type(req) == "table" and req.args then
    args, kconfig = req.args, req.config
  else
    args = req
  end
  if not args or (type(args) == "table" and #args == 0) then
    vim.notify("LLM: request builder returned no arguments; skipping", vim.log.levels.WARN)
    pcall(vim.api.nvim_win_close, scratch_win, true)
    return
  end

  if active_job then
    active_job:shutdown()
    active_job = nil
  end

  local function normalize_chunk(out)
    if type(out) == "table" then
      out = table.concat(out, "\n")
    end
    return (out or ""):gsub("\r\n", "\n")
  end

  local parser_state = { buf = "", ctx = ctx }
  local error_notified = false
  local stderr_buf = {}
  local stdout_buf = {}

  local function on_stdout(_, out)
    local chunk = normalize_chunk(out)
    if chunk == "" then
      return
    end
    if #stdout_buf < 6 then
      table.insert(stdout_buf, chunk)
    end
    chunk = chunk .. "\n"
    local ok = pcall(handle_spec_data_fn, chunk, parser_state)
    if not ok then
      pcall(handle_spec_data_fn, chunk)
    end
  end

  local function remove_esc_keymap()
    pcall(vim.keymap.del, "n", "<Esc>", { buffer = scratch_bufnr })
  end

  local on_exit = vim.schedule_wrap(function(_, code)
    if framework ~= "OPENAI" then
      provider_state.OPENAI = { response_id = "" }
    end

    ctx:finalize()

    vim.schedule(function()
      if code ~= 0 then
        -- code == nil means the job was cancelled — clean up without the
        -- failure notification (the cancel path already notified).
        if code ~= nil then
          local body = table.concat(stdout_buf, " ")
          local _, api_msg = extract_error_message(body)
          local detail = api_msg and (": " .. api_msg) or (#body > 0 and ("\nResponse: " .. body) or "")
          vim.notify("LLM: request failed (curl " .. tostring(code) .. ")" .. detail, vim.log.levels.ERROR)
        end
        remove_esc_keymap()
        pcall(vim.api.nvim_win_close, scratch_win, true)
        active_job = nil
        ctx:end_anchor()
        return
      end

      -- Capture the streamed replacement, stripping any trailing blank lines.
      local new_lines = vim.api.nvim_buf_get_lines(scratch_bufnr, 0, -1, false)
      while #new_lines > 0 and new_lines[#new_lines] == "" do
        table.remove(new_lines)
      end
      if #new_lines == 0 then
        new_lines = { "" }
      end

      if opts.auto_apply then
        -- Replace mode: the stream finished cleanly, so write the new lines
        -- into the original buffer and close the scratch window.
        remove_esc_keymap()
        vim.api.nvim_buf_set_lines(original_bufnr, sel.start_row, sel.end_row, false, new_lines)
        pcall(vim.api.nvim_win_close, scratch_win, true)
        if vim.api.nvim_win_is_valid(original_win) then
          vim.api.nvim_set_current_win(original_win)
          pcall(vim.api.nvim_win_set_cursor, original_win, { sel.start_row + 1, 0 })
        end
        vim.notify("LLM: replacement applied (u to undo)", vim.log.levels.INFO)
        pcall(Log.log, {
          time = os.date("%Y-%m-%dT%H:%M:%S"),
          framework = framework,
          model = model,
          user = { role = "user", content = prompt },
          assistant = { role = "assistant", content = ctx.accum },
        })
        active_job = nil
        ctx:end_anchor()
        return
      end

      -- Replace scratch buffer with the full patched file so the diff shows
      -- only the changed region in context, not the whole file as different.
      local orig_all = vim.api.nvim_buf_get_lines(original_bufnr, 0, -1, false)
      local patched = M._build_patched(orig_all, new_lines, sel.start_row, sel.end_row)
      vim.api.nvim_buf_set_lines(scratch_bufnr, 0, -1, false, patched)

      -- Scroll both windows to the changed region before enabling diff.
      pcall(vim.api.nvim_win_set_cursor, original_win, { sel.start_row + 1, 0 })
      pcall(vim.api.nvim_win_set_cursor, scratch_win, { sel.start_row + 1, 0 })
      vim.api.nvim_set_current_win(original_win)
      vim.cmd("diffthis")
      vim.api.nvim_set_current_win(scratch_win)
      vim.cmd("diffthis")

      local km = Config.keymaps or {}
      local key_accept = km.diff_accept or "<leader>da"
      local key_reject = km.diff_reject or "<leader>dr"

      vim.notify("LLM diff ready — " .. key_accept .. ": accept  " .. key_reject .. ": reject", vim.log.levels.INFO)

      local function cleanup(apply)
        pcall(vim.keymap.del, "n", key_accept, { buffer = original_bufnr })
        pcall(vim.keymap.del, "n", key_reject, { buffer = original_bufnr })
        remove_esc_keymap()
        vim.cmd("diffoff!")
        if apply then
          vim.api.nvim_buf_set_lines(original_bufnr, sel.start_row, sel.end_row, false, new_lines)
        end
        pcall(vim.api.nvim_win_close, scratch_win, true)
        if vim.api.nvim_win_is_valid(original_win) then
          vim.api.nvim_set_current_win(original_win)
          pcall(vim.api.nvim_win_set_cursor, original_win, { sel.start_row + 1, 0 })
        end
      end

      for _, bufnr in ipairs({ original_bufnr, scratch_bufnr }) do
        pcall(vim.keymap.set, "n", key_accept, function()
          cleanup(true)
        end, {
          buffer = bufnr,
          nowait = true,
          silent = true,
          desc = "LLM diff: accept changes",
        })
        pcall(vim.keymap.set, "n", key_reject, function()
          cleanup(false)
        end, {
          buffer = bufnr,
          nowait = true,
          silent = true,
          desc = "LLM diff: reject changes",
        })
      end

      -- Tidy up if the user closes the scratch window manually with :q.
      vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = scratch_bufnr,
        once = true,
        callback = function()
          pcall(vim.cmd, "diffoff!")
          local km2 = Config.keymaps or {}
          pcall(vim.keymap.del, "n", km2.diff_accept or "<leader>da", { buffer = original_bufnr })
          pcall(vim.keymap.del, "n", km2.diff_reject or "<leader>dr", { buffer = original_bufnr })
        end,
      })

      pcall(Log.log, {
        time = os.date("%Y-%m-%dT%H:%M:%S"),
        framework = framework,
        model = model,
        user = { role = "user", content = prompt },
        assistant = { role = "assistant", content = ctx.accum },
      })
      active_job = nil
      ctx:end_anchor()
    end)
  end)

  active_job = Job:new({
    command = "curl",
    args = args,
    on_stdout = on_stdout,
    on_stderr = function(_, err)
      if err and err ~= "" then
        dbg("STDERR: " .. err:gsub("\r", "\\r"))
        table.insert(stderr_buf, err)
        if not error_notified then
          local c = extract_error_message(err)
          if c then
            error_notified = true
            notify_http_error(err)
          end
        end
      end
    end,
    on_exit = on_exit,
    enable_handlers = true,
    writer = kconfig,
  })

  active_job:start()

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "LLM_Escape",
    callback = function()
      if active_job then
        active_job:shutdown()
        vim.notify("LLM " .. mode_label .. " cancelled", vim.log.levels.INFO)
        active_job = nil
        remove_esc_keymap()
        pcall(vim.api.nvim_win_close, scratch_win, true)
        ctx:end_anchor()
      end
    end,
  })

  pcall(
    vim.keymap.set,
    "n",
    "<Esc>",
    ":doautocmd User LLM_Escape<CR>",
    { buffer = scratch_bufnr, noremap = true, silent = true }
  )

  return active_job
end

--- Single setup entry point.
---   require("llm").setup({
---     default_keymaps = true,             -- register the built-in <leader> maps
---     constants = { models = {...}, api_endpoints = {...}, prompts = {...} },
---     ui = {...}, memory = {...}, network = {...}, keymaps = {...}, logging = {...},
---   })
function M.setup(opts)
  opts = opts or {}
  Config.setup(opts)
  if opts.default_keymaps then
    require("llm.keymaps").apply()
  end
end

function M.reset_message_buffers()
  provider_state.OPENAI = { response_id = "" }
  fallback_ctx = new_stream_ctx()
  Memory.clear()
  vim.notify("LLM session cleared", vim.log.levels.INFO)
end

-- ===== User Commands =====
pcall(vim.api.nvim_create_user_command, "LLMCancel", function()
  vim.api.nvim_exec_autocmds("User", { pattern = "LLM_Escape" })
end, { desc = "Cancel running LLM stream" })

pcall(vim.api.nvim_create_user_command, "LLMReset", function()
  M.reset_message_buffers()
end, { desc = "Reset LLM message buffers" })

pcall(vim.api.nvim_create_user_command, "LLMClear", function()
  Memory.clear()
  vim.notify("LLM memory cleared", vim.log.levels.INFO)
end, { desc = "Clear conversation memory for current buffer" })

-- Generic invoker: :LLMInvoke provider=<openai|anthropic|ollama> mode=<invoke|code|chat>
pcall(vim.api.nvim_create_user_command, "LLMInvoke", function(cmd)
  local args = cmd.args or ""
  local provider = args:match("provider=([%w_%-]+)") or args:match("^([%w_%-]+)") or "ollama"
  local mode = args:match("mode=([%w_%-]+)") or "invoke"
  if mode == "chat" then
    mode = "code_chat"
  end
  local ok, mod = pcall(require, "llm." .. provider)
  if not ok then
    vim.notify("LLM: unknown provider '" .. provider .. "' (valid: openai, anthropic, ollama)", vim.log.levels.ERROR)
    return
  end
  local fn = mod[mode]
  if type(fn) ~= "function" then
    fn = mod.invoke
  end
  fn()
end, { desc = "Invoke LLM provider (openai|anthropic|ollama)", nargs = "*" })

-- Agent mode: multi-turn tool-use loop with project read access.
-- :LLMAgent [provider=ollama|anthropic] {task}  (prompts for the task if omitted)
pcall(vim.api.nvim_create_user_command, "LLMAgent", function(cmd)
  local ok, agent = pcall(require, "llm.agent")
  if not ok then
    vim.notify("LLM: agent module failed to load: " .. tostring(agent), vim.log.levels.ERROR)
    return
  end
  agent.start(cmd.args)
end, { desc = "Run the LLM agent (read_file/list_files/grep tools)", nargs = "*" })

pcall(vim.api.nvim_create_user_command, "LLMAgentResume", function()
  local ok, agent = pcall(require, "llm.agent")
  if not ok then
    vim.notify("LLM: agent module failed to load: " .. tostring(agent), vim.log.levels.ERROR)
    return
  end
  agent.resume()
end, { desc = "Resume a saved LLM agent session" })

pcall(vim.api.nvim_create_user_command, "LLMDalle", function()
  local ok, mod = pcall(require, "llm.openai")
  if not ok then
    vim.notify("LLM: openai provider not available", vim.log.levels.ERROR)
    return
  end
  mod.dalle()
end, { desc = "Generate image with DALL·E" })

-- Project memory commands
pcall(vim.api.nvim_create_user_command, "LLMMemoryEdit", function()
  local ok, pm = pcall(require, "llm.project_memory")
  if ok then
    pm.edit()
  end
end, { desc = "Open llm_memory.md in a split for editing" })

pcall(vim.api.nvim_create_user_command, "LLMMemoryPath", function()
  local ok, pm = pcall(require, "llm.project_memory")
  if ok then
    vim.notify("LLM memory file: " .. pm.path(), vim.log.levels.INFO)
  end
end, { desc = "Show path to the project memory file" })

-- Context picker commands
pcall(vim.api.nvim_create_user_command, "LLMContextAdd", function()
  local ok, cp = pcall(require, "llm.context_picker")
  if ok then
    cp.add()
  end
end, { desc = "Toggle a buffer in/out of LLM context" })

pcall(vim.api.nvim_create_user_command, "LLMContextClear", function()
  local ok, cp = pcall(require, "llm.context_picker")
  if ok then
    cp.clear()
  end
end, { desc = "Clear all LLM context buffers" })

pcall(vim.api.nvim_create_user_command, "LLMContextList", function()
  local ok, cp = pcall(require, "llm.context_picker")
  if ok then
    cp.list()
  end
end, { desc = "List currently selected LLM context buffers" })

return M
