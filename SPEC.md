# llm.nvim v2 — In-Editor LLM Agent: Specification

Status: **approved — M1, M3 (read-only agent), M4 (editing agent), and the core of M5 (conversational agent panel, session persistence/resume, OpenAI tool support) landed 2026-07-03; M2 partially landed (normalized Sink events, fake-transport injection)** · Drafted: 2026-07-02

## Decisions (owner-approved)

1. **Ollama-first.** The primary daily driver is local models via Ollama (gemma/qwen
   family). Anthropic and OpenAI stay fully supported; every feature is designed
   provider-agnostic, with Ollama as the reference deployment. Default endpoint is
   `http://localhost:11434/api/chat`; switching to a personal remote server is a
   documented one-line override.
2. **Default Anthropic model: `claude-haiku-4-5`.**
3. **`bash` tool is in scope for v2** (owner is comfortable with it). It ships in the
   agent milestone with policy `review` (every command shown and confirmed before it
   runs) and never `allow`-able for destructive patterns; see F1.
4. **Ollama models without tool support fail fast**: agent mode errors early with
   "model X does not support tools" rather than degrading silently.
5. **Module namespace moved to `lua/llm/`** with deprecation shims for the old
   top-level names (`openai`, `anthropic`, `ollama`, `llm_config`), so existing
   configs keep working for one release.

This document is the result of a full audit of the current codebase plus a design for
turning llm.nvim from a streaming-completion plugin into a real in-editor agent that can
read, search, and modify files under user control — while keeping the parts that already
work well (streaming engine, diff review, project memory, context picker).

---

## 1. Where the plugin stands today

**What works and is worth keeping:**

- Token streaming into buffers via curl + plenary.job with an extmark anchor,
  UTF-8-safe chunking, and throttled flushing (`lua/llm.lua`)
- Three providers (Anthropic, OpenAI Responses, Ollama) behind a factory (`lua/provider.lua`)
- Diff-review mode: stream into a scratch vsplit, native `diffthis`, accept/reject
- API keys passed to curl via stdin config (never in argv) — keep this pattern
- Project memory (`llm_memory.md`) and per-buffer chat history
- Context picker for selecting buffers
- A real unit-test suite (busted + hand-rolled `vim` stub, ~1750 lines) and CI with
  luacheck + stylua + busted

**What it fundamentally cannot do yet:** the model never acts. There is no tool use, so
the LLM cannot read a file it wasn't given, search the project, or propose an edit to a
file other than the current selection. Everything below builds toward that.

---

## 2. Problems found in the current code

> **Status update (2026-07-03):** every bug below except P13 is **fixed** as part of
> Milestone 1, each with a regression test where unit-testable. P13 (single global
> stream state) is deliberately deferred to M2, where the session model removes it
> structurally. P7 was fixed via the `lua/llm/` namespace move with compat shims.

### 2.1 Bugs / correctness

