llm.nvim
========

Neovim plugin for streaming LLM responses directly into your editor. Built local-first
around **Ollama** (gemma, qwen, and friends on your own machine), with full support for
**Anthropic** and **OpenAI** as cloud providers. Inline editing, multi-turn chat, a
diff-preview replace mode, project-level memory, and an interactive context picker.

Features
--------
- Local-first: works out of the box against Ollama at `http://localhost:11434`
- **Agent mode** (`:LLMAgent`) — the model explores your project itself with
  `read_file` / `list_files` / `grep` tools in a multi-turn loop, confined to the
  project root — and can **propose edits** (`edit_file` / `write_file`) that you
  review as a native diff before anything is applied, plus run shell commands
  (`bash`) with per-command confirmation
- Token-by-token streaming into the current buffer
- Three providers: Ollama (Chat API), Anthropic (Messages API), OpenAI (Responses API)
- Multi-turn code chat with per-buffer conversation history
- **Diff mode** — proposed code change shown in a split; accept or reject before touching your file
- **Safe replace mode** — `code` streams into a scratch split and applies only on success; a failed or cancelled request never touches your buffer
- Project memory — `llm_memory.md` auto-injected into every request
- Context picker — interactively choose which open buffers to include
- One-line default keymaps for every provider and mode (`default_keymaps = true`)
- `Esc` cancels any running stream
- API keys passed to curl via stdin (never in process argv)
- `:checkhealth llm` diagnoses curl, plenary, API keys, and endpoints
- Optional JSONL logging with redaction

Quick Start (lazy.nvim)
-----------------------

The minimal setup — local Ollama with all default keymaps:

```lua
return {
  {
    "Chunt0/llm.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      require("llm").setup({
        default_keymaps = true,
        constants = {
          models = {
            ollama    = "qwen3.6:latest",   -- or "gemma4:26b", any model you've pulled
            anthropic = "claude-haiku-4-5",
            openai    = "gpt-5.4-mini",
          },
        },
      })
    end,
  },
}
```

A fuller example lives in `local_config.lua.example`. Run `:checkhealth llm` after
installing to verify everything is wired up.

Ollama Endpoint
---------------

The default endpoint is your local instance: `http://localhost:11434/api/chat`.
No API key is needed.

**Pointing at a remote / personal Ollama server** is one line in `setup()`:

```lua
require("llm").setup({
  constants = {
    api_endpoints = {
      ollama = "https://ollama.putty-ai.com/api/chat", -- your own server
    },
  },
})
```

`:checkhealth llm` shows which endpoint is currently active.

Environment Variables (cloud providers only)
--------------------------------------------

```sh
export ANTHROPIC_API_KEY="sk-ant-..."
export OPENAI_API_KEY="sk-..."
```

Ollama requires nothing.

Default Keymaps
---------------

Enabled with `default_keymaps = true`. The prefix picks the provider —
`<leader>l` (local/Ollama), `<leader>a` (Anthropic), `<leader>o` (OpenAI) — and the
final key picks the mode. Shown here for Ollama:

| Keymap | Mode(s) | Action |
|--------|---------|--------|
| `<leader>li` | n, v | `invoke` — single-turn Q&A, no history |
| `<leader>lc` | v | `code` — replace the selection with generated code |
| `<leader>lb` | v | `code_all_buf` — replace, with all open buffers as context |
| `<leader>lt` | n, v | `code_chat` — multi-turn chat |
| `<leader>la` | n, v | `code_chat_all_buf` — chat, with all open buffers as context |
| `<leader>ld` | v | `code_diff` — propose replacement in a diff split |

The same six exist as `<leader>a…` for Anthropic and `<leader>o…` for OpenAI.

Shared controls:

| Keymap | Action |
|--------|--------|
| `<leader>zz` | Reset all conversation state |
| `<leader>zc` | Toggle current buffer in/out of LLM context |
| `<leader>zx` | Clear all context buffers |
| `<leader>zl` | List context buffers |
| `<leader>zm` | Edit project memory (`llm_memory.md`) |
| `<leader>zh` | Run `:checkhealth llm` |
| `<leader>zg` | Run the agent (prompts for a task) |
| `<leader>da` / `<leader>dr` | Accept / reject a pending diff (configurable) |

