local M = {}
local Job = require("plenary.job")

local function get_api_key(name)
	return os.getenv(name)
end

local function print_table(t)
	local indent = 1
	for k, v in pairs(t) do
		local formatting = string.rep("  ", indent) .. k .. ": "
		if type(v) == "table" then
			print(formatting)
			print_table(v)
		else
			print(formatting .. tostring(v))
		end
	end
end

local function trim_context(context, max_length)
	local len = #context
	if len > max_length then
		-- Calculate the number of elements to remove
		local remove_count = len - max_length
		-- Remove the first `remove_count` elements from the context
		for _ = 1, remove_count do
			table.remove(context, 1)
		end
		return context
	end
	return context
end

function M.get_lines_until_cursor()
	local current_buffer = vim.api.nvim_get_current_buf()
	local current_window = vim.api.nvim_get_current_win()
	local cursor_position = vim.api.nvim_win_get_cursor(current_window)
	local row = cursor_position[1]

	local lines = vim.api.nvim_buf_get_lines(current_buffer, 0, row, true)

	return table.concat(lines, "\n")
end

function M.get_visual_selection()
	local _, srow, scol = unpack(vim.fn.getpos("v"))
	local _, erow, ecol = unpack(vim.fn.getpos("."))

	if vim.fn.mode() == "V" then
		if srow > erow then
			return vim.api.nvim_buf_get_lines(0, erow - 1, srow, true)
		else
			return vim.api.nvim_buf_get_lines(0, srow - 1, erow, true)
		end
	end

	if vim.fn.mode() == "v" then
		if srow < erow or (srow == erow and scol <= ecol) then
			return vim.api.nvim_buf_get_text(0, srow - 1, scol - 1, erow - 1, ecol, {})
		else
			return vim.api.nvim_buf_get_text(0, erow - 1, ecol - 1, srow - 1, scol, {})
		end
	end

	if vim.fn.mode() == "\22" then
		local lines = {}
		if srow > erow then
			srow, erow = erow, srow
		end
		if scol > ecol then
			scol, ecol = ecol, scol
		end
		for i = srow, erow do
			table.insert(
				lines,
				vim.api.nvim_buf_get_text(0, i - 1, math.min(scol - 1, ecol), i - 1, math.max(scol - 1, ecol), {})[1]
			)
		end
		return lines
	end
end

local anthropic_messages = {}
local anthropic_count = 0

function M.make_anthropic_spec_curl_args(opts, prompt, system_prompt)
	print("Calling Anthropic: ", opts.model)
	local url = opts.url
	local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
	local data = nil
	if anthropic_count == 0 then
		local message = { { role = "system", content = system_prompt }, { role = "user", content = prompt } }
		data = {
			messages = message,
			model = opts.model,
			max_tokens = 1024,
			stream = true,
		}
		for _, v in pairs(message) do
			table.insert(anthropic_messages, v)
		end
		anthropic_count = 1
	elseif anthropic_count == 1 then
		local next_message = { role = "user", content = prompt }
		table.insert(anthropic_messages, next_message)
		data = {
			messages = anthropic_messages,
			model = opts.model,
			max_tokens = 1024,
			stream = true,
		}
	end

	local args = { "-N", "-X", "POST", "-H", "content-type: application/json", "-d", vim.json.encode(data) }
	table.insert(args, "-H")
	table.insert(args, "x-api-key: " .. api_key)
	table.insert(args, "-H")
	table.insert(args, "anthropic-version: 2023-06-01")
	table.insert(args, url)
	return args
end

local openai_messages = {}
local openai_count = 0