| # | Problem | Location | Severity |
|---|---------|----------|----------|
| P1 | **Default Ollama endpoint is a personal remote server** (`https://ollama.putty-ai.com/api/chat`), while the README claims `http://localhost:11434`. Anyone installing the plugin silently sends their code to that server. | `lua/constants.lua:11`, `lua/llm.lua:278` | Critical |
| P2 | **`code` mode deletes the visual selection before the request is sent** (`normal! d`). A failed request leaves the user staring at deleted code (undo recovers it, but nothing tells them that). | `lua/utils.lua:231` | High |
| P3 | **Chat-memory role alternation breaks after a failed/cancelled request.** `Memory.append(bufnr, "user", …)` happens before the request; if no assistant reply arrives, the next request sends two consecutive `user` messages — Anthropic rejects this with a 400 and the chat is wedged until `:LLMClear`. | `lua/llm.lua:554`, `lua/memory.lua` | High |
| P4 | **`temperature`/`top_p` are sent to Anthropic unconditionally** (`temp = 1` from `constants.vars`). Claude Opus 4.7+, Opus 4.8, Sonnet 5, and Fable 5 reject sampling parameters with a 400 — switching the model config to any current frontier model breaks the plugin. | `lua/llm.lua:229-230` | High |
| P5 | **OpenAI `previous_response_id` chain corrupts on failure.** `provider_state.OPENAI.count` increments in `on_exit` even when curl exits non-zero, so the next request sends `previous_response_id = ""` → 400. | `lua/llm.lua:607-613` | Medium |
| P6 | **The `<Esc>` buffer-local keymap is never removed** after a stream ends. Esc in that buffer permanently fires `LLM_Escape`. It is also set on whatever buffer is current, not the target buffer. | `lua/llm.lua:702-709` | Medium |
| P7 | **Module namespace pollution.** Modules live at `lua/utils.lua`, `lua/memory.lua`, `lua/ui.lua`, `lua/log.lua`, `lua/constants.lua`, `lua/stream.lua`. Any other plugin with a top-level `utils.lua` (there are many) collides — `require("utils")` returns whichever is first on the runtimepath. | `lua/*.lua` | High |
| P8 | **SSE event name not carried across chunk boundaries.** `current_event` in `handle_anthropic_spec_data` is local to one chunk; an `event:` line at the end of one stdout read and its `data:` line at the start of the next lose their pairing (works today only because of the `obj.delta` fallback). | `lua/llm.lua:250-273` | Low |
| P9 | **No handling of stream-level errors or stop reasons.** Anthropic `error` SSE events, `message_delta.stop_reason` (`max_tokens` truncation, `refusal`), and Ollama `{"error": …}` lines are all silently ignored — the stream just goes quiet. | `lua/llm.lua` handlers | Medium |
| P10 | **The HTTP-error notifier is mostly dead code.** `extract_error_message` matches `HTTP/1.1 401`-style status lines on stderr, but curl (without `-v`) writes `curl: (22) The requested URL returned error: 401` — no match, so the friendly 401/429 hints never fire. | `lua/llm.lua:160-191` | Low |
| P11 | **`invoke` mode actually uses chat memory.** `provider.create().invoke` sets `code_chat = true`, so "single-turn Q&A, no history" (README) is wrong — invoke calls append to per-buffer history and get replayed. | `lua/provider.lua:40-55` | Low |
| P12 | **Log dir without trailing slash breaks the log path.** `data_dir .. os.date(...)` produces `…/logs2026-07-02.jsonl` if `logging.dir` is set without a trailing `/`. | `lua/log.lua:55-56` | Low |
| P13 | **Global mutable stream state** (`response_accum`, `utf8_carry`, `pending_text`, `stream_anchor`, `assistant_message`) means exactly one stream can exist; a second invocation while scheduled callbacks are in flight can interleave text into the wrong buffer. | `lua/llm.lua:78-141` | Medium |
| P14 | **`max_tokens` defaults to 4096** for Anthropic — long code rewrites truncate mid-function, and P9 means the user is never told. | `lua/llm.lua:228` | Medium |

### 2.2 Design / hygiene issues

- **Dead config**: `context.ignore_dirs` is never read; `vars.frequency_penalty`, `vars.presence_penalty` are plumbed but unused by all three request builders.
- **Docs drift**: `docs/recipes.md` references `openai.en2ch` and `prompts.en2ch_prompt`, which don't exist; README's Ollama endpoint claim contradicts the code (P1).
- **Side effects at require time**: user commands are registered when `lua/llm.lua` is first required; `memory.lua` registers an autocmd at require time. There is no `plugin/` bootstrap and no single `setup()` entry point (config is split across `llm_config.setup` and `constants.setup`).
- **No `:checkhealth` support** — missing curl, missing API key, unreachable Ollama are all diagnosed by cryptic failures.
- **Anthropic request shape is dated**: no `thinking` support, no tool use, static `anthropic-version` handling only. (Correct per-model behavior matters: on Opus 4.6+ use `thinking = {type = "adaptive"}`; never send `budget_tokens` on 4.7+.)
- **Test suite gaps**: everything runs against a hand-rolled `vim` stub (`tests/busted_helper.lua`), which drifts from real Neovim behavior. There are no integration tests that exercise the plugin inside a headless `nvim`, and no test covers the curl/job layer (a mock server is never spun up).

---

## 3. Goals for v2

