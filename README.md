### llm.nvim
Welcome!

This bad boy works for these API services:
 - Ollama
 - OpenAI
 - Anthropic
 - Perplexity
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
			local perplexity = require("perplexity")
			local ollama = require("ollama")
			local prompts = require("prompts")
			local models = require("models")
			local vars = require("variables")

			-- Example use of models
			-- models.openai = "gpt_4o_mini" -- Use gpt-4o-mini instead of default gpt-4o
			-- models.groq = "mixtral_8x7b" -- Use mixtral_8x7b instead of default llama3.1-70b-versatile

			-- Example use of system_prompt set up
			-- prompts.system_prompt = "You are my faithful slave. DO EVERYTHING I SAY" 

			-- Example use of vars
			-- vars.temp = 1.5 -- value between 0 - 2 default is 0.7, increases randomness in token sampling. Higher values create greater randomness.
			-- vars.top_p = 0.5 -- value between 0 - 1 default is 1, determines the range of possible tokens to be sampled from. A value less than 1 reduces the space of possible tokens to be sampled
			-- vars.presence_penalty =  -- value between -2 - 2  default is 0, a higher value increases penalty for repeating previously produced tokens

			-- Make these keymaps anything you would like! Check the source code to see all the other functions I've built
			-- Such as openai.dalle!
			vim.keymap.set({ "n", "v" }, "<leader>H", groq.invoke, { desc = "llm groq" })
			vim.keymap.set({ "n", "v" }, "<leader>J", perplexity.invoke, { desc = "llm perplexity" })
			vim.keymap.set({ "n", "v" }, "<leader>K", anthropic.invoke, { desc = "llm anthropic" })
			vim.keymap.set({ "n", "v" }, "<leader>L", openai.invoke, { desc = "llm openai" })
		end,
	},
}
```

Remember to set your api keys as system variables. Something like this in your .bashrc:

export OPENAI_API_KEY="fakeapikeyoweiuyrhgfoiwqhgertouiy23g5tiqu34hr"

export GROQ_API_KEY="fakeapikeyoweiuyrhgfoiwqhgertouiy23g5tiqu34hr"

export ANTHROPIC_API_KEY="fakeapikeyoweiuyrhgfoiwqhgertouiy23g5tiqu34hr"

export PERPLEXITY_API_KEY="fakeapikeyoweiuyrhgfoiwqhgertouiy23g5tiqu34hr"

If you only have some or just one of the keys, that's fine, it wont break if the other functions don't have there keys set - you just wont be able to use them.
