-- Tests for stream.lua: SSE and JSONL parsing logic.
-- These are pure-function tests with no side effects or async behavior.

local Stream = require("stream")

-- ── SSE (Server-Sent Events) parser ──────────────────────────────────────────

describe("Stream.parse_sse_chunk", function()
  it("fires on_data for a complete data: line", function()
    local state    = { buf = "" }
    local received = {}
    Stream.parse_sse_chunk(state, "data: hello world\n", {
      on_data = function(d) table.insert(received, d) end,
    })
    assert.are.equal(1, #received)
    assert.are.equal("hello world", received[1])
  end)

  it("fires on_event for an event: line", function()
    local state  = { buf = "" }
    local events = {}
    Stream.parse_sse_chunk(state, "event: content_block_delta\n", {
      on_event = function(e) table.insert(events, e) end,
    })
    assert.are.equal(1, #events)
    assert.are.equal("content_block_delta", events[1])
  end)

  it("dispatches both event and data from one chunk", function()
    local state      = { buf = "" }
    local evs, data  = {}, {}
    local chunk      = "event: content_block_delta\ndata: {\"type\":\"delta\"}\n"
    Stream.parse_sse_chunk(state, chunk, {
      on_event = function(e) table.insert(evs,  e) end,
      on_data  = function(d) table.insert(data, d) end,
    })
    assert.are.equal(1, #evs)
    assert.are.equal(1, #data)
    assert.are.equal("content_block_delta", evs[1])
  end)

  it("dispatches multiple events from a single chunk", function()
    local state = { buf = "" }
    local evs   = {}
    local chunk = "event: content_block_delta\ndata: {}\nevent: message_stop\ndata: {}\n"
    Stream.parse_sse_chunk(state, chunk, {
      on_event = function(e) table.insert(evs, e) end,
    })
    assert.are.equal(2, #evs)
    assert.are.equal("content_block_delta", evs[1])
    assert.are.equal("message_stop",        evs[2])
  end)

  it("buffers a partial line and dispatches only once a newline arrives", function()
    local state    = { buf = "" }
    local received = {}
    local cb       = { on_data = function(d) table.insert(received, d) end }

    -- No newline yet — nothing should be dispatched
    Stream.parse_sse_chunk(state, "data: parti", cb)
    assert.are.equal(0, #received)

    -- Second chunk completes the line
    Stream.parse_sse_chunk(state, "al payload\n", cb)
    assert.are.equal(1, #received)
    assert.are.equal("partial payload", received[1])
  end)

  it("handles an event split across two chunks", function()
    local state = { buf = "" }
    local evs   = {}
    local cb    = { on_event = function(e) table.insert(evs, e) end }

    Stream.parse_sse_chunk(state, "event: content_blo", cb) -- partial
    assert.are.equal(0, #evs)

    Stream.parse_sse_chunk(state, "ck_delta\n", cb) -- completes it
    assert.are.equal(1, #evs)
    assert.are.equal("content_block_delta", evs[1])
  end)

  it("fires on_comment for comment (: ...) lines", function()
    local state    = { buf = "" }
    local comments = {}
    Stream.parse_sse_chunk(state, ": keep-alive\n", {
      on_comment = function(c) table.insert(comments, c) end,
    })
    assert.are.equal(1, #comments)
  end)

  it("fires on_line for every completed line", function()
    local state = { buf = "" }
    local lines = {}
    Stream.parse_sse_chunk(state, "data: a\nevent: b\n: c\n\n", {
      on_line = function(l) table.insert(lines, l) end,
    })
    assert.is_true(#lines >= 3, "expected at least 3 lines, got " .. #lines)
  end)

  it("handles empty chunk without error or dispatch", function()
    local state    = { buf = "" }
    local received = {}
    assert.has_no.errors(function()
      Stream.parse_sse_chunk(state, "", {
        on_data = function(d) table.insert(received, d) end,
      })
    end)
    assert.are.equal(0, #received)
  end)

  it("handles nil chunk without error or dispatch", function()
    local state    = { buf = "" }
    local received = {}
    assert.has_no.errors(function()
      Stream.parse_sse_chunk(state, nil, {
        on_data = function(d) table.insert(received, d) end,
      })
    end)
    assert.are.equal(0, #received)
  end)

  it("does not corrupt the buffer after multiple calls", function()
    local state = { buf = "" }
    local data  = {}
    local cb    = { on_data = function(d) table.insert(data, d) end }
    Stream.parse_sse_chunk(state, "data: first\ndata: se", cb)
    Stream.parse_sse_chunk(state, "cond\n",                 cb)
    assert.are.equal(2, #data)
    assert.are.equal("first",  data[1])
    assert.are.equal("second", data[2])
  end)
end)

-- ── JSONL (newline-delimited JSON) parser ─────────────────────────────────────

describe("Stream.parse_jsonl_chunk", function()
  it("calls on_json for a complete JSON line", function()
    local state   = { buf = "" }
    local objects = {}
    Stream.parse_jsonl_chunk(
      state,
      '{"message":{"content":"hello"},"done":false}\n',
      { on_json = function(o) table.insert(objects, o) end }
    )
    assert.are.equal(1, #objects)
    assert.are.equal("hello", objects[1].message.content)
    assert.is_false(objects[1].done)
  end)

  it("dispatches each line when multiple JSON objects arrive in one chunk", function()
    local state   = { buf = "" }
    local objects = {}
    local chunk   = '{"message":{"content":"a"},"done":false}\n'
                  .. '{"message":{"content":"b"},"done":true}\n'
    Stream.parse_jsonl_chunk(state, chunk, {
      on_json = function(o) table.insert(objects, o) end,
    })
    assert.are.equal(2, #objects)
    assert.are.equal("a", objects[1].message.content)
    assert.are.equal("b", objects[2].message.content)
    assert.is_true(objects[2].done)
  end)

  it("buffers a partial line and dispatches when the next chunk completes it", function()
    local state   = { buf = "" }
    local objects = {}
    local cb      = { on_json = function(o) table.insert(objects, o) end }

    Stream.parse_jsonl_chunk(state, '{"message":{"content":"he', cb)
    assert.are.equal(0, #objects)

    Stream.parse_jsonl_chunk(state, 'llo"},"done":false}\n', cb)
    assert.are.equal(1, #objects)
    assert.are.equal("hello", objects[1].message.content)
  end)

  it("silently skips invalid JSON lines without raising an error", function()
    local state   = { buf = "" }
    local objects = {}
    assert.has_no.errors(function()
      Stream.parse_jsonl_chunk(state, "this is not JSON\n", {
        on_json = function(o) table.insert(objects, o) end,
      })
    end)
    assert.are.equal(0, #objects)
  end)

  it("handles empty chunk without error or dispatch", function()
    local state   = { buf = "" }
    local objects = {}
    assert.has_no.errors(function()
      Stream.parse_jsonl_chunk(state, "", {
        on_json = function(o) table.insert(objects, o) end,
      })
    end)
    assert.are.equal(0, #objects)
  end)

  it("handles nil chunk without error or dispatch", function()
    local state   = { buf = "" }
    local objects = {}
    assert.has_no.errors(function()
      Stream.parse_jsonl_chunk(state, nil, {
        on_json = function(o) table.insert(objects, o) end,
      })
    end)
    assert.are.equal(0, #objects)
  end)

  it("correctly detects done=true in a final chunk", function()
    local state    = { buf = "" }
    local done_val = false
    Stream.parse_jsonl_chunk(
      state,
      '{"model":"llama3","done":true,"done_reason":"stop"}\n',
      { on_json = function(o) if o.done then done_val = true end end }
    )
    assert.is_true(done_val)
  end)

  it("does not corrupt state when mixing partial and complete lines", function()
    local state   = { buf = "" }
    local results = {}
    local cb      = { on_json = function(o) table.insert(results, o.v) end }

    Stream.parse_jsonl_chunk(state, '{"v":1}\n{"v":2', cb)  -- 1 complete, 1 partial
    Stream.parse_jsonl_chunk(state, '}\n{"v":3}\n',   cb)   -- completes 2, adds 3

    assert.are.equal(3, #results)
    assert.are.equal(1, results[1])
    assert.are.equal(2, results[2])
    assert.are.equal(3, results[3])
  end)
end)