1. **Agent mode**: the model can search the project, read files, and propose edits via
   tool calls, in a multi-turn loop, with every mutation gated behind user review.
2. **A real chat surface**: a persistent, dedicated chat panel instead of separators
   typed into the working buffer.
3. **Keep and harden inline rewriting**: `code_diff` stays the flagship "rewrite this
   selection" flow; plain `code` becomes non-destructive.
4. **Fix everything in §2.**
5. **Testing you can trust**: three tiers (pure-Lua unit, headless-nvim integration,
   mock-server end-to-end), all in CI, no API keys required.

Non-goals for v2 (explicitly out of scope): MCP client support, multi-agent
orchestration, embeddings/RAG indexing, image generation improvements (DALL·E stays
as-is), completion-engine (`cmp`) integration.

---

## 4. Target architecture

### 4.1 Module layout (breaking change, namespaced)

```
lua/llm/
  init.lua            -- setup(), public API, user commands
  config.lua          -- single merged config (absorbs llm_config + constants)
  health.lua          -- :checkhealth llm
  util/
    fs.lua            -- path resolution + project-root confinement
    text.lua          -- utf8 carry, visual selection, splice (from utils.lua)
  provider/
    init.lua          -- provider registry + shared request/stream contract
    anthropic.lua     -- Messages API: streaming, tools, thinking, stop reasons
    openai.lua        -- Responses API: streaming, function calling
    ollama.lua        -- /api/chat: streaming, tool calls
  stream.lua          -- SSE/JSONL parsers (event carried in state — fixes P8)
  job.lua             -- curl job wrapper: config-via-stdin, cancel, error surface
  session.lua         -- one conversation: messages, tool transcript, per-session state
  tools/
    init.lua          -- tool registry, JSON schemas, approval policy
    read_file.lua
    list_files.lua
    grep.lua
    edit_file.lua
    write_file.lua
  agent.lua           -- the tool-use loop
  chat/
    ui.lua            -- chat panel buffer/window
    render.lua        -- role headers, markdown, tool-call folds
    persist.lua       -- save/load sessions as JSONL
  edit/
    diff.lua          -- existing diff mode (moved, kept)
    apply.lua         -- apply agent-proposed edits with per-file diff review
  context.lua         -- context picker + project memory (merged front-end)
  log.lua
plugin/llm.lua        -- command registration only (no require side effects)
```

A thin compatibility shim keeps `require("anthropic").code_chat` etc. working for one
release, emitting a deprecation notice.

### 4.2 The provider contract

Every provider implements one interface; everything above it (chat, agent, inline
rewrite) is provider-agnostic:

```lua
---@class llm.Provider
---@field name string
---@field build_request fun(req: llm.Request): { url:string, headers:table, body:table }
---@field parse_stream  fun(state: table, chunk: string, sink: llm.Sink)

---@class llm.Request
---@field model string
---@field system string|nil
---@field messages llm.Msg[]          -- normalized: user | assistant | tool_result
---@field tools llm.ToolSchema[]|nil
---@field max_tokens integer
---@field thinking "adaptive"|nil     -- Anthropic only; ignored elsewhere

---@class llm.Sink                    -- normalized stream events
---@field on_text fun(delta: string)
---@field on_thinking fun(delta: string)|nil
---@field on_tool_call fun(call: { id:string, name:string, input:table })
---@field on_stop fun(reason: "end_turn"|"tool_use"|"max_tokens"|"refusal"|"error", detail?: string)
---@field on_error fun(err: { code?:integer, message:string })
```

Provider notes:

- **Ollama** (primary daily driver): `/api/chat` with `tools` for models that support
  them (qwen and most recent instruct models do; availability is model-dependent).
  Per decision 4, agent mode checks the first response — a model that ignores or
  rejects the `tools` field fails fast with "model X does not support tools; use
  chat mode or switch models". Default endpoint `http://localhost:11434/api/chat`
  (fixed P1); `{"error": …}` lines are surfaced (P9).
