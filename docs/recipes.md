Recipes

- Replace Code (visual selection)
  - Select code in visual mode
  - Run your provider's `code` function (e.g. `<leader>lc`, or `:LLMInvoke provider=ollama mode=code`)
  - The replacement streams into a scratch split and is applied when it completes;
    a failed or cancelled request leaves your buffer untouched

- Review Before Applying
  - Select code in visual mode
  - Run `code_diff` (e.g. `<leader>ld`) — accept with `<leader>da`, reject with `<leader>dr`

- Chat With Context
  - Select your question in visual mode (or select nothing and type at the prompt)
  - Run `code_chat` (e.g. `<leader>lt`, or `:LLMInvoke provider=ollama mode=chat`)
  - Follow up below the inserted `User` separator and invoke again

- Ask About Specific Files
  - `:LLMContextAdd` to toggle buffers into the context, then use any mode —
    the selected files are prepended as a `# Code Context:` block

- Point at a Remote Ollama Server
  - `require("llm").setup({ constants = { api_endpoints = { ollama = "https://my-server.example.com/api/chat" } } })`
