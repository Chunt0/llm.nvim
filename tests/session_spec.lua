-- Session continuation (follow-up turns), the alternation-safe trim, and
-- persistence round-trips.
local Agent = require("llm.agent")
local Persist = require("llm.chat.persist")

local function scripted_transport(turns)
  local sent = {}
  local n = 0
  return function(body, sink)
    table.insert(sent, body)
    n = n + 1
    turns[math.min(n, #turns)](body, sink)
    return { shutdown = function() end }
  end,
    sent
end

describe("Agent.run session continuation", function()
  it("a second run on the same session sees the whole conversation", function()
    local transport, sent = scripted_transport({
      function(_, sink)
        sink.on_text("First answer.")
        sink.on_stop("end_turn")
      end,
    })
    local h1 = Agent.run({
      provider = "anthropic",
      model = "m",
      prompt = "first question",
      tools = {},
      transport = transport,
      dispatch = function()
        return { result = "" }
      end,
    })
    Agent.run({
      provider = "anthropic",
      model = "m",
      prompt = "follow-up",
      session = h1.session,
      tools = {},
      transport = transport,
      dispatch = function()
        return { result = "" }
      end,
    })
    assert.are.equal(2, #sent)
    local replay = sent[2].messages
    assert.are.equal(3, #replay)
    assert.are.equal("first question", replay[1].content)
    assert.are.equal("First answer.", replay[2].content)
    assert.are.equal("follow-up", replay[3].content)
  end)

  it("merges into a dangling user message instead of doubling roles", function()
    local session = { messages = { { role = "user", content = "orphaned by an error" } } }
    local transport, sent = scripted_transport({
      function(_, sink)
        sink.on_stop("end_turn")
      end,
    })
    Agent.run({
      provider = "anthropic",
      model = "m",
      prompt = "retry",
      session = session,
      tools = {},
      transport = transport,
      dispatch = function()
        return { result = "" }
      end,
    })
    assert.are.equal(1, #sent)
    assert.are.equal(1, #sent[1].messages)
    assert.truthy(sent[1].messages[1].content:match("orphaned"))
    assert.truthy(sent[1].messages[1].content:match("retry"))
  end)

  it("an errored turn leaves a transcript safe to continue", function()
    local transport = scripted_transport({
      function(_, sink)
        sink.on_tool_call({ id = "t", name = "x", input = {} })
        sink.on_stop("tool_use")
      end,
      function(_, sink)
        sink.on_error({ message = "boom" })
      end,
    })
    local h = Agent.run({
      provider = "anthropic",
      model = "m",
      prompt = "q",
      tools = {},
      transport = transport,
      dispatch = function()
        return { result = "ok" }
      end,
    })
    -- after trim, nothing dangles: no assistant-with-calls, no tool_results
    local msgs = h.session.messages
    local last = msgs[#msgs]
    assert.is_true(last.role == "user" or (last.role == "assistant" and not last.tool_calls))
  end)

  it("cancel trims the in-flight turn", function()
    local h = Agent.run({
      provider = "anthropic",
      model = "m",
      prompt = "q",
      tools = {},
      transport = function()
        return { shutdown = function() end }
      end,
      dispatch = function()
        return { result = "" }
      end,
    })
    h.cancel()
    assert.are.equal(1, #h.session.messages)
    assert.are.equal("user", h.session.messages[1].role)
  end)
end)

describe("Agent.trim_incomplete", function()
  it("drops dangling tool_results and assistant tool_use", function()
    local session = {
      messages = {
        { role = "user", content = "q" },
        { role = "assistant", content = "a1" },
        { role = "assistant", content = "", tool_calls = { { id = "t", name = "x", input = {} } } },
        { role = "tool_results", results = {} },
      },
    }
    Agent.trim_incomplete(session)
    assert.are.equal(2, #session.messages)
    assert.are.equal("a1", session.messages[2].content)
  end)

  it("keeps a bare user prompt for merge-on-retry", function()
    local session = { messages = { { role = "user", content = "q" } } }
    Agent.trim_incomplete(session)
    assert.are.equal(1, #session.messages)
  end)
end)

describe("chat.persist", function()
  local dir = "/tmp/llm_nvim_sessions_fixture"
  os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)

  it("round-trips a session through disk", function()
    local session = {
      meta = { provider = "ollama", model = "qwen3.6:latest" },
      messages = {
        { role = "user", content = "find the bug" },
        {
          role = "assistant",
          content = "Found it.",
          tool_calls = { { id = "c1", name = "grep", input = { pattern = "bug" } } },
        },
        { role = "tool_results", results = { { id = "c1", name = "grep", content = "a.lua:1:1:bug" } } },
        { role = "assistant", content = "It is in a.lua." },
      },
    }
    local path, err = Persist.save(session, dir)
    assert.is_nil(err)
    assert.is_string(session.meta.id)
    assert.truthy(session.meta.title:match("find the bug"))

    local loaded = Persist.load(path)
    assert.are.equal(4, #loaded.messages)
    assert.are.equal("ollama", loaded.meta.provider)
    assert.are.same({ pattern = "bug" }, loaded.messages[2].tool_calls[1].input)
  end)

  it("keeps the same file on re-save (same id)", function()
    local session = { messages = { { role = "user", content = "x" } } }
    local p1 = Persist.save(session, dir)
    table.insert(session.messages, { role = "assistant", content = "y" })
    local p2 = Persist.save(session, dir)
    assert.are.equal(p1, p2)
    assert.are.equal(2, #Persist.load(p2).messages)
  end)

  it("lists sessions newest-id first with titles", function()
    local entries = Persist.list(dir)
    assert.is_true(#entries >= 2)
    assert.is_string(entries[1].title)
  end)

  it("reports corrupt files instead of raising", function()
    local f = assert(io.open(dir .. "/zz_corrupt.json", "w"))
    f:write("{nope")
    f:close()
    local loaded, err = Persist.load(dir .. "/zz_corrupt.json")
    assert.is_nil(loaded)
    assert.truthy(err:match("corrupt"))
  end)
end)