- **Anthropic** (reference implementation for the tool-call wire format, since its
  streaming tool-use shape is the best documented): `POST /v1/messages`,
  `stream = true`, `anthropic-version: 2023-06-01`. Tools go in `tools` with
  `input_schema`; streamed tool calls arrive as `content_block_start` (type
  `tool_use`, carrying `id`/`name`) followed by `input_json_delta` fragments that are
  accumulated and JSON-decoded at `content_block_stop`. `message_delta` carries
  `stop_reason`. Tool results are sent back as `tool_result` blocks — **all results
  for one assistant turn in a single user message**, each with the matching
  `tool_use_id`. Drop `temperature`/`top_p` entirely (fixes P4); default
  `max_tokens = 16000` for chat/agent and `32000` for rewrites (fixes P14); support
  `thinking = { type = "adaptive" }` as an opt-in config. Handle `error` SSE events
  and `stop_reason` values `max_tokens` (notify truncation) and `refusal` (surface
  message, never auto-retry). Default model `claude-haiku-4-5` (decision 2).
- **OpenAI**: keep the Responses API; replace the fragile `previous_response_id`
  counter with full message replay from `session.lua` (fixes P5 and removes the
  cross-buffer shared state). Function calling maps onto the same `on_tool_call` sink.

### 4.3 Session model

`session.lua` owns the canonical conversation: an ordered list of normalized messages
plus tool transcripts. Chat memory moves here from `memory.lua`, with the P3 fix:

- The user turn is appended to the session **only after** a successful assistant reply
  (or the failed turn is rolled back on error/cancel).
- Sessions are keyed by an explicit session id (default: one per chat panel; the old
  per-buffer behavior is retained for inline chat).
- `chat/persist.lua` writes sessions to `stdpath("data")/llm/sessions/*.jsonl` so a chat
  survives restarting Neovim (`:LLMChatResume`).

---

## 5. Feature specs

### F1 — Tool system (`lua/llm/tools/`)

Each tool is a table: `{ name, description, input_schema, exec(input, ctx) -> result|err, policy }`.
The registry produces the provider-specific schema list and dispatches calls.

Core tools (v2 ships these six — `bash` included per owner decision, gated hard):

| Tool | Input | Behavior | Approval policy (default) |
|------|-------|----------|---------------------------|
| `read_file` | `path`, optional `start_line`, `end_line` | Returns file content with line numbers, capped at `context.max_buffer_bytes`; prefers the loaded buffer over disk so unsaved edits are visible | auto-allow |
| `list_files` | optional `glob`, `max_results` | `vim.fs`-based listing honoring `.gitignore` via `rg --files` when available, falling back to `vim.fs.dir` | auto-allow |
| `grep` | `pattern`, optional `glob`, `max_results` | Runs `rg --vimgrep` (required dependency for this tool; degrade to `vim.fn.systemlist(grep …)` with a health warning) | auto-allow |
| `edit_file` | `path`, `old_string`, `new_string`, optional `replace_all` | str_replace semantics: error if 0 or >1 matches (unless `replace_all`). Never writes directly — produces a pending edit for review (see F3) | **review required** |
| `write_file` | `path`, `content` | Create or overwrite a whole file — also goes through review; overwriting an existing file is flagged in the review UI | **review required** |
| `bash` | `command`, optional `timeout_s` | Runs the command from the project root via `vim.system` with a timeout and captured stdout/stderr (truncated to a configurable cap). The exact command is always shown in the confirmation prompt. Cannot be set to auto-allow: `tools.policy.bash` accepts only `"review"` or `"disabled"`. | **review required, every call** |

**Security invariants (non-negotiable, enforced in `util/fs.lua`, unit-tested):**

1. Every model-supplied `path` is resolved to canonical form
   (`vim.fs.normalize` + `vim.uv.fs_realpath` of the deepest existing ancestor) and must
   remain inside the project root (`vim.fs.root()` markers `.git`, fallback cwd).
   Reject `..` traversal, absolute paths outside the root, and symlink escapes.
2. Reads of files matching `constants.excluded_extensions` and dotfiles like `.env` are
   refused (returns a tool error the model can see).
3. Tool `exec` never raises — failures return `{ error = "…" }` which is sent back as a
   `tool_result` with `is_error = true` so the model can adapt.
4. Approval policy is config: `tools.policy = { read_file = "allow", edit_file = "review", … }`,
   with a global `tools.yolo = false` escape hatch that must be set explicitly.

