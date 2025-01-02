local llm = require("llm")
local constants = require("constants")

local PERPLEXITY_URL = constants.api_endpoints.perplexity
local PERPLEXITY_API_KEY = "PERPLEXITY_API_KEY"
local FRAMEWORK = "PERPLEXITY"

local M = {}

function M.invoke()
	llm.invoke_llm_and_stream_into_editor({
		url = PERPLEXITY_URL,
		model = constants.model.perplexity,
		api_key_name = PERPLEXITY_API_KEY,
		system_prompt = constants.prompts.system_prompt,
		replace = false,
		code_chat = false,
		all_buffers = false,
		framework = FRAMEWORK,
		temp = constants.vars.temp,
		presence_penalty = constants.vars.presence_penalty,
		top_p = constants.vars.top_p,
	}, llm.make_perplexity_spec_curl_args, llm.handle_perplexity_spec_data)
end

function M.code()
	llm.invoke_llm_and_stream_into_editor({
		url = PERPLEXITY_URL,
		model = constants.model.perplexity,
		api_key_name = PERPLEXITY_API_KEY,
		system_prompt = constants.prompts.code_prompt,
		replace = true,
		code_chat = false,
		all_buffers = false,
		framework = FRAMEWORK,
		temp = constants.vars.temp,
		presence_penalty = constants.vars.presence_penalty,
		top_p = constants.vars.top_p,
	}, llm.make_perplexity_spec_curl_args, llm.handle_perplexity_spec_data)
end

function M.code_all_buf()
	llm.invoke_llm_and_stream_into_editor({
		url = PERPLEXITY_URL,
		model = constants.model.perplexity,
		api_key_name = PERPLEXITY_API_KEY,
		system_prompt = constants.prompts.code_prompt,
		replace = true,
		code_chat = false,
		all_buffers = true,
		framework = FRAMEWORK,
		temp = constants.vars.temp,
		presence_penalty = constants.vars.presence_penalty,
		top_p = constants.vars.top_p,
	}, llm.make_perplexity_spec_curl_args, llm.handle_perplexity_spec_data)
end

function M.code_chat()
	llm.invoke_llm_and_stream_into_editor({
		url = PERPLEXITY_URL,
		model = constants.model.perplexity,
		api_key_name = PERPLEXITY_API_KEY,
		system_prompt = constants.prompts.code_prompt,
		replace = false,
		code_chat = true,
		all_buffers = false,
		framework = FRAMEWORK,
		temp = constants.vars.temp,
		presence_penalty = constants.vars.presence_penalty,
		top_p = constants.vars.top_p,
	}, llm.make_perplexity_spec_curl_args, llm.handle_perplexity_spec_data)
end

function M.code_chat_all_buf()
	llm.invoke_llm_and_stream_into_editor({
		url = PERPLEXITY_URL,
		model = constants.model.perplexity,
		api_key_name = PERPLEXITY_API_KEY,
		system_prompt = constants.prompts.code_prompt,
		replace = false,
		code_chat = true,
		all_buffers = true,
		framework = FRAMEWORK,
		temp = constants.vars.temp,
		presence_penalty = constants.vars.presence_penalty,
		top_p = constants.vars.top_p,
	}, llm.make_perplexity_spec_curl_args, llm.handle_perplexity_spec_data)
end

return M
