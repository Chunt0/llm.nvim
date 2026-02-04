Recipes

- Replace Code (visual selection)
  - Select code in visual mode
  - Run your provider's `code` function (e.g., `:LLMInvoke provider=openai mode=code`)

- Chat With Context
  - Select question in visual mode
  - Run `mode=chat` to open a conversational reply inline or in your chosen UI mode

- Translate
  - Use provider-specific helpers (e.g., `openai.en2ch`) or set `prompts.en2ch_prompt` and run `mode=invoke`