### F2 — Agent loop (`lua/llm/agent.lua`)

```
user prompt ─► request(tools) ─► stream text into chat panel
                    │
                    ├─ stop_reason == "tool_use":
                    │     render tool-call cards in panel
                    │     for each call: check policy → exec (reads) or queue (edits)
                    │     if queued edits: show review UI, wait for accept/reject
                    │     send ALL tool_results in one user message ─► loop
                    │
                    └─ stop_reason == "end_turn": done, persist session
```

Rules:

- Max `agent.max_turns` iterations per user prompt (default 25); exceeding it stops the
  loop with a notice rather than spinning.
- `Esc` / `:LLMCancel` aborts the in-flight curl job **and** the loop; a cancelled turn
  is rolled back from the session (P3 discipline).
- Every tool call and result is rendered in the chat panel as a folded card:
  `▸ grep("TODO", "**/*.lua") → 14 matches` — expandable to see the full result.
- Parallel tool calls in one assistant turn are executed in order (reads) and their
  results are batched into a single tool-result message. Rejected edits return
  `tool_result` with `is_error = true` and the user's optional reason.
- The agent's system prompt states the project root, OS, and available tools, and
  includes project memory (`llm_memory.md`) exactly as today.

### F3 — Edit review (`lua/llm/edit/apply.lua`)

Agent-proposed edits reuse the proven diff-mode muscle:

- Each `edit_file`/`write_file` call becomes a **pending edit**. The target file opens
  (or its buffer is used if loaded), a scratch buffer with the patched content sits in a
  vsplit with `diffthis`, and the existing accept/reject keymaps apply
  (`keymaps.diff_accept` / `diff_reject`).
- Multiple edits queue; the review UI steps through them (`]e` / `[e` next/prev pending
  edit; statusline shows `LLM edits: 2/5`).
- Accept applies via `nvim_buf_set_lines` on the buffer (never raw disk writes for
  loaded buffers — the user decides when to `:w`); for unloaded files the write goes to
  disk and the file is opened.
- Reject sends the failure back to the model with the user's optional one-line reason.
- Buffer-staleness guard: the pending edit records the buffer `changedtick`; if it
  changed before accept, re-anchor via the `old_string` match or mark the edit stale.

### F4 — Chat panel (`lua/llm/chat/`)

- `:LLMChat` opens a right-hand vsplit (configurable: `float`/`split`/`vsplit`),
  filetype `llmchat` (markdown-based), `buftype=nofile` but backed by session persistence.
- Layout: `## User` / `## Assistant` sections, tool cards as folds, a `> ` input area at
  the bottom. `<CR>` in normal mode (or `<C-s>` in insert) submits; `gq` requeues the
  last user message after editing it.
- Streaming reuses the extmark-anchor engine, but anchor state lives on the session,
  not module-global (fixes P13 — two chats in two tabs can stream concurrently).
- Panel keymaps (buffer-local, documented in the panel header): submit, cancel, new
  session, resume picker, toggle tool folds, yank last code block (`gy`).
- `@file` mentions in the input auto-attach that file's content to the turn; the
  existing context picker (`:LLMContextAdd`) continues to work and is displayed as
  chips in the panel header.
- Inline `code_chat` (chat in the working buffer with separators) remains for users who
  prefer it, but the README repositions the panel as the default chat experience.

### F5 — Inline rewriting hardening (existing modes)

- `code` no longer deletes the selection up-front (P2): it streams into a hidden
  scratch, then replaces the selection only on successful completion; on failure the
  buffer is untouched.
- `code_diff` unchanged in UX; internally moves to `edit/diff.lua` and gains the
  buffer-staleness guard from F3.
- `invoke` becomes genuinely stateless (P11): no memory append, no history replay.
- The `<Esc>` cancel mapping is set on the target buffer only and **deleted** in
  `on_exit` and on cancel (P6).

### F6 — Config, setup, health

Single entry point; old shape accepted with a deprecation notice:

