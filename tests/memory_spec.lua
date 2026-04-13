-- Tests for memory.lua: per-buffer chat history storage used by invoke/code_chat.

local Memory = require("memory")
local Config = require("llm_config")
local llm    = require("llm")

-- Use an explicit buffer number that won't collide with real vim buffers in tests.
local BUF  = 9001
local BUF2 = 9002

local function clean()
  Memory.clear(BUF)
  Memory.clear(BUF2)
end

-- ── append / messages ─────────────────────────────────────────────────────────

describe("Memory.append and Memory.messages", function()
  before_each(clean)

  it("starts empty for a fresh buffer", function()
    assert.are.same({}, Memory.messages(BUF))
  end)

  it("appends a user message", function()
    Memory.append(BUF, "user", "hello")
    local msgs = Memory.messages(BUF)
    assert.are.equal(1, #msgs)
    assert.are.equal("user",  msgs[1].role)
    assert.are.equal("hello", msgs[1].content)
  end)

  it("appends an assistant message after a user message", function()
    Memory.append(BUF, "user",      "question")
    Memory.append(BUF, "assistant", "answer")
    local msgs = Memory.messages(BUF)
    assert.are.equal(2,           #msgs)
    assert.are.equal("assistant", msgs[2].role)
    assert.are.equal("answer",    msgs[2].content)
  end)

  it("preserves insertion order across multiple turns", function()
    Memory.append(BUF, "user",      "q1")
    Memory.append(BUF, "assistant", "a1")
    Memory.append(BUF, "user",      "q2")
    Memory.append(BUF, "assistant", "a2")
    local msgs = Memory.messages(BUF)
    assert.are.equal(4,           #msgs)
    assert.are.equal("q1",        msgs[1].content)
    assert.are.equal("a1",        msgs[2].content)
    assert.are.equal("q2",        msgs[3].content)
    assert.are.equal("a2",        msgs[4].content)
  end)

  it("silently ignores append when role is nil", function()
    Memory.append(BUF, nil, "content")
    assert.are.same({}, Memory.messages(BUF))
  end)

  it("silently ignores append when content is nil", function()
    Memory.append(BUF, "user", nil)
    assert.are.same({}, Memory.messages(BUF))
  end)

  it("keeps each buffer's store independent", function()
    Memory.append(BUF,  "user", "buf-one")
    Memory.append(BUF2, "user", "buf-two")
    assert.are.equal(1,         #Memory.messages(BUF))
    assert.are.equal(1,         #Memory.messages(BUF2))
    assert.are.equal("buf-one", Memory.messages(BUF)[1].content)
    assert.are.equal("buf-two", Memory.messages(BUF2)[1].content)
  end)
end)

-- ── clear ─────────────────────────────────────────────────────────────────────

describe("Memory.clear", function()
  before_each(clean)

  it("empties the store for the specified buffer", function()
    Memory.append(BUF, "user", "hello")
    Memory.clear(BUF)
    assert.are.same({}, Memory.messages(BUF))
  end)

  it("does not affect a different buffer's store", function()
    Memory.append(BUF,  "user", "mine")
    Memory.append(BUF2, "user", "theirs")
    Memory.clear(BUF)
    assert.are.same({}, Memory.messages(BUF))
    assert.are.equal(1, #Memory.messages(BUF2))
  end)

  it("is idempotent — clearing an already-empty buffer does not error", function()
    assert.has_no.errors(function()
      Memory.clear(BUF)
      Memory.clear(BUF)
    end)
  end)
end)

-- ── max_messages cap ──────────────────────────────────────────────────────────

describe("Memory max_messages cap", function()
  before_each(clean)

  local MAX = (Config.memory and Config.memory.max_messages) or 20

  it("never stores more than max_messages entries", function()
    for i = 1, MAX + 5 do
      Memory.append(BUF, "user", "msg " .. i)
    end
    assert.are.equal(MAX, #Memory.messages(BUF))
  end)

  it("retains the most recent messages when the cap is exceeded", function()
    for i = 1, MAX + 2 do
      Memory.append(BUF, "user", "msg " .. i)
    end
    local msgs = Memory.messages(BUF)
    -- first two messages should have been evicted
    assert.are.equal("msg 3",           msgs[1].content)
    assert.are.equal("msg " .. (MAX+2), msgs[#msgs].content)
  end)

  it("exactly at the cap, no eviction occurs", function()
    for i = 1, MAX do
      Memory.append(BUF, "user", "msg " .. i)
    end
    local msgs = Memory.messages(BUF)
    assert.are.equal(MAX,       #msgs)
    assert.are.equal("msg 1",   msgs[1].content)
    assert.are.equal("msg "..MAX, msgs[#msgs].content)
  end)
end)

-- ── build_messages ────────────────────────────────────────────────────────────

describe("Memory.build_messages", function()
  before_each(clean)

  it("returns [system, user] when history is empty", function()
    local msgs = Memory.build_messages(BUF, "SYS", "USR")
    assert.are.equal(2,       #msgs)
    assert.are.equal("system","SYS" == msgs[1].content and msgs[1].role or msgs[1].role)
    assert.are.equal("system", msgs[1].role)
    assert.are.equal("SYS",    msgs[1].content)
    assert.are.equal("user",   msgs[2].role)
    assert.are.equal("USR",    msgs[2].content)
  end)

  it("omits system entry when system_prompt is empty string", function()
    local msgs = Memory.build_messages(BUF, "", "USR")
    assert.are.equal(1,      #msgs)
    assert.are.equal("user", msgs[1].role)
    assert.are.equal("USR",  msgs[1].content)
  end)

  it("omits system entry when system_prompt is nil", function()
    local msgs = Memory.build_messages(BUF, nil, "USR")
    assert.are.equal(1,      #msgs)
    assert.are.equal("user", msgs[1].role)
  end)

  it("interleaves history between system and the new user message", function()
    Memory.append(BUF, "user",      "q1")
    Memory.append(BUF, "assistant", "a1")
    local msgs = Memory.build_messages(BUF, "SYS", "q2")
    -- Expected: [system, user:q1, assistant:a1, user:q2]
    assert.are.equal(4,           #msgs)
    assert.are.equal("system",    msgs[1].role)
    assert.are.equal("user",      msgs[2].role);      assert.are.equal("q1", msgs[2].content)
    assert.are.equal("assistant", msgs[3].role);      assert.are.equal("a1", msgs[3].content)
    assert.are.equal("user",      msgs[4].role);      assert.are.equal("q2", msgs[4].content)
  end)

  it("works with multiple prior turns", function()
    Memory.append(BUF, "user",      "q1")
    Memory.append(BUF, "assistant", "a1")
    Memory.append(BUF, "user",      "q2")
    Memory.append(BUF, "assistant", "a2")
    local msgs = Memory.build_messages(BUF, "SYS", "q3")
    assert.are.equal(6, #msgs)  -- system + 4 history + new user
    assert.are.equal("q3", msgs[#msgs].content)
  end)

  it("the new user prompt is always last", function()
    Memory.append(BUF, "user", "old")
    local msgs = Memory.build_messages(BUF, "SYS", "new question")
    assert.are.equal("user",         msgs[#msgs].role)
    assert.are.equal("new question", msgs[#msgs].content)
  end)
end)

-- ── session reset (llm.reset_message_buffers) ─────────────────────────────────

describe("llm.reset_message_buffers", function()
  it("runs without error", function()
    assert.has_no.errors(function()
      llm.reset_message_buffers()
    end)
  end)

  it("clears the memory store for the current buffer", function()
    -- Seed BUF with history, then clear via reset (which calls Memory.clear())
    Memory.append(BUF, "user", "some prior message")
    -- reset_message_buffers clears the *current* buffer; seed that one too
    local cur = vim.api.nvim_get_current_buf()
    Memory.append(cur, "user", "current buf message")
    llm.reset_message_buffers()
    assert.are.same({}, Memory.messages(cur))
  end)
end)
