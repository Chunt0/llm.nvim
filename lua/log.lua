local M = {}

local Config = require("llm_config")
local enabled = (os.getenv("LLM_LOG") == "1")
local redact = true

function M.setup(opts)
    if type(opts) == "table" then
        if opts.enabled ~= nil then
            enabled = not not opts.enabled
        end
        if opts.redact ~= nil then
            redact = not not opts.redact
        end
    end
end

local function ensure_dir(path)
    local ok, err = pcall(vim.fn.mkdir, path, "p")
    if not ok then
        vim.schedule(function()
            vim.notify("LLM log: failed to create log dir: " .. tostring(err), vim.log.levels.WARN)
        end)
    end
end

local function safe_decode(json_str)
    local ok, res = pcall(vim.json.decode, json_str)
    if ok and type(res) == "table" then
        return res
    end
    return {}
end

local function maybe_redact(entry)
    if not redact then
        return entry
    end
    local copy = {}
    for k, v in pairs(entry) do
        copy[k] = v
    end
    if copy.user and type(copy.user) == "table" then
        copy.user = { role = copy.user.role or "user", content = "[redacted]" }
    end
    if copy.assistant and type(copy.assistant) == "table" then
        local content = copy.assistant.content or ""
        if content and #content > 200 then
            content = content:sub(1, 200) .. " …"
        end
        copy.assistant = { role = copy.assistant.role or "assistant", content = content }
    end
    return copy
end

function M.log(log_entry)
    local cfg = Config.logging or {}
    if cfg.enabled ~= nil then enabled = cfg.enabled end
    if cfg.redact ~= nil then redact = cfg.redact end
    if not enabled then
        return
    end
    local data_dir = cfg.dir or (vim.fn.stdpath('data') .. "/llm/logs/")
    local date = os.date("%Y-%m-%d")
    local log_directory = data_dir
    local log_file_path = log_directory .. date .. ".json"

    ensure_dir(log_directory)

    local log_entries = {}
    local log_file = io.open(log_file_path, "r")
    if log_file then
        local content = log_file:read("*a")
        if content and content ~= "" then
            log_entries = safe_decode(content)
        end
        log_file:close()
    end

    table.insert(log_entries, maybe_redact(log_entry))

    log_file = io.open(log_file_path, "w")
    if log_file then
        local ok, out = pcall(vim.json.encode, log_entries)
        if ok then
            log_file:write(out)
        end
        log_file:close()
    else
        vim.schedule(function()
            vim.notify("LLM log: unable to open log file", vim.log.levels.WARN)
        end)
    end
end

return M
