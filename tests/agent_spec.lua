-- Agent loop (SPEC.md §F2): request building, tool-result batching, the
-- multi-turn loop against a scripted fake transport, and the turn cap.
local Agent = require("llm.agent")

describe("Agent.build_request (anthropic)", function()
  local messages = {
    { role = "user", content = "find the bug" },
    {
      role = "assistant",
      content = "Searching.",
      tool_calls = {
        { id = "t1", name = "grep", input = { pattern = "bug" } },
        { id = "t2", name = "list_files", input = {} },
      },
    },
    {
      role = "tool_results",
      results = {
        { id = "t1", name = "grep", content = "a.lua:1:1:bug" },
        { id = "t2", name = "list_files", content = "boom", is_error = true },
      },
    },
  }

  local body = Agent.build_request("anthropic", {
    model = "claude-haiku-4-5",
    system = "sys",
    messages = messages,
    tools = { { name = "grep" } },
  })

  it("sets model, stream, system, tools and default max_tokens", function()
    assert.are.equal("claude-haiku-4-5", body.model)
    assert.is_true(body.stream)
    assert.are.equal("sys", body.system)
    assert.are.equal(16000, body.max_tokens)
    assert.are.equal(1, #body.tools)
  end)

  it("renders assistant tool calls as text + tool_use blocks", function()
    local a = body.messages[2]
    assert.are.equal("assistant", a.role)
    assert.are.equal("text", a.content[1].type)
    assert.are.equal("Searching.", a.content[1].text)
    assert.are.equal("tool_use", a.content[2].type)
    assert.are.equal("t1", a.content[2].id)
    assert.are.same({ pattern = "bug" }, a.content[2].input)
  end)

  it("batches ALL tool results into a single user message", function()
    assert.are.equal(3, #body.messages)
    local r = body.messages[3]
    assert.are.equal("user", r.role)
    assert.are.equal(2, #r.content)
    assert.are.equal("tool_result", r.content[1].type)
    assert.are.equal("t1", r.content[1].tool_use_id)
    assert.is_nil(r.content[1].is_error)
    assert.is_true(r.content[2].is_error)
  end)

  it("contains no sampling parameters", function()
    assert.is_nil(body.temperature)
    assert.is_nil(body.top_p)
  end)

  it("keeps plain assistant turns as plain strings", function()
    local b = Agent.build_request("anthropic", {
      model = "m",
      messages = { { role = "assistant", content = "hi" } },
    })
    assert.are.equal("hi", b.messages[1].content)
  end)
end)

describe("Agent.build_request (ollama)", function()
  local body = Agent.build_request("ollama", {
    model = "qwen3.6:latest",
    system = "sys",
    messages = {
      { role = "user", content = "hi" },
      { role = "assistant", content = "", tool_calls = { { id = "c1", name = "grep", input = { pattern = "x" } } } },
      {
        role = "tool_results",
        results = {
          { id = "c1", name = "grep", content = "no matches" },
          { id = "c2", name = "read_file", content = "denied", is_error = true },
        },
      },
    },
    tools = { { type = "function" } },
  })

  it("puts the system prompt first", function()
    assert.are.equal("system", body.messages[1].role)
    assert.are.equal("sys", body.messages[1].content)
  end)

  it("renders tool calls in the function shape", function()
    local a = body.messages[3]
    assert.are.equal("grep", a.tool_calls[1]["function"].name)
    assert.are.same({ pattern = "x" }, a.tool_calls[1]["function"].arguments)
  end)

  it("renders each tool result as a role=tool message, errors prefixed", function()
    assert.are.equal("tool", body.messages[4].role)
    assert.are.equal("no matches", body.messages[4].content)
    assert.are.equal("grep", body.messages[4].tool_name)
    assert.are.equal("ERROR: denied", body.messages[5].content)
  end)

  it("rejects unknown providers", function()
    assert.has_error(function()
      Agent.build_request("openai", { messages = {} })
    end)
  end)
end)

--- A transport whose turns are scripted: each entry is a function(body, sink).
local function scripted_transport(turns)
  local sent = {}
  local n = 0
  return function(body, sink)
    table.insert(sent, body)
    n = n + 1
    local script = turns[math.min(n, #turns)]
    script(body, sink)
    return { shutdown = function() end }
  end,
    sent
end

local function ui_recorder()
  local ev = {}
  return ev,
    {
      on_text = function(d)
        table.insert(ev, { "text", d })
      end,
      on_tool_start = function(call)
        table.insert(ev, { "tool_start", call.name })
      end,
      on_tool_done = function(_, res)
        table.insert(ev, { "tool_done", res.error and "error" or "ok" })
      end,
      on_turn = function(i)
        table.insert(ev, { "turn", i })
      end,
      on_done = function(reason)
        table.insert(ev, { "done", reason })
      end,
      on_error = function(err)
        table.insert(ev, { "error", err.message })
      end,
    }
end

describe("Agent.run", function()
  it("executes a tool round-trip and finishes on end_turn", function()
    local transport, sent = scripted_transport({
      function(_, sink)
        sink.on_text("Checking. ")
        sink.on_tool_call({ id = "t1", name = "fake_grep", input = { pattern = "TODO" } })
        sink.on_stop("tool_use")
      end,
      function(_, sink)
        sink.on_text("Found it in a.lua.")
        sink.on_stop("end_turn")
      end,
    })
    local ev, ui = ui_recorder()
    local dispatched = {}
    local handle = Agent.run({
      provider = "anthropic",
      model = "m",
      prompt = "where is the TODO?",
      tools = { { name = "fake_grep" } },
      transport = transport,
      dispatch = function(name, input)
        table.insert(dispatched, { name = name, input = input })
        return { result = "a.lua:3:1:-- TODO fix" }
      end,
      ui = ui,
    })

    -- two requests were sent; the second carries the tool result back
    assert.are.equal(2, #sent)
    local results_msg = sent[2].messages[3]
    assert.are.equal("user", results_msg.role)
    assert.are.equal("tool_result", results_msg.content[1].type)
    assert.are.equal("a.lua:3:1:-- TODO fix", results_msg.content[1].content)

    -- the tool actually ran, once, with the model's input
    assert.are.equal(1, #dispatched)
    assert.are.same({ pattern = "TODO" }, dispatched[1].input)

    -- final transcript: user, assistant+calls, tool_results, assistant
    local msgs = handle.session.messages
    assert.are.equal(4, #msgs)
    assert.are.equal("assistant", msgs[4].role)
    assert.are.equal("Found it in a.lua.", msgs[4].content)

    -- done with end_turn, and UI saw the tool lifecycle
    assert.are.same({ "done", "end_turn" }, ev[#ev])
    local saw_start = false
    for _, e in ipairs(ev) do
      if e[1] == "tool_start" and e[2] == "fake_grep" then
        saw_start = true
      end
    end
    assert.is_true(saw_start)
  end)

  it("sends tool errors back as is_error results and lets the model adapt", function()
    local transport, sent = scripted_transport({
      function(_, sink)
        sink.on_tool_call({ id = "t1", name = "fake_read", input = { path = "/etc/passwd" } })
        sink.on_stop("tool_use")
      end,
      function(_, sink)
        sink.on_text("That file is off limits; using the project copy instead.")
        sink.on_stop("end_turn")
      end,
    })
    local _, ui = ui_recorder()
    local handle = Agent.run({
      provider = "anthropic",
      model = "m",
      prompt = "read passwd",
      tools = {},
      transport = transport,
      dispatch = function()
        return { error = "path escapes the project root: /etc/passwd" }
      end,
      ui = ui,
    })
    local r = sent[2].messages[3].content[1]
    assert.is_true(r.is_error)
    assert.truthy(r.content:match("escapes the project root"))
    assert.are.equal(4, #handle.session.messages)
  end)

  it("stops at max_turns when the model never finishes", function()
    local transport, sent = scripted_transport({
      function(_, sink)
        sink.on_tool_call({ id = "t", name = "loopy", input = {} })
        sink.on_stop("tool_use")
      end,
    })
    local ev, ui = ui_recorder()
    Agent.run({
      provider = "ollama",
      model = "m",
      prompt = "loop forever",
      tools = {},
      max_turns = 3,
      transport = transport,
      dispatch = function()
        return { result = "ok" }
      end,
      ui = ui,
    })
    assert.are.equal(3, #sent)
    assert.are.same({ "done", "max_turns" }, ev[#ev])
  end)

  it("reports transport errors and stops the loop", function()
    local transport, sent = scripted_transport({
      function(_, sink)
        sink.on_error({ message = "model qwen2:0.5b does not support tools" })
      end,
    })
    local ev, ui = ui_recorder()
    Agent.run({
      provider = "ollama",
      model = "qwen2:0.5b",
      prompt = "hi",
      tools = {},
      transport = transport,
      dispatch = function()
        return { result = "" }
      end,
      ui = ui,
    })
    assert.are.equal(1, #sent)
    assert.are.same({ "error", "model qwen2:0.5b does not support tools" }, ev[#ev - 1])
    assert.are.same({ "done", "error" }, ev[#ev])
  end)

  it("ignores stream events after cancel", function()
    local captured_sink
    local ev, ui = ui_recorder()
    local handle = Agent.run({
      provider = "anthropic",
      model = "m",
      prompt = "hi",
      tools = {},
      transport = function(_, sink)
        captured_sink = sink
        return { shutdown = function() end }
      end,
      dispatch = function()
        return { result = "" }
      end,
      ui = ui,
    })
    handle.cancel()
    captured_sink.on_text("late")
    captured_sink.on_stop("end_turn")
    for _, e in ipairs(ev) do
      assert.is_not.equal("done", e[1])
    end
    -- the cancelled turn appended nothing beyond the user prompt
    assert.are.equal(1, #handle.session.messages)
  end)

  it("treats a truncated stream (max_tokens, no tool calls) as final", function()
    local transport = scripted_transport({
      function(_, sink)
        sink.on_text("partial answ")
        sink.on_stop("max_tokens")
      end,
    })
    local ev, ui = ui_recorder()
    Agent.run({
      provider = "anthropic",
      model = "m",
      prompt = "hi",
      tools = {},
      transport = transport,
      dispatch = function()
        return { result = "" }
      end,
      ui = ui,
    })
    assert.are.same({ "done", "max_tokens" }, ev[#ev])
  end)
end)

describe("Agent.default_system", function()
  it("names the root, the tools and the citation convention", function()
    local s = Agent.default_system("/proj", { "read_file", "grep" })
    assert.truthy(s:match("Project root: /proj"))
    assert.truthy(s:match("read_file, grep"))
    assert.truthy(s:match("path:line"))
  end)
end)
