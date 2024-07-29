local llm = require("llm")
local prompts = require("prompts")

local OPENAI_URL = "https://api.openai.com/v1/chat/completions"
local OPENAI_MODEL = "gpt-4o"
local OPENAI_API_KEY_NAME = "OPENAI_API_KEY"
local FRAMEWORK = "OPENAI"

local M = {}

function M.code()
	llm.invoke_llm_and_stream_into_editor({
		url = OPENAI_URL,
		model = OPENAI_MODEL,
		api_key_name = OPENAI_API_KEY_NAME,
		system_prompt = prompts.code_prompt,
		replace = true,
		framework = FRAMEWORK,
	}, llm.make_openai_spec_curl_args, llm.handle_openai_spec_data)
end

function M.help()
	llm.invoke_llm_and_stream_into_editor({
		url = OPENAI_URL,
		model = OPENAI_MODEL,
		api_key_name = OPENAI_API_KEY_NAME,
		system_prompt = prompts.helpful_prompt,
		replace = false,
		framework = FRAMEWORK,
	}, llm.make_openai_spec_curl_args, llm.handle_openai_spec_data)
end

function M.en2ch()
	llm.invoke_llm_and_stream_into_editor({
		url = OPENAI_URL,
		model = OPENAI_MODEL,
		system_prompt = prompts.en2ch_prompt,
		replace = false,
		framework = FRAMEWORK,
	}, llm.make_openai_spec_curl_args, llm.handle_openai_spec_data)
end

function M.en2ar()
	llm.invoke_llm_and_stream_into_editor({
		url = OPENAI_URL,
		model = OPENAI_MODEL,
		system_prompt = prompts.en2ar_prompt,
		replace = false,
		framework = FRAMEWORK,
	}, llm.make_openai_spec_curl_args, llm.handle_openai_spec_data)
end

return M
