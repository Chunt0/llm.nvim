local Constants = require("constants")
local M = {}

function M.get_api_key(name)
  return os.getenv(name)
end

function M.print_table(t)
  local indent = 1
  for k, v in pairs(t) do
    local formatting = string.rep("  ", indent) .. k .. ": "
    if type(v) == "table" then
      print(formatting)
      M.print_table(v)
    else
      print(formatting .. tostring(v))
    end
  end
end

--- Return false if the file should be excluded from context.
function M.should_include_file(filename)
  if not filename or filename == "" then
    return false
  end
  local base = filename:gsub("\\", "/"):match("([^/]+)$") or filename
  local base_l = base:lower()

  -- Explicit filename exclusions
  if base_l == "chat.md" or base_l == "notes.md" then
    return false
  end

  for _, ex in ipairs(Constants.excluded_extensions) do
    local ex_l = tostring(ex):lower()
    if ex_l:sub(1, 1) == "." then
      if base_l:sub(-#ex_l) == ex_l then
        return false
      end
    else
      if base_l == ex_l then
        return false
      end
    end
  end
  return true
end

--- Collect buffer text from:
---   1. Context-picker selected buffers (always, if any)
---   2. All loaded buffers  (when opts.all_buffers == true)
function M.get_all_buffers_text(opts)
  local all_text = {}
  local max_bytes = (opts and opts.max_buffer_bytes)
    or (require("llm_config").context.max_buffer_bytes)
    or (200 * 1024)
  local include_fts = require("llm_config").context.include_filetypes

  local function process_buffer(buf)
    local filename = vim.api.nvim_buf_get_name(buf)
    if M.should_include_file(filename) then
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      table.insert(all_text, "File: " .. filename)
      table.insert(all_text, table.concat(lines, "\n"))
      table.insert(all_text, "\n---\n")
    end
  end

  -- Always include context-picker selection first
  local seen = {}
  local ok_cp, ContextPicker = pcall(require, "context_picker")
  if ok_cp then
    for _, bufnr in ipairs(ContextPicker.get_selected()) do
      seen[bufnr] = true
      process_buffer(bufnr)
    end
  end

  if opts and opts.all_buffers then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and not seen[buf] then
        local name = vim.api.nvim_buf_get_name(buf)
        if include_fts then
          local ft = vim.bo[buf].filetype
          local allowed = false
          for _, x in ipairs(include_fts) do
            if x == ft then
              allowed = true
              break
            end
          end
          if not allowed then
            goto continue
          end
        end
        local ok, stat = pcall(vim.loop.fs_stat, name)
        if not (ok and stat and stat.size and stat.size > max_bytes) then
          process_buffer(buf)
        end
        ::continue::
      end
    end
  end

  return table.concat(all_text, "\n")
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

function M.trim_context(context, max_length)
  local len = #context
  if len > max_length then
    local start_idx = len - max_length + 1
    local out = {}
    for i = start_idx, len do
      out[#out + 1] = context[i]
    end
    return out
  end
  return context
end

function M.get_prompt(opts)
  local replace = opts.replace
  local visual_lines = M.get_visual_selection()
  local prompt = nil

  if visual_lines then
    prompt = table.concat(visual_lines, "\n")

    if replace then
      -- Code-replacement mode: inject context-picker files if selected
      local ok_cp, ContextPicker = pcall(require, "context_picker")
      local ctx_text = ok_cp and ContextPicker.get_text() or nil

      local code_instruction = "# You are a dutiful coding assistant, your job is to ONLY WRITE CODE.\n"
        .. "ONLY RESPOND WITH CODE. NO EXPLANATIONS OUTSIDE A CODE BLOCK. ONLY SIMPLE COMMENTS IN CODE. "
        .. "IF WHAT IS HIGHLIGHTED IS CODE INFER HOW TO IMPROVE IT AND IMPROVE IT, OTHERWISE FOLLOW THE WRITTEN INSTRUCTIONS PERFECTLY.\n\n"
        .. "Here is your prompt:\n"
        .. prompt

      if ctx_text then
        prompt = "# Code Context:\n" .. ctx_text .. "\n\n" .. code_instruction
      else
        prompt = code_instruction
      end

      -- Delete the visual selection and prepare insertion point
      vim.api.nvim_command("normal! d")
      local bufnr = vim.api.nvim_get_current_buf()
      local line, _ = unpack(vim.api.nvim_win_get_cursor(0))
      vim.api.nvim_buf_set_lines(bufnr, line - 1, line - 1, false, { "" })
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", false, true, true), "nx", false)

    elseif opts.code_chat then
      -- Chat mode: insert Agent separator, then build buffer context
      if opts.ui_mode == "inline" then
        local bufnr = vim.api.nvim_get_current_buf()
        local line, _ = unpack(vim.api.nvim_win_get_cursor(0))
        local agent_line = "---------------------------Agent---------------------------"
        vim.api.nvim_buf_set_lines(bufnr, line, line, false, { "", agent_line, "", "" })
        vim.api.nvim_win_set_cursor(0, { line + 4, 0 })
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", false, true, true), "nx", false)
      end
      local buffer_text = M.get_all_buffers_text(opts)
      prompt = "# You are a highly knowledgeable coding assistant. "
        .. "I will give you the current code context and you will answer my questions with this context to help guide you.\n\n"
        .. "# Code Context:\n"
        .. buffer_text
        .. "\n\n# User question:\n"
        .. prompt

    else
      -- Plain invoke mode: insert Agent separator, inject context-picker files if any
      if opts.ui_mode == "inline" then
        local bufnr = vim.api.nvim_get_current_buf()
        local line, _ = unpack(vim.api.nvim_win_get_cursor(0))
        local agent_line = "---------------------------Agent---------------------------"
        vim.api.nvim_buf_set_lines(bufnr, line, line, false, { "", agent_line, "", "" })
        vim.api.nvim_win_set_cursor(0, { line + 4, 0 })
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", false, true, true), "nx", false)
      end
      local ok_cp, ContextPicker = pcall(require, "context_picker")
      if ok_cp then
        local ctx_text = ContextPicker.get_text()
        if ctx_text then
          prompt = "# Code Context:\n" .. ctx_text .. "\n\n# Question:\n" .. prompt
        end
      end
    end
  else
    vim.notify("LLM: You must highlight the prompt you wish to send.", vim.log.levels.ERROR)
  end

  return prompt
end

function M.write_string_at_cursor(str)
  vim.schedule(function()
    local current_window = vim.api.nvim_get_current_win()
    local cursor_position = vim.api.nvim_win_get_cursor(current_window)
    local row, col = cursor_position[1], cursor_position[2]

    local lines = vim.split(str, "\n")

    vim.cmd("undojoin")
    vim.api.nvim_put(lines, "c", true, true)

    local num_lines = #lines
    local last_line_length = #lines[num_lines]

    vim.api.nvim_win_set_cursor(
      current_window,
      { row + num_lines - 1, (num_lines > 1 and last_line_length or col + last_line_length) }
    )
  end)
end

return M