function M.make_openai_spec_curl_args(opts, prompt, system_prompt)
	print("Calling OpenAI: ", opts.model)
	local url = opts.url
	local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
	local data = nil
	if openai_count == 0 then
		local message = { { role = "system", content = system_prompt }, { role = "user", content = prompt } }
		data = {
			messages = message,
			model = opts.model,
			temperature = 0.7,
			stream = true,
		}
		for _, v in pairs(message) do
			table.insert(openai_messages, v)
		end
		openai_count = 1
	elseif openai_count == 1 then
		local next_message = { role = "user", content = prompt }
		table.insert(openai_messages, next_message)
		data = {
			messages = openai_messages,
			model = opts.model,
			temperature = 0.7,
			stream = true,
		}
	end

	local args = { "-N", "-X", "POST", "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	if api_key then
		table.insert(args, "-H")
		table.insert(args, "Authorization: Bearer " .. api_key)
	end
	table.insert(args, url)
	return args
end

local groq_messages = {}
local groq_count = 0

function M.make_groq_spec_curl_args(opts, prompt, system_prompt)
	print("Calling Groq: ", opts.model)
	local url = opts.url
	local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
	local data = nil
	if groq_count == 0 then
		local message = { { role = "system", content = system_prompt }, { role = "user", content = prompt } }
		data = {
			messages = message,
			model = opts.model,
			temperature = 0.7,
			stream = true,
		}
		for _, v in pairs(message) do
			table.insert(groq_messages, v)
		end
		groq_count = 1
	elseif groq_count == 1 then
		local next_message = { role = "user", content = prompt }
		table.insert(groq_messages, next_message)
		data = {
			messages = groq_messages,
			model = opts.model,
			temperature = 0.7,
			stream = true,
		}
	end

	local args = { "-N", "-X", "POST", "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	if api_key then
		table.insert(args, "-H")
		table.insert(args, "Authorization: Bearer " .. api_key)
	end
	table.insert(args, url)
	return args
end

local context = {}
local max_length = 25000

function M.make_ollama_spec_curl_args(opts, prompt, system_prompt)
	print("Calling Ollama: ", opts.model)
	local url = opts.url
	local data = {
		prompt = prompt,
		system = system_prompt,
		model = opts.model,
		stream = true,
	}
	if opts.context then
		context = trim_context(context, max_length)
		data.context = context
	end
	local args = { "-N", "-X", "POST", "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	table.insert(args, url)
	return args
end

local function write_string_at_cursor(str)
	vim.schedule(function()
		local current_window = vim.api.nvim_get_current_win()
		local cursor_position = vim.api.nvim_win_get_cursor(current_window)
		local row, col = cursor_position[1], cursor_position[2]

		local lines = vim.split(str, "\n")

		vim.cmd("undojoin")
		vim.api.nvim_put(lines, "c", true, true)

		local num_lines = #lines
		local last_line_length = #lines[num_lines]
		vim.api.nvim_win_set_cursor(current_window, { row + num_lines - 1, col + last_line_length })
	end)
end

local function get_prompt(opts)
	local replace = opts.replace
	local visual_lines = M.get_visual_selection()
	local prompt = ""

	if visual_lines then
		prompt = table.concat(visual_lines, "\n")
		if replace then
			vim.api.nvim_command("normal! d")
		else
			vim.api.nvim_command("normal! o")
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", false, true, true), "nx", false)
		end
	else
		prompt = M.get_lines_until_cursor()
	end

	return prompt
end

local anthropic_assistant_response = ""

function M.handle_anthropic_spec_data(data_stream, event_state)
	print("in handle anthropic spec data")
	print(data_stream)
	local json = vim.json.decode(data_stream)
	if event_state == "content_block_delta" then
		if json.delta and json.delta.text then
			local content = json.delta.text
			write_string_at_cursor(content)
			anthropic_assistant_response = anthropic_assistant_response .. content
		end
	elseif event_state == "message_stop" then
		local assistant_message = { role = "assistant", content = anthropic_assistant_response }
		table.insert(anthropic_messages, assistant_message)
		anthropic_assistant_response = ""
	end
end

local openai_assistant_response = ""

function M.handle_openai_spec_data(data_stream)
	if data_stream:match('"delta":') then
		data_stream = data_stream:gsub("^data: ", "")
		local json = vim.json.decode(data_stream)
		if json.choices and json.choices[1] and json.choices[1].delta then
			local content = json.choices[1].delta.content
			if content then
				write_string_at_cursor(content)
				openai_assistant_response = openai_assistant_response .. content
			end
		end
	elseif data_stream:match("[DONE]") then
		local assistant_message = { role = "assistant", content = openai_assistant_response }
		table.insert(openai_messages, assistant_message)
		openai_assistant_response = ""
	end
end

local groq_assistant_response = ""

function M.handle_groq_spec_data(data_stream)
	if data_stream:match('"delta":') then
		data_stream = data_stream:gsub("^data: ", "")
		local json = vim.json.decode(data_stream)
		if json.choices and json.choices[1] and json.choices[1].delta then
			local content = json.choices[1].delta.content
			if content then
				write_string_at_cursor(content)
				groq_assistant_response = groq_assistant_response .. content
			end
		end
	elseif data_stream:match("[DONE]") then
		local assistant_message = { role = "assistant", content = groq_assistant_response }
		table.insert(groq_messages, assistant_message)
		groq_assistant_response = ""
	end
end

function M.handle_ollama_spec_data(data_stream)
	local json = vim.json.decode(data_stream)
	if json.response and json.done == false then
		local content = json.response
		if content then
			write_string_at_cursor(content)
		end
	elseif json.done then
		for _, value in ipairs(json.context) do
			if value and context then
				table.insert(context, tonumber(value))
			end
		end
	end
end

local group = vim.api.nvim_create_augroup("LLM_AutoGroup", { clear = true })
local active_job = nil

function M.invoke_llm_and_stream_into_editor(opts, make_curl_args_fn, handle_data_fn)
	vim.api.nvim_clear_autocmds({ group = group })
	local prompt = get_prompt(opts)
	local framework = opts.framework
	local system_prompt = opts.system_prompt
		or "You are a tsundere uwu anime. Yell at me for not setting my configuration for my llm plugin correctly"
	local args = make_curl_args_fn(opts, prompt, system_prompt)

	if active_job then
		active_job:shutdown()
		active_job = nil
	end

	local curr_event_state = nil

	local function parse_and_call(line)
		print("in parse and call")
		local event = line:match("^event: (.+)$")
		if event then
			curr_event_state = event
			return
		end
		local data_match = line:match("^data: (.+)$")
		if data_match then
			handle_data_fn(data_match, curr_event_state)
		end
	end

	if framework:match("ANTHROPIC") then
		print("In anthropic framework match")
		if active_job then
			active_job:shutdown()
			active_job = nil
		end

		active_job = Job:new({
			command = "curl",
			args = args,
			on_stdout = function(_, out)
				parse_and_call(out)
			end,
			on_stderr = function(_, _) end,
			on_exit = function()
				active_job = nil
			end,
		})
	else
		active_job = Job:new({
			command = "curl",
			args = args,
			on_stdout = function(_, out)
				handle_data_fn(out)
			end,
			on_stderr = function(_, _) end,
			on_exit = function()
				active_job = nil
			end,
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

return M