Prefer your own maps? Skip `default_keymaps` and bind the functions directly:

```lua
local ollama = require("llm.ollama")
vim.keymap.set({ "n", "v" }, "<leader>lt", ollama.code_chat, { desc = "LLM chat" })
```

Operation Modes
---------------

Every provider exposes six functions:

| Mode                | Key (Ollama)  | What it does |
|---------------------|---------------|--------------|
| `invoke`            | `<leader>li`  | Single-turn Q&A. Streams the answer after your text. No history. |
| `code`              | `<leader>lc`  | Streams a replacement into a scratch split, applies it to the selection on success. |
| `code_all_buf`      | `<leader>lb`  | Same as `code`, but every open buffer is sent as context. |
| `code_chat`         | `<leader>lt`  | Multi-turn chat with per-buffer conversation memory. |
| `code_chat_all_buf` | `<leader>la`  | Same as `code_chat`, plus all open buffers as context. |
| `code_diff`         | `<leader>ld`  | Proposed replacement shown in a diff split — accept or reject before anything changes. |

For `invoke`, `code_chat`, and `code_chat_all_buf` a visual selection is optional — if
nothing is selected the plugin prompts for input at the bottom of the screen. `code`,
`code_all_buf`, and `code_diff` always require a visual selection (they need to know
which code to work on).

Code Mode (replace)
-------------------

`code` and `code_all_buf` replace the visual selection with the model's output.

The replacement is **never destructive while in flight**: the response streams into a
scratch split so you can watch it, and your selection is swapped out only when the
request completes successfully. A failed request, a mid-stream `Esc`, or a network
error leaves your buffer untouched. After a successful apply, `u` undoes it.

Code Diff Mode
--------------

`code_diff` is the review-first variant — nothing is applied until you accept.

### How it works

1. **Select code** in visual mode (a function, block, or any lines).
2. **Invoke** (e.g. `<leader>ld`). The plugin records the selection without touching your file.
3. A **vertical split** opens to the right. The LLM streams its replacement into the
   right pane while your original code stays untouched on the left.
4. When streaming finishes, Neovim's native **diff highlighting** activates.
5. Review the diff, then:
   - **`<leader>da`** — accept. The new lines are written into your file, the split closes.
   - **`<leader>dr`** — reject. The split closes. Your file is completely unchanged.
   - **`Esc`** — cancel mid-stream. The split closes before diff mode even activates.

If you close the split manually (`:q`), diff mode and the keybinds are cleaned up
automatically. The accept/reject keys are configurable — see Configuration.

Code Chat — Multi-turn Conversations
-------------------------------------

`code_chat` and `code_chat_all_buf` keep a running conversation history tied to the
current buffer so the model remembers what you discussed.

### How it works

1. **Write your question** anywhere in the buffer, or select it in visual mode, or
   invoke with nothing selected and type it at the prompt.
2. **Invoke** (e.g. `<leader>lt`). The response streams in after your text.
3. When the stream finishes a separator is inserted:
   ```
   ---------------------------User---------------------------

   ```
4. **Type your follow-up** below the separator and invoke again.
5. The model receives the full conversation so far on every request.

A conversation turn is stored only after the request succeeds, so a failed request
never corrupts the history (Anthropic requires strictly alternating user/assistant
roles — the plugin guarantees this).

### Cancelling a stream

Press `Esc` at any time to stop the running stream mid-response.

### Resetting the conversation

History is per-buffer and persists until you reset it:

```
:LLMReset           clear all conversation state (incl. OpenAI response chain)
:LLMClear           clear per-buffer chat history for the current buffer
<leader>zz          reset all conversation state (keymap)
```

### History limit

The plugin keeps the last `max_messages` turns in memory (default 20). Older turns are
dropped automatically.

```lua
require("llm").setup({ memory = { max_messages = 40 } })
```

