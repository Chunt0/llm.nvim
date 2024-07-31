local llm = require("llm")
local prompts = require("prompts")

local PERPLEXITY_URL = "https://api.perplexity.ai/chat/completions"
local PERPLEXITY_MODEL = "llama-3.1-sonar-large-128k-chat"
local PERPLEXITY_API_KEY = "PERPLEXITY_API_KEY"
local FRAMEWORK = "PERPLEXITY"

local M = {}

function M.code()
	llm.invoke_llm_and_stream_into_editor({
		url = PERPLEXITY_URL,
		model = PERPLEXITY_MODEL,
		api_key_name = PERPLEXITY_API_KEY,
		system_prompt = prompts.code_prompt,
		replace = true,
		framework = FRAMEWORK,
	}, llm.make_perplexity_spec_curl_args, llm.handle_perplexity_spec_data)
end

function M.help()
	llm.invoke_llm_and_stream_into_editor({
		url = PERPLEXITY_URL,
		model = PERPLEXITY_MODEL,
		api_key_name = PERPLEXITY_API_KEY,
		system_prompt = prompts.helpful_prompt,
		replace = false,
		framework = FRAMEWORK,
	}, llm.make_perplexity_spec_curl_args, llm.handle_perplexity_spec_data)
end

return M
