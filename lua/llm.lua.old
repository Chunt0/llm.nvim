local M = {}
local Job = require("plenary.job")
local Log = require("log")
local Utils = require("utils")

-------------------------------- Initialize Variables---------------------------
local assistant_message = nil

local anthropic_messages = {}
local anthropic_count = 0
local anthropic_assistant_response = ""
local anthropic_session_cost = 0

local openai_messages = {}
local openai_count = 0
local openai_assistant_response = ""
local openai_session_cost = 0

local ollama_assistant_response = ""

local groq_messages = {}
local groq_count = 0
local groq_assistant_response = ""

local perplexity_messages = {}
local perplexity_count = 0
local perplexity_assistant_response = ""

-- Models that don't allow sampling controls on the Responses API
local RESPONSES_NO_SAMPLING = {
	["gpt-5"] = true,
}

-------------------------------- Anthropic ---------------------------
function M.make_anthropic_spec_curl_args(opts, prompt, system_prompt)
	print("Calling Anthropic: ", opts.model)
	local url = opts.url or "https://api.anthropic.com/v1/messages"
	local api_key = opts.api_key_name and Utils.get_api_key(opts.api_key_name)
	local data = nil
	if anthropic_count == 0 then
		local message = { { role = "user", content = prompt } }
		data = {
			messages = message,
			model = opts.model,
			max_tokens = 1024,
			stream = true,
			system = system_prompt,
		}
		for _, v in pairs(message) do
			table.insert(anthropic_messages, v)
		end
	else
		local next_message = { role = "user", content = prompt }
		table.insert(anthropic_messages, next_message)
		data = {
			messages = anthropic_messages,
			model = opts.model,
			max_tokens = 1024,
			stream = true,
			system = system_prompt,
		}
	end
	anthropic_count = anthropic_count + 1
	local args = { "-N", "-X", "POST", "-H", "content-type: application/json", "-d", vim.json.encode(data) }
	table.insert(args, "-H")
	table.insert(args, "x-api-key: " .. api_key)
	table.insert(args, "-H")
	table.insert(args, "anthropic-version: 2023-06-01")
	table.insert(args, url)
	return args, "EVENTS"
end

function M.handle_anthropic_spec_data(data_stream, event_state)
	local ok, json = pcall(vim.json.decode, data_stream)
	if not ok or not json then
		return
	end
	if event_state == "content_block_delta" then
		if json.delta and json.delta.text then
			local content = json.delta.text
			Utils.write_string_at_cursor(content)
			anthropic_assistant_response = anthropic_assistant_response .. content
		end
	elseif event_state == "message_stop" then
		assistant_message = { role = "assistant", content = anthropic_assistant_response }
		table.insert(anthropic_messages, assistant_message)
		anthropic_assistant_response = ""
	end
end

function M.calculate_anthropic_session_cost(input_tokens, output_tokens) end

