local llm = require("llm")
local constants = require("constants")

local OPENAI_URL = constants.api_endpoints.openai
local DALLE_URL = constants.api_endpoints.dalle
local OPENAI_API_KEY_NAME = "OPENAI_API_KEY"
local FRAMEWORK = "OPENAI"

local M = {}

function M.invoke()
	llm.invoke_llm_and_stream_into_editor({
		url = OPENAI_URL,
		model = constants.models.openai,
		api_key_name = OPENAI_API_KEY_NAME,
		system_prompt = constants.prompts.system_prompt,
		replace = false,
		code_chat = false,
		all_buffers = false,
		framework = FRAMEWORK,
		temp = constants.vars.temp,
		presence_penalty = constants.vars.presence_penalty,
		top_p = constants.vars.top_p,
	}, llm.make_openai_spec_curl_args, llm.handle_openai_spec_data)
end

function M.code()
	llm.invoke_llm_and_stream_into_editor({
		url = OPENAI_URL,
		model = constants.models.openai,
		api_key_name = OPENAI_API_KEY_NAME,
		system_prompt = constants.prompts.code_prompt,
		replace = true,
		code_chat = false,
		all_buffers = false,
		framework = FRAMEWORK,
		temp = constants.vars.temp,
		presence_penalty = constants.vars.presence_penalty,
		top_p = constants.vars.top_p,
	}, llm.make_openai_spec_curl_args, llm.handle_openai_spec_data)
end

function M.code_all_buf()
	llm.invoke_llm_and_stream_into_editor({
		url = OPENAI_URL,
		model = constants.models.openai,
		api_key_name = OPENAI_API_KEY_NAME,
		system_prompt = constants.prompts.code_prompt,
		replace = true,
		code_chat = false,
		all_buffers = true,
		framework = FRAMEWORK,
		temp = constants.vars.temp,
		presence_penalty = constants.vars.presence_penalty,
		top_p = constants.vars.top_p,
	}, llm.make_openai_spec_curl_args, llm.handle_openai_spec_data)
end

function M.code_chat()
	llm.invoke_llm_and_stream_into_editor({
		url = OPENAI_URL,
		model = constants.models.openai,
		api_key_name = OPENAI_API_KEY_NAME,
		system_prompt = constants.prompts.code_prompt,
		replace = false,
		code_chat = true,
		all_buffers = false,
		framework = FRAMEWORK,
		temp = constants.vars.temp,
		presence_penalty = constants.vars.presence_penalty,
		top_p = constants.vars.top_p,
	}, llm.make_openai_spec_curl_args, llm.handle_openai_spec_data)
end

function M.code_chat_all_buf()
	llm.invoke_llm_and_stream_into_editor({
		url = OPENAI_URL,
		model = constants.models.openai,
		api_key_name = OPENAI_API_KEY_NAME,
		system_prompt = constants.prompts.code_prompt,
		replace = false,
		code_chat = true,
		all_buffers = true,
		framework = FRAMEWORK,
		temp = constants.vars.temp,
		presence_penalty = constants.vars.presence_penalty,
		top_p = constants.vars.top_p,
	}, llm.make_openai_spec_curl_args, llm.handle_openai_spec_data)
end

function M.dalle()
	llm.invoke_llm_and_stream_into_editor({
		url = DALLE_URL,
		model = constants.models.openai,
		api_key_name = OPENAI_API_KEY_NAME,
		framework = FRAMEWORK,
	}, llm.make_dalle_spec_curl_args, llm.handle_dalle_spec_data)
end

function M.en2ch()
	llm.invoke_llm_and_stream_into_editor({
		url = OPENAI_URL,
		model = constants.models.openai,
		system_prompt = constants.prompts.en2ch_prompt,
		replace = false,
		code_chat = false,
		framework = FRAMEWORK,
		temp = constants.vars.temp,
		presence_penalty = constants.vars.presence_penalty,
		top_p = constants.vars.top_p,
	}, llm.make_openai_spec_curl_args, llm.handle_openai_spec_data)
end

function M.en2ar()
	llm.invoke_llm_and_stream_into_editor({
		url = OPENAI_URL,
		model = constants.models.openai,
		system_prompt = constants.prompts.en2ar_prompt,
		replace = false,
		code_chat = false,
		framework = FRAMEWORK,
		temp = constants.vars.temp,
		presence_penalty = constants.vars.presence_penalty,
		top_p = constants.vars.top_p,
	}, llm.make_openai_spec_curl_args, llm.handle_openai_spec_data)
end

return M
