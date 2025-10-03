-- llm_responses_debug.lua
-- Responses API *only* + aggressive debug logs.

local M = {}
local Job = require("plenary.job")
local Log = require("log")
local Utils = require("utils")

-- ===== Debug toggle =====
local DEBUG = true -- set true to spam :messages
local function dbg(msg)
	if not DEBUG then
		return
	end
	msg = "[llm] " .. tostring(msg)
	vim.schedule(function()
		pcall(vim.notify, msg, vim.log.levels.INFO)
	end)
	pcall(vim.api.nvim_echo, { { msg, "None" } }, true, {})
end
function M.set_debug(on)
	DEBUG = not not on
	dbg("DEBUG=" .. tostring(DEBUG))
end

-- ===== Stream anchor =====
local NS = vim.api.nvim_create_namespace("LLMStream")
local stream_anchor = nil
local function start_anchor()
	local bufnr = vim.api.nvim_get_current_buf()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local id = vim.api.nvim_buf_set_extmark(bufnr, NS, row - 1, col, { right_gravity = false })
	stream_anchor = { bufnr = bufnr, id = id }
	dbg(("anchor start buf=%d row=%d col=%d"):format(bufnr, row - 1, col))
end
local function append_at_anchor(txt)
	if not txt or txt == "" then
		return
	end
	txt = txt:gsub("[\r\b]", "")
	local sa = stream_anchor and { bufnr = stream_anchor.bufnr, id = stream_anchor.id } or nil
	vim.schedule(function()
		if not sa or not sa.bufnr or not sa.id or not vim.api.nvim_buf_is_loaded(sa.bufnr) then
			local bufnr = vim.api.nvim_get_current_buf()
			local row, col = unpack(vim.api.nvim_win_get_cursor(0))
			local id = vim.api.nvim_buf_set_extmark(bufnr, NS, row - 1, col, { right_gravity = false })
			stream_anchor = { bufnr = bufnr, id = id }
			sa = { bufnr = bufnr, id = id }
			dbg("anchor recreated")
		end
		local ok_pos, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, sa.bufnr, NS, sa.id, {})
		local row, col
		if ok_pos and pos and pos[1] ~= nil then
			row, col = pos[1], pos[2]
		else
			local last_row = vim.api.nvim_buf_line_count(sa.bufnr) - 1
			local last_line = vim.api.nvim_buf_get_lines(sa.bufnr, last_row, last_row + 1, false)[1] or ""
			row, col = last_row, #last_line
			pcall(vim.api.nvim_buf_set_extmark, sa.bufnr, NS, row, col, { id = sa.id, right_gravity = false })
			dbg("anchor moved to EOF")
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
	dbg("anchor cleared")
end

-- ===== UTF-8 safe write =====
local utf8_carry = ""
local function split_complete_utf8(s)
	if s == "" then
		return "", ""
	end
	local len, i = #s, #s
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

-- ===== State =====
local assistant_message = nil
local openai_count = 0
local openai_response_id = ""

