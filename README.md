llm.nvim
========

Neovim plugin for streaming LLM responses directly into your editor. Supports OpenAI, Anthropic, and Ollama with inline editing, multi-turn chat, project-level memory, and an interactive context picker.

Features
--------
- Token-by-token streaming into the current buffer
- Three providers: OpenAI (Responses API), Anthropic (Messages API), Ollama (Chat API)
- Multi-turn code chat with per-buffer conversation history
- Project memory — `llm_memory.md` is auto-injected into every request
- Context picker — interactively choose which open buffers to include
- `Esc` cancels any running stream
- API keys passed to curl via stdin (never in process argv)
- Optional JSON logging with redaction

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
      vim.keymap.set({ "n", "v" }, "<leader>oc", openai.code,              { desc = "LLM OpenAI: Code" })
      vim.keymap.set({ "n", "v" }, "<leader>ob", openai.code_all_buf,      { desc = "LLM OpenAI: Code (all buffers)" })
      vim.keymap.set({ "n", "v" }, "<leader>ot", openai.code_chat,         { desc = "LLM OpenAI: Code chat" })
      vim.keymap.set({ "n", "v" }, "<leader>oa", openai.code_chat_all_buf, { desc = "LLM OpenAI: Code chat (all buffers)" })

      -- Anthropic
      vim.keymap.set({ "n", "v" }, "<leader>ai", anthropic.invoke,            { desc = "LLM Anthropic: Invoke" })
      vim.keymap.set({ "n", "v" }, "<leader>ac", anthropic.code,              { desc = "LLM Anthropic: Code" })
      vim.keymap.set({ "n", "v" }, "<leader>ab", anthropic.code_all_buf,      { desc = "LLM Anthropic: Code (all buffers)" })
      vim.keymap.set({ "n", "v" }, "<leader>at", anthropic.code_chat,         { desc = "LLM Anthropic: Code chat" })
      vim.keymap.set({ "n", "v" }, "<leader>aa", anthropic.code_chat_all_buf, { desc = "LLM Anthropic: Code chat (all buffers)" })

      -- Ollama
      vim.keymap.set({ "n", "v" }, "<leader>li", ollama.invoke,            { desc = "LLM Ollama: Invoke" })
      vim.keymap.set({ "n", "v" }, "<leader>lc", ollama.code,              { desc = "LLM Ollama: Code" })
      vim.keymap.set({ "n", "v" }, "<leader>lb", ollama.code_all_buf,      { desc = "LLM Ollama: Code (all buffers)" })
      vim.keymap.set({ "n", "v" }, "<leader>lt", ollama.code_chat,         { desc = "LLM Ollama: Code chat" })
      vim.keymap.set({ "n", "v" }, "<leader>la", ollama.code_chat_all_buf, { desc = "LLM Ollama: Code chat (all buffers)" })

      -- Shared controls
      vim.keymap.set({ "n", "v" }, "<leader>zz", llm.reset_message_buffers, { desc = "LLM: Reset conversation" })
      vim.keymap.set({ "n", "v" }, "<leader>zc", "<cmd>LLMContextAdd<CR>",  { desc = "LLM: Toggle buffer in context" })
      vim.keymap.set("n",          "<leader>zx", "<cmd>LLMContextClear<CR>",{ desc = "LLM: Clear context buffers" })
      vim.keymap.set("n",          "<leader>zl", "<cmd>LLMContextList<CR>", { desc = "LLM: List context buffers" })
      vim.keymap.set("n",          "<leader>zm", "<cmd>LLMMemoryEdit<CR>",  { desc = "LLM: Edit llm_memory.md" })
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

Every provider exposes five functions:

| Mode                | Key (example) | What it does |
|---------------------|---------------|--------------|
| `invoke`            | `<leader>oi`  | Single-turn Q&A. Streams the answer after your selection. No history. |
| `code`              | `<leader>oc`  | Replaces the visual selection with generated code. |
| `code_all_buf`      | `<leader>ob`  | Same as `code`, but every open buffer is sent as context. |
| `code_chat`         | `<leader>ot`  | Multi-turn chat with per-buffer history. See below. |
| `code_chat_all_buf` | `<leader>oa`  | Same as `code_chat`, plus all open buffers as context. |

For all modes you must select your prompt in visual mode before invoking (or position the cursor on the line you want sent in normal mode).

Code Chat — Multi-turn Conversations
-------------------------------------

`code_chat` and `code_chat_all_buf` are the main workflows for getting code help. They keep a running conversation history tied to the current buffer so the model remembers what you discussed.

### How it works

1. **Write your question** anywhere in the buffer (or select it in visual mode).
2. **Invoke** (e.g. `<leader>ot`). The response streams in immediately after your text.
3. When the stream finishes a separator is inserted:
   ```
   ---------------------------User---------------------------

   ```
