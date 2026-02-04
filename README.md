llm.nvim

Neovim plugin for streaming LLM responses directly into your editor. It supports multiple providers (OpenAI, Groq, Anthropic, Perplexity, Ollama), inline editing, optional chat memory, and image generation with DALL·E.

Features
- Streaming responses into the current buffer or a float/split scratch buffer.
- Provider wrappers for OpenAI (Responses), Groq, Anthropic, Perplexity, and Ollama.
- DALL·E image generation; saves images to disk and reports the file path.
- Per-buffer conversation memory for code chat (optional, configurable).
- Log redaction and opt-in logging to stdpath data directory.

Quick Start (lazy.nvim)
```lua
return {
  {
    "Chunt0/llm.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      local groq = require("groq")
      local openai = require("openai")
      local anthropic = require("anthropic")
      local perplexity = require("perplexity")
      local ollama = require("ollama")

      -- Optional config
      require("llm_config").setup({
        ui = { mode = "inline", throttle_ms = 20 },
        memory = { enabled = true, max_messages = 20 },
        context = { max_buffer_bytes = 200 * 1024 },
        logging = { enabled = false, redact = true },
        network = { max_time = 120, retry = 2 },
      })

      -- Example keymaps
      vim.keymap.set({ "n", "v" }, "<leader>J", groq.invoke, { desc = "llm groq" })
      vim.keymap.set({ "n", "v" }, "<leader>K", anthropic.invoke, { desc = "llm anthropic" })
      vim.keymap.set({ "n", "v" }, "<leader>L", openai.invoke, { desc = "llm openai" })
      vim.keymap.set({ "n", "v" }, "<leader>P", perplexity.invoke, { desc = "llm perplexity" })
      vim.keymap.set({ "n", "v" }, "<leader>O", ollama.invoke, { desc = "llm ollama" })
    end,
  },
}
```

Environment Variables
Set API keys as environment variables:
```
export OPENAI_API_KEY="..."
export GROQ_API_KEY="..."
export ANTHROPIC_API_KEY="..."
export PERPLEXITY_API_KEY="..."
```

If you only have some keys, the others will just not work for their providers.

How It Works (Important Code Paths)
- Core streaming engine: `lua/llm.lua`
  - Builds provider-specific curl requests.
  - Streams and parses responses (SSE/JSONL).
  - Inserts content at a stream anchor in the target buffer.
  - Handles cancel/reset and logging.
- Provider wrappers: `lua/openai.lua`, `lua/groq.lua`, `lua/anthropic.lua`, `lua/perplexity.lua`, `lua/ollama.lua`
  - Small wrappers for invoking provider-specific handlers.
- Stream parser helpers: `lua/stream.lua`
  - SSE and JSONL parsing utilities.
- UI targets: `lua/ui.lua`
  - Inline, float, or split buffers for output.
- Conversation memory: `lua/memory.lua`
  - Per-buffer chat history for `code_chat`.
- Configuration: `lua/llm_config.lua`

Commands
- `:LLMInvoke provider=<openai|groq|anthropic|perplexity|ollama> mode=<invoke|code|chat>`
- `:LLMCancel` to stop a running stream
- `:LLMReset` to clear internal buffers
- `:LLMClear` to clear per-buffer conversation memory
- `:LLMDalle` to generate an image (uses visual selection as prompt)

Configuration
Use `require('llm_config').setup{ ... }`.

Options:
- ui.mode: `"inline" | "float" | "split"`
- ui.throttle_ms: delay for batching stream writes
- memory.enabled: enable per-buffer memory (used in code_chat)
- memory.max_messages: limit stored messages per buffer
- context.max_buffer_bytes: max size for a buffer to be included in context
- context.include_filetypes: allowlist of filetypes
- logging.enabled: opt-in logging
- logging.redact: redact user/assistant text
- logging.dir: override log directory
- network.max_time: curl max time
- network.retry: curl retry count

Usage Patterns
- Invoke (single answer)
  - Select your prompt in visual mode, then run a provider's `invoke` or use `:LLMInvoke`.
- Code replace
  - Select code in visual mode, run `mode=code` to replace the selection with the model output.
- Code chat
  - Select a question and run `mode=chat` for context-aware answers. Memory is enabled by default.
- DALL·E
  - Select an image prompt and run `:LLMDalle`.

Logging and Privacy
- Logging is disabled by default.
- Enable by setting `LLM_LOG=1` or `logging.enabled = true` in config.
- Logs are written under `stdpath('data')/llm/logs` and redacted by default.

Security Notes
- API keys are passed to curl via stdin (`curl -K -`) to keep them out of process argv.
- Avoid committing keys in config files or scripts.

Troubleshooting
- 401/403: API key missing or invalid.
- 429: Rate limited; try again later.
- 5xx: Provider error; retry after a short delay.
- If streaming stalls, try increasing `network.max_time` or using a smaller prompt.

Development
- Lint: `luacheck .`
- Format: `stylua .`
- Tests: `busted -v`

See also
- `docs/recipes.md` for usage examples
- `CONTRIBUTING.md` for development guidelines
