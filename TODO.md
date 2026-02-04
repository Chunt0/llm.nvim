TODOs to make this tool better (v2)

Purpose: a prioritized, actionable plan to improve reliability, UX, security, performance, and maintainability. Start with Critical, then High, then the rest.

---

Critical
- Implement Real Provider Handlers (large)
  Why: Non-OpenAI calls are stubbed; enable full functionality.
  What: Implement make_/handle_ for Anthropic (messages SSE), Groq (OpenAI-compatible Chat Completions), Perplexity (chat completions, streaming), Ollama (JSON lines/stream). Implement DALL·E image generation; save images and emit file paths.
  Files: `lua/llm.lua`, `lua/*provider*.lua`, `lua/provider.lua`

- Provider Contract and Parser Abstraction (large)
  Why: Avoid one-off parsing per provider; reduce drift.
  What: Define ProviderSpec: auth builder, payload builder, curl args, stream parser (SSE/JSONL), error parser, end-of-stream hook. Extract common SSE/JSONL parsing into `lua/stream.lua`.
  Files: `lua/llm.lua`, `lua/provider.lua`, `lua/stream.lua` (new)

- Better Error Reporting (medium)
  Why: Users need clear errors and next steps.
  What: Detect 401/403/429/5xx from curl stderr/body; show actionable messages (missing key, rate limit, retry). Add `--max-time` and limited `--retry` with backoff.
  Files: `lua/llm.lua`

High
- Config Module and Setup API (medium)
  Why: Centralize defaults; let users configure in one place.
  What: `require('llm_config').setup{...}` for model defaults, logging, size limits, mappings, UI mode, etc. Read from it everywhere.
  Files: `lua/llm_config.lua` (new) + call sites

- Commands and Keymaps (medium)
  Why: Avoid implicit mappings; expose consistent UX.
  What: Add `:LLMInvoke`, `:LLMCode`, `:LLMChat`, `:LLMCancel`, `:LLMReset`, `:LLMDalle` with -provider/-model flags. Leave keymaps to user config in README.
  Files: `lua/llm.lua`, `README.md`

- Streaming UI Modes (medium)
  Why: Inline editing is great; floating/split can be better for chat.
  What: `ui.mode = 'inline'|'float'|'split'`; route stream to selected target. Provide minimal status (spinner, elapsed, token estimate).
  Files: `lua/llm.lua`, `lua/ui.lua` (new)

- Conversation Memory (medium)
  Why: Multi-turn chat with retained context per buffer.
  What: Maintain ring buffer {role,content} per buffer; `:LLMClear` to reset. Factor into provider payloads.
  Files: `lua/memory.lua` (new), `lua/llm.lua`, `lua/provider.lua`

Security/Privacy
- Keep API Keys out of argv (medium)
  Why: Headers in argv can be visible via ps.
  What: Use `curl -K -` and write config via stdin using Job writer so secrets do not appear in argv.
  Files: `lua/llm.lua`

- Safer Log Location and Rotation (small)
  Why: Avoid HOME-only path and unbounded growth.
  What: Use `vim.fn.stdpath('data') .. '/llm/logs'`; rotate by size (e.g., 5MB/day); add `Log.prune(max_days)`.
  Files: `lua/log.lua`

Performance
- Write Throttling During Stream (small)
  Why: Reduce UI overhead on rapid streams.
  What: Buffer small chunks and flush on a timer (e.g., every 15–30ms) or on newline.
  Files: `lua/llm.lua`

- Smarter Context Collection (medium)
  Why: Avoid huge prompts; include only relevant code.
  What: Filter by filetype; cap per-buffer bytes; include only changed/visible buffers; add project root detection and ignore vendor dirs.
  Files: `lua/utils.lua`, `lua/llm_config.lua`

- Robust UTF-8 Tests (small)
  Why: Ensure chunk splitter handles edge cases.
  What: Add unit tests for combining chars, multi-byte boundaries, CRLF mixtures.
  Files: `tests/utf8_spec.lua` (new)

Reliability
- SSE and JSON Lines Parsers (medium)
  Why: Providers vary; reduce brittle parsing.
  What: Implement `stream.parse_sse` (comments, event/data blocks), `stream.parse_jsonl`. Use from provider handlers.
  Files: `lua/stream.lua` (new), `lua/llm.lua`

- Cancellation and Cleanup (small)
  Why: Avoid stale anchors and mappings.
  What: Clear extmark and buffer-local mappings on job end or BufLeave; fix Job:shutdown races.
  Files: `lua/llm.lua`

Developer Experience
- Expand Tests (medium)
  Why: Prevent regressions as features grow.
  What: Tests for provider arg builders, parsers, utils.get_all_buffers_text, cancel flow. Mock Job outputs for streams.
  Files: `tests/*`

- PR Template and Contributing Guide (small)
  Why: Encourage consistent standards.
  What: PR checklist (lint, tests, docs), contributing steps, provider-adding guide.
  Files: `.github/PULL_REQUEST_TEMPLATE.md`, `CONTRIBUTING.md`

- Continuous Formatting (small)
  Why: Keep diffs clean.
  What: CI step to run stylua or fail on diff; optional pre-commit hook.
  Files: `.github/workflows/ci.yml`, scripts

Docs & Examples
- Provider Matrix and Examples (small)
  Why: Make setup clear per provider.
  What: Minimal configs, required env vars, known limits, recommended models.
  Files: `README.md`

- Recipes (small)
  Why: Show value fast.
  What: Code edit (replace), Q&A chat, translate, refactor, doc generate, unit test generate.
  Files: `docs/recipes.md` (new)

Roadmap Enhancements
- Tool/Function Calling (large)
  Why: Enable code actions (run tests, open file, etc.).
  What: Define a safe, whitelisted tool interface and provider mapping; start with OpenAI Responses tool schema.
  Files: `lua/tools.lua`, `lua/llm.lua`

- Vision and Images (medium)
  Why: Unlock multimodal tasks.
  What: Accept image paths from selection; route to providers that support vision; render output/links.
  Files: `lua/llm.lua`, `lua/provider.lua`

- Session Persistence (medium)
  Why: Continue chats across restarts.
  What: Store per-buffer sessions under `stdpath('data')` and reload on buffer open (opt-in).
  Files: `lua/memory.lua`

Quick Wins (1–2 hours)
- Add `--max-time 120 --retry 2 --retry-all-errors` to curl args.
- Switch logs to `vim.fn.stdpath('data') .. '/llm/logs'` and cap size.
- Add `:LLMCancel` and `:LLMReset` commands.
- Throttle streaming writes with a short timer.
- Improve missing-key prompts with `vim.notify_once` and provider name.
- Filter context by filetype and ignore common vendor dirs.

Implementation Sketches (for reference)
- Curl config via stdin (no secrets in argv): use `curl -K -` and write headers + data over stdin via Job writer.
- SSE parser: accumulate until blank line; parse `event:` + multiple `data:` lines; handle heartbeats (`:` lines).
- Ollama parser: read JSONL lines, stream `response`, detect `done` and finalize.