4. **Type your follow-up** below the separator line and invoke again.
5. The model receives the full conversation so far on every request.

### Example session

```
How do I read a file line by line in Python?
                                              ← invoke here
with open("file.txt") as f:
    for line in f:
        print(line.strip())

---------------------------User---------------------------

Can you add error handling for missing files?
                                              ← invoke again
try:
    with open("file.txt") as f:
        for line in f:
            print(line.strip())
except FileNotFoundError:
    print("File not found")

---------------------------User---------------------------

```

### Cancelling a stream

Press `Esc` at any time to stop the running stream mid-response.

### Resetting the conversation

History is per-buffer and persists until you reset it:

```
:LLMReset           clear OpenAI conversation state (response IDs)
:LLMClear           clear per-buffer chat history for the current buffer
<leader>zz          reset all conversation state (keymap)
```

Use `:LLMClear` when you want to start a fresh conversation in the same buffer without opening a new one. Use `:LLMReset` when switching tasks with OpenAI (clears the `previous_response_id` chain).

### History limit

The plugin keeps the last `max_messages` turns in memory (default 20). Older turns are dropped automatically. Configure with:

```lua
require("llm_config").setup({ memory = { max_messages = 40 } })
```

Code Mode (replace)
--------------------

`code` and `code_all_buf` work differently from chat — they **replace** the visual selection with the model's output rather than appending to the buffer. Use this to:

- Refactor a function: select it, invoke, the new version replaces the old
- Fill in a stub: write a comment describing what you want, select it, invoke
- Translate or reformat a block of code in place

The `code_prompt` (set in `constants.prompts.code_prompt`) instructs the model to output only valid code with no explanation.

Context Picker
--------------

Selectively inject open buffers into any prompt without having to switch to `code_all_buf`.

```
:LLMContextAdd    open picker — toggle buffers with Enter, [x] = selected
:LLMContextClear  deselect all buffers
:LLMContextList   show which buffers are currently selected
```

Selected buffers are prepended to the prompt in every mode as a `# Code Context:` block. The picker uses `vim.ui.select` and works with Telescope (`telescope-ui-select.nvim`) automatically.

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

| Command           | Description |
|-------------------|-------------|
| `:LLMCancel`      | Stop the running stream |
| `:LLMReset`       | Clear OpenAI conversation state (response ID chain) |
| `:LLMClear`       | Clear per-buffer chat history |
| `:LLMContextAdd`  | Toggle a buffer in/out of context |
| `:LLMContextClear`| Remove all context buffers |
| `:LLMContextList` | List selected context buffers |
| `:LLMMemoryEdit`  | Open llm_memory.md in a split |
| `:LLMMemoryPath`  | Print path to the memory file |
| `:LLMDalle`       | Generate an image (visual selection = prompt) |

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
    enabled = false, -- or set LLM_LOG=1
    redact = true,   -- truncate prompts/responses in logs
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
| OpenAI    | Responses API (SSE)     | `OPENAI_API_KEY`    | Supports multi-turn via `previous_response_id` |
| Anthropic | Messages API (SSE)      | `ANTHROPIC_API_KEY` | |
| Ollama    | Chat API (JSONL stream) | none                | Endpoint: `constants.api_endpoints.ollama` |

Architecture
------------

```
lua/
  llm.lua            Streaming engine, all provider builders/handlers, user commands
  provider.lua       Factory that generates invoke/code/code_chat wrappers
  openai.lua         OpenAI provider instance
  anthropic.lua      Anthropic provider instance
  ollama.lua         Ollama provider instance
  stream.lua         SSE and JSONL stream parsers
  memory.lua         Per-buffer conversation history
  project_memory.lua Loads llm_memory.md and injects it into the system prompt
  context_picker.lua vim.ui.select picker for per-request buffer selection
  utils.lua          Prompt builder, buffer collection, context injection
  ui.lua             Inline / float / split output target
  llm_config.lua     Runtime configuration with defaults
  constants.lua      Default models, endpoints, prompts, generation vars
  log.lua            Optional JSON logging with redaction
```

Troubleshooting
---------------

| Symptom | Fix |
|---------|-----|
| 401 / 403 | API key missing or wrong env var |
| 400 | Check model name is valid for the chosen provider |
| 429 | Rate limited — wait and retry |
| Stream stalls | Increase `network.max_time` |
| Nothing sent | You must have text selected or cursor on a non-empty line |
| Ollama not responding | Check `constants.api_endpoints.ollama` |
| Conversation out of sync | `:LLMReset` then `:LLMClear` |

Development
-----------

```sh
busted        # run tests (uses .busted config)
luacheck .    # lint
stylua .      # format
```