Agent Mode
----------

`:LLMAgent {task}` runs a tool-using agent against your project: the model can
list files, grep, and read files on its own, in a loop, until it can answer.

```
:LLMAgent where is the Esc keymap cleaned up after a stream ends?
:LLMAgent provider=anthropic summarize how streaming works in this plugin
:LLMAgent                                    (prompts for the task)
```

A markdown panel opens on the right; the response streams in and every tool
call is shown as a card:

```
▸ grep(pattern="remove_esc_keymap") → 6 lines
▸ read_file(path="lua/llm/init.lua", start_line=620) → 90 lines
```

**It's a conversation**: when a turn finishes, an input area opens at the
bottom of the panel — type a follow-up and press `<CR>` in normal mode to send
it with the full conversation context. Press `Esc` in the panel (or
`:LLMCancel`) to stop a running turn. Each request/tool loop is capped at
`agent.max_turns` (default 25) rounds.

**Sessions persist**: every conversation is saved under
`stdpath("data")/llm/sessions`. `:LLMAgentResume` lists saved sessions, renders
the transcript back into a panel, and lets you keep going — across Neovim
restarts.

**Defaults**: the provider comes from `agent.provider` (default `ollama`) with
the model from `constants.models`; pin one run with
`:LLMAgent provider=anthropic …` (all three providers — `ollama`, `anthropic`,
`openai` — support agent mode). Ollama models must support tool calling
(qwen3, llama3.1+, etc.) — a model without tool support fails immediately with
a clear error instead of degrading silently.

**Editing under review**: when the agent calls `edit_file` (exact string
replacement) or `write_file` (create/overwrite), nothing touches your file.
The proposed result opens as a native diff — `<leader>da` accepts, `<leader>dr`
rejects (optionally with a reason the model sees and must respect). Accepting
applies to the *buffer* for loaded files (you decide when to `:w`) and to disk
only for unloaded ones. If the file changed while you were looking, the edit
re-anchors or fails as stale rather than clobbering your work. The agent loop
pauses during review and resumes when you decide.

**Shell commands**: the `bash` tool shows you the exact command and runs it
from the project root only after you confirm — every single call. Its policy
can never be set to `allow`; only `review` or `disabled`.

**Sandboxing**: every path the model supplies is resolved and confined to the
project root (no `..` traversal, no absolute paths outside the root, no symlink
escapes), and secret files (`.env*`) plus binary/database/etc. extensions are
refused — for reads and writes alike. Tool failures are fed back to the model
as errors, never raised.

```lua
require("llm").setup({
  agent = { provider = "ollama", max_turns = 25 },
  tools = {
    enabled = { "read_file", "list_files", "grep", "edit_file", "write_file", "bash" },
    policy = { bash = "disabled" },      -- e.g. no shell at all
    max_result_bytes = 60 * 1024,        -- cap on a single tool result
  },
})
```

Context Picker
--------------

Selectively inject open buffers into any prompt without switching to `code_all_buf`.

```
:LLMContextAdd    open picker — toggle buffers with Enter, [x] = selected
:LLMContextClear  deselect all buffers
:LLMContextList   show which buffers are currently selected
```

Selected buffers are prepended to the prompt in every mode as a `# Code Context:`
block. The picker shows only normal file buffers (terminals and scratch buffers are
excluded). It uses `vim.ui.select` and works with Telescope
(`telescope-ui-select.nvim`) automatically.

Project Memory
--------------

Create `llm_memory.md` in your project root. It is prepended to the system prompt on
every request, giving the model persistent knowledge about your codebase across
sessions.

```
:LLMMemoryEdit   open / create llm_memory.md in a split
:LLMMemoryPath   print the full path to the file
```

Example `llm_memory.md`:

```markdown
# Project: MyApp
- Language: TypeScript + React
- State management: Zustand
- API: REST, base URL /api/v1
- Key files: src/store.ts, src/api/client.ts
- Conventions: camelCase vars, PascalCase components
- Do not suggest class components
```

