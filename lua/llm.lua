local M = {}
local Job = require("plenary.job")
local Log = require("log")
local Utils = require("utils")
local Stream = require("stream")
local Config = require("llm_config")
local Memory = require("memory")
local UI = require("ui")

-- ===== Debug toggle =====
local DEBUG = true -- set true to spam :messages
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

-- ===== Stream anchor =====
local NS = vim.api.nvim_create_namespace("LLMStream")
local stream_anchor = nil
local function start_anchor(bufnr, winid)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local win = winid or vim.api.nvim_get_current_win()
  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  local id = vim.api.nvim_buf_set_extmark(bufnr, NS, row - 1, col, { right_gravity = false })
  stream_anchor = { bufnr = bufnr, id = id }
  dbg(("anchor start buf=%d row=%d col=%d"):format(bufnr, row - 1, col))
end
local function append_at_anchor(txt)
  if not txt or txt == "" then
    return
  end
  txt = txt:gsub("[\r\b]", "")
  local sa = stream_anchor and { bufnr = stream_anchor.bufnr, id = stream_anchor.id } or nil
  vim.schedule(function()
    if not sa or not sa.bufnr or not sa.id or not vim.api.nvim_buf_is_loaded(sa.bufnr) then
      local bufnr = vim.api.nvim_get_current_buf()
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      local id = vim.api.nvim_buf_set_extmark(bufnr, NS, row - 1, col, { right_gravity = false })
      stream_anchor = { bufnr = bufnr, id = id }
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
local function end_anchor()
  stream_anchor = nil
  dbg("anchor cleared")
end

-- ===== UTF-8 safe write =====
local utf8_carry = ""
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
  local need = (lead < 0xE0 and 1) or (lead < 0xF0 and 2) or (lead < 0xF8 and 3) or 0
  local have = len - i
  if have < need then
    return s:sub(1, i - 1), s:sub(i)
  else
    return s, ""
  end
end
local pending_text = ""
local response_accum = ""
local flush_scheduled = false
local function flush_pending()
  if pending_text ~= "" then
    append_at_anchor(pending_text)
    pending_text = ""
  end
  flush_scheduled = false
end

local function write_safely(chunk)
  if not chunk or chunk == "" then
    return
  end
  dbg("write_safely: " .. tostring(chunk):sub(1, 80))
  if utf8_carry ~= "" then
    chunk = utf8_carry .. chunk
    utf8_carry = ""
  end
  chunk = chunk:gsub("\r\n", "\n"):gsub("[\r\b]", "")
  local complete, tail = split_complete_utf8(chunk)
  utf8_carry = tail
  if complete ~= "" then
    response_accum = response_accum .. complete
    pending_text = pending_text .. complete
    if not flush_scheduled then
      flush_scheduled = true
      local t = (Config.ui and Config.ui.throttle_ms) or 20
      vim.defer_fn(flush_pending, t)
    end
  end
end

-- ===== State =====
local assistant_message = nil
local openai_count = 0
local openai_response_id = ""

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
  local code = err:match("HTTP/%d+%.?%d*%s+(%d%d%d)")
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
  local data = {
    model = model,
    stream = true,
    system = system or system_prompt,
    messages = rest,
    temperature = opts.temp,
    top_p = opts.top_p,
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
  local current_event = nil
  Stream.parse_sse_chunk(state, chunk, {
    on_event = function(ev)
      current_event = ev
    end,
    on_data = function(payload)
      local ok, obj = pcall(vim.json.decode, payload)
      if not ok or not obj then
        return
      end
      if (current_event and current_event:match("content_block")) or obj.delta then
        local text = (obj.delta and obj.delta.text) or (obj.delta and obj.delta[1] and obj.delta[1].text)
        if text and #text > 0 then
          write_safely(text)
        end
      end
      if obj.type == "message_stop" or current_event == "message_stop" then
        assistant_message = { role = "assistant", content = "" }
      end
    end,
  })
end

-- ===== Provider: Ollama (Chat API — JSONL) =====
-- Uses /api/chat with messages[] for proper multi-turn support.
function M.make_ollama_spec_curl_args(opts, prompt, system_prompt)
  local url = (opts.url and #opts.url > 0) and opts.url or "https://ollama.putty-ai.com/api/chat"
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
  Stream.parse_jsonl_chunk(state, chunk, {
    on_json = function(obj)
      if obj.message and obj.message.content then
        write_safely(tostring(obj.message.content))
      end
      if obj.done then
        assistant_message = { role = "assistant", content = response_accum }
      end
    end,
  })
end

-- ===== Provider: OpenAI (Responses API) =====
function M.make_openai_spec_curl_args(opts, prompt, system_prompt)
  local model = opts.model
  local url = (opts.url and #opts.url > 0) and opts.url or "https://api.openai.com/v1/responses"
  local api_key = opts.api_key_name and Utils.get_api_key(opts.api_key_name) or os.getenv("OPENAI_API_KEY")
  local reasoning_effort = opts.reasoning_effort or "minimal"

  dbg("count: " .. openai_count)

  local data
  local instructions = system_prompt
  if opts.messages then
    instructions = nil
  end
  if openai_count == 0 then
    data = {
      model = model,
      stream = true,
      input = opts.messages or prompt,
      instructions = instructions,
      reasoning = { effort = reasoning_effort },
      store = true,
    }
  else
    data = {
      model = model,
      stream = true,
      input = opts.messages or prompt,
      instructions = instructions,
      previous_response_id = openai_response_id,
      reasoning = { effort = reasoning_effort },
      store = true,
    }
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

function M.handle_openai_spec_data(line)
  if not line then
    return
  end

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
    openai_response_id = json.response.id
    dbg("response.id=" .. openai_response_id)
  end

  local t = tostring(json.type or "")

  if (t == "response.output_text.delta" or t:match("%.output_text%.delta$")) and json.delta then
    write_safely(json.delta)
    return
  end

  if t == "response.output_text.done" or t:match("%.output_text%.done$") then
    if json.text then
      assistant_message = { role = "assistant", content = json.text }
      dbg("Assistant Message: " .. json.text)
    end
    return
  end

  if t == "response.completed" then
    dbg("response.completed")
    return
  end

  if t == "response.error" and json.error then
    dbg("OpenAI error: " .. (json.error.message or vim.inspect(json.error)))
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

  local replace = opts.replace
  local ui_mode = (Config.ui and Config.ui.mode) or "inline"
  if replace then
    ui_mode = "inline"
  end
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
  local ok_pm, pm = pcall(require, "project_memory")
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
    opts.messages = Memory.build_messages(mem_bufnr, system_prompt, prompt)
    Memory.append(mem_bufnr, "user", prompt)
  end

  response_accum = ""
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

  start_anchor(target_bufnr, target_win)

  local function normalize_chunk(out)
    if type(out) == "table" then
      out = table.concat(out, "\n")
    end
    return (out or ""):gsub("\r\n", "\n")
  end

  local parser_state = { buf = "" }
  local error_notified = false
  local function on_stdout(_, out)
    local chunk = normalize_chunk(out)
    if chunk == "" then
      return
    end
    -- plenary.job strips newlines; re-add so SSE/JSONL stream parsers can
    -- detect line boundaries and dispatch on_event/on_data/on_json callbacks.
    chunk = chunk .. "\n"
    local ok = pcall(handle_spec_data_fn, chunk, parser_state)
    if not ok then
      pcall(handle_spec_data_fn, chunk)
    end
  end

  local on_exit_common = vim.schedule_wrap(function(_, code)
    openai_count = 1

    if utf8_carry ~= "" then
      write_safely(utf8_carry)
      utf8_carry = ""
    end

    if not replace then
      local bufnr = target_bufnr
      local last_line = vim.api.nvim_buf_line_count(bufnr) - 1
      local insert_at = last_line + 1
      local user_line = "---------------------------User---------------------------"
      vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, { "", user_line, "" })
      pcall(vim.api.nvim_win_set_cursor, target_win, { insert_at + 3, 0 })
    end

    if not assistant_message and response_accum ~= "" then
      assistant_message = { role = "assistant", content = response_accum }
    end
    if use_memory and assistant_message and assistant_message.content and assistant_message.content ~= "" then
      Memory.append(mem_bufnr, "assistant", assistant_message.content)
    end

    local user_message = { role = "user", content = prompt }
    local time = os.date("%Y-%m-%dT%H:%M:%S")
    local log_entry = {
      time = time,
      framework = framework,
      model = model,
      user = user_message,
      assistant = assistant_message,
    }
    pcall(Log.log, log_entry)
    active_job = nil
    assistant_message = nil
    end_anchor()
    if code ~= 0 then
      vim.notify("LLM: request exited with code " .. tostring(code), vim.log.levels.WARN)
    end
    dbg("job closed")
  end)

  active_job = Job:new({
    command = "curl",
    args = args,
    on_stdout = on_stdout,
    on_stderr = function(_, err)
      if err and err ~= "" then
        local eprev = err
        if #eprev > 400 then
          eprev = eprev:sub(1, 380) .. " … " .. eprev:sub(-20)
        end
        dbg("STDERR: " .. eprev:gsub("\r", "\\r"))
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
        end_anchor()
        dbg("cancelled by user")
      end
    end,
  })

  local bufnr = vim.api.nvim_get_current_buf()
  pcall(
    vim.keymap.set,
    "n",
    "<Esc>",
    ":doautocmd User LLM_Escape<CR>",
    { buffer = bufnr, noremap = true, silent = true }
  )
  return active_job
end

function M.reset_message_buffers()
  openai_count = 0
  openai_response_id = ""
  assistant_message = nil
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
  local provider = args:match("provider=([%w_%-]+)") or args:match("^([%w_%-]+)") or "openai"
  local mode = args:match("mode=([%w_%-]+)") or "invoke"
  if mode == "chat" then
    mode = "code_chat"
  end
  local ok, mod = pcall(require, provider)
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

pcall(vim.api.nvim_create_user_command, "LLMDalle", function()
  local ok, mod = pcall(require, "openai")
  if not ok then
    vim.notify("LLM: openai provider not available", vim.log.levels.ERROR)
    return
  end
  mod.dalle()
end, { desc = "Generate image with DALL·E" })

-- Project memory commands
pcall(vim.api.nvim_create_user_command, "LLMMemoryEdit", function()
  local ok, pm = pcall(require, "project_memory")
  if ok then
    pm.edit()
  end
end, { desc = "Open llm_memory.md in a split for editing" })

pcall(vim.api.nvim_create_user_command, "LLMMemoryPath", function()
  local ok, pm = pcall(require, "project_memory")
  if ok then
    vim.notify("LLM memory file: " .. pm.path(), vim.log.levels.INFO)
  end
end, { desc = "Show path to the project memory file" })

-- Context picker commands
pcall(vim.api.nvim_create_user_command, "LLMContextAdd", function()
  local ok, cp = pcall(require, "context_picker")
  if ok then
    cp.add()
  end
end, { desc = "Toggle a buffer in/out of LLM context" })

pcall(vim.api.nvim_create_user_command, "LLMContextClear", function()
  local ok, cp = pcall(require, "context_picker")
  if ok then
    cp.clear()
  end
end, { desc = "Clear all LLM context buffers" })

pcall(vim.api.nvim_create_user_command, "LLMContextList", function()
  local ok, cp = pcall(require, "context_picker")
  if ok then
    cp.list()
  end
end, { desc = "List currently selected LLM context buffers" })

return M
