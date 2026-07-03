-- DEPRECATED shim: this module moved to lua/llm/openai.lua.
-- Update your config to require("llm.openai"). This shim will be removed
-- in a future release.
pcall(function()
  vim.notify_once('llm.nvim: require("openai") is deprecated — use require("llm.openai")', vim.log.levels.WARN)
end)
return require("llm.openai")
