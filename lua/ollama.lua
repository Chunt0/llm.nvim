local llm = require("llm")
local constants = require("constants")

local OLLAMA_URL = constants.api_endpoints.ollama
local FRAMEWORK = "OLLAMA"

local M = {}

function M.invoke()
	llm.invoke_llm_and_stream_into_editor({
		url = OLLAMA_URL,
		model = constants.constants.models.ollama,
		system_prompt = constants.constants.prompts.system_prompt,
		replace = false,
		code_chat = false,
		context = true,
		framework = FRAMEWORK,
	}, llm.make_ollama_spec_curl_args, llm.handle_ollama_spec_data)
end

function M.code()
	llm.invoke_llm_and_stream_into_editor({
		url = OLLAMA_URL,
		model = constants.models.ollama,
		system_prompt = constants.constants.prompts.code_prompt,
		replace = true,
		code_chat = false,
		all_buffers = false,
		context = false,
		framework = FRAMEWORK,
	}, llm.make_ollama_spec_curl_args, llm.handle_ollama_spec_data)
end

function M.code_all_buf()
	llm.invoke_llm_and_stream_into_editor({
		url = OLLAMA_URL,
		model = constants.models.ollama,
		system_prompt = constants.constants.prompts.code_prompt,
		replace = true,
		code_chat = false,
		all_buffers = true,
		context = false,
		framework = FRAMEWORK,
	}, llm.make_ollama_spec_curl_args, llm.handle_ollama_spec_data)
end

function M.code_chat()
	llm.invoke_llm_and_stream_into_editor({
		url = OLLAMA_URL,
		model = constants.models.ollama,
		system_prompt = constants.constants.prompts.code_prompt,
		replace = false,
		code_chat = true,
		all_buffers = false,
		context = true,
		framework = FRAMEWORK,
	}, llm.make_ollama_spec_curl_args, llm.handle_ollama_spec_data)
end

function M.code_chat_all_buf()
	llm.invoke_llm_and_stream_into_editor({
		url = OLLAMA_URL,
		model = constants.models.ollama,
		system_prompt = constants.constants.prompts.code_prompt,
		replace = false,
		code_chat = true,
		all_buffers = true,
		context = true,
		framework = FRAMEWORK,
	}, llm.make_ollama_spec_curl_args, llm.handle_ollama_spec_data)
end

function M.en2ch()
	llm.invoke_llm_and_stream_into_editor({
		url = OLLAMA_URL,
		model = constants.models.ollama,
		system_prompt = constants.constants.prompts.en2ch_prompt,
		replace = false,
		code_chat = false,
		context = false,
		framework = FRAMEWORK,
	}, llm.make_ollama_spec_curl_args, llm.handle_ollama_spec_data)
end

function M.ch2en()
	llm.invoke_llm_and_stream_into_editor({
		url = OLLAMA_URL,
		model = constants.models.ollama,
		system_prompt = constants.constants.prompts.ch2en_prompt,
		replace = false,
		code_chat = false,
		context = false,
		framework = FRAMEWORK,
	}, llm.make_ollama_spec_curl_args, llm.handle_ollama_spec_data)
end

return M
