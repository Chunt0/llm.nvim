-- Normalized Sink events (SPEC.md §4.2): Anthropic tool_use accumulation and
-- Ollama tool_calls, including fragments split at every possible byte boundary.
local Stream = require("llm.stream")

local function collect_sink()
  local ev = { text = {}, thinking = {}, calls = {}, stops = {}, errors = {} }
  return ev,
    {
      on_text = function(d)
        table.insert(ev.text, d)
      end,
      on_thinking = function(d)
        table.insert(ev.thinking, d)
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

local function sse(event, obj)
  return "event: " .. event .. "\ndata: " .. vim.json.encode(obj) .. "\n\n"
end

describe("Stream.anthropic_events", function()
  local tool_use_stream = table.concat({
    sse("message_start", { type = "message_start", message = { id = "m1" } }),
    sse("content_block_start", {
      type = "content_block_start",
      index = 0,
      content_block = { type = "text", text = "" },
    }),
    sse("content_block_delta", {
      type = "content_block_delta",
      index = 0,
      delta = { type = "text_delta", text = "Let me search. " },
    }),
    sse("content_block_stop", { type = "content_block_stop", index = 0 }),
    sse("content_block_start", {
      type = "content_block_start",
      index = 1,
      content_block = { type = "tool_use", id = "toolu_1", name = "grep" },
    }),
    sse("content_block_delta", {
      type = "content_block_delta",
      index = 1,
      delta = { type = "input_json_delta", partial_json = '{"pattern"' },
    }),
    sse("content_block_delta", {
      type = "content_block_delta",
      index = 1,
      delta = { type = "input_json_delta", partial_json = ':"TODO","glob":"*.lua"}' },
    }),
    sse("content_block_stop", { type = "content_block_stop", index = 1 }),
    sse("message_delta", { type = "message_delta", delta = { stop_reason = "tool_use" } }),
    sse("message_stop", { type = "message_stop" }),
  })

  it("accumulates input_json_delta fragments into a decoded tool call", function()
    local ev, sink = collect_sink()
    local state = { buf = "" }
    Stream.anthropic_events(state, tool_use_stream, sink)

    assert.are.equal("Let me search. ", table.concat(ev.text))
    assert.are.equal(1, #ev.calls)
    assert.are.equal("toolu_1", ev.calls[1].id)
    assert.are.equal("grep", ev.calls[1].name)
    assert.are.same({ pattern = "TODO", glob = "*.lua" }, ev.calls[1].input)
    assert.are.same({ "tool_use" }, ev.stops)
    assert.are.equal(0, #ev.errors)
  end)

  it("survives the stream split at every byte boundary", function()
    for cut = 1, #tool_use_stream - 1 do
      local ev, sink = collect_sink()
      local state = { buf = "" }
      Stream.anthropic_events(state, tool_use_stream:sub(1, cut), sink)
      Stream.anthropic_events(state, tool_use_stream:sub(cut + 1), sink)
      assert.are.equal(1, #ev.calls, "cut at byte " .. cut)
      assert.are.same({ pattern = "TODO", glob = "*.lua" }, ev.calls[1].input, "cut at byte " .. cut)
      assert.are.same({ "tool_use" }, ev.stops, "cut at byte " .. cut)
    end
  end)

  it("emits a tool call with empty input when no json arrives", function()
    local ev, sink = collect_sink()
    local chunk = table.concat({
      sse("content_block_start", {
        type = "content_block_start",
        index = 0,
        content_block = { type = "tool_use", id = "toolu_2", name = "list_files" },
      }),
      sse("content_block_stop", { type = "content_block_stop", index = 0 }),
      sse("message_delta", { type = "message_delta", delta = { stop_reason = "tool_use" } }),
      sse("message_stop", { type = "message_stop" }),
    })
    Stream.anthropic_events({ buf = "" }, chunk, sink)
    assert.are.equal(1, #ev.calls)
    assert.are.same({}, ev.calls[1].input)
  end)

  it("reports malformed tool input as an error but still emits the call", function()
    local ev, sink = collect_sink()
    local chunk = table.concat({
      sse("content_block_start", {
        type = "content_block_start",
        index = 0,
        content_block = { type = "tool_use", id = "toolu_3", name = "grep" },
      }),
      sse("content_block_delta", {
        type = "content_block_delta",
        index = 0,
        delta = { type = "input_json_delta", partial_json = "{not json" },
      }),
      sse("content_block_stop", { type = "content_block_stop", index = 0 }),
      sse("message_stop", { type = "message_stop" }),
    })
    Stream.anthropic_events({ buf = "" }, chunk, sink)
    assert.are.equal(1, #ev.errors)
    assert.are.equal(1, #ev.calls)
    assert.are.same({}, ev.calls[1].input)
  end)

  it("passes end_turn and max_tokens stop reasons through", function()
    for _, reason in ipairs({ "end_turn", "max_tokens", "refusal" }) do
      local ev, sink = collect_sink()
      local chunk = table.concat({
        sse("message_delta", { type = "message_delta", delta = { stop_reason = reason } }),
        sse("message_stop", { type = "message_stop" }),
      })
      Stream.anthropic_events({ buf = "" }, chunk, sink)
      assert.are.same({ reason }, ev.stops)
    end
  end)

  it("defaults to end_turn when no stop_reason was seen", function()
    local ev, sink = collect_sink()
    Stream.anthropic_events({ buf = "" }, sse("message_stop", { type = "message_stop" }), sink)
    assert.are.same({ "end_turn" }, ev.stops)
  end)

  it("emits thinking deltas separately from text", function()
    local ev, sink = collect_sink()
    local chunk = sse("content_block_delta", {
      type = "content_block_delta",
      index = 0,
      delta = { type = "thinking_delta", thinking = "hmm" },
    })
    Stream.anthropic_events({ buf = "" }, chunk, sink)
    assert.are.same({ "hmm" }, ev.thinking)
    assert.are.equal(0, #ev.text)
  end)

  it("surfaces error events", function()
    local ev, sink = collect_sink()
    local chunk = sse("error", { type = "error", error = { type = "overloaded_error", message = "Overloaded" } })
    Stream.anthropic_events({ buf = "" }, chunk, sink)
    assert.are.equal("Overloaded", ev.errors[1].message)
  end)
end)

describe("Stream.ollama_events", function()
  local function jl(obj)
    return vim.json.encode(obj) .. "\n"
  end

  it("emits text deltas and end_turn", function()
    local ev, sink = collect_sink()
    local state = { buf = "" }
    Stream.ollama_events(state, jl({ message = { role = "assistant", content = "Hel" } }), sink)
    Stream.ollama_events(state, jl({ message = { role = "assistant", content = "lo" } }), sink)
    Stream.ollama_events(state, jl({ done = true, done_reason = "stop", message = { content = "" } }), sink)
    assert.are.equal("Hello", table.concat(ev.text))
    assert.are.same({ "end_turn" }, ev.stops)
  end)

  it("emits tool calls with object arguments and synthesizes ids", function()
    local ev, sink = collect_sink()
    local state = { buf = "" }
    local line = jl({
      message = {
        role = "assistant",
        content = "",
        tool_calls = {
          { ["function"] = { name = "grep", arguments = { pattern = "TODO" } } },
          { ["function"] = { name = "read_file", arguments = { path = "a.lua" } } },
        },
      },
    })
    Stream.ollama_events(state, line, sink)
    Stream.ollama_events(state, jl({ done = true, done_reason = "stop" }), sink)
    assert.are.equal(2, #ev.calls)
    assert.are.equal("call_1", ev.calls[1].id)
    assert.are.equal("call_2", ev.calls[2].id)
    assert.are.same({ pattern = "TODO" }, ev.calls[1].input)
    assert.are.same({ "tool_use" }, ev.stops)
  end)

  it("decodes string arguments as JSON", function()
    local ev, sink = collect_sink()
    local line = jl({
      message = {
        role = "assistant",
        tool_calls = { { ["function"] = { name = "grep", arguments = '{"pattern":"x"}' } } },
      },
    })
    Stream.ollama_events({ buf = "" }, line, sink)
    assert.are.same({ pattern = "x" }, ev.calls[1].input)
  end)

  it("maps done_reason length to max_tokens", function()
    local ev, sink = collect_sink()
    Stream.ollama_events({ buf = "" }, jl({ done = true, done_reason = "length" }), sink)
    assert.are.same({ "max_tokens" }, ev.stops)
  end)

  it("surfaces error lines (e.g. model does not support tools)", function()
    local ev, sink = collect_sink()
    Stream.ollama_events({ buf = "" }, jl({ error = "registry: model does not support tools" }), sink)
    assert.truthy(ev.errors[1].message:match("does not support tools"))
    assert.are.equal(0, #ev.stops)
  end)

  it("handles a line split across chunks", function()
    local line = jl({ message = { role = "assistant", content = "chunked" }, done = false })
    for cut = 1, #line - 1 do
      local ev, sink = collect_sink()
      local state = { buf = "" }
      Stream.ollama_events(state, line:sub(1, cut), sink)
      Stream.ollama_events(state, line:sub(cut + 1), sink)
      assert.are.equal("chunked", table.concat(ev.text), "cut at " .. cut)
    end
  end)
end)
