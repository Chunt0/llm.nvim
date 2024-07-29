local llm = require("llm")
local prompts = require("prompts")

local GROQ_URL = "https://api.groq.com/openai/v1/chat/completions"
local GROQ_MODEL = "llama-3.1-70b-versatile"
local GROQ_API_KEY = "GROQ_API_KEY"
local FRAMEWORK = "GROQ"

local M = {}

function M.code()
	llm.invoke_llm_and_stream_into_editor({
		url = GROQ_URL,
		model = GROQ_MODEL,
		api_key_name = GROQ_API_KEY,
		system_prompt = prompts.code_prompt,
		replace = true,
		framework = FRAMEWORK,
	}, llm.make_groq_spec_curl_args, llm.handle_groq_spec_data)
end

function M.help()
	llm.invoke_llm_and_stream_into_editor({
		url = GROQ_URL,
		model = GROQ_MODEL,
		api_key_name = GROQ_API_KEY,
		system_prompt = prompts.helpful_prompt,
		replace = false,
		framework = FRAMEWORK,
	}, llm.make_groq_spec_curl_args, llm.handle_groq_spec_data)
end

return M
