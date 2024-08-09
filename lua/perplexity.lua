local llm = require("llm")
local prompts = require("prompts")
local models = require("models")
local vars = require("variables")

local PERPLEXITY_URL = "https://api.perplexity.ai/chat/completions"
local PERPLEXITY_API_KEY = "PERPLEXITY_API_KEY"
local FRAMEWORK = "PERPLEXITY"

local M = {}

function M.code()
	llm.invoke_llm_and_stream_into_editor({
		url = PERPLEXITY_URL,
		model = models.perplexity,
		api_key_name = PERPLEXITY_API_KEY,
		system_prompt = prompts.code_prompt,
		replace = true,
		framework = FRAMEWORK,
		temp = vars.temp,
	}, llm.make_perplexity_spec_curl_args, llm.handle_perplexity_spec_data)
end

function M.invoke()
	llm.invoke_llm_and_stream_into_editor({
		url = PERPLEXITY_URL,
		model = models.perplexity,
		api_key_name = PERPLEXITY_API_KEY,
		system_prompt = prompts.system_prompt,
		replace = false,
		framework = FRAMEWORK,
		temp = vars.temp,
	}, llm.make_perplexity_spec_curl_args, llm.handle_perplexity_spec_data)
end

return M
