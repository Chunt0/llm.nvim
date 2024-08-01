local M = {}

local log_file_path = "log.json"

function M.log(log_entry)
	local log_file = io.open(log_file_path, "r")
	local log_entries = {}

	if log_file then
		local content = log_file:read("*a")
		if content and content ~= "" then
			log_entries = vim.json.decode(content)
		end
		log_file:close()
	end

	-- Append the new log entry
	table.insert(log_entries, log_entry)

	-- Write the updated log entries back to the file
	log_file = io.open(log_file_path, "w")
	if log_file then
		log_file:write(vim.json.encode(log_entries))
		log_file:close()
	else
		print("Error: Unable to open log file.")
	end
end

return M
