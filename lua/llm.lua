-- llm.lua (OpenAI + Ollama only)
local M = {}
local Job = require("plenary.job")
local Log = require("log")
local Utils = require("utils")

-------------------------------- Stream insertion anchor (fix token-at-cursor drift) ----------
local NS = vim.api.nvim_create_namespace("LLMStream")
local stream_anchor = nil

local function start_anchor()
	local bufnr = vim.api.nvim_get_current_buf()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0)) -- row is 1-indexed
	local id = vim.api.nvim_buf_set_extmark(bufnr, NS, row - 1, col, {
		right_gravity = false, -- keep mark on the left side of inserted text
	})
	stream_anchor = { bufnr = bufnr, id = id }
end

local function append_at_anchor(txt)
	if not stream_anchor or not txt or txt == "" then
		return
	end
	-- sanitize odd control chars that sometimes appear in streams
	txt = txt:gsub("[\r\b]", "")

	vim.schedule(function()
		if not vim.api.nvim_buf_is_loaded(stream_anchor.bufnr) then
			return
		end
		local pos = vim.api.nvim_buf_get_extmark_by_id(stream_anchor.bufnr, NS, stream_anchor.id, {})
		if not pos or pos[1] == nil then
			return
		end
		local row, col = pos[1], pos[2]

		local lines = vim.split(txt, "\n", { plain = true })
		vim.api.nvim_buf_set_text(stream_anchor.bufnr, row, col, row, col, lines)

		local last = lines[#lines]
		local new_row = row + (#lines - 1)
		local new_col = (#lines == 1) and (col + #last) or #last

		vim.api.nvim_buf_set_extmark(stream_anchor.bufnr, NS, new_row, new_col, {
			id = stream_anchor.id,
			right_gravity = false,
		})
	end)
end

local function end_anchor()
	stream_anchor = nil
end

-- UTF-8 safe streaming (carry incomplete multi-byte at chunk boundary)
local utf8_carry = ""

local function split_complete_utf8(s)
	if s == "" then
		return "", ""
	end
	local len = #s
	local i = len
	-- walk back over UTF-8 continuation bytes (10xx xxxx)
	while i > 0 do
		local b = s:byte(i)
		if b < 0x80 or b >= 0xC0 then
			break
		end
		i = i - 1
	end
	if i == 0 then
		return "", s
	end
	local lead = s:byte(i)
	local need = (lead < 0xE0 and 1) or (lead < 0xF0 and 2) or (lead < 0xF8 and 3) or 0
	local have = len - i
	if have < need then
		return s:sub(1, i - 1), s:sub(i)
	else
		return s, ""
	end
end

local function write_safely(chunk)
	if not chunk or chunk == "" then
		return
	end
	-- prepend any carried tail from previous chunk
	if utf8_carry ~= "" then
		chunk = utf8_carry .. chunk
		utf8_carry = ""
	end
	-- normalize newlines early (helps SSE parsing elsewhere)
	chunk = chunk:gsub("\r\n", "\n")
	-- strip control chars we don't want
	chunk = chunk:gsub("[\r\b]", "")

	local complete, tail = split_complete_utf8(chunk)
	utf8_carry = tail -- keep the incomplete suffix for the next call

	if complete ~= "" then
		append_at_anchor(complete)
	end
end

-------------------------------- Initialize Variables---------------------------
local assistant_message = nil

-- OpenAI state
local openai_messages = {}
local openai_count = 0
local openai_assistant_response = ""
local openai_session_cost = 0

-- Ollama state
local ollama_assistant_response = ""
local context = {}
local max_length = 25000

-- Models that don't allow sampling controls on the Responses API
local RESPONSES_NO_SAMPLING = {
	["gpt-5"] = true,
}

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
				-- (optional) temperature/top_p only for models that support it on Responses
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

-- Chat Completions (legacy SSE) handler
function M.handle_openai_spec_data(data_stream)
	if data_stream:match('"delta":') then
		data_stream = data_stream:gsub("^data:%s*", "")
		local ok, json = pcall(vim.json.decode, data_stream)
		if ok and json and json.choices and json.choices[1] and json.choices[1].delta then
			local content = json.choices[1].delta.content
			if content then
				write_safely(content)
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
			write_safely(json.delta)
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

function M.calculate_openai_session_cost(_input_tokens, _output_tokens) end

------------------------------------- Ollama -------------------------------
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
			write_safely(content)
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
		stream_mode = "LEGACY"
	end

	if active_job then
		active_job:shutdown()
		active_job = nil
	end

	-- stable insertion point for streaming
	start_anchor()

	-- SSE/line buffers
	local sse_buf = ""
	local line_buf = ""
	local function handle_events_stdout(_, out)
		-- normalize CRLF to LF; append
		sse_buf = sse_buf .. out:gsub("\r\n", "\n")
		while true do
			local sep = sse_buf:find("\n\n", 1, true) -- blank line separates SSE blocks
			if not sep then
				break
			end
			local block = sse_buf:sub(1, sep - 1)
			sse_buf = sse_buf:sub(sep + 2)

			-- extract event (first or any line)
			local ev = block:match("\nevent:%s*(.-)\n") or block:match("^event:%s*(.-)\n")
			-- each data line
			for data in block:gmatch("\ndata:%s*(.-)\n") do
				if handle_events_fn then
					handle_events_fn(data, ev)
				end
			end
		end
	end

	local function handle_legacy_stdout(_, out)
		line_buf = line_buf .. out:gsub("\r\n", "\n")
		local i = 1
		while true do
			local j = line_buf:find("\n", i, true)
			if not j then
				line_buf = line_buf:sub(i)
				break
			end
			local line = line_buf:sub(i, j - 1)
			i = j + 1
			if handle_legacy_fn then
				handle_legacy_fn(line)
			end
		end
	end

	local on_exit_common = vim.schedule_wrap(function()
		-- flush any leftover partial utf-8
		if utf8_carry ~= "" then
			append_at_anchor(utf8_carry)
			utf8_carry = ""
		end

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
		end_anchor()
	end)

	if stream_mode == "EVENTS" then
		active_job = Job:new({
			command = "curl",
			args = args,
			on_stdout = handle_events_stdout,
			on_stderr = function(_, _) end,
			on_exit = on_exit_common,
		})
	else
		active_job = Job:new({
			command = "curl",
			args = args,
			on_stdout = handle_legacy_stdout,
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
				end_anchor()
			end
		end,
	})

	vim.api.nvim_set_keymap("n", "<Esc>", ":doautocmd User LLM_Escape<CR>", { noremap = true, silent = true })

	return active_job
end

function M.reset_message_buffers()
	-- Reset OpenAI messages
	openai_messages = {}
	openai_count = 0
	openai_assistant_response = ""

	-- Reset Ollama context
	context = {}
	ollama_assistant_response = ""

	vim.notify("LLM buffers reset", vim.log.levels.INFO)
end

return M
