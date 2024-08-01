local M = {}

function M.log(log_entry)
	local home_path = os.getenv("HOME")
	local date = os.date("%Y-%m-%d")
	local log_directory = home_path .. "/.logs/"
	local log_file_path = log_directory .. date .. ".json"
	local command = "mkdir -p " .. log_directory
	os.execute(command)

	local log_file = io.open(log_file_path, "r")
	local log_entries = {}

	if log_file then
		local content = log_file:read("*a")
		if content and content ~= "" then
			print(content)
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
