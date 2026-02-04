TODOs to make this codebase clean and efficient

This file collects prioritized, actionable tasks discovered by a quick codebase audit. Start with the Critical items, then address High, Medium, and Low priorities. Each item lists affected files, priority and an estimated effort.

---

Critical
-
- Implement missing llm handler functions for each framework (critical — large)
  Description: Add implementations (or a unified adapter) for the make_XXX_spec_curl_args and handle_XXX_spec_data functions referenced by the per-framework wrapper modules (ollama, anthropic, groq, perplexity, openai/dalle, etc.). Define and document a stable llm core API contract so wrappers don't assume missing symbols.
  Affected files: `lua/llm.lua`, `lua/ollama.lua`, `lua/anthropic.lua`, `lua/groq.lua`, `lua/perplexity.lua`, `lua/openai.lua`

- Fix Perplexity model reference bug (critical — small)
  Description: Normalize constants naming so `perplexity.lua` references `constants.models.perplexity` (or change `constants.lua` to match). This prevents nil model values at runtime.
  Affected files: `lua/perplexity.lua`, `lua/constants.lua`

- Correct and harden file exclusion logic (critical — medium)
  Description: Rewrite `utils.should_include_file` to compare basenames for filename exclusions, correctly handle explicit filenames in excluded lists (e.g., `package-lock.json`), and add unit tests for edge cases. Add size/type guards before including buffer content.
  Affected files: `lua/utils.lua`, `lua/constants.lua`

- Remove tracked backup files (critical — small)
  Description: Remove or move `llm.lua.backup*` files from `lua/` (they duplicate functionality and increase repo noise). Keep a single canonical `lua/llm.lua`.
  Affected files: `lua/llm.lua.backup1`, `lua/llm.lua.backup.responses`

High
-
- Harden logging (high — small)
  Description: Wrap JSON decode/read operations in `pcall` to handle corrupt log files without crashing. Replace `os.execute('mkdir -p')` with a safer approach and report errors with `vim.notify` when appropriate.
  Affected files: `lua/log.lua`

- Avoid storing sensitive prompts raw in logs (high — small)
  Description: Add an opt-in logging flag and/or redact user prompts/assistant content before writing logs. Document log location and privacy implications in README.
  Affected files: `lua/log.lua`, `README.md`

- Stop overriding global `<Esc>` mapping (high — small)
  Description: Replace global `vim.api.nvim_set_keymap('n','<Esc>',...)` with a buffer-local mapping or a less intrusive cancel flow. Document the behavior.
  Affected files: `lua/llm.lua`

- Add tests and CI (high — large)
  Description: Add a test harness (for example, `busted`), unit tests for `utils` and core llm behaviors, and a GitHub Actions workflow to run tests and linters on PRs.
  Affected files: repo root (new `tests/`, `.github/workflows/`)

Medium
-
- Introduce linting and formatting (medium — medium)
  Description: Add `stylua` and/or `luacheck` configs and a CI lint job. Add pre-commit hooks if desired.
  Affected files: repository config files

- Refactor duplicated framework wrappers into a generic factory (medium — large)
  Description: Consolidate repetitive wrapper modules (`openai.lua`, `anthropic.lua`, `groq.lua`, `ollama.lua`, `perplexity.lua`) into a small registration/factory system to reduce duplication and risk of drift.
  Affected files: `lua/openai.lua`, `lua/anthropic.lua`, `lua/groq.lua`, `lua/ollama.lua`, `lua/perplexity.lua`, `lua/llm.lua`

- Limit size of all-buffers text and guard `get_all_buffers_text` (medium — medium)
  Description: Add configurable max-size limits, filter by filetype, and/or sample large buffers instead of concatenating everything into a single prompt.
  Affected files: `lua/utils.lua`

Low
-
- Replace `print()` with `vim.notify()` and structured debug logging (low — small)
  Description: Use `vim.notify` for user-facing messages and configurable structured logging for debug output; make debug behavior conditional via settings.
  Affected files: `lua/llm.lua`, `lua/utils.lua`, `lua/log.lua`

- Optimize `trim_context` implementation (low — small)
  Description: Replace repeated `table.remove` loops with a slicing approach to avoid O(n^2) behavior on large contexts.
  Affected files: `lua/utils.lua`

- Document plugin configuration and security guidance (low — small)
  Description: Extend `README.md` with setup steps, required environment variables (API keys), supported Neovim versions, and security guidance about logs and key handling.
  Affected files: `README.md`

---

Suggested next steps
- Start by fixing Critical items in small commits: (1) Perplexity constant, (2) file-exclusion logic, (3) remove backup files, (4) implement or stub missing handlers so runtime errors stop.
- Add a minimal `busted` test for `utils.should_include_file` and `trim_context` before refactoring behavior.
- Add GitHub Actions workflow to run tests and linting for PRs.
- Consider a single follow-up PR to consolidate wrappers into a factory and add missing llm handler implementations.

If you'd like, I can: (1) commit this `TODO.md`, (2) open small PRs to fix the Critical items, or (3) scaffold tests+CI. Tell me which and I'll proceed.