```lua
require("llm").setup({
  default_keymaps = true,
  providers = {
    ollama    = { model = "qwen3.6:latest", url = "http://localhost:11434/api/chat" },
    anthropic = { model = "claude-haiku-4-5", api_key_name = "ANTHROPIC_API_KEY",
                  max_tokens = 16000, thinking = "adaptive" },
    openai    = { model = "gpt-5.4-mini" },
  },
  default_provider = "ollama",
  chat  = { ui = "vsplit", width = 0.4 },
  agent = { max_turns = 25 },
  tools = {
    enabled = { "read_file", "list_files", "grep", "edit_file", "write_file", "bash" },
    policy  = { edit_file = "review", write_file = "review", bash = "review" },
  },
  keymaps = { diff_accept = "<leader>da", diff_reject = "<leader>dr" },
  logging = { enabled = false, redact = true },
})
```

- `:checkhealth llm` verifies: curl present and version, `rg` present, API key env vars
  set for configured providers, Ollama endpoint reachable (async, non-fatal), Neovim ≥ 0.10.
- New/changed commands: `:LLMChat`, `:LLMChatResume`, `:LLMAgent {prompt}` (one-shot
  agent invocation on the current project), `:LLMEditsReview`, plus everything existing.
- Fix P12 (join log paths with `vim.fs.joinpath`), remove dead config keys, fix README
  endpoint claim, delete or implement `recipes.md` references.

---

## 6. Testing strategy

Three tiers, all runnable locally and in CI, **no API keys anywhere**.

### Tier 1 — Pure-Lua unit tests (busted, existing suite extended)

Keep the current busted + `tests/busted_helper.lua` stub setup for logic with no real
editor dependency:

- `stream_spec`: SSE parsing including **event-name carry across chunk boundaries**
  (P8 regression test), tool_use block accumulation from `input_json_delta` fragments
  split at every possible byte boundary, error events, `[DONE]`, JSONL with Ollama
  error lines.
- `provider_spec` (per provider): `build_request` golden tests — assert the exact JSON
  body for chat, agent (with tools), and rewrite requests; assert Anthropic body
  contains **no** `temperature`/`top_p` (P4 regression), correct `max_tokens`,
  tool_result batching in a single message.
- `tools_spec`: schema validity; `edit_file` 0-match / multi-match errors; path
  confinement — table-driven cases for `../`, absolute paths, symlink escape,
  `.env` refusal (uses a temp dir fixture, no vim APIs needed beyond the stub).
- `session_spec`: role alternation invariant under success / failure / cancel (P3
  regression); rollback; persistence round-trip (encode → decode → deep-equal).
- Keep existing `diff_spec`, `utf8_spec`, `memory_spec`, `request_spec` (ported to new
  module paths).

### Tier 2 — Headless Neovim integration tests (new)

The stub can drift from real Neovim; these tests run the actual plugin inside
`nvim --headless` using **mini.test** (single-file dependency, child-process model —
each case gets a fresh editor):

- Chat panel: open, submit, streamed text lands in the right section, fold cards render,
  cancel mid-stream restores a consistent panel.
- Edit review: pending edit → diff windows open → accept mutates the buffer exactly as
  expected → reject leaves it untouched → staleness guard fires when the buffer is
  edited under the diff.
- Inline `code`: failure path leaves the selection intact (P2 regression).
- `<Esc>` mapping lifecycle: absent before, present during, absent after a stream (P6).
- Provider layer wired to a **fake transport**: `job.lua` accepts an injectable runner
  so tests feed recorded SSE chunks without any network.

Runner: `make test-integration` →
`nvim --headless --noplugin -u tests/integration/init.lua -c "lua MiniTest.run()"`.

### Tier 3 — End-to-end against a mock server (new, small)

A ~100-line Lua (or Python stdlib) HTTP server that speaks just enough SSE: canned
Anthropic/OpenAI/Ollama responses, including a scripted tool-use conversation
(`grep` → `read_file` → `edit_file` → end_turn). Tests point
`providers.*.url` at `127.0.0.1:<port>` and drive a full agent turn through real curl,
real plenary.job, real parsing — asserting the final buffer state and the exact request
bodies the server received (this is the only tier that catches curl-config quoting bugs
and the stdin key-passing path).

Marked `--tags=e2e`; runs in CI on Linux, skipped if `curl` is missing.

