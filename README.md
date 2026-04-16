llm.nvim
========

Neovim plugin for streaming LLM responses directly into your editor. Supports OpenAI, Anthropic, and Ollama with inline editing, multi-turn chat, a diff-preview replace mode, project-level memory, and an interactive context picker.

Features
--------
- Token-by-token streaming into the current buffer
- Three providers: OpenAI (Responses API), Anthropic (Messages API), Ollama (Chat API)
- Multi-turn code chat with per-buffer conversation history
- **Diff mode** — proposed code change shown in a split; accept or reject before touching your file
- Project memory — `llm_memory.md` auto-injected into every request
- Context picker — interactively choose which open buffers to include
- No visual selection required for chat/invoke — falls back to a typed prompt
- `Esc` cancels any running stream
- API keys passed to curl via stdin (never in process argv)
- Optional JSONL logging with redaction

Quick Start (lazy.nvim)
-----------------------

Copy `local_config.lua.example` into your Neovim config as a plugin spec and edit it.

```lua
return {
  {
    "Chunt0/llm.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      local llm       = require("llm")
      local openai    = require("openai")
      local anthropic = require("anthropic")
      local ollama    = require("ollama")
      local constants = require("constants")

      constants.models.openai    = "gpt-4o-mini"
      constants.models.anthropic = "claude-haiku-4-5-20251001"
      constants.models.ollama    = "gemma4:26b"

      -- OpenAI
      vim.keymap.set({ "n", "v" }, "<leader>oi", openai.invoke,            { desc = "LLM OpenAI: Invoke" })
      vim.keymap.set({ "n", "v" }, "<leader>oc", openai.code,              { desc = "LLM OpenAI: Code (replace)" })
      vim.keymap.set({ "n", "v" }, "<leader>ob", openai.code_all_buf,      { desc = "LLM OpenAI: Code (all buffers)" })
      vim.keymap.set({ "n", "v" }, "<leader>ot", openai.code_chat,         { desc = "LLM OpenAI: Code chat" })
      vim.keymap.set({ "n", "v" }, "<leader>oa", openai.code_chat_all_buf, { desc = "LLM OpenAI: Code chat (all buffers)" })
      vim.keymap.set("v",          "<leader>od", openai.code_diff,         { desc = "LLM OpenAI: Code diff" })

      -- Anthropic
      vim.keymap.set({ "n", "v" }, "<leader>ai", anthropic.invoke,            { desc = "LLM Anthropic: Invoke" })
      vim.keymap.set({ "n", "v" }, "<leader>ac", anthropic.code,              { desc = "LLM Anthropic: Code (replace)" })
      vim.keymap.set({ "n", "v" }, "<leader>ab", anthropic.code_all_buf,      { desc = "LLM Anthropic: Code (all buffers)" })
      vim.keymap.set({ "n", "v" }, "<leader>at", anthropic.code_chat,         { desc = "LLM Anthropic: Code chat" })
      vim.keymap.set({ "n", "v" }, "<leader>aa", anthropic.code_chat_all_buf, { desc = "LLM Anthropic: Code chat (all buffers)" })
      vim.keymap.set("v",          "<leader>ad", anthropic.code_diff,         { desc = "LLM Anthropic: Code diff" })

      -- Ollama
      vim.keymap.set({ "n", "v" }, "<leader>li", ollama.invoke,            { desc = "LLM Ollama: Invoke" })
      vim.keymap.set({ "n", "v" }, "<leader>lc", ollama.code,              { desc = "LLM Ollama: Code (replace)" })
      vim.keymap.set({ "n", "v" }, "<leader>lb", ollama.code_all_buf,      { desc = "LLM Ollama: Code (all buffers)" })
      vim.keymap.set({ "n", "v" }, "<leader>lt", ollama.code_chat,         { desc = "LLM Ollama: Code chat" })
      vim.keymap.set({ "n", "v" }, "<leader>la", ollama.code_chat_all_buf, { desc = "LLM Ollama: Code chat (all buffers)" })
      vim.keymap.set("v",          "<leader>ld", ollama.code_diff,         { desc = "LLM Ollama: Code diff" })

      -- Shared controls
      vim.keymap.set({ "n", "v" }, "<leader>zz", llm.reset_message_buffers, { desc = "LLM: Reset conversation" })
      vim.keymap.set({ "n", "v" }, "<leader>zc", "<cmd>LLMContextAdd<CR>",  { desc = "LLM: Toggle buffer in context" })
      vim.keymap.set("n",          "<leader>zx", "<cmd>LLMContextClear<CR>",{ desc = "LLM: Clear context buffers" })
      vim.keymap.set("n",          "<leader>zl", "<cmd>LLMContextList<CR>", { desc = "LLM: List context buffers" })
      vim.keymap.set("n",          "<leader>zm", "<cmd>LLMMemoryEdit<CR>",  { desc = "LLM: Edit llm_memory.md" })

      -- Diff accept / reject (active only while a diff split is open)
      require("llm_config").setup({
        keymaps = {
          diff_accept = "<leader>da",
          diff_reject = "<leader>dr",
        },
      })
    end,
  },
}
```

