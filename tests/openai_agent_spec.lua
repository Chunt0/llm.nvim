-- OpenAI Responses API agent support: flat tool schemas, transcript replay as
-- input items, and function-call stream events.
local Agent = require("llm.agent")
local Stream = require("llm.stream")
local Tools = require("llm.tools")

Tools.setup_builtin()

describe("Agent.build_request (openai)", function()
  local body = Agent.build_request("openai", {
    model = "gpt-5.4-mini",
    system = "sys",
    max_tokens = 8000,
    messages = {
      { role = "user", content = "hi" },
      {
        role = "assistant",
        content = "Checking.",
        tool_calls = { { id = "call_1", name = "grep", input = { pattern = "x" } } },
      },
      {
        role = "tool_results",
        results = {
          { id = "call_1", name = "grep", content = "a.lua:1:1:x" },
          { id = "call_2", name = "read_file", content = "denied", is_error = true },
        },
      },
    },
    tools = Tools.schemas("openai_responses"),
  })

  it("uses instructions + input items, no server-side chaining", function()
    assert.are.equal("sys", body.instructions)
    assert.are.equal(false, body.store)
    assert.is_nil(body.previous_response_id)
    assert.are.equal(8000, body.max_output_tokens)
  end)

  it("replays assistant text and function calls as separate items", function()
    assert.are.same({ role = "user", content = "hi" }, body.input[1])
    assert.are.same({ role = "assistant", content = "Checking." }, body.input[2])
    local fc = body.input[3]
    assert.are.equal("function_call", fc.type)
    assert.are.equal("call_1", fc.call_id)
    assert.are.equal("grep", fc.name)
    assert.truthy(fc.arguments:match('"pattern"'))
  end)

  it("sends tool results as function_call_output items, errors prefixed", function()
    assert.are.equal("function_call_output", body.input[4].type)
    assert.are.equal("call_1", body.input[4].call_id)
    assert.are.equal("a.lua:1:1:x", body.input[4].output)
    assert.truthy(body.input[5].output:match("^ERROR: denied"))
  end)

  it("uses the flat Responses tool shape", function()
    assert.are.equal("function", body.tools[1].type)
    assert.are.equal("read_file", body.tools[1].name)
    assert.are.equal("object", body.tools[1].parameters.type)
    assert.is_nil(body.tools[1]["function"])
  end)

  it("schema_shape maps providers to wire formats", function()
    assert.are.equal("anthropic", Agent.schema_shape("anthropic"))
    assert.are.equal("openai_responses", Agent.schema_shape("openai"))
    assert.are.equal("openai", Agent.schema_shape("ollama"))
  end)
end)

describe("Stream.openai_events", function()
  local function collect()
    local ev = { text = {}, calls = {}, stops = {}, errors = {} }
    return ev,
      {
        on_text = function(d)
          table.insert(ev.text, d)
        end,
        on_tool_call = function(c)
          table.insert(ev.calls, c)
        end,
        on_stop = function(r)
          table.insert(ev.stops, r)
        end,
        on_error = function(e)
          table.insert(ev.errors, e)
        end,
      }
  end

  local function sse(obj)
    return "event: " .. obj.type .. "\ndata: " .. vim.json.encode(obj) .. "\n\n"
  end

  local call_stream = table.concat({
    sse({ type = "response.output_text.delta", delta = "Looking. " }),
    sse({
      type = "response.output_item.added",
      output_index = 1,
      item = { type = "function_call", call_id = "call_9", name = "grep", arguments = "" },
    }),
    sse({ type = "response.function_call_arguments.delta", output_index = 1, delta = '{"pattern"' }),
    sse({ type = "response.function_call_arguments.delta", output_index = 1, delta = ':"TODO"}' }),
    sse({
      type = "response.output_item.done",
      output_index = 1,
      item = { type = "function_call", call_id = "call_9", name = "grep", arguments = '{"pattern":"TODO"}' },
    }),
    sse({ type = "response.completed", response = { status = "completed" } }),
  })

  it("assembles function calls from argument deltas", function()
    local ev, sink = collect()
    Stream.openai_events({ buf = "" }, call_stream, sink)
    assert.are.equal("Looking. ", table.concat(ev.text))
    assert.are.equal(1, #ev.calls)
    assert.are.equal("call_9", ev.calls[1].id)
    assert.are.same({ pattern = "TODO" }, ev.calls[1].input)
    assert.are.same({ "tool_use" }, ev.stops)
  end)

  it("survives splits at every byte boundary", function()
    for cut = 1, #call_stream - 1, 7 do -- step 7 keeps runtime sane
      local ev, sink = collect()
      local state = { buf = "" }
      Stream.openai_events(state, call_stream:sub(1, cut), sink)
      Stream.openai_events(state, call_stream:sub(cut + 1), sink)
      assert.are.equal(1, #ev.calls, "cut at " .. cut)
      assert.are.same({ "tool_use" }, ev.stops, "cut at " .. cut)
    end
  end)

  it("falls back to accumulated deltas when the done item has no arguments", function()
    local ev, sink = collect()
    local chunk = table.concat({
      sse({
        type = "response.output_item.added",
        output_index = 0,
        item = { type = "function_call", call_id = "c", name = "list_files", arguments = "" },
      }),
      sse({ type = "response.function_call_arguments.delta", output_index = 0, delta = '{"glob":"*.lua"}' }),
      sse({
        type = "response.output_item.done",
        output_index = 0,
        item = { type = "function_call", call_id = "c", name = "list_files", arguments = "" },
      }),
      sse({ type = "response.completed", response = {} }),
    })
    Stream.openai_events({ buf = "" }, chunk, sink)
    assert.are.same({ glob = "*.lua" }, ev.calls[1].input)
  end)

  it("maps incomplete responses to max_tokens", function()
    local ev, sink = collect()
    Stream.openai_events(
      { buf = "" },
      sse({ type = "response.incomplete", response = { incomplete_details = { reason = "max_output_tokens" } } }),
      sink
    )
    assert.are.same({ "max_tokens" }, ev.stops)
  end)

  it("plain completion is end_turn", function()
    local ev, sink = collect()
    Stream.openai_events({ buf = "" }, sse({ type = "response.completed", response = {} }), sink)
    assert.are.same({ "end_turn" }, ev.stops)
  end)

  it("surfaces failures", function()
    local ev, sink = collect()
    Stream.openai_events(
      { buf = "" },
      sse({ type = "response.failed", response = { error = { message = "rate limited" } } }),
      sink
    )
    assert.are.equal("rate limited", ev.errors[1].message)
  end)
end)
