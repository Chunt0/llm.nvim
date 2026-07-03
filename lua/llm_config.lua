-- DEPRECATED shim: this module moved to lua/llm/config.lua.
-- Update your config to require("llm.config"). This shim will be removed
-- in a future release.
pcall(function()
  vim.notify_once('llm.nvim: require("llm_config") is deprecated — use require("llm.config")', vim.log.levels.WARN)
end)
return require("llm.config")
