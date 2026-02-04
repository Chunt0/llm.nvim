Contributing Guide

- Development
  - Install dependencies: `luarocks install luacheck` and `luarocks install busted`
  - Lint: `luacheck .`
  - Format: `stylua .`
  - Test: `busted -v`

- Code style
  - Keep functions small and focused
  - Avoid global side effects; prefer module-local state
  - Use `vim.notify` for user messages; logs go through `log.lua`

- Commit and PRs
  - One logical change per PR when possible
  - Include tests for bug fixes and new features
  - Update README/docs for user-facing changes

- Providers
  - Add handlers via `llm.make_*_spec_curl_args` and `llm.handle_*_spec_data`
  - Prefer streaming and use `stream.lua` helpers (SSE/JSONL)
