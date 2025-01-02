local llm = require("llm")
local constants = require("constants")

local GROQ_URL = constants.api_endpoints.groq
local GROQ_API_KEY = "GROQ_API_KEY"
local FRAMEWORK = "GROQ"

local M = {}

function M.invoke()
	llm.invoke_llm_and_stream_into_editor({
		url = GROQ_URL,
		model = constants.models.groq,
		api_key_name = GROQ_API_KEY,
		system_prompt = constants.prompts.system_prompt,
		replace = false,
		code_chat = false,
		all_buffers = false,
		framework = FRAMEWORK,
		temp = constants.vars.temp,
		presence_penalty = constants.vars.presence_penalty,
		top_p = constants.vars.top_p,
	}, llm.make_groq_spec_curl_args, llm.handle_groq_spec_data)
end

function M.code()
	llm.invoke_llm_and_stream_into_editor({
		url = GROQ_URL,
		model = constants.models.groq,
		api_key_name = GROQ_API_KEY,
		system_prompt = constants.prompts.code_prompt,
		replace = true,
		code_chat = false,
		all_buffers = false,
		framework = FRAMEWORK,
		temp = constants.vars.temp,
		presence_penalty = constants.vars.presence_penalty,
		top_p = constants.vars.top_p,
	}, llm.make_groq_spec_curl_args, llm.handle_groq_spec_data)
end

function M.code_all_buf()
	llm.invoke_llm_and_stream_into_editor({
		url = GROQ_URL,
		model = constants.models.groq,
		api_key_name = GROQ_API_KEY,
		system_prompt = constants.prompts.code_prompt,
		replace = true,
		code_chat = false,
		all_buffers = true,
		framework = FRAMEWORK,
		temp = constants.vars.temp,
		presence_penalty = constants.vars.presence_penalty,
		top_p = constants.vars.top_p,
	}, llm.make_groq_spec_curl_args, llm.handle_groq_spec_data)
end

function M.code_chat()
	llm.invoke_llm_and_stream_into_editor({
		url = GROQ_URL,
		model = constants.models.groq,
		api_key_name = GROQ_API_KEY,
		system_prompt = constants.prompts.code_prompt,
		replace = false,
		code_chat = true,
		all_buffers = false,
		framework = FRAMEWORK,
		temp = constants.vars.temp,
		presence_penalty = constants.vars.presence_penalty,
		top_p = constants.vars.top_p,
	}, llm.make_groq_spec_curl_args, llm.handle_groq_spec_data)
end

function M.code_chat_all_buf()
	llm.invoke_llm_and_stream_into_editor({
		url = GROQ_URL,
		model = constants.models.groq,
		api_key_name = GROQ_API_KEY,
		system_prompt = constants.prompts.code_prompt,
		replace = false,
		code_chat = true,
		all_buffers = true,
		framework = FRAMEWORK,
		temp = constants.vars.temp,
		presence_penalty = constants.vars.presence_penalty,
		top_p = constants.vars.top_p,
	}, llm.make_groq_spec_curl_args, llm.handle_groq_spec_data)
end

return M