-- ===== OpenAI (Responses API only) =====
function M.make_openai_spec_curl_args(opts, prompt, system_prompt)
	local model = opts.model
	local url = (opts.url and #opts.url > 0) and opts.url or "https://api.openai.com/v1/responses"
	local api_key = opts.api_key_name and Utils.get_api_key(opts.api_key_name) or os.getenv("OPENAI_API_KEY")
	local reasoning_effort = opts.reasoning_effort or "minimal"

	-- Build payload
	local data
	if openai_count == 0 then
		data = {
			model = model,
			stream = true,
			input = opts.input_overrides or prompt, -- can be string or messages[]
			instructions = system_prompt,
			reasoning = { effort = reasoning_effort },
			-- store = true,
		}
	else
		data = {
			model = model,
			stream = true,
			input = opts.input_overrides or prompt,
			previous_response_id = openai_response_id,
			reasoning = { effort = reasoning_effort },
		}
	end
	local json = vim.json.encode(data)
	dbg(("openai req: url=%s model=%s bytes=%d"):format(url, tostring(model), #json))
	if DEBUG then
		-- Print the first 400 chars of the payload
		local head = json:sub(1, 400)
		dbg("openai req head: " .. head .. (#json > 400 and " …" or ""))
	end

	-- Compose curl args (Responses API + SSE)
	local args = {
		"-sS", -- quiet progress, show errors
		"-N", -- no buffering (stream)
		"--no-buffer", -- keep flushing
		"--fail-with-body", -- non-2xx -> error + body on stderr
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-H",
		"Accept: text/event-stream",
		"-d",
		json,
	}
	if api_key and #api_key > 0 then
		table.insert(args, "-H")
		table.insert(args, "Authorization: Bearer " .. api_key)
	else
		dbg("WARNING: no OPENAI_API_KEY found")
	end
	-- If needed for certain models:
	-- table.insert(args, "-H"); table.insert(args, "OpenAI-Beta: reasoning=enable")
	table.insert(args, url)

	-- Log final curl line (redact key)
	do
		local shown = {}
		for _, a in ipairs(args) do
			if type(a) == "string" then
				a = a:gsub("Authorization: Bearer%s+[%w%p]+", "Authorization: Bearer ***")
			end
			table.insert(shown, a)
		end
		dbg("curl " .. table.concat(shown, " "))
	end

	return args
end

function M.handle_openai_spec_data(line)
	if not line then
		return
	end
	-- Raw SSE line visibility
	if DEBUG then
		local preview = line
		if #preview > 220 then
			preview = preview:sub(1, 200) .. " … " .. preview:sub(-20)
		end
		dbg(("SSE line(%d): %s"):format(#line, preview:gsub("\r", "\\r"):gsub("\t", "\\t")))
	end

	-- Ignore comments/heartbeats and 'event:' lines
	if line:match("^:%s?.*") or line:match("^event:%s*[%w%._-]+%s*$") then
		return
	end

	-- Typical end sentinel from SSE sources; Responses API doesn't use [DONE] but safe to ignore
	if line:match("^data:%s*%[DONE%]") then
		return
	end

	local payload = line:gsub("^data:%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if payload == "" then
		return
	end

	local ok, json = pcall(vim.json.decode, payload)
	if not ok or not json then
		dbg("JSON decode fail: " .. payload)
		return
	end

	dbg("Current json: " .. json)

	-- Capture response id early
	if json.response and json.response.id and openai_response_id == "" then
		openai_response_id = json.response.id
		dbg("response.id=" .. openai_response_id)
	end

	local t = tostring(json.type or "")

	-- Streaming text delta
	if (t == "response.output_text.delta" or t:match("%.output_text%.delta$")) and json.delta then
		write_safely(json.delta)
		return
	end

	-- Final output chunk for that channel
	if t == "response.output_text.done" or t:match("%.output_text%.done$") then
		if json.content and json.content[1] and json.content[1].text then
			assistant_message = { role = "assistant", content = json.content[1].text }
		end
		return
	end

	if t == "response.completed" then
		dbg("response.completed")
		return
	end

	if t == "response.error" and json.error then
		dbg("OpenAI error: " .. (json.error.message or vim.inspect(json.error)))
		return
	end

	-- Log anything unexpected so we can adapt
	if DEBUG then
		dbg("Unhandled event: " .. vim.inspect(json))
	end
end

-- ===== Invoke =====
local group = vim.api.nvim_create_augroup("LLM_AutoGroup", { clear = true })
local active_job = nil

function M.invoke_llm_and_stream_into_editor(opts, make_curl_args_fn, handle_spec_data_fn)
	vim.api.nvim_clear_autocmds({ group = group })

	local prompt = Utils.get_prompt(opts)
	if not prompt or prompt == "" then
		dbg("no prompt from Utils.get_prompt(opts)")
		return
	end

	local replace = opts.replace
	local framework = opts.framework
	local model = opts.model
	local system_prompt = opts.system_prompt or "Please configure your system prompt."

	local args = make_curl_args_fn(opts, prompt, system_prompt)

	if active_job then
		dbg("shutting down previous job")
		active_job:shutdown()
		active_job = nil
	end

	start_anchor()

	local line_buf = ""
	local total_bytes = 0
	local total_lines = 0

	local function normalize_chunk(out)
		if type(out) == "table" then
			out = table.concat(out, "\n")
		end
		return (out or ""):gsub("\r\n", "\n")
	end

	local function on_stdout(_, out)
		local chunk = normalize_chunk(out)
		if chunk == "" then
			return
		end
		total_bytes = total_bytes + #chunk
		if DEBUG then
			local prev = chunk
			if #prev > 220 then
				prev = prev:sub(1, 200) .. " … " .. prev:sub(-20)
			end
			-- dbg(("stdout chunk bytes=%d head/tail: %s"):format(#chunk, prev:gsub("\r", "\\r")))
		end

		line_buf = line_buf .. chunk
		while true do
			local j = line_buf:find("\n", 1, true)
			if not j then
				break
			end
			local line = line_buf:sub(1, j - 1)
			line_buf = line_buf:sub(j + 1)
			total_lines = total_lines + 1
			if handle_spec_data_fn and line ~= "" then
				dbg("Entering handle_spec_data with line: " .. line)
				handle_spec_data_fn(line)
			end
		end
	end

	local on_exit_common = vim.schedule_wrap(function(code, signal)
		dbg(
			("curl exit code=%s signal=%s total_bytes=%d total_lines=%d remainder_bytes=%d"):format(
				tostring(code),
				tostring(signal),
				total_bytes,
				total_lines,
				#line_buf
			)
		)

		-- Try to parse any remainder
		if line_buf ~= "" then
			local payload = line_buf:gsub("^data:%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
			local ok, json = pcall(vim.json.decode, payload)
			if ok and json and handle_spec_data_fn then
				handle_spec_data_fn("data: " .. payload)
			else
				if DEBUG then
					--dbg("remainder not JSON: " .. payload)
				end
			end
			line_buf = ""
		end

		if utf8_carry ~= "" then
			write_safely(utf8_carry)
			utf8_carry = ""
		end

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
		pcall(Log.log, log_entry)
		active_job = nil
		assistant_message = nil
		end_anchor()
		dbg("job closed")
	end)

	active_job = Job:new({
		command = "curl",
		args = args,
		on_stdout = on_stdout,
		on_stderr = function(_, err)
			if err and err ~= "" then
				-- curl --fail-with-body will dump HTTP errors here
				local eprev = err
				if #eprev > 400 then
					eprev = eprev:sub(1, 380) .. " … " .. eprev:sub(-20)
				end
				dbg("STDERR: " .. eprev:gsub("\r", "\\r"))
			end
		end,
		on_exit = on_exit_common,
		enable_handlers = true,
	})

	dbg("starting curl job…")
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
				dbg("cancelled by user")
			end
		end,
	})

	vim.api.nvim_set_keymap("n", "<Esc>", ":doautocmd User LLM_Escape<CR>", { noremap = true, silent = true })
	return active_job
end

function M.reset_message_buffers()
	openai_count = 0
	openai_response_id = ""
	assistant_message = nil
	vim.notify("LLM buffers reset", vim.log.levels.INFO)
end

return M
