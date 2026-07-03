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

- Let the Model Explore the Project Itself (agent)
  - `:LLMAgent where does the Esc keymap get cleaned up?` (or `<leader>zg`)
  - The model greps, lists, and reads files on its own — each call shows as a
    `▸ tool(...)` card in the panel; `Esc` in the panel cancels
  - Pin a provider per run: `:LLMAgent provider=anthropic summarize the streaming layer`

- Answer Questions About an Unfamiliar Codebase
  - Open the repo, run `:LLMAgent how does X reach Y?` — the agent is confined
    to the project root, so it is safe to point at anything

- Let the Agent Fix Something (with review)
  - `:LLMAgent rename get_visual_info to get_selection_info everywhere`
  - Each proposed change opens as a native diff: `<leader>da` accepts (applies
    to the buffer — you still `:w`), `<leader>dr` rejects with an optional
    reason the model sees
  - Shell commands (`bash` tool) always show the exact command and wait for
    your confirmation; disable entirely with
    `tools = { policy = { bash = "disabled" } }`

- Point at a Remote Ollama Server
  - `require("llm").setup({ constants = { api_endpoints = { ollama = "https://my-server.example.com/api/chat" } } })`
