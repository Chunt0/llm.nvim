llm.nvim

Neovim plugin for streaming LLM responses directly into your editor. Supports OpenAI, Anthropic, and Ollama with inline editing, project-level memory, an interactive context picker, optional chat history, and DALL·E image generation.

Features
- Streaming responses into the current buffer or a float/split scratch buffer.
- Three providers: OpenAI (Responses API), Anthropic (Messages API), Ollama (Chat API).
- Project memory — write a `llm_memory.md` in your project root; it is injected into every request automatically.
- Context picker — interactively select open buffers to include in any prompt with `:LLMContextAdd`.
- Per-buffer conversation memory for code chat (optional, configurable).
- DALL·E image generation; saves images to disk and reports the file path.
- Opt-in logging with redaction to `stdpath('data')/llm/logs`.
- API keys passed via stdin (never exposed in process argv).

Quick Start (lazy.nvim)

Copy `local_config.lua.example` into your Neovim config as a plugin spec and adjust the settings. The example is self-contained — no extra files needed.

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

      -- Pick your models
      constants.models.openai    = "gpt-4o-mini"
      constants.models.anthropic = "claude-haiku-4-5-20251001"
      constants.models.ollama    = "gemma4:26b"

      -- Optional: override system/code prompts
      -- constants.prompts.system_prompt = "You are a helpful assistant."

      -- Optional: tune generation parameters
      -- constants.vars.temp = 0.7

      -- OpenAI
      vim.keymap.set({ "n", "v" }, "<leader>oi", openai.invoke,            { desc = "LLM OpenAI: Invoke" })
      vim.keymap.set({ "n", "v" }, "<leader>oc", openai.code,              { desc = "LLM OpenAI: Code" })
      vim.keymap.set({ "n", "v" }, "<leader>ot", openai.code_chat,         { desc = "LLM OpenAI: Code chat" })
      vim.keymap.set({ "n", "v" }, "<leader>oa", openai.code_chat_all_buf, { desc = "LLM OpenAI: Code chat (all buffers)" })

      -- Anthropic
      vim.keymap.set({ "n", "v" }, "<leader>ai", anthropic.invoke,            { desc = "LLM Anthropic: Invoke" })
      vim.keymap.set({ "n", "v" }, "<leader>ac", anthropic.code,              { desc = "LLM Anthropic: Code" })
      vim.keymap.set({ "n", "v" }, "<leader>at", anthropic.code_chat,         { desc = "LLM Anthropic: Code chat" })
      vim.keymap.set({ "n", "v" }, "<leader>aa", anthropic.code_chat_all_buf, { desc = "LLM Anthropic: Code chat (all buffers)" })

      -- Ollama
      vim.keymap.set({ "n", "v" }, "<leader>li", ollama.invoke,            { desc = "LLM Ollama: Invoke" })
      vim.keymap.set({ "n", "v" }, "<leader>lc", ollama.code,              { desc = "LLM Ollama: Code" })
      vim.keymap.set({ "n", "v" }, "<leader>lt", ollama.code_chat,         { desc = "LLM Ollama: Code chat" })
      vim.keymap.set({ "n", "v" }, "<leader>la", ollama.code_chat_all_buf, { desc = "LLM Ollama: Code chat (all buffers)" })

      -- Context picker
      vim.keymap.set({ "n", "v" }, "<leader>zc", "<cmd>LLMContextAdd<CR>",   { desc = "LLM: Toggle buffer in context" })
      vim.keymap.set("n",          "<leader>zx", "<cmd>LLMContextClear<CR>", { desc = "LLM: Clear context buffers" })
      vim.keymap.set("n",          "<leader>zl", "<cmd>LLMContextList<CR>",  { desc = "LLM: List context buffers" })

      -- Project memory
      vim.keymap.set("n", "<leader>zm", "<cmd>LLMMemoryEdit<CR>", { desc = "LLM: Edit llm_memory.md" })

      -- Reset OpenAI conversation state
      vim.keymap.set({ "n", "v" }, "<leader>zz", llm.reset_message_buffers, { desc = "LLM: Reset message buffers" })
    end,
  },
}
```

Environment Variables

Set API keys as environment variables before starting Neovim:
```
export OPENAI_API_KEY="..."
export ANTHROPIC_API_KEY="..."
```

Ollama requires no API key. Its endpoint is configured in `constants.api_endpoints.ollama`.

Providers

| Provider  | API style               | Auth env var        |
|-----------|-------------------------|---------------------|
| OpenAI    | Responses API (SSE)     | `OPENAI_API_KEY`    |
| Anthropic | Messages API (SSE)      | `ANTHROPIC_API_KEY` |
| Ollama    | Chat API (JSONL stream) | none                |

Operation Modes

Every provider exposes five functions that map to the same set of keymaps:

| Function            | What it does                                                         |
|---------------------|----------------------------------------------------------------------|
| `invoke`            | Single answer, no memory. Writes response after the selection.       |
| `code`              | Replaces the visual selection with generated code.                   |
| `code_all_buf`      | Same as `code`, but all open buffers are sent as context.            |
| `code_chat`         | Stateful chat with per-buffer conversation memory.                   |
| `code_chat_all_buf` | Same as `code_chat`, plus all open buffers as context.               |

For all modes, you must first select your prompt in visual mode.

Project Memory

Create a file called `llm_memory.md` in your project root. Its contents are prepended to the system prompt on every request, giving the LLM persistent knowledge about your codebase.

```
:LLMMemoryEdit   open / create llm_memory.md in a horizontal split
:LLMMemoryPath   print the full path to the memory file
```

Example `llm_memory.md`:
```markdown
# Project: MyApp
- Language: TypeScript + React
- State management: Zustand
- API: REST, base URL /api/v1
- Key files: src/store.ts, src/api/client.ts
- Conventions: camelCase vars, PascalCase components
```

A template `llm_memory.md` is included in this repo as a starting point.

Context Picker

Selectively inject open buffers into the LLM prompt using an interactive picker.

```
:LLMContextAdd    open picker — select/deselect buffers ([x] = selected)
:LLMContextClear  remove all context buffers
:LLMContextList   show which buffers are currently selected
```

Selected buffers are included in **all** operation modes:
- `code` / `code_all_buf` — prepended as `# Code Context:` before the instruction
- `invoke` — prepended as `# Code Context:` before the question
- `code_chat` / `code_chat_all_buf` — prepended before any all-buffers context

