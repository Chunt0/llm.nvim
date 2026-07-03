-- :checkhealth llm
local M = {}

function M.check()
  local health = vim.health
  health.start("llm.nvim")

  -- curl is the transport for every provider
  if vim.fn.executable("curl") == 1 then
    local out = vim.fn.system({ "curl", "--version" })
    local ver = type(out) == "string" and out:match("^curl [%w%.]+") or "curl"
    health.ok(ver .. " found")
  else
    health.error("curl not found in PATH — llm.nvim cannot make requests without it")
  end

  if pcall(require, "plenary.job") then
    health.ok("plenary.nvim found")
  else
    health.error("plenary.nvim not found — add 'nvim-lua/plenary.nvim' as a dependency")
  end

  if vim.fn.executable("rg") == 1 then
    health.ok("ripgrep (rg) found")
  else
    health.warn("ripgrep (rg) not found — optional today, required for the planned agent grep tool")
  end

  -- Provider configuration
  local constants = require("llm.constants")
  health.info(
    "models: ollama="
      .. tostring(constants.models.ollama)
      .. "  anthropic="
      .. tostring(constants.models.anthropic)
      .. "  openai="
      .. tostring(constants.models.openai)
  )
  health.info(
    "ollama endpoint: "
      .. tostring(constants.api_endpoints.ollama)
      .. "  (override: setup({ constants = { api_endpoints = { ollama = '…' } } }))"
  )

  for env, provider in pairs({ ANTHROPIC_API_KEY = "anthropic", OPENAI_API_KEY = "openai" }) do
    local v = os.getenv(env)
    if v and #v > 0 then
      health.ok(env .. " is set (" .. provider .. " provider available)")
    else
      health.warn(
        env
          .. " not set — the "
          .. provider
          .. " provider will fail with an auth error; ignore this if you only use ollama"
      )
    end
  end
end

return M