Environment Variables
---------------------

```sh
export OPENAI_API_KEY="sk-..."
export ANTHROPIC_API_KEY="sk-ant-..."
```

Ollama requires no API key. Its endpoint is set in `constants.api_endpoints.ollama`.

Operation Modes
---------------

Every provider exposes six functions:

| Mode                | Key (example) | What it does |
|---------------------|---------------|--------------|
| `invoke`            | `<leader>oi`  | Single-turn Q&A. Streams the answer after your text. No history. |
| `code`              | `<leader>oc`  | Replaces the visual selection with generated code immediately. |
| `code_all_buf`      | `<leader>ob`  | Same as `code`, but every open buffer is sent as context. |
| `code_chat`         | `<leader>ot`  | Multi-turn chat with per-buffer conversation memory. |
| `code_chat_all_buf` | `<leader>oa`  | Same as `code_chat`, plus all open buffers as context. |
| `code_diff`         | `<leader>od`  | Proposed replacement shown in a diff split — accept or reject before anything changes. |

For `invoke`, `code_chat`, and `code_chat_all_buf` a visual selection is optional — if nothing is selected the plugin prompts for input at the bottom of the screen. `code`, `code_all_buf`, and `code_diff` always require a visual selection (they need to know which code to work on).

Code Diff Mode
--------------

`code_diff` is the safest way to use code generation — your file is never modified until you explicitly accept the result.

### How it works

1. **Select code** in visual mode (select a function, block, or any lines).
2. **Invoke** (e.g. `<leader>ld` for Ollama). The plugin records the selection without touching your file.
3. A **vertical split** opens to the right. The LLM streams its replacement into the right pane while your original code stays untouched on the left.
4. When streaming finishes, Neovim's native **diff highlighting** activates — changed lines are highlighted, identical context is shown for reference.
5. Review the diff, then:
   - **`<leader>da`** — accept. The new lines are written into your file, the split closes, cursor lands at the change.
   - **`<leader>dr`** — reject. The split closes. Your file is completely unchanged.
   - **`Esc`** — cancel mid-stream. The split closes before diff mode even activates.

If you close the split manually (`:q`), diff mode and the keybinds are cleaned up automatically.

The accept/reject keys are configurable — see the Configuration section.

Code Chat — Multi-turn Conversations
-------------------------------------

`code_chat` and `code_chat_all_buf` keep a running conversation history tied to the current buffer so the model remembers what you discussed.

### How it works

1. **Write your question** anywhere in the buffer, or select it in visual mode, or invoke with nothing selected and type it at the prompt.
2. **Invoke** (e.g. `<leader>ot`). The response streams in immediately after your text.
3. When the stream finishes a separator is inserted:
   ```
   ---------------------------User---------------------------

   ```
4. **Type your follow-up** below the separator and invoke again.
5. The model receives the full conversation so far on every request.

### Cancelling a stream

Press `Esc` at any time to stop the running stream mid-response.

### Resetting the conversation

History is per-buffer and persists until you reset it:

```
:LLMReset           clear OpenAI conversation state (response IDs)
:LLMClear           clear per-buffer chat history for the current buffer
<leader>zz          reset all conversation state (keymap)
```

Use `:LLMClear` to start a fresh conversation in the same buffer. Use `:LLMReset` when switching tasks with OpenAI (clears the `previous_response_id` chain).

### History limit

The plugin keeps the last `max_messages` turns in memory (default 20). Older turns are dropped automatically.

```lua
require("llm_config").setup({ memory = { max_messages = 40 } })
```

Code Mode (direct replace)
---------------------------

`code` and `code_all_buf` **replace** the visual selection with the model's output immediately. Use this for quick, low-stakes edits where you're comfortable undoing with `u` if the result isn't right. For anything you want to review first, prefer `code_diff`.

- Refactor a function: select it, invoke, the new version replaces the old
- Fill in a stub: write a comment describing what you want, select it, invoke
- Translate or reformat a block of code in place

Context Picker
--------------

Selectively inject open buffers into any prompt without switching to `code_all_buf`.

