local llm = require("llm")
local prompts = require("prompts")
local models = require("models")

local ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
--local ANTHROPIC_MODEL = "claude-3-5-sonnet-20240620"
local ANTHROPIC_API_KEY_NAME = "ANTHROPIC_API_KEY"
local FRAMEWORK = "ANTHROPIC"

local M = {}

function M.invoke()
	llm.invoke_llm_and_stream_into_editor({
		url = ANTHROPIC_URL,
		model = models.anthropic,
		api_key_name = ANTHROPIC_API_KEY_NAME,
		system_prompt = prompts.prompt,
		replace = false,
		framework = FRAMEWORK,
	}, llm.make_anthropic_spec_curl_args, llm.handle_anthropic_spec_data)
end

function M.code()
	llm.invoke_llm_and_stream_into_editor({
		url = ANTHROPIC_URL,
		model = models.anthropic,
		api_key_name = ANTHROPIC_API_KEY_NAME,
		system_prompt = prompts.code_prompt,
		replace = true,
		framework = FRAMEWORK,
	}, llm.make_anthropic_spec_curl_args, llm.handle_anthropic_spec_data)
end

return M
