-- llm.lua (OpenAI Chat Completions + Ollama only)
-- Robust SSE buffering, UTF-8 safe writes, anchored insertion, and debug taps.
local M = {}
local Job = require("plenary.job")
local Log = require("log")
local Utils = require("utils")

-- ===== Debug =====
local DEBUG = false
local function dbg(msg)
	if not DEBUG then
		return
	end
	msg = "[llm] " .. tostring(msg)
	vim.schedule(function()
		pcall(vim.notify, msg, vim.log.levels.INFO)
	end)
	-- also echo to :messages
	pcall(vim.api.nvim_echo, { { msg, "None" } }, true, {})
end
function M.set_debug(on)
	DEBUG = not not on
	dbg("DEBUG=" .. tostring(DEBUG))
end

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
	dbg("Anchor started at row=" .. (row - 1) .. ", col=" .. col)
end

-- resilient writer that survives anchor clears and buffer switches
local function append_at_anchor(txt)
	if not txt or txt == "" then
		return
	end
	txt = txt:gsub("[\r\b]", "")

	local sa = stream_anchor and { bufnr = stream_anchor.bufnr, id = stream_anchor.id } or nil

	vim.schedule(function()
		-- if anchor gone, recreate one at current cursor in the current buffer
		if not sa or not sa.bufnr or not sa.id or not vim.api.nvim_buf_is_loaded(sa.bufnr) then
			local bufnr = vim.api.nvim_get_current_buf()
			local row, col = unpack(vim.api.nvim_win_get_cursor(0))
			local id = vim.api.nvim_buf_set_extmark(bufnr, NS, row - 1, col, { right_gravity = false })
			stream_anchor = { bufnr = bufnr, id = id }
			sa = { bufnr = bufnr, id = id }
			dbg("Anchor recreated at row=" .. (row - 1) .. ", col=" .. col)
		end

		-- find current mark; if missing, move to end-of-buffer
		local ok_pos, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, sa.bufnr, NS, sa.id, {})
		local row, col
		if ok_pos and pos and pos[1] ~= nil then
			row, col = pos[1], pos[2]
		else
			local last_row = vim.api.nvim_buf_line_count(sa.bufnr) - 1
			local last_line = vim.api.nvim_buf_get_lines(sa.bufnr, last_row, last_row + 1, false)[1] or ""
			row, col = last_row, #last_line
			pcall(vim.api.nvim_buf_set_extmark, sa.bufnr, NS, row, col, { id = sa.id, right_gravity = false })
			dbg("Extmark missing; moved to EOF row=" .. row .. ", col=" .. col)
		end

		local lines = vim.split(txt, "\n", { plain = true })
		pcall(vim.api.nvim_buf_set_text, sa.bufnr, row, col, row, col, lines)

		local last = lines[#lines]
		local new_row = row + (#lines - 1)
		local new_col = (#lines == 1) and (col + #last) or #last
		pcall(vim.api.nvim_buf_set_extmark, sa.bufnr, NS, new_row, new_col, { id = sa.id, right_gravity = false })
	end)
end

local function end_anchor()
	stream_anchor = nil
	dbg("Anchor cleared")
end

-- ===== UTF-8 safe streaming (carry incomplete multi-byte at chunk boundary)
local utf8_carry = ""

local function split_complete_utf8(s)
	if s == "" then
		return "", ""
	end
	local len = #s
	local i = len
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
	if utf8_carry ~= "" then
		chunk = utf8_carry .. chunk
		utf8_carry = ""
	end
	chunk = chunk:gsub("\r\n", "\n"):gsub("[\r\b]", "")
	local complete, tail = split_complete_utf8(chunk)
	utf8_carry = tail
	if complete ~= "" then
		append_at_anchor(complete)
	end
end

-------------------------------- Initialize Variables---------------------------
local assistant_message = nil

-- OpenAI (chat/completions) state
local openai_messages = {}
local openai_count = 0
local openai_assistant_response = ""
local openai_prev_resp_id = nil

-- Ollama state
local ollama_assistant_response = ""
local context = {}
local max_length = 25000

------------------------------------- OpenAI (Chat Completions only) -----------------------------------
-- No Responses endpoint, no temperature/top_p/etc.
function M.make_openai_spec_curl_args(opts, prompt, system_prompt)
	print("Calling OpenAI: ", opts.model)

	local model = opts.model
	local url_chat = opts.url_chat or "https://api.openai.com/v1/chat/completions"
	local api_key = opts.api_key_name and Utils.get_api_key(opts.api_key_name)
	local reasoning_effort = "minimal"

	local data

	if openai_count == 0 then
		local first = {
			{ role = "system", content = system_prompt },
			{ role = "user", content = prompt },
		}
		data = {
			model = model,
			messages = first,
			stream = true,
			reasoning_effort = reasoning_effort,
		}
		for _, v in pairs(first) do
			table.insert(openai_messages, v)
		end
	else
		local next_message = { role = "user", content = prompt }
		table.insert(openai_messages, next_message)
		data = {
			model = model,
			messages = openai_messages,
			stream = true,
		}
	end

	openai_count = openai_count + 1

	local args = { "-sS", "-N", "-X", "POST", "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	if api_key then
		table.insert(args, "-H")
		table.insert(args, "Authorization: Bearer " .. api_key)
	end
	table.insert(args, url_chat)

	-- debug: show curl args (redact bearer)
	do
		local shown = {}
		for _, a in ipairs(args) do
			if type(a) == "string" then
				a = a:gsub("Authorization: Bearer%s+[%w%p]+", "Authorization: Bearer ***")
			end
			table.insert(shown, a)
		end
		dbg("OpenAI curl args: " .. table.concat(shown, " "))
	end

	return args, "LEGACY"
end

-- Chat Completions SSE handler (one line is "data: {...}" or "data: [DONE]")
function M.handle_openai_spec_data(line)
	if not line or line == "" then
		return
	end
	dbg("OpenAI LEGACY line: " .. math.min(#line, 160) .. " bytes")
	if line:match("^data:%s*%[DONE%]") then
		assistant_message = { role = "assistant", content = openai_assistant_response }
		table.insert(openai_messages, assistant_message)
		openai_assistant_response = ""
		return
	end
	local payload = line:gsub("^data:%s*", "")
	if payload == "" then
		return
	end

	local ok, json = pcall(vim.json.decode, payload)
	if not ok or not json then
		return
	end
	local delta = json.choices and json.choices[1] and json.choices[1].delta and json.choices[1].delta.content
	if delta then
		write_safely(delta)
		openai_assistant_response = openai_assistant_response .. delta
	end
end

------------------------------------- OpenAI (Responses API) -----------------------------------
-- New Responses endpoint support with reasoning effort and previous_response_id
function M.make_openai_spec_curl_args(opts, prompt, system_prompt)
	-- log call
	print("Calling OpenAI: ", opts.model)

	local model = opts.model
	local url_responses = opts.url_responses or "https://api.openai.com/v1/responses"
	local api_key = opts.api_key_name and Utils.get_api_key(opts.api_key_name)
	local reasoning_effort = opts.reasoning_effort or "minimal"

	-- Build request body for Responses API
	local data = {
		model = model,
		instructions = system_prompt,
		input = prompt,
		stream = true,
		reasoning = { effort = reasoning_effort },
	}

	-- If we have a previous response id, include it
	if openai_prev_response_id and openai_prev_response_id ~= "" and openai_count > 0 then
		data.previous_response_id = openai_prev_response_id
	end

	-- Track this invocation count
	openai_count = (openai_count or 0) + 1

	-- Build curl args
	local args = { "-sS", "-N", "-X", "POST", "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	if api_key then
		table.insert(args, "-H")
		table.insert(args, "Authorization: Bearer " .. api_key)
	end
	table.insert(args, url_responses)

	-- debug: show curl args (redact bearer)
	do
		local shown = {}
		for _, a in ipairs(args) do
			if type(a) == "string" then
				a = a:gsub("Authorization: Bearer%s+[%w%p]+", "Authorization: Bearer ***")
			end
			table.insert(shown, a)
		end
		dbg("OpenAI curl args: " .. table.concat(shown, " "))
	end

	return args, "RESPONSES"
end

-- Responses SSE handler (handles new Responses API streaming chunks and [DONE])
function M.handle_openai_spec_data(line)
	if not line or line == "" then
		return
	end
	dbg("OpenAI RESPONSES line: " .. math.min(#line, 160) .. " bytes")

	-- End of stream
	if line:match("^data:%s*%[DONE%]") then
		-- finalize assistant message and save to history
		local assistant_message = { role = "assistant", content = openai_assistant_response }
		table.insert(openai_messages, assistant_message)
		-- reset accumulator
		openai_assistant_response = ""
		return
	end

	-- strip "data: " prefix
	local payload = line:gsub("^data:%s*", "")
	if payload == "" then
		return
	end

	local ok, json = pcall(vim.json.decode, payload)
	if not ok or not json then
		return
	end

	-- save response id if provided so next request can reference it
	if json.id and type(json.id) == "string" then
		openai_prev_response_id = json.id
	end

	-- extract incremental text from various possible payload shapes
	local delta_text = ""

	-- 1) delta.content arrays (like some streaming formats)
	if json.delta and json.delta.content then
		local contents = json.delta.content
		if type(contents) == "string" then
			delta_text = delta_text .. contents
		elseif type(contents) == "table" then
			for _, c in ipairs(contents) do
				if type(c) == "string" then
					delta_text = delta_text .. c
				elseif type(c) == "table" then
					if c.text and type(c.text) == "string" then
						delta_text = delta_text .. c.text
					elseif c.content and type(c.content) == "string" then
						delta_text = delta_text .. c.content
					end
				end
			end
		end
	end

	-- 2) output array (Responses API may emit output with content blocks)
	if delta_text == "" and json.output and type(json.output) == "table" then
		for _, out in ipairs(json.output) do
			-- if out is a text block with .content array
			if out.content and type(out.content) == "table" then
				for _, c in ipairs(out.content) do
					if c.text and type(c.text) == "string" then
						delta_text = delta_text .. c.text
					elseif type(c) == "string" then
						delta_text = delta_text .. c
					end
				end
			-- else some formats use .text directly
			elseif out.text and type(out.text) == "string" then
				delta_text = delta_text .. out.text
			end
		end
	end

	-- 3) legacy Chat-style choices.delta.content
	if
		delta_text == ""
		and json.choices
		and json.choices[1]
		and json.choices[1].delta
		and json.choices[1].delta.content
	then
		local c = json.choices[1].delta.content
		if type(c) == "string" then
			delta_text = delta_text .. c
		elseif type(c) == "table" then
			for _, part in ipairs(c) do
				if type(part) == "string" then
					delta_text = delta_text .. part
				elseif type(part) == "table" and part.text then
					delta_text = delta_text .. part.text
				end
			end
		end
	end

	-- write and accumulate if we found incremental text
	if delta_text and delta_text ~= "" then
		write_safely(delta_text)
		openai_assistant_response = (openai_assistant_response or "") .. delta_text
	end
end

------------------------------------- Ollama -----------------------------------
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
	local args = { "-sS", "-N", "-X", "POST", "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	table.insert(args, url)

	-- debug
	do
		local shown = {}
		for _, a in ipairs(args) do
			table.insert(shown, a)
		end
		dbg("Ollama curl args: " .. table.concat(shown, " "))
	end

	return args, "LEGACY"
end

function M.handle_ollama_spec_data(line)
	if not line or line == "" then
		return
	end
	dbg("Ollama LEGACY line: " .. math.min(#line, 160) .. " bytes")
	local ok, json = pcall(vim.json.decode, line)
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

-- ===== JSON extractor for concatenated JSON streams (no newlines)
local function extract_json_objects(buf)
	local out = {}
	local i, n = 1, #buf
	while true do
		local s = buf:find("{", i, true)
		if not s then
			break
		end
		local j, depth, in_str, esc = s, 0, false, false
		while j <= n do
			local c = buf:sub(j, j)
			if in_str then
				if esc then
					esc = false
				elseif c == "\\" then
					esc = true
				elseif c == '"' then
					in_str = false
				end
			else
				if c == '"' then
					in_str = true
				elseif c == "{" then
					depth = depth + 1
				elseif c == "}" then
					depth = depth - 1
					if depth == 0 then
						local json_str = buf:sub(s, j)
						table.insert(out, json_str)
						i = j + 1
						break
					end
				end
			end
			j = j + 1
		end
		if j > n then
			i = s
			break
		end -- incomplete object at end
	end
	local remainder = (i <= n) and buf:sub(i) or ""
	return out, remainder
end

-------------------------------- Invoke LLM -----------------------------------
local group = vim.api.nvim_create_augroup("LLM_AutoGroup", { clear = true })
local active_job = nil

function M.invoke_llm_and_stream_into_editor(opts, make_curl_args_fn, handle_legacy_fn, _handle_events_fn)
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
	-- Force legacy mode (we only support chat.completions + ollama)
	stream_mode = "LEGACY"

	if active_job then
		active_job:shutdown()
		active_job = nil
	end

	start_anchor()
	dbg("Starting job in mode: " .. stream_mode)

	-- === Robust chunk buffer for LEGACY mode
	local line_buf = ""

	local function normalize_chunk(out)
		if type(out) == "table" then
			out = table.concat(out, "\n")
		end
		return (out or ""):gsub("\r\n", "\n")
	end

	local function legacy_on_stdout(_, out)
		local chunk = normalize_chunk(out)
		if chunk == "" then
			return
		end
		dbg("LEGACY chunk: " .. #chunk .. " bytes")

		line_buf = line_buf .. chunk
		local progressed = true
		while progressed do
			progressed = false

			-- Case A: newline-delimited lines (OpenAI chat style)
			local j = line_buf:find("\n", 1, true)
			if j then
				local line = line_buf:sub(1, j - 1)
				line_buf = line_buf:sub(j + 1)
				if handle_legacy_fn and line ~= "" then
					handle_legacy_fn(line)
				end
				progressed = true
			else
				-- Case B: concatenated JSON objects (Ollama style)
				local objs
				objs, line_buf = extract_json_objects(line_buf)
				if #objs > 0 then
					for _, js in ipairs(objs) do
						if handle_legacy_fn then
							handle_legacy_fn(js)
						end
					end
					progressed = true
				end
			end
		end
	end

	local on_exit_common = vim.schedule_wrap(function()
		-- Flush any remainder (possibly a complete JSON without newline)
		if line_buf and line_buf ~= "" then
			dbg("Flushing remainder from line_buf (" .. #line_buf .. " bytes)")
			local objs
			objs, line_buf = extract_json_objects(line_buf)
			for _, js in ipairs(objs) do
				if handle_legacy_fn then
					handle_legacy_fn(js)
				end
			end
			line_buf = ""
		end

		-- flush any leftover partial utf-8
		if utf8_carry ~= "" then
			append_at_anchor(utf8_carry)
			utf8_carry = ""
		end

		-- move cursor to last line in current buffer, then set lines and set cursor
		if not replace then
			local bufnr = vim.api.nvim_get_current_buf()
			local last_line = vim.api.nvim_buf_line_count(bufnr) - 1
			local insert_at = last_line + 1
			local user_line = "---------------------------User---------------------------"
			vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, { "", user_line, "" })
			vim.api.nvim_win_set_cursor(0, { insert_at + 3, 0 })
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
		dbg("Job exited")
	end)

	active_job = Job:new({
		command = "curl",
		args = args,
		on_stdout = legacy_on_stdout,
		on_stderr = function(_, err)
			if err and err ~= "" then
				dbg("STDERR: " .. err)
			end
		end,
		on_exit = on_exit_common,
		enable_handlers = true,
	})

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
	openai_messages = {}
	openai_count = 0
	openai_assistant_response = ""

	context = {}
	ollama_assistant_response = ""

	vim.notify("LLM buffers reset", vim.log.levels.INFO)
end

return M