```
:LLMContextAdd    open picker — toggle buffers with Enter, [x] = selected
:LLMContextClear  deselect all buffers
:LLMContextList   show which buffers are currently selected
```

Selected buffers are prepended to the prompt in every mode as a `# Code Context:` block. The picker shows only normal file buffers (terminals and scratch buffers are excluded). It uses `vim.ui.select` and works with Telescope (`telescope-ui-select.nvim`) automatically.

Project Memory
--------------

Create `llm_memory.md` in your project root. It is prepended to the system prompt on every request, giving the model persistent knowledge about your codebase across sessions.

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
| `:LLMCancel`       | Stop the running stream |
| `:LLMReset`        | Clear OpenAI conversation state (response ID chain) |
| `:LLMClear`        | Clear per-buffer chat history |
| `:LLMContextAdd`   | Toggle a buffer in/out of context |
| `:LLMContextClear` | Remove all context buffers |
| `:LLMContextList`  | List selected context buffers |
| `:LLMMemoryEdit`   | Open llm_memory.md in a split |
| `:LLMMemoryPath`   | Print path to the memory file |
| `:LLMDalle`        | Generate an image (visual selection = prompt) |

Configuration
-------------

```lua
require("llm_config").setup({
  ui = {
    mode = "inline",     -- "inline" | "float" | "split"
    throttle_ms = 20,    -- stream write batching interval in ms
  },
  memory = {
    enabled = true,
    max_messages = 20,   -- conversation turns kept per buffer
  },
  context = {
    max_buffer_bytes = 200 * 1024,  -- skip buffers larger than this
    include_filetypes = nil,         -- allowlist e.g. { "lua", "ts", "py" }
  },
  network = {
    max_time = 120,  -- curl --max-time (seconds)
    retry = 2,       -- curl --retry count
  },
  logging = {
    enabled = false, -- or set LLM_LOG=1 in your environment
    redact = true,   -- truncate prompts/responses in logs
  },
  keymaps = {
    diff_accept = "<leader>da",  -- confirm diff and write changes to file
    diff_reject = "<leader>dr",  -- discard diff, leave file unchanged
  },
})
```

Model names, prompts, and generation parameters are set directly on the `constants` table:

```lua
local constants = require("constants")
constants.models.openai            = "gpt-4o-mini"
constants.models.anthropic         = "claude-haiku-4-5-20251001"
constants.models.ollama            = "gemma4:26b"
constants.prompts.system_prompt    = "You are a helpful assistant. Be concise."
constants.prompts.code_prompt      = "Only output valid code. No explanations."
constants.vars.temp                = 0.7
```

Providers
---------

| Provider  | API                     | Auth env var        | Notes |
|-----------|-------------------------|---------------------|-------|
| OpenAI    | Responses API (SSE)     | `OPENAI_API_KEY`    | Multi-turn via `previous_response_id` |
| Anthropic | Messages API (SSE)      | `ANTHROPIC_API_KEY` | |
| Ollama    | Chat API (JSONL stream) | none                | Endpoint: `constants.api_endpoints.ollama` |

Architecture
------------

```
lua/
  llm.lua            Streaming engine, provider builders/handlers, diff mode, user commands
  provider.lua       Factory: invoke / code / code_chat / code_diff wrappers
  openai.lua         OpenAI provider instance
  anthropic.lua      Anthropic provider instance
  ollama.lua         Ollama provider instance
  stream.lua         SSE and JSONL stream parsers
  memory.lua         Per-buffer conversation history
  project_memory.lua Loads llm_memory.md and injects it into the system prompt
  context_picker.lua vim.ui.select picker for per-request buffer selection
  utils.lua          Prompt builder, buffer collection, visual selection helpers
  ui.lua             Inline / float / split / diff output targets
  llm_config.lua     Runtime configuration with defaults
  constants.lua      Default models, endpoints, prompts, generation vars
  log.lua            Optional JSONL logging with redaction
```

Troubleshooting
---------------

| Symptom | Fix |
|---------|-----|
| 401 / 403 | API key missing or wrong env var |
| 400 | Check model name is valid for the chosen provider |
| 429 | Rate limited — wait and retry |
| Stream stalls | Increase `network.max_time` |
| Diff split closes immediately | Stream failed — check the error notification for the curl exit code |
| Ollama not responding | Check `constants.api_endpoints.ollama` |
| Conversation out of sync | `:LLMReset` then `:LLMClear` |

Development
-----------

```sh
busted        # run tests (uses .busted config)
luacheck .    # lint
stylua .      # format
```