### CI matrix (`.github/workflows/ci.yml`)

| Job | Contents |
|-----|----------|
| lint | luacheck + stylua --check (unchanged) |
| unit | busted (Lua 5.4 + LuaJIT — Neovim is LuaJIT; today only 5.4 is tested) |
| integration | nvim `stable` and `nightly` × mini.test + e2e mock server |

Definition of done for every feature PR: unit tests for new logic, an integration test
for any new UI surface, and no `luacheck`/`stylua` regressions.

---

## 7. Milestones

Ordered so the plugin is never broken in between; each milestone is shippable.

1. ✅ **M1 — Foundation & bug fixes** *(landed 2026-07-03)*:
   namespace move to `lua/llm/` with compat shims; single `require("llm").setup()`;
   fixed P1–P6, P8–P12, P14 with regression tests; non-destructive `code` mode via the
   diff engine with `auto_apply`; `:checkhealth llm`; opt-in default keymaps
   (`default_keymaps = true`); LuaJIT added to CI; tests ported (159 passing) and
   luacheck/stylua clean.
2. **M2 — Provider contract** *(partially landed 2026-07-03)*: ✅ normalized `Sink`
   stream events (`stream.anthropic_events` / `stream.ollama_events`, chunk-boundary
   tested), ✅ fake-transport injection point (`agent.run{transport=…}`); ⬜ session
   model for chat modes, ⬜ mini.test harness + integration tests, ⬜ mock e2e server.
3. ✅ **M3 — Read-only agent** *(landed 2026-07-03)*: tool registry with per-provider
   schemas + policy (`lua/llm/tools/`), `read_file`/`list_files`/`grep` with path
   confinement enforced in `lua/llm/util/fs.lua` (traversal/absolute/symlink escapes +
   secret-file refusal, table-driven tests), agent loop (`lua/llm/agent.lua`) for
   Ollama and Anthropic with tool cards in a minimal markdown panel, `:LLMAgent`
   command, Esc/`:LLMCancel` cancellation, max_turns cap, and fail-fast for Ollama
   models without tool support. 93 new unit tests (252 total).
4. ✅ **M4 — Editing agent** *(landed 2026-07-03)*: `edit_file`/`write_file` compute
   pending edits (str_replace semantics, 0/&gt;1-match errors, confinement + secret
   refusal for writes) reviewed as a native diff in `lua/llm/edit/apply.lua` —
   buffer-apply for loaded files, disk for unloaded, staleness guard with re-anchor,
   reject-with-reason fed back as `is_error`; `bash` runs from the project root with
   a timeout, confirm-gated on **every** call and never `allow`-able (registry
   clamp); the agent loop executes calls sequentially through an async executor so
   it pauses during review and resumes on accept/reject. 32 new unit tests (284
   total) plus a headless-nvim smoke test that drives the real review UI.
   Deviation from the spec: review is one-edit-at-a-time inline in the loop —
   the `]e`/`[e` multi-edit queue UI is deferred to M5.
5. **M5 — Chat polish & parity** *(core landed 2026-07-03)*: ✅ the agent panel is
   a conversation — after each turn an input area opens and `<CR>` sends a
   follow-up with full context (`agent.run{session=…}` continuation; on
   error/cancel/max_turns the transcript is trimmed so role alternation stays
   valid, and a dangling user prompt merges on retry); ✅ sessions persist as JSON
   under `stdpath("data")/llm/sessions` with `:LLMAgentResume` re-rendering the
   transcript and continuing; ✅ OpenAI Responses API tool support (flat function
   schemas, transcript replay via `function_call`/`function_call_output` items,
   `store=false` — no `previous_response_id` fragility in agent mode).
   Remaining: tool-card folds, `@file` mentions, README repositioning of the
   panel as the default chat, delete compat shims next release.

---

## 8. Open questions — resolved

All four resolved 2026-07-02 (see the Decisions section at the top):

1. Module-name move → done, with deprecation shims so old configs keep working.
2. Default Anthropic model → `claude-haiku-4-5`.
3. `bash` tool → included in v2, review-required on every call (never auto-allow).
4. Ollama models without tool support → agent mode errors early and clearly.
