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

--- Build the request body for a provider from a normalized transcript.
--- opts: { model, system, messages, tools (provider-shaped), max_tokens }
function M.build_request(provider, opts)
  if provider == "anthropic" then
    return anthropic_body(opts)
  elseif provider == "ollama" then
    return ollama_body(opts)
  end
  error("agent: unsupported provider '" .. tostring(provider) .. "'")
end

--- Tool schema wire shape per provider.
function M.schema_shape(provider)
  return provider == "anthropic" and "anthropic" or "openai"
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
---   provider   "anthropic" | "ollama"
---   model, system, max_tokens
---   prompt     the user's task
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

  local session = { messages = { { role = "user", content = opts.prompt } } }
  local state = { cancelled = false, handle = nil }
  local turn = 0

  local function finish(reason)
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
  local parse = popts.provider == "anthropic" and Stream.anthropic_events or Stream.ollama_events

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
  pcall(vim.api.nvim_buf_set_name, bufnr, "llm://agent")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { title, "" })
  return bufnr, win
end

--- :LLMAgent entry point. args: optional "provider=<name>" plus the prompt;
--- prompts interactively when no prompt text is given.
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
  if provider ~= "ollama" and provider ~= "anthropic" then
    vim.notify(
      "LLM agent: provider '" .. provider .. "' not supported yet (use ollama or anthropic)",
      vim.log.levels.ERROR
    )
    return
  end

  local model = Constants.models[provider]
  local url = Constants.api_endpoints[provider]
  local root = Fs.project_root()
  Tools.setup_builtin()
  local tool_names = {}
  for _, t in ipairs(Tools.enabled()) do
    table.insert(tool_names, t.name)
  end

  local bufnr = open_panel("# LLM Agent — " .. tostring(model) .. " (" .. provider .. ")")
  append_text(bufnr, "## User\n" .. prompt .. "\n\n## Assistant\n")

  local handle
  local group = vim.api.nvim_create_augroup("LLM_Agent", { clear = true })
  local function cleanup()
    pcall(vim.keymap.del, "n", "<Esc>", { buffer = bufnr })
    pcall(vim.api.nvim_clear_autocmds, { group = group })
  end

  handle = M.run({
    provider = provider,
    model = model,
    prompt = prompt,
    root = root,
    panel_bufnr = bufnr,
    system = M.default_system(root, tool_names),
    max_tokens = Constants.vars.max_tokens,
    transport = M.curl_transport({
      provider = provider,
      url = url,
      api_key_name = provider == "anthropic" and "ANTHROPIC_API_KEY" or nil,
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
          local first = res.error:match("^([^\n]*)")
          append_text(bufnr, " → ERROR: " .. first .. "\n")
        else
          local out = tostring(res.result or "")
          local first = out:match("^([^\n]*)")
          local n = select(2, out:gsub("\n", "")) + 1
          if n == 1 and #first <= 60 then
            append_text(bufnr, " → " .. first .. "\n")
          else
            append_text(bufnr, " → " .. n .. " lines\n")
          end
        end
      end,
      on_turn = function(n)
        if n > 1 then
          append_text(bufnr, "\n")
        end
      end,
      on_done = function(reason)
        cleanup()
        if reason == "max_turns" then
          append_text(bufnr, "\n\n*(stopped: turn limit reached — raise agent.max_turns to continue further)*")
        elseif reason == "max_tokens" then
          append_text(bufnr, "\n\n*(response truncated: max_tokens reached)*")
        elseif reason ~= "error" then
          append_text(bufnr, "\n\n*(done)*")
        end
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

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "LLM_Escape",
    callback = function()
      handle.cancel()
      cleanup()
      append_text(bufnr, "\n\n*(cancelled)*")
      vim.notify("LLM agent cancelled", vim.log.levels.INFO)
    end,
  })
  pcall(vim.keymap.set, "n", "<Esc>", function()
    vim.api.nvim_exec_autocmds("User", { pattern = "LLM_Escape" })
  end, { buffer = bufnr, noremap = true, silent = true })

  return handle
end

return M
