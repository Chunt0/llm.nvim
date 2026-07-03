-- The agent loop (SPEC.md §F2): send a request with tools, execute the tool
-- calls the model makes, feed the results back, repeat until end_turn.
--
-- The core (build_request / run) is editor-independent and fully unit-testable:
-- the transport (network) and dispatch (tool execution) are injectable, and
-- all UI is callback-based. start() wires the real curl transport and a
-- minimal markdown panel for :LLMAgent.
local Config = require("llm.config")
local Constants = require("llm.constants")
local Stream = require("llm.stream")
local Tools = require("llm.tools")
local Fs = require("llm.util.fs")
local Apply = require("llm.edit.apply")

local M = {}

-- ===== Normalized transcript → provider request body =========================
-- Transcript entries:
--   { role = "user",         content = string }
--   { role = "assistant",    content = string, tool_calls = { {id,name,input}… }? }
--   { role = "tool_results", results = { {id, name, content, is_error}… } }

-- vim.json.encode({}) produces "[]", but tool inputs/arguments must encode as
-- JSON objects — Anthropic rejects "input": [] with a 400.
local function as_object(t)
  if type(t) == "table" and next(t) == nil and vim.empty_dict then
    return vim.empty_dict()
  end
  return t
end

local function anthropic_body(opts)
  local msgs = {}
  for _, m in ipairs(opts.messages) do
    if m.role == "user" then
      table.insert(msgs, { role = "user", content = m.content })
    elseif m.role == "assistant" then
      if m.tool_calls and #m.tool_calls > 0 then
        local blocks = {}
        if m.content and m.content ~= "" then
          table.insert(blocks, { type = "text", text = m.content })
        end
        for _, c in ipairs(m.tool_calls) do
          table.insert(blocks, { type = "tool_use", id = c.id, name = c.name, input = as_object(c.input) })
        end
        table.insert(msgs, { role = "assistant", content = blocks })
      else
        table.insert(msgs, { role = "assistant", content = m.content or "" })
      end
    elseif m.role == "tool_results" then
      -- All results for one assistant turn go in a single user message.
      local blocks = {}
      for _, r in ipairs(m.results) do
        local b = { type = "tool_result", tool_use_id = r.id, content = r.content }
        if r.is_error then
          b.is_error = true
        end
        table.insert(blocks, b)
      end
      table.insert(msgs, { role = "user", content = blocks })
    end
  end
  local body = {
    model = opts.model,
    stream = true,
    max_tokens = opts.max_tokens or 16000,
    messages = msgs,
  }
  if opts.system and opts.system ~= "" then
    body.system = opts.system
  end
  if opts.tools and #opts.tools > 0 then
    body.tools = opts.tools
  end
  return body
end

local function ollama_body(opts)
  local msgs = {}
  if opts.system and opts.system ~= "" then
    table.insert(msgs, { role = "system", content = opts.system })
  end
  for _, m in ipairs(opts.messages) do
    if m.role == "user" then
      table.insert(msgs, { role = "user", content = m.content })
    elseif m.role == "assistant" then
      local out = { role = "assistant", content = m.content or "" }
      if m.tool_calls and #m.tool_calls > 0 then
        out.tool_calls = {}
        for _, c in ipairs(m.tool_calls) do
          table.insert(out.tool_calls, { ["function"] = { name = c.name, arguments = as_object(c.input) } })
        end
      end
      table.insert(msgs, out)
    elseif m.role == "tool_results" then
      -- Ollama has no is_error flag; prefix so the model can tell.
      for _, r in ipairs(m.results) do
        local content = r.is_error and ("ERROR: " .. r.content) or r.content
        table.insert(msgs, { role = "tool", tool_name = r.name, content = content })
      end
    end
  end
  local body = { model = opts.model, stream = true, messages = msgs }
  if opts.tools and #opts.tools > 0 then
    body.tools = opts.tools
  end
  return body
end

