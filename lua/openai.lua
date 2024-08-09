local llm = require("llm")
local prompts = require("prompts")
local models = require("models")
local options = require("options")

local OPENAI_URL = "https://api.openai.com/v1/chat/completions"
local DALLE_URL = "https://api.openai.com/v1/images/generations"
local OPENAI_API_KEY_NAME = "OPENAI_API_KEY"
local FRAMEWORK = "OPENAI"

local M = {}

function M.code()
	llm.invoke_llm_and_stream_into_editor({
		url = OPENAI_URL,
		model = models.openai,
		api_key_name = OPENAI_API_KEY_NAME,
		system_prompt = prompts.code_prompt,
		replace = true,
		framework = FRAMEWORK,
		temp = options.temp,
	}, llm.make_openai_spec_curl_args, llm.handle_openai_spec_data)
end

function M.invoke()
	llm.invoke_llm_and_stream_into_editor({
		url = OPENAI_URL,
		model = models.openai,
		api_key_name = OPENAI_API_KEY_NAME,
		system_prompt = prompts.system_prompt,
		replace = false,
		framework = FRAMEWORK,
		temp = options.temp,
	}, llm.make_openai_spec_curl_args, llm.handle_openai_spec_data)
end

function M.dalle()
	llm.invoke_llm_and_stream_into_editor({
		url = DALLE_URL,
		model = models.openai,
		api_key_name = OPENAI_API_KEY_NAME,
		framework = FRAMEWORK,
	}, llm.make_dalle_spec_curl_args, llm.handle_dalle_spec_data)
end

function M.en2ch()
	llm.invoke_llm_and_stream_into_editor({
		url = OPENAI_URL,
		model = models.openai,
		system_prompt = prompts.en2ch_prompt,
		replace = false,
		framework = FRAMEWORK,
	}, llm.make_openai_spec_curl_args, llm.handle_openai_spec_data)
end

function M.en2ar()
	llm.invoke_llm_and_stream_into_editor({
		url = OPENAI_URL,
		model = models.openai,
		system_prompt = prompts.en2ar_prompt,
		replace = false,
		framework = FRAMEWORK,
	}, llm.make_openai_spec_curl_args, llm.handle_openai_spec_data)
end

return M