Commands Reference
------------------

| Command            | Description |
|--------------------|-------------|
| `:LLMAgent`        | Run the tool-using agent, e.g. `:LLMAgent provider=ollama find the bug in X` |
| `:LLMAgentResume`  | Pick a saved agent session and continue the conversation |
| `:LLMInvoke`       | Generic invoker, e.g. `:LLMInvoke provider=ollama mode=chat` |
| `:LLMCancel`       | Stop the running stream |
| `:LLMReset`        | Clear conversation state (incl. OpenAI response-ID chain) |
| `:LLMClear`        | Clear per-buffer chat history |
| `:LLMContextAdd`   | Toggle a buffer in/out of context |
| `:LLMContextClear` | Remove all context buffers |
| `:LLMContextList`  | List selected context buffers |
| `:LLMMemoryEdit`   | Open llm_memory.md in a split |
| `:LLMMemoryPath`   | Print path to the memory file |
| `:LLMDalle`        | Generate an image (visual selection = prompt) |
| `:checkhealth llm` | Verify curl, plenary, ripgrep, API keys, endpoints |

Configuration
-------------

Everything is configured through a single `require("llm").setup()` call. All keys are
optional — omitting any value keeps the built-in default.

```lua
require("llm").setup({

  -- ── Keymaps ─────────────────────────────────────────────────────────────
  default_keymaps = true,   -- register the <leader> maps documented above

  -- ── Models, endpoints, prompts ──────────────────────────────────────────
  constants = {
    models = {
      ollama    = "qwen3.6:latest",     -- any model you've pulled locally
      anthropic = "claude-haiku-4-5",
      openai    = "gpt-5.4-mini",
    },
    api_endpoints = {
      ollama    = "http://localhost:11434/api/chat", -- or your remote server
      anthropic = "https://api.anthropic.com/v1/messages",
      openai    = "https://api.openai.com/v1/responses",
    },
    prompts = {
      system_prompt    = "You are a helpful assistant. Be concise.",
      code_prompt      = "You are a code-replacement engine. Output ONLY raw source code — no markdown, no fences, no explanations.",
      code_instruction = "OUTPUT ONLY RAW CODE — no markdown fences, no backticks. Task:\n",
    },
    vars = {
      max_tokens       = nil,   -- per-provider default when nil (Anthropic: 16000)
      reasoning_effort = "low", -- OpenAI Responses API reasoning effort
    },
  },

  -- ── UI ──────────────────────────────────────────────────────────────────
  ui = {
    mode        = "inline",  -- "inline" | "float" | "split"
    throttle_ms = 20,        -- stream write batching interval in ms
  },

  -- ── Conversation memory ─────────────────────────────────────────────────
  memory = {
    enabled      = true,
    max_messages = 20,   -- conversation turns kept per buffer
  },

  -- ── Context picker ──────────────────────────────────────────────────────
  context = {
    max_buffer_bytes  = 200 * 1024,  -- skip buffers larger than this
    include_filetypes = nil,          -- allowlist e.g. { "lua", "ts", "py" }
  },

  -- ── Network ─────────────────────────────────────────────────────────────
  network = {
    max_time = 120,  -- curl --max-time (seconds)
    retry    = 2,    -- curl --retry count
  },

  -- ── Logging ─────────────────────────────────────────────────────────────
  logging = {
    enabled = false, -- or set LLM_LOG=1 in your environment
    redact  = true,  -- truncate prompts/responses in logs
  },

  -- ── Diff keymaps ────────────────────────────────────────────────────────
  keymaps = {
    diff_accept = "<leader>da",  -- confirm diff and write changes to file
    diff_reject = "<leader>dr",  -- discard diff, leave file unchanged
  },
})
```

Note: sampling parameters (`temperature`/`top_p`) are intentionally not configurable —
current Anthropic models reject them with a 400, and prompts steer better anyway.

Providers
---------

