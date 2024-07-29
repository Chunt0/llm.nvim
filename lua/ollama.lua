local llm = require("llm")
local prompts = require("prompts")

local OLLAMA_URL = "http://localhost:11434/api/generate"
local OLLAMA_MODEL = "llama3.1:70b-instruct-q2_k"
local OLLAMA_MODEL_CODE = "deepseek-coder:33b"
local OLLAMA_MODEL_EN2CH = "yi:34b"
local FRAMEWORK = "OLLAMA"

local M = {}

function M.help()
	llm.invoke_llm_and_stream_into_editor({
		url = OLLAMA_URL,
		model = OLLAMA_MODEL,
		system_prompt = prompts.helpful_prompt,
		replace = false,
		context = true,
		framework = FRAMEWORK,
	}, llm.make_ollama_spec_curl_args, llm.handle_ollama_spec_data)
end

function M.code()
	llm.invoke_llm_and_stream_into_editor({
		url = OLLAMA_URL,
		model = OLLAMA_MODEL_CODE,
		system_prompt = prompts.system_prompt,
		replace = true,
		context = false,
		framework = FRAMEWORK,
	}, llm.make_ollama_spec_curl_args, llm.handle_ollama_spec_data)
end

function M.en2ch()
	llm.invoke_llm_and_stream_into_editor({
		url = OLLAMA_URL,
		model = OLLAMA_MODEL_EN2CH,
		system_prompt = prompts.en2ch_prompt,
		replace = false,
		context = false,
		framework = FRAMEWORK,
	}, llm.make_ollama_spec_curl_args, llm.handle_ollama_spec_data)
end

return M
