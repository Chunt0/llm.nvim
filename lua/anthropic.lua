local llm = require("llm")
local constants = require("constants")

local ANTHROPIC_URL = constants.api_endpoints.anthropic
local ANTHROPIC_API_KEY_NAME = "ANTHROPIC_API_KEY"
local FRAMEWORK = "ANTHROPIC"

local M = {}

function M.invoke()
	llm.invoke_llm_and_stream_into_editor({
		url = ANTHROPIC_URL,
		model = constants.models.anthropic,
		api_key_name = ANTHROPIC_API_KEY_NAME,
		system_prompt = constants.prompts.system_prompt,
		replace = false,
		code_chat = false,
		all_buffers = false,
		framework = FRAMEWORK,
	}, llm.make_anthropic_spec_curl_args, llm.handle_anthropic_spec_data)
end

function M.code()
	llm.invoke_llm_and_stream_into_editor({
		url = ANTHROPIC_URL,
		model = constants.models.anthropic,
		api_key_name = ANTHROPIC_API_KEY_NAME,
		system_prompt = constants.prompts.code_prompt,
		replace = true,
		code_chat = false,
		all_buffers = false,
		framework = FRAMEWORK,
	}, llm.make_anthropic_spec_curl_args, llm.handle_anthropic_spec_data)
end

function M.code_all_buf()
	llm.invoke_llm_and_stream_into_editor({
		url = ANTHROPIC_URL,
		model = constants.models.anthropic,
		api_key_name = ANTHROPIC_API_KEY_NAME,
		system_prompt = constants.prompts.code_prompt,
		replace = true,
		code_chat = false,
		all_buffers = true,
		framework = FRAMEWORK,
	}, llm.make_anthropic_spec_curl_args, llm.handle_anthropic_spec_data)
end

function M.code_chat()
	llm.invoke_llm_and_stream_into_editor({
		url = ANTHROPIC_URL,
		model = constants.models.anthropic,
		api_key_name = ANTHROPIC_API_KEY_NAME,
		system_prompt = constants.prompts.code_prompt,
		replace = false,
		code_chat = true,
		all_buffers = false,
		framework = FRAMEWORK,
	}, llm.make_anthropic_spec_curl_args, llm.handle_anthropic_spec_data)
end

function M.code_chat_all_buf()
	llm.invoke_llm_and_stream_into_editor({
		url = ANTHROPIC_URL,
		model = constants.models.anthropic,
		api_key_name = ANTHROPIC_API_KEY_NAME,
		system_prompt = constants.prompts.code_prompt,
		replace = false,
		code_chat = true,
		all_buffers = true,
		framework = FRAMEWORK,
	}, llm.make_anthropic_spec_curl_args, llm.handle_anthropic_spec_data)
end

return M
