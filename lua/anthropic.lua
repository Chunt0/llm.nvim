-- DEPRECATED shim: this module moved to lua/llm/anthropic.lua.
-- Update your config to require("llm.anthropic"). This shim will be removed
-- in a future release.
pcall(function()
  vim.notify_once('llm.nvim: require("anthropic") is deprecated — use require("llm.anthropic")', vim.log.levels.WARN)
end)
return require("llm.anthropic")