local function openai_body(opts)
  -- Responses API: the transcript replays as input items; server-side state
  -- (previous_response_id) is deliberately unused so a failed request can't
  -- corrupt the chain.
  local items = {}
  for _, m in ipairs(opts.messages) do
    if m.role == "user" then
      table.insert(items, { role = "user", content = m.content })
    elseif m.role == "assistant" then
      if m.content and m.content ~= "" then
        table.insert(items, { role = "assistant", content = m.content })
      end
      for _, c in ipairs(m.tool_calls or {}) do
        table.insert(items, {
          type = "function_call",
          call_id = c.id,
          name = c.name,
          arguments = vim.json.encode(as_object(c.input)),
        })
      end
    elseif m.role == "tool_results" then
      for _, r in ipairs(m.results) do
        local output = r.is_error and ("ERROR: " .. r.content) or r.content
        table.insert(items, { type = "function_call_output", call_id = r.id, output = output })
      end
    end
  end
  local body = {
    model = opts.model,
    stream = true,
    input = items,
    store = false,
  }
  if opts.system and opts.system ~= "" then
    body.instructions = opts.system
  end
  if opts.max_tokens then
    body.max_output_tokens = opts.max_tokens
  end
  if opts.tools and #opts.tools > 0 then
    body.tools = opts.tools
  end
  return body
end

--- Build the request body for a provider from a normalized transcript.
--- opts: { model, system, messages, tools (provider-shaped), max_tokens }
function M.build_request(provider, opts)
  if provider == "anthropic" then
    return anthropic_body(opts)
  elseif provider == "ollama" then
    return ollama_body(opts)
  elseif provider == "openai" then
    return openai_body(opts)
  end
  error("agent: unsupported provider '" .. tostring(provider) .. "'")
end

--- Tool schema wire shape per provider.
function M.schema_shape(provider)
  if provider == "anthropic" then
    return "anthropic"
  elseif provider == "openai" then
    return "openai_responses"
  end
  return "openai"
end