| Provider  | API                     | Auth env var        | Notes |
|-----------|-------------------------|---------------------|-------|
| Ollama    | Chat API (JSONL stream) | none                | Default `http://localhost:11434/api/chat`; point `constants.api_endpoints.ollama` at any remote server |
| Anthropic | Messages API (SSE)      | `ANTHROPIC_API_KEY` | Default model `claude-haiku-4-5` |
| OpenAI    | Responses API (SSE)     | `OPENAI_API_KEY`    | Multi-turn via `previous_response_id` |

Architecture
------------

```
lua/llm/
  init.lua           Streaming engine, provider builders/handlers, diff mode, setup(), user commands
  agent.lua          Agent loop: request building, tool round-trips, review gating, curl transport, panel
  edit/
    apply.lua        Pending edits: str_replace compute, staleness guard, diff review, apply
  chat/
    persist.lua      Session save/load/list (stdpath data)/llm/sessions
  tools/
    init.lua         Tool registry: schemas per provider, policy (bash never allow-able), safe dispatch
    read_file.lua    Line-numbered reads (buffer-aware), range + byte caps
    list_files.lua   rg --files listing with glob filtering
    grep.lua         rg --vimgrep search (plain grep fallback)
    edit_file.lua    Exact-string replacement → pending edit for review
    write_file.lua   Create/overwrite a whole file → pending edit for review
    bash.lua         Shell command, confirm-gated on every call
  util/
    fs.lua           Path confinement (root escape/symlink/secret-file guards), globs
    proc.lua         vim.system wrapper for tool subprocesses
  provider.lua       Factory: invoke / code / code_chat / code_diff wrappers
  ollama.lua         Ollama provider instance
  anthropic.lua      Anthropic provider instance
  openai.lua         OpenAI provider instance
  stream.lua         SSE/JSONL parsers + normalized stream events (text/tool_call/stop)
  memory.lua         Per-buffer conversation history (role-alternation safe)
  project_memory.lua Loads llm_memory.md and injects it into the system prompt
  context_picker.lua vim.ui.select picker for per-request buffer selection
  utils.lua          Prompt builder, buffer collection, visual selection helpers
  ui.lua             Inline / float / split / diff output targets
  config.lua         Runtime configuration with defaults
  constants.lua      Default models, endpoints, prompts
  keymaps.lua        Optional built-in <leader> keymaps
  health.lua         :checkhealth llm
  log.lua            Optional JSONL logging with redaction
```

### Migrating from the old module names

Modules moved under the `llm.` namespace (they previously collided with any other
plugin shipping a top-level `utils.lua`/`memory.lua`). Old requires still work via
deprecation shims for now:

| Old                       | New                          |
|---------------------------|------------------------------|
| `require("openai")`       | `require("llm.openai")`      |
| `require("anthropic")`    | `require("llm.anthropic")`   |
| `require("ollama")`       | `require("llm.ollama")`      |
| `require("llm_config")`   | `require("llm.config")` — or just call `require("llm").setup()` |

Troubleshooting
---------------

Run `:checkhealth llm` first — it catches most of these.

| Symptom | Fix |
|---------|-----|
| Ollama not responding | Is `ollama serve` running? Check `constants.api_endpoints.ollama` |
| 401 / 403 | API key missing or wrong env var |
| 400 | Check model name is valid for the chosen provider |
| 429 | Rate limited — wait and retry |
| Response cut off | Notification says max_tokens reached — raise `constants.vars.max_tokens` |
| Stream stalls | Increase `network.max_time` |
| Diff split closes immediately | Stream failed — the notification includes the API's error message |
| Conversation out of sync | `:LLMReset` then `:LLMClear` |

Development
-----------

```sh
busted        # run tests (uses .busted config; passes on Lua 5.4 and LuaJIT)
luacheck .    # lint
stylua .      # format
```

CI runs luacheck + stylua and the busted suite on both Lua 5.4 and LuaJIT (the Lua
Neovim actually embeds).

Roadmap
-------

See `SPEC.md` — the plugin is being grown into a full in-editor agent (file
reading/search/edit tools with review gating, a dedicated chat panel, and
provider-agnostic tool calling).
