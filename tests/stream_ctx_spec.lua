-- P13 regression: stream state is per-invocation. Two concurrent streams must
-- never interleave text into each other's accumulator or transcript.
local llm = require("llm")

describe("per-invocation stream contexts (P13)", function()
  it("two interleaved ollama streams keep their text apart", function()
    local s1 = { buf = "", ctx = llm.new_stream_ctx() }
    local s2 = { buf = "", ctx = llm.new_stream_ctx() }

    llm.handle_ollama_spec_data('{"message":{"role":"assistant","content":"AAA "},"done":false}\n', s1)
    llm.handle_ollama_spec_data('{"message":{"role":"assistant","content":"BBB "},"done":false}\n', s2)
    llm.handle_ollama_spec_data('{"message":{"role":"assistant","content":"111"},"done":false}\n', s1)
    llm.handle_ollama_spec_data('{"message":{"role":"assistant","content":"222"},"done":false}\n', s2)
    llm.handle_ollama_spec_data('{"done":true,"done_reason":"stop"}\n', s1)
    llm.handle_ollama_spec_data('{"done":true,"done_reason":"stop"}\n', s2)

    assert.are.equal("AAA 111", s1.ctx.assistant_message.content)
    assert.are.equal("BBB 222", s2.ctx.assistant_message.content)
  end)

  it("an ollama stream and an anthropic stream stay isolated", function()
    local so = { buf = "", ctx = llm.new_stream_ctx() }
    local sa = { buf = "", ctx = llm.new_stream_ctx() }

    llm.handle_ollama_spec_data('{"message":{"role":"assistant","content":"from ollama"},"done":false}\n', so)
    llm.handle_anthropic_spec_data(
      'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"from claude"}}\n',
      sa
    )
    llm.handle_anthropic_spec_data('event: message_stop\ndata: {"type":"message_stop"}\n', sa)
    llm.handle_ollama_spec_data('{"done":true,"done_reason":"stop"}\n', so)

    assert.are.equal("from ollama", so.ctx.assistant_message.content)
    assert.are.equal("from claude", sa.ctx.assistant_message.content)
  end)

  it("bare handler calls (no state) still work via the fallback context", function()
    llm.reset_message_buffers() -- fresh fallback context
    assert.has_no.errors(function()
      llm.handle_openai_spec_data('data: {"type":"response.output_text.delta","delta":"legacy"}')
    end)
  end)

  it("finalize flushes a held UTF-8 carry into the accumulator", function()
    local ctx = llm.new_stream_ctx()
    -- é = 0xC3 0xA9; feed only the lead byte, then finalize
    ctx:write("caf" .. string.char(0xC3))
    assert.are.equal("caf", ctx.accum)
    assert.are.equal(string.char(0xC3), ctx.carry)
    ctx:write(string.char(0xA9))
    ctx:finalize()
    assert.are.equal("café", ctx.accum)
    assert.are.equal("", ctx.carry)
  end)

  it("a cancelled stream's late writes cannot touch a new stream", function()
    local old = { buf = "", ctx = llm.new_stream_ctx() }
    local new = { buf = "", ctx = llm.new_stream_ctx() }
    llm.handle_ollama_spec_data('{"message":{"content":"stale tail"},"done":false}\n', old)
    llm.handle_ollama_spec_data('{"message":{"content":"fresh"},"done":true}\n', new)
    assert.are.equal("fresh", new.ctx.assistant_message.content)
    assert.are.equal("stale tail", old.ctx.accum)
  end)
end)
