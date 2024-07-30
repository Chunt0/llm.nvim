### llm.nvim
Welcome!

This bad boy works for these API services:
 - Ollama
 - OpenAI
 - Anthropic
 - Groq

Best way to use this is with neovim's lazy plugin manager. Here is my current config script
``` lua
return {
	{ -- Integrated LLM
		"Chunt0/llm.nvim",
		dependencies = { "nvim-lua/plenary.nvim" },
		config = function()
			local groq = require("groq")
			local openai = require("openai")
			local anthropic = require("anthropic")
			local ollama = require("ollama")

			vim.keymap.set({ "n", "v" }, "<leader>J", ollama.help, { desc = "llm ollama help" })
			vim.keymap.set({ "n", "v" }, "<leader>j", ollama.code, { desc = "llm ollama code" })
			vim.keymap.set({ "n", "v" }, "<leader>K", groq.help, { desc = "llm groq help" })
			vim.keymap.set({ "n", "v" }, "<leader>k", groq.code, { desc = "llm groq code" })
			vim.keymap.set({ "n", "v" }, "<leader>L", openai.help, { desc = "llm openai help" })
			vim.keymap.set({ "n", "v" }, "<leader>l", openai.code, { desc = "llm openai code" })
			vim.keymap.set({ "n", "v" }, "<leader>H", anthropic.help, { desc = "llm anthropic help" })
			vim.keymap.set({ "n", "v" }, "<leader>h", anthropic.code, { desc = "llm anthropic code" })
		end,
	},
}

```

Mess around with the keymappings to set it up to your liking. There are currently only a few different modes - help, code, and en2ch/ch2en (chinese/english translation)
The file prompts.lua is where you can write your own custom system prompts. This is great if you want to have your LLM act in a specific way. I will be adding more functions as I work with these tools and find out what is needed.