--- Drop trailing transcript entries that would leave the conversation in an
--- invalid state for the next request (assistant tool_use with no results, or
--- dangling tool_results) — used after error/cancel/max_turns. A bare user
--- prompt is kept; the next turn merges into it (see run()).
function M.trim_incomplete(session)
  local msgs = session.messages
  while #msgs > 0 do
    local last = msgs[#msgs]
    if last.role == "user" then
      break
    end
    if last.role == "assistant" and not (last.tool_calls and #last.tool_calls > 0) then
      break
    end
    table.remove(msgs)
  end
end

-- ===== System prompt ==========================================================

function M.default_system(root, tool_names)
  local os_name = "unknown"
  pcall(function()
    os_name = (vim.uv or vim.loop).os_uname().sysname
  end)
  local parts = {
    "You are a coding agent running inside Neovim (llm.nvim), operating on the user's project.",
    "Project root: " .. root,
    "OS: " .. os_name,
    "Available tools: " .. table.concat(tool_names, ", ") .. ".",
    "Investigate with tools before answering: list or grep to locate things, read_file to confirm.",
    "Cite findings as path:line. Never invent file contents — if a tool errors, adapt or say so.",
    "Edits you propose (edit_file/write_file) are shown to the user as a diff for approval, and bash "
      .. "commands require confirmation; a rejection comes back as an error, possibly with the user's reason — "
      .. "respect it, do not retry the same change.",
    "When you have enough information, give a direct, concise answer.",
  }
  local ok_pm, pm = pcall(require, "llm.project_memory")
  if ok_pm then
    local mem = pm.load()
    if mem and mem ~= "" then
      table.insert(parts, "\n# Project Memory (persistent codebase context):\n" .. mem)
    end
  end
  return table.concat(parts, "\n")
end

-- ===== @file mentions =========================================================

--- Expand @path mentions: each mentioned project file's content is attached
--- below the prompt so the model doesn't have to read_file it first. Paths go
--- through the same confinement and secret-file rules as the tools; anything
--- refused or missing is simply left as literal text.
--- Returns the expanded prompt and the list of attached relative paths.
function M.expand_mentions(prompt, root, opts)
  local max_bytes = (opts and opts.max_bytes) or (Config.tools and Config.tools.max_result_bytes) or 60 * 1024
  local attachments, seen = {}, {}
  for token in prompt:gmatch("@([%w%._%-/]+)") do
    token = token:gsub("%.+$", "") -- "@foo.lua." at sentence end
    if token ~= "" and not seen[token] then
      seen[token] = true
      local abs = Fs.confine(token, root, opts)
      if abs and not Fs.is_denied(abs) then
        local lines = Fs.read_lines(abs)
        if lines then
          local content = table.concat(lines, "\n")
          if #content > max_bytes then
            content = content:sub(1, max_bytes) .. "\n[truncated — use read_file with start_line for the rest]"
          end
          table.insert(attachments, { path = token, content = content })
        end
      end
    end
  end
  if #attachments == 0 then
    return prompt, {}
  end
  local parts = { prompt, "", "# Attached files (@mentions):" }
  local names = {}
  for _, a in ipairs(attachments) do
    table.insert(parts, "## " .. a.path .. "\n```\n" .. a.content .. "\n```")
    table.insert(names, a.path)
  end
  return table.concat(parts, "\n"), names
end

-- ===== The loop ===============================================================

local function noop() end
local function cb(ui, name)
  return (ui and ui[name]) or noop
end

local function default_confirmer(text, done)
  local ok, choice = pcall(vim.fn.confirm, "LLM agent wants to:\n" .. text, "&Run\n&Cancel", 2)
  done(ok and choice == 1)
end

--- Build the tool executor: policy routing + review gating around dispatch.
--- executor(call, done) — done({ result }|{ error }) fires exactly once, and
--- may fire asynchronously (the loop pauses while the user reviews an edit).
local function make_executor(opts)
  local dispatch = opts.dispatch
    or function(name, input)
      return Tools.dispatch(name, input, { root = opts.root })
    end
  local reviewer = opts.reviewer
    or function(spec, done)
      Apply.review(spec, { root = opts.root }, done, { panel_bufnr = opts.panel_bufnr })
    end
  local confirmer = opts.confirmer or default_confirmer

  return function(call, done)
    local tool = Tools.get(call.name)
    local policy = Tools.policy(call.name)
    local function run_exec()
      local res = dispatch(call.name, call.input)
      if res.pending_edit then
        -- Mutations never happen inside exec: an explicit "allow" policy
        -- applies directly, anything else goes through diff review.
        if policy == "allow" then
          done(Apply.apply(res.pending_edit, { root = opts.root }))
        else
          reviewer(res.pending_edit, done)
        end
      else
        done(res)
      end
    end
    if tool and policy == "review" and tool.review_kind == "confirm" then
      local text = (tool.describe and tool.describe(call.input)) or ("run tool " .. call.name)
      confirmer(text, function(approved)
        if approved then
          run_exec()
        else
          done({ error = "user declined to run " .. call.name })
        end
      end)
    else
      run_exec()
    end
  end
end

--- Run the agent loop.
--- opts:
---   provider   "anthropic" | "ollama" | "openai"
---   model, system, max_tokens
---   prompt     the user's task
---   session    existing session to continue (follow-up turns); default fresh
---   tools      provider-shaped schema list (default: registry for provider)
---   max_turns  default Config.agent.max_turns (25)
---   transport  function(body, sink) -> handle?      (default: curl_transport)
---   dispatch   function(name, input) -> {result|error|pending_edit} (default: Tools.dispatch)
---   reviewer   function(pending_edit, done) — diff review for mutations (default: Apply.review)
---   confirmer  function(text, done(bool)) — gate for review_kind="confirm" tools (bash)
---   executor   function(call, done) — full override of policy routing (tests)
---   panel_bufnr  buffer the default reviewer must not reuse as its host window
---   ui         { on_text, on_thinking, on_tool_start(call), on_tool_done(call, res),
---                on_turn(n), on_done(reason, session), on_error(err) }
--- Returns { cancel = fn, session = { messages } }.
function M.run(opts)
  local ui = opts.ui or {}
  local max_turns = opts.max_turns or (Config.agent and Config.agent.max_turns) or 25
  local transport = opts.transport
  local executor = opts.executor or make_executor(opts)
  local tools = opts.tools
  if tools == nil then
    Tools.setup_builtin()
    tools = Tools.schemas(M.schema_shape(opts.provider))
  end

  -- Continue an existing session (follow-up turns) or start fresh. When the
  -- transcript already ends with a user message (a previously failed or
  -- cancelled turn), merge instead of appending — providers reject
  -- consecutive same-role messages.
  local session = opts.session or { messages = {} }
  local last = session.messages[#session.messages]
  if last and last.role == "user" and type(last.content) == "string" then
    last.content = last.content .. "\n\n" .. opts.prompt
  else
    table.insert(session.messages, { role = "user", content = opts.prompt })
  end
  local state = { cancelled = false, handle = nil }
  local turn = 0

  local function finish(reason)
    if reason == "error" or reason == "max_turns" then
      M.trim_incomplete(session)
    end
    cb(ui, "on_done")(reason, session)
  end

  local function step()
    if state.cancelled then
      return
    end
    turn = turn + 1
    if turn > max_turns then
      finish("max_turns")
      return
    end
    cb(ui, "on_turn")(turn)

    local body = M.build_request(opts.provider, {
      model = opts.model,
      system = opts.system,
      messages = session.messages,
      tools = tools,
      max_tokens = opts.max_tokens,
    })

    local text_parts, calls = {}, {}
    local settled = false
    state.handle = transport(body, {
      on_text = function(d)
        table.insert(text_parts, d)
        cb(ui, "on_text")(d)
      end,
      on_thinking = function(d)
        cb(ui, "on_thinking")(d)
      end,
      on_tool_call = function(call)
        table.insert(calls, call)
      end,
      on_stop = function(reason)
        if settled or state.cancelled then
          return
        end
        settled = true
        local text = table.concat(text_parts)
        if #calls == 0 then
          table.insert(session.messages, { role = "assistant", content = text })
          finish(reason)
          return
        end
        table.insert(session.messages, { role = "assistant", content = text, tool_calls = calls })
        -- Calls run one at a time; the executor's done may fire later (edit
        -- review, bash confirmation), pausing the loop until the user acts.
        local results = {}
        local function run_calls(i)
          if state.cancelled then
            return
          end
          if i > #calls then
            table.insert(session.messages, { role = "tool_results", results = results })
            step()
            return
          end
          local call = calls[i]
          cb(ui, "on_tool_start")(call)
          executor(call, function(res)
            if state.cancelled then
              return
            end
            cb(ui, "on_tool_done")(call, res)
            table.insert(results, {
              id = call.id,
              name = call.name,
              content = res.error or res.result or "",
              is_error = res.error ~= nil or nil,
            })
            run_calls(i + 1)
          end)
        end
        run_calls(1)
      end,
      on_error = function(err)
        if settled or state.cancelled then
          return
        end
        settled = true
        cb(ui, "on_error")(err)
        finish("error")
      end,
    })
  end

  step()

  return {
    session = session,
    cancel = function()
      state.cancelled = true
      if state.handle and state.handle.shutdown then
        pcall(state.handle.shutdown, state.handle)
      end
      M.trim_incomplete(session)
    end,
  }
end

-- ===== Default transport: curl via plenary.job ================================

local function curl_common_args()
  local args = { "-sS", "-N", "--no-buffer", "--fail-with-body", "-K", "-" }
  local net = Config.network or {}
  if net.max_time then
    table.insert(args, "--max-time")
    table.insert(args, tostring(net.max_time))
  end
  return args
end

--- Build a transport bound to one provider endpoint. API keys travel in the
--- curl stdin config, never in argv.
--- popts: { provider, url, api_key_name }
function M.curl_transport(popts)
  local Job = require("plenary.job")
  local parse = Stream.ollama_events
  if popts.provider == "anthropic" then
    parse = Stream.anthropic_events
  elseif popts.provider == "openai" then
    parse = Stream.openai_events
  end

  return function(body, sink)
    local json = vim.json.encode(body)
    local cfg = {
      string.format('url = "%s"', popts.url),
      'request = "POST"',
      'header = "Content-Type: application/json"',
    }
    if popts.provider == "anthropic" then
      table.insert(cfg, 'header = "Accept: text/event-stream"')
      table.insert(cfg, 'header = "anthropic-version: 2023-06-01"')
      local key = popts.api_key_name and os.getenv(popts.api_key_name)
      if key and #key > 0 then
        table.insert(cfg, string.format('header = "x-api-key: %s"', key))
      end
    elseif popts.provider == "openai" then
      table.insert(cfg, 'header = "Accept: text/event-stream"')
      local key = popts.api_key_name and os.getenv(popts.api_key_name)
      if key and #key > 0 then
        table.insert(cfg, string.format('header = "Authorization: Bearer %s"', key))
      end
    else
      table.insert(cfg, 'header = "Accept: application/x-ndjson"')
    end
    table.insert(cfg, string.format("data = %q", json))

    local parser_state = { buf = "" }
    local body_snippets = {}
    local errored = false
    local guarded = setmetatable({
      on_error = function(err)
        errored = true
        sink.on_error(err)
      end,
    }, { __index = sink })

    local job = Job:new({
      command = "curl",
      args = curl_common_args(),
      writer = table.concat(cfg, "\n"),
      enable_handlers = true,
      on_stdout = function(_, out)
        if type(out) == "table" then
          out = table.concat(out, "\n")
        end
        local chunk = (out or ""):gsub("\r\n", "\n")
        if chunk == "" then
          return
        end
        if #body_snippets < 4 then
          table.insert(body_snippets, chunk)
        end
        -- plenary strips newlines; restore so line-based parsers see boundaries.
        chunk = chunk .. "\n"
        -- Parse on the main loop: sinks touch buffers and run tools.
        vim.schedule(function()
          parse(parser_state, chunk, guarded)
        end)
      end,
      on_exit = function(_, code)
        vim.schedule(function()
          if code and code ~= 0 and not errored then
            local detail = table.concat(body_snippets, " ")
            sink.on_error({
              code = code,
              message = "request failed (curl " .. tostring(code) .. ")" .. (detail ~= "" and ": " .. detail or ""),
            })
          end
        end)
      end,
    })
    job:start()
    return job
  end
end

-- ===== Minimal agent panel (:LLMAgent) ========================================

local function append_text(bufnr, text)
  if not (vim.api.nvim_buf_is_loaded(bufnr) and text and text ~= "") then
    return
  end
  local lc = vim.api.nvim_buf_line_count(bufnr)
  local last = vim.api.nvim_buf_get_lines(bufnr, lc - 1, lc, false)[1] or ""
  local lines = vim.split(text:gsub("[\r\b]", ""), "\n", { plain = true })
  lines[1] = last .. lines[1]
  vim.api.nvim_buf_set_lines(bufnr, lc - 1, lc, false, lines)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    pcall(vim.api.nvim_win_set_cursor, win, { lc - 1 + #lines, 0 })
  end
end

local function summarize_input(input)
  local parts = {}
  for k, v in pairs(input or {}) do
    local s = tostring(v)
    if #s > 48 then
      s = s:sub(1, 45) .. "…"
    end
    table.insert(parts, k .. "=" .. (type(v) == "string" and ('"' .. s .. '"') or s))
  end
  table.sort(parts)
  return table.concat(parts, ", ")
end

local function open_panel(title)
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, bufnr)
  pcall(vim.api.nvim_win_set_width, win, math.max(60, math.floor(vim.o.columns * 0.42)))
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].filetype = "markdown"
  -- unique per buffer: a second panel must not fail the name collision
  pcall(vim.api.nvim_buf_set_name, bufnr, "llm://agent/" .. bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { title, "" })
  return bufnr, win
end

local function api_key_for(provider)
  if provider == "anthropic" then
    return "ANTHROPIC_API_KEY"
  elseif provider == "openai" then
    return "OPENAI_API_KEY"
  end
  return nil
end

--- Render a saved transcript into the panel (resume).
local function render_transcript(bufnr, session)
  for _, m in ipairs(session.messages) do
    if m.role == "user" and type(m.content) == "string" then
      append_text(bufnr, "## User\n" .. m.content .. "\n\n")
    elseif m.role == "assistant" then
      append_text(bufnr, "## Assistant\n")
      if type(m.content) == "string" and m.content ~= "" then
        append_text(bufnr, m.content)
      end
      for _, c in ipairs(m.tool_calls or {}) do
        append_text(bufnr, "\n▸ " .. c.name .. "(" .. summarize_input(c.input) .. ")")
      end
      append_text(bufnr, "\n\n")
    end
  end
end

--- Open the agent panel around a (new or resumed) session. The panel is a
--- conversation: after each turn an input area opens at the bottom — type a
--- follow-up and press <CR> in normal mode to send it.
--- opts: { provider, model?, prompt?, session? }
function M.open_session(opts)
  local provider = opts.provider
  local model = opts.model or Constants.models[provider]
  local url = Constants.api_endpoints[provider]
  local root = Fs.project_root()
  Tools.setup_builtin()
  local tool_names = {}
  for _, t in ipairs(Tools.enabled()) do
    table.insert(tool_names, t.name)
  end

  local bufnr = open_panel("# LLM Agent — " .. tostring(model) .. " (" .. provider .. ")")
  append_text(bufnr, "*<CR> in normal mode sends the input below; Esc cancels a running turn*\n\n")

  local ctl = {
    session = opts.session, -- nil until the first run returns it
    running = false,
    handle = nil,
    input_start = nil,
  }

  local function open_input()
    append_text(bufnr, "\n\n## User\n")
    ctl.input_start = vim.api.nvim_buf_line_count(bufnr) - 1
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      pcall(vim.api.nvim_win_set_cursor, win, { ctl.input_start + 1, 0 })
    end
  end

  local function save_session()
    if not ctl.session then
      return
    end
    ctl.session.meta = ctl.session.meta or {}
    ctl.session.meta.provider = provider
    ctl.session.meta.model = model
    pcall(function()
      require("llm.chat.persist").save(ctl.session)
    end)
  end

  local function begin_run(prompt)
    ctl.running = true
    local expanded, attached = M.expand_mentions(prompt, root)
    if #attached > 0 then
      append_text(bufnr, "\n*(attached: " .. table.concat(attached, ", ") .. ")*")
    end
    append_text(bufnr, "\n\n## Assistant\n")
    ctl.handle = M.run({
      provider = provider,
      model = model,
      prompt = expanded,
      root = root,
      panel_bufnr = bufnr,
      session = ctl.session,
      system = M.default_system(root, tool_names),
      max_tokens = Constants.vars.max_tokens,
      transport = M.curl_transport({
        provider = provider,
        url = url,
        api_key_name = api_key_for(provider),
      }),
      ui = {
        on_text = function(d)
          append_text(bufnr, d)
        end,
        on_tool_start = function(call)
          append_text(bufnr, "\n▸ " .. call.name .. "(" .. summarize_input(call.input) .. ")")
        end,
        on_tool_done = function(_, res)
          if res.error then
            append_text(bufnr, " → ERROR: " .. res.error:match("^([^\n]*)") .. "\n")
          else
            local out = tostring(res.result or "")
            local first = out:match("^([^\n]*)")
            local n = select(2, out:gsub("\n", "")) + 1
            append_text(bufnr, " → " .. ((n == 1 and #first <= 60) and first or (n .. " lines")) .. "\n")
          end
        end,
        on_turn = function(n)
          if n > 1 then
            append_text(bufnr, "\n")
          end
        end,
        on_done = function(reason, session)
          ctl.session = session
          ctl.running = false
          save_session()
          if reason == "max_turns" then
            append_text(bufnr, "\n\n*(stopped: turn limit reached — send a follow-up to continue)*")
          elseif reason == "max_tokens" then
            append_text(bufnr, "\n\n*(response truncated: max_tokens reached)*")
          end
          open_input()
        end,
        on_error = function(err)
          local msg = err.message or "unknown error"
          if msg:lower():match("does not support tools") then
            msg = "model "
              .. tostring(model)
              .. " does not support tools — pull a tool-capable model (e.g. qwen3, llama3.1+) or use chat mode"
          end
          append_text(bufnr, "\n\n**ERROR:** " .. msg)
          vim.notify("LLM agent: " .. msg, vim.log.levels.ERROR)
        end,
      },
    })
    ctl.session = ctl.handle.session
  end

  local function submit()
    if ctl.running then
      vim.notify("LLM agent: a turn is already running — Esc to cancel it first", vim.log.levels.WARN)
      return
    end
    if not ctl.input_start then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, ctl.input_start, -1, false)
    local prompt = vim.trim(table.concat(lines, "\n"))
    if prompt == "" then
      return
    end
    begin_run(prompt)
  end

  -- Panel keymaps live for the whole conversation, not per turn.
  pcall(vim.keymap.set, "n", "<CR>", submit, {
    buffer = bufnr,
    noremap = true,
    silent = true,
    desc = "LLM agent: send follow-up",
  })
  local group = vim.api.nvim_create_augroup("LLM_Agent_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "LLM_Escape",
    callback = function()
      if ctl.running and ctl.handle then
        ctl.handle.cancel()
        ctl.running = false
        save_session()
        append_text(bufnr, "\n\n*(cancelled)*")
        open_input()
        vim.notify("LLM agent cancelled", vim.log.levels.INFO)
      end
    end,
  })
  pcall(vim.keymap.set, "n", "<Esc>", function()
    vim.api.nvim_exec_autocmds("User", { pattern = "LLM_Escape" })
  end, { buffer = bufnr, noremap = true, silent = true })

  if opts.session then
    render_transcript(bufnr, opts.session)
    open_input()
  elseif opts.prompt then
    append_text(bufnr, "## User\n" .. opts.prompt)
    begin_run(opts.prompt)
  else
    open_input()
  end

  return ctl
end

--- :LLMAgent entry point. args: optional "provider=<name>" plus the task;
--- prompts interactively when no task text is given.
function M.start(args)
  args = args or ""
  local provider = args:match("provider=([%w_%-]+)") or (Config.agent and Config.agent.provider) or "ollama"
  local prompt = vim.trim(args:gsub("provider=[%w_%-]+", ""))
  if prompt == "" then
    local ok, input = pcall(vim.fn.input, "Agent task: ")
    prompt = ok and vim.trim(input or "") or ""
  end
  if prompt == "" then
    return
  end
  if provider ~= "ollama" and provider ~= "anthropic" and provider ~= "openai" then
    vim.notify(
      "LLM agent: provider '" .. provider .. "' not supported (use ollama, anthropic, or openai)",
      vim.log.levels.ERROR
    )
    return
  end
  return M.open_session({ provider = provider, prompt = prompt })
end

--- :LLMAgentResume — pick a saved session and continue it.
function M.resume()
  local Persist = require("llm.chat.persist")
  local sessions = Persist.list()
  if #sessions == 0 then
    vim.notify("LLM agent: no saved sessions", vim.log.levels.INFO)
    return
  end
  vim.ui.select(sessions, {
    prompt = "Resume agent session:",
    format_item = function(s)
      return s.id .. "  " .. (s.title or "") .. (s.model and ("  [" .. s.model .. "]") or "")
    end,
  }, function(choice)
    if not choice then
      return
    end
    local session, err = Persist.load(choice.path)
    if not session then
      vim.notify("LLM agent: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    M.open_session({
      provider = session.meta.provider or (Config.agent and Config.agent.provider) or "ollama",
      model = session.meta.model,
      session = session,
    })
  end)
end

return M