The picker works with the built-in `vim.ui.select`. If you have Telescope installed with `telescope-ui-select.nvim`, it will use that automatically.

Commands Reference

| Command                              | Description                                    |
|--------------------------------------|------------------------------------------------|
| `:LLMInvoke provider=X mode=Y`       | Invoke provider (openai\|anthropic\|ollama)    |
| `:LLMCancel`                         | Stop the running stream                        |
| `:LLMReset`                          | Clear OpenAI conversation state                |
| `:LLMClear`                          | Clear per-buffer conversation memory           |
| `:LLMDalle`                          | Generate an image (selection = prompt)         |
| `:LLMMemoryEdit`                     | Open llm_memory.md in a split                 |
| `:LLMMemoryPath`                     | Print path to the memory file                  |
| `:LLMContextAdd`                     | Toggle a buffer in/out of LLM context          |
| `:LLMContextClear`                   | Remove all context buffers                     |
| `:LLMContextList`                    | List currently selected context buffers        |

Configuration

Use `require('llm_config').setup{ ... }` for runtime options. Model names, prompts, and vars are changed by overriding `constants` fields directly (see the example config).

```lua
require("llm_config").setup({
  ui = {
    mode = "inline",      -- "inline" | "float" | "split"
    throttle_ms = 20,     -- stream write batching interval (ms)
  },
  memory = {
    enabled = true,
    max_messages = 20,    -- conversation turns kept per buffer
  },
  context = {
    max_buffer_bytes = 200 * 1024,   -- skip buffers larger than this
    include_filetypes = nil,          -- e.g. { "lua", "ts", "py" } to allowlist
  },
  network = {
    max_time = 120,   -- curl --max-time (seconds)
    retry = 2,        -- curl --retry count
  },
  logging = {
    enabled = false,  -- or set LLM_LOG=1 in environment
    redact = true,    -- truncate user/assistant text in logs
  },
})
```

Code Architecture

```
lua/
  llm.lua            Core streaming engine, all provider API implementations,
                     all user commands.
  provider.lua       Factory — generates invoke/code/code_chat wrappers.
  openai.lua         OpenAI provider (uses provider factory + extras).
  anthropic.lua      Anthropic provider.
  ollama.lua         Ollama provider.
  project_memory.lua Loads llm_memory.md and supplies it to the engine.
  context_picker.lua vim.ui.select picker for per-request buffer selection.
  utils.lua          Prompt builder, buffer collection, context injection.
  memory.lua         Per-buffer session conversation history.
  stream.lua         SSE and JSONL stream parsers.
  ui.lua             Inline / float / split output target selection.
  llm_config.lua     Runtime configuration with defaults.
  constants.lua      Default models, endpoints, prompts, vars.
  log.lua            Optional JSON logging with redaction.
```

Logging and Privacy
- Logging is disabled by default; enable with `LLM_LOG=1` or `logging.enabled = true`.
- Logs are written to `stdpath('data')/llm/logs/{YYYY-MM-DD}.json`.
- With `redact = true` (default), user prompts are omitted and assistant responses are truncated.
- API keys are passed to curl via stdin (`curl -K -`) and never appear in process argv.

Troubleshooting

| Symptom                | Cause / Fix                                               |
|------------------------|-----------------------------------------------------------|
| 401 / 403              | API key missing or wrong env var name                     |
| 429                    | Rate limited — wait and retry                             |
| 5xx                    | Provider outage — retry after a short delay               |
| Stream stalls          | Increase `network.max_time` or use a shorter prompt       |
| Ollama not responding  | Verify the endpoint in `constants.api_endpoints.ollama`   |
| No prompt sent         | You must highlight text in visual mode before invoking    |

Development
- Lint: `luacheck .`
- Format: `stylua .`
- Tests: `busted -v`

See also
- `local_config.lua.example` — full annotated configuration example
- `llm_memory.md` — project memory template
- `docs/recipes.md` — usage recipes
- `CONTRIBUTING.md` — development guidelines