------------------------------------- OpenAI (AUTO endpoint) -----------------------------------
-- Auto-switch between /v1/responses (EVENTS) and /v1/chat/completions (LEGACY)
function M.make_openai_spec_curl_args(opts, prompt, system_prompt)
	print("Calling OpenAI (AUTO): ", opts.model)

	local model = opts.model
	local url_responses = opts.url_responses or "https://api.openai.com/v1/responses"
	local url_chat = opts.url_chat or "https://api.openai.com/v1/chat/completions"
	local api_key = opts.api_key_name and Utils.get_api_key(opts.api_key_name)

	local have_sampling = (opts.temp ~= nil) or (opts.top_p ~= nil)
	local use_chat_legacy = RESPONSES_NO_SAMPLING[model] and have_sampling

	local data, url, stream_mode

	if openai_count == 0 then
		local first = {
			{ role = "system", content = system_prompt },
			{ role = "user", content = prompt },
		}

		if use_chat_legacy then
			data = {
				model = model,
				messages = first,
				stream = true,
				temperature = opts.temp,
				top_p = opts.top_p,
				presence_penalty = opts.presence_penalty,
			}
			url = opts.url or url_chat
			stream_mode = "LEGACY"
		else
			data = {
				model = model,
				input = first,
				stream = true,
				-- (optional) add temperature/top_p here only for models that support it on Responses
			}
			url = opts.url or url_responses
			stream_mode = "EVENTS"
		end

		for _, v in pairs(first) do
			table.insert(openai_messages, v)
		end
	else
		local next_message = { role = "user", content = prompt }
		table.insert(openai_messages, next_message)

		if use_chat_legacy then
			data = {
				model = model,
				messages = openai_messages,
				stream = true,
				temperature = opts.temp,
				top_p = opts.top_p,
				presence_penalty = opts.presence_penalty,
			}
			url = opts.url or url_chat
			stream_mode = "LEGACY"
		else
			data = {
				model = model,
				input = openai_messages,
				stream = true,
			}
			url = opts.url or url_responses
			stream_mode = "EVENTS"
		end
	end

	openai_count = openai_count + 1

	local args = { "-N", "-X", "POST", "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	if api_key then
		table.insert(args, "-H")
		table.insert(args, "Authorization: Bearer " .. api_key)
	end
	table.insert(args, url)

	return args, stream_mode
end

-- Chat Completions (legacy SSE) handler (keep existing)
function M.handle_openai_spec_data(data_stream)
	if data_stream:match('"delta":') then
		data_stream = data_stream:gsub("^data: ", "")
		local ok, json = pcall(vim.json.decode, data_stream)
		if ok and json and json.choices and json.choices[1] and json.choices[1].delta then
			local content = json.choices[1].delta.content
			if content then
				Utils.write_string_at_cursor(content)
				openai_assistant_response = openai_assistant_response .. content
			end
		end
	elseif data_stream:match("%[DONE%]") then
		assistant_message = { role = "assistant", content = openai_assistant_response }
		table.insert(openai_messages, assistant_message)
		openai_assistant_response = ""
	end
end

-- Responses API (event-typed SSE) handler
function M.handle_openai_responses_data(data_json, event_type)
	local ok, json = pcall(vim.json.decode, data_json)
	if not ok or not json then
		return
	end

	if event_type == "response.output_text.delta" then
		if json.delta then
			Utils.write_string_at_cursor(json.delta)
			openai_assistant_response = openai_assistant_response .. json.delta
		end
	elseif event_type == "response.completed" then
		assistant_message = { role = "assistant", content = openai_assistant_response }
		table.insert(openai_messages, assistant_message)
		openai_assistant_response = ""
	elseif event_type == "response.error" then
		local msg = (json.error and json.error.message) or "unknown"
		vim.notify("OpenAI error: " .. msg, vim.log.levels.ERROR)
	end
end

function M.make_dalle_spec_curl_args(opts, prompt)
	print("Calling OpenAI: DALL-E 3")
	local url = opts.url or "https://api.openai.com/v1/images/generations"
	local api_key = opts.api_key_name and Utils.get_api_key(opts.api_key_name)
	local data = {
		model = "dall-e-3",
		prompt = prompt,
		n = 1,
		size = "1024x1024",
	}
	local args = { "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	if api_key then
		table.insert(args, "-H")
		table.insert(args, "Authorization: Bearer " .. api_key)
	end
	table.insert(args, url)
	return args, "LEGACY" -- responses are non-SSE JSON
end

function M.handle_dalle_spec_data(data_stream)
	if data_stream:match('"url":') then
		local content = data_stream:match('"url":%s*"(https://[^"]+)"')
		if content then
			Utils.write_string_at_cursor(content)
			assistant_message = { role = "assistant", content = content }
			table.insert(openai_messages, assistant_message)
		end
	end
end

function M.calculate_openai_session_cost(input_tokens, output_tokens) end

------------------------------------- Groq -------------------------------------
function M.make_groq_spec_curl_args(opts, prompt, system_prompt)
	print("Calling Groq: ", opts.model)
	local url = opts.url or "https://api.groq.com/openai/v1/chat/completions"
	local api_key = opts.api_key_name and Utils.get_api_key(opts.api_key_name)
	local data
	if groq_count == 0 then
		local message = { { role = "system", content = system_prompt }, { role = "user", content = prompt } }
		data = {
			messages = message,
			model = opts.model,
			temperature = opts.temp,
			stream = true,
			presence_penalty = opts.presence_penalty,
			top_p = opts.top_p,
		}
		for _, v in pairs(message) do
			table.insert(groq_messages, v)
		end
	else
		local next_message = { role = "user", content = prompt }
		table.insert(groq_messages, next_message)
		data = {
			messages = groq_messages,
			model = opts.model,
			temperature = opts.temp,
			stream = true,
			presence_penalty = opts.presence_penalty,
			top_p = opts.top_p,
		}
	end
	groq_count = groq_count + 1
	local args = { "-N", "-X", "POST", "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	if api_key then
		table.insert(args, "-H")
		table.insert(args, "Authorization: Bearer " .. api_key)
	end
	table.insert(args, url)
	return args, "LEGACY"
end

function M.handle_groq_spec_data(data_stream)
	if data_stream:match('"delta":') then
		data_stream = data_stream:gsub("^data: ", "")
		local ok, json = pcall(vim.json.decode, data_stream)
		if ok and json and json.choices and json.choices[1] and json.choices[1].delta then
			local content = json.choices[1].delta.content
			if content then
				Utils.write_string_at_cursor(content)
				groq_assistant_response = groq_assistant_response .. content
			end
		end
	elseif data_stream:match("%[DONE%]") then
		assistant_message = { role = "assistant", content = groq_assistant_response }
		table.insert(groq_messages, assistant_message)
		groq_assistant_response = ""
	end
end

------------------------------------- Perplexity -------------------------------
function M.make_perplexity_spec_curl_args(opts, prompt, system_prompt)
	print("Calling Perplexity: ", opts.model)
	local url = opts.url or "https://api.perplexity.ai/chat/completions"
	local api_key = opts.api_key_name and Utils.get_api_key(opts.api_key_name)
	local data
	if perplexity_count == 0 then
		local message = { { role = "system", content = system_prompt }, { role = "user", content = prompt } }
		data = {
			messages = message,
			model = opts.model,
			temperature = opts.temp,
			stream = true,
			presence_penalty = opts.presence_penalty,
			top_p = opts.top_p,
		}
		for _, v in pairs(message) do
			table.insert(perplexity_messages, v)
		end
	else
		local next_message = { role = "user", content = prompt }
		table.insert(perplexity_messages, next_message)
		data = {
			messages = perplexity_messages,
			model = opts.model,
			temperature = opts.temp,
			stream = true,
			presence_penalty = opts.presence_penalty,
			top_p = opts.top_p,
		}
	end
	perplexity_count = perplexity_count + 1
	local args = { "-N", "-X", "POST", "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	if api_key then
		table.insert(args, "-H")
		table.insert(args, "Authorization: Bearer " .. api_key)
	end
	table.insert(args, url)
	return args, "LEGACY"
end

-- Hardened SSE handler
function M.handle_perplexity_spec_data(data_stream)
	local line = (data_stream or ""):gsub("^%s+", "")
	if line:match("^data:%s*%[DONE%]%s*$") then
		assistant_message = { role = "assistant", content = perplexity_assistant_response }
		table.insert(perplexity_messages, assistant_message)
		perplexity_assistant_response = ""
		return
	end

	local json_part = line:match("^data:%s*(.+)$")
	if not json_part then
		return
	end

	local ok, json = pcall(vim.json.decode, json_part)
	if not ok or not json then
		return
	end

	if json.choices and json.choices[1] and json.choices[1].delta then
		local content = json.choices[1].delta.content
		if content then
			Utils.write_string_at_cursor(content)
			perplexity_assistant_response = perplexity_assistant_response .. content
		end
	end

	local finish_reason = json.choices and json.choices[1] and json.choices[1].finish_reason
	if finish_reason and finish_reason ~= vim.NIL then
		assistant_message = { role = "assistant", content = perplexity_assistant_response }
		table.insert(perplexity_messages, assistant_message)
		perplexity_assistant_response = ""
	end
end

------------------------------------- Ollama -------------------------------
local context = {}
local max_length = 25000

function M.make_ollama_spec_curl_args(opts, prompt, system_prompt)
	print("Calling Ollama: ", opts.model)
	local url = opts.url or "https://ollama.putty-ai.com/api/generate"
	local data = {
		prompt = prompt,
		system = system_prompt,
		model = opts.model,
		stream = true,
	}
	if opts.context then
		context = Utils.trim_context(context, max_length)
		data.context = context
	end
	local args = { "-N", "-X", "POST", "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	table.insert(args, url)
	return args, "LEGACY"
end

function M.handle_ollama_spec_data(data_stream)
	local ok, json = pcall(vim.json.decode, data_stream)
	if not ok or not json then
		return
	end
	if json.response and json.done == false then
		local content = json.response
		if content then
			ollama_assistant_response = ollama_assistant_response .. content
			Utils.write_string_at_cursor(content)
		end
	elseif json.done then
		if json.context and type(json.context) == "table" then
			for _, value in ipairs(json.context) do
				if value and context then
					table.insert(context, tonumber(value))
				end
			end
		end
		assistant_message = { role = "assistant", content = ollama_assistant_response }
	end
end

-------------------------------- Invoke LLM -----------------------------------
local group = vim.api.nvim_create_augroup("LLM_AutoGroup", { clear = true })
local active_job = nil

-- Updated invoke function supports both LEGACY and EVENTS stream styles
function M.invoke_llm_and_stream_into_editor(opts, make_curl_args_fn, handle_legacy_fn, handle_events_fn)
	vim.api.nvim_clear_autocmds({ group = group })
	local prompt = Utils.get_prompt(opts)
	if not prompt then
		return
	end

	local replace = opts.replace
	local framework = opts.framework
	local model = opts.model
	local system_prompt = opts.system_prompt
		or "Yell at me for not setting my configuration for my llm plugin correctly"

	local args, stream_mode = make_curl_args_fn(opts, prompt, system_prompt)

	-- Default inference if maker didn't return a mode
	if not stream_mode then
		if framework and framework:match("ANTHROPIC") then
			stream_mode = "EVENTS"
		else
			stream_mode = "LEGACY"
		end
	end

	if active_job then
		active_job:shutdown()
		active_job = nil
	end

	local curr_event_state = nil

	local function parse_and_call(line)
		local event = line:match("^event:%s*(.+)$")
		if event then
			curr_event_state = event
			return
		end
		local data_match = line:match("^data:%s*(.+)$")
		if data_match and handle_events_fn then
			handle_events_fn(data_match, curr_event_state)
		end
	end

	local on_exit_common = vim.schedule_wrap(function()
		if not replace then
			local bufnr = vim.api.nvim_get_current_buf()
			local line, _ = unpack(vim.api.nvim_win_get_cursor(0))
			local user_line = "---------------------------User---------------------------"
			vim.api.nvim_buf_set_lines(bufnr, line, line, false, { "", user_line, "", "" })
			vim.api.nvim_win_set_cursor(0, { line + 4, 0 })
		end
		local user_message = { role = "user", content = prompt }
		local time = os.date("%Y-%m-%dT%H:%M:%S")
		local log_entry = {
			time = time,
			framework = framework,
			model = model,
			user = user_message,
			assistant = assistant_message,
		}
		Log.log(log_entry)
		active_job = nil
		assistant_message = nil
	end)

	if stream_mode == "EVENTS" then
		active_job = Job:new({
			command = "curl",
			args = args,
			on_stdout = function(_, out)
				parse_and_call(out)
			end,
			on_stderr = function(_, _) end,
			on_exit = on_exit_common,
		})
	else
		active_job = Job:new({
			command = "curl",
			args = args,
			on_stdout = function(_, out)
				if handle_legacy_fn then
					handle_legacy_fn(out)
				end
			end,
			on_stderr = function(_, _) end,
			on_exit = on_exit_common,
		})
	end

	active_job:start()

	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "LLM_Escape",
		callback = function()
			if active_job then
				active_job:shutdown()
				print("LLM streaming cancelled")
				active_job = nil
			end
		end,
	})

	vim.api.nvim_set_keymap("n", "<Esc>", ":doautocmd User LLM_Escape<CR>", { noremap = true, silent = true })

	return active_job
end

function M.reset_message_buffers()
	-- Reset Anthropic messages
	anthropic_messages = {}
	anthropic_count = 0
	anthropic_assistant_response = ""

	-- Reset OpenAI messages
	openai_messages = {}
	openai_count = 0
	openai_assistant_response = ""

	-- Reset Groq messages
	groq_messages = {}
	groq_count = 0
	groq_assistant_response = ""

	-- Reset Perplexity messages
	perplexity_messages = {}
	perplexity_count = 0
	perplexity_assistant_response = ""

	-- Reset Ollama context
	context = {}
	ollama_assistant_response = ""

	-- Optional: Log the reset action
	vim.notify("All LLM message buffers have been reset", vim.log.levels.INFO)
end

return M
