-- Built-in keymaps, opt-in via require("llm").setup({ default_keymaps = true }).
--
-- Layout (mnemonic: l = local/ollama, a = anthropic, o = openai, z = shared):
--   <leader>{l,a,o}i  invoke        — single-turn Q&A (n: type prompt, v: use selection)
--   <leader>{l,a,o}c  code          — replace visual selection with generated code
--   <leader>{l,a,o}b  code all-buf  — replace selection, all open buffers as context
--   <leader>{l,a,o}t  chat          — multi-turn chat with per-buffer history
--   <leader>{l,a,o}a  chat all-buf  — chat, all open buffers as context
--   <leader>{l,a,o}d  diff          — propose replacement in a diff split (accept/reject)
--   <leader>zz  reset conversation state      <leader>zc  toggle buffer in context
--   <leader>zx  clear context buffers         <leader>zl  list context buffers
--   <leader>zm  edit project memory           <leader>zh  :checkhealth llm
-- Diff accept/reject default to <leader>da / <leader>dr (config: keymaps.diff_accept/diff_reject).

local M = {}

local function provider_maps(prefix, mod, label)
  local function fn(name)
    return function()
      require(mod)[name]()
    end
  end
  local map = vim.keymap.set
  local L = "<leader>" .. prefix
  map({ "n", "v" }, L .. "i", fn("invoke"), { desc = "LLM " .. label .. ": invoke (single-turn Q&A)" })
  map("v", L .. "c", fn("code"), { desc = "LLM " .. label .. ": replace selection" })
  map("v", L .. "b", fn("code_all_buf"), { desc = "LLM " .. label .. ": replace selection (all buffers)" })
  map({ "n", "v" }, L .. "t", fn("code_chat"), { desc = "LLM " .. label .. ": chat" })
  map({ "n", "v" }, L .. "a", fn("code_chat_all_buf"), { desc = "LLM " .. label .. ": chat (all buffers)" })
  map("v", L .. "d", fn("code_diff"), { desc = "LLM " .. label .. ": diff review" })
end

function M.apply()
  provider_maps("l", "llm.ollama", "Ollama")
  provider_maps("a", "llm.anthropic", "Anthropic")
  provider_maps("o", "llm.openai", "OpenAI")

  local map = vim.keymap.set
  map({ "n", "v" }, "<leader>zz", function()
    require("llm").reset_message_buffers()
  end, { desc = "LLM: reset conversation state" })
  map("n", "<leader>zc", "<cmd>LLMContextAdd<CR>", { desc = "LLM: toggle buffer in context" })
  map("n", "<leader>zx", "<cmd>LLMContextClear<CR>", { desc = "LLM: clear context buffers" })
  map("n", "<leader>zl", "<cmd>LLMContextList<CR>", { desc = "LLM: list context buffers" })
  map("n", "<leader>zm", "<cmd>LLMMemoryEdit<CR>", { desc = "LLM: edit project memory" })
  map("n", "<leader>zh", "<cmd>checkhealth llm<CR>", { desc = "LLM: health check" })
end

return M
