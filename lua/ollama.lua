-- DEPRECATED shim: this module moved to lua/llm/ollama.lua.
-- Update your config to require("llm.ollama"). This shim will be removed
-- in a future release.
pcall(function()
  vim.notify_once('llm.nvim: require("ollama") is deprecated — use require("llm.ollama")', vim.log.levels.WARN)
end)
return require("llm.ollama")
