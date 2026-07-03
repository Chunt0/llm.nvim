-- Pending-edit review (SPEC.md §F3): agent-proposed edits never touch a file
-- directly. edit_file/write_file compute a pending edit here; review() shows
-- it as a native diff and apply() runs only on accept — via the buffer for
-- loaded files (the user decides when to :w), via disk for unloaded ones.
local Fs = require("llm.util.fs")

local M = {}

--- Plain-text (non-pattern) replacement. Returns new string + match count;
--- replaces only the first occurrence unless all is true.
function M.replace_plain(s, old, new, all)
  local out, init, n = {}, 1, 0
  while true do
    local i, j = s:find(old, init, true)
    if not i then
      table.insert(out, s:sub(init))
      break
    end
    n = n + 1
    table.insert(out, s:sub(init, i - 1))
    table.insert(out, new)
    init = j + 1
    if not all then
      table.insert(out, s:sub(init))
      break
    end
  end
  return table.concat(out), n
end

function M.count_plain(s, needle)
  local n, init = 0, 1
  while true do
    local i, j = s:find(needle, init, true)
    if not i then
      return n
    end
    n = n + 1
    init = j + 1
  end
end

--- Compute a pending edit for a str_replace-style change.
--- Returns spec | nil, err. The spec carries everything review/apply need:
--- { kind = "edit", path, abs, new_lines, summary, changedtick? }
function M.compute_edit(input, ctx)
  local abs, err = Fs.confine(input.path, ctx.root, ctx)
  if not abs then
    return nil, err
  end
  local denied, why = Fs.is_denied(abs)
  if denied then
    return nil, why
  end
  if type(input.old_string) ~= "string" or input.old_string == "" then
    return nil, "old_string must be a non-empty string"
  end
  if type(input.new_string) ~= "string" then
    return nil, "new_string must be a string"
  end
  local lines = Fs.read_lines(abs)
  if not lines then
    return nil, "file not found: " .. Fs.relative(abs, ctx.root) .. " (use write_file to create a new file)"
  end
  local content = table.concat(lines, "\n")
  local count = M.count_plain(content, input.old_string)
  if count == 0 then
    return nil, "old_string not found in " .. Fs.relative(abs, ctx.root) .. " — read the file again and match exactly"
  end
  if count > 1 and not input.replace_all then
    return nil,
      count .. " matches for old_string in " .. Fs.relative(abs, ctx.root) .. " — add context or set replace_all"
  end
  local new_content = M.replace_plain(content, input.old_string, input.new_string, input.replace_all)
  local rel = Fs.relative(abs, ctx.root)
  return {
    kind = "edit",
    path = rel,
    abs = abs,
    root = ctx.root,
    old_string = input.old_string,
    new_string = input.new_string,
    replace_all = input.replace_all and true or false,
    new_lines = vim.split(new_content, "\n", { plain = true }),
    base_content = content,
    summary = string.format("edit %s (%d replacement%s)", rel, count, count == 1 and "" or "s"),
  }
end

--- Compute a pending edit that creates or overwrites a whole file.
function M.compute_write(input, ctx)
  local abs, err = Fs.confine(input.path, ctx.root, ctx)
  if not abs then
    return nil, err
  end
  local denied, why = Fs.is_denied(abs)
  if denied then
    return nil, why
  end
  if type(input.content) ~= "string" then
    return nil, "content must be a string"
  end
  local exists = Fs.read_lines(abs) ~= nil
  local rel = Fs.relative(abs, ctx.root)
  return {
    kind = exists and "overwrite" or "create",
    path = rel,
    abs = abs,
    root = ctx.root,
    new_lines = vim.split(input.content, "\n", { plain = true }),
    summary = (exists and "OVERWRITE " or "create ") .. rel,
  }
end

--- Staleness guard: recompute an edit against the file's current content.
--- Returns a fresh spec | nil, err ("stale" when the anchor is gone).
local function refresh(spec, ctx)
  if spec.kind ~= "edit" then
    return spec
  end
  local lines = Fs.read_lines(spec.abs)
  local content = lines and table.concat(lines, "\n") or nil
  if content == spec.base_content then
    return spec
  end
  local fresh, err = M.compute_edit({
    path = spec.path,
    old_string = spec.old_string,
    new_string = spec.new_string,
    replace_all = spec.replace_all,
  }, ctx)
  if not fresh then
    return nil, "edit is stale — the file changed and the target text no longer matches (" .. (err or "?") .. ")"
  end
  return fresh
end

--- Apply a pending edit: buffer when loaded (no disk write), disk otherwise.
--- Returns { result } | { error }.
function M.apply(spec, ctx)
  local fresh, err = refresh(spec, ctx or { root = spec.root })
  if not fresh then
    return { error = err }
  end
  spec = fresh
  local bufnr = Fs.buffer_for(spec.abs)
  if bufnr then
    local ok, aerr = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, spec.new_lines)
    if not ok then
      return { error = "failed to apply to buffer: " .. tostring(aerr) }
    end
    return { result = "applied to " .. spec.path .. " (buffer — :w to save)" }
  end
  if spec.kind == "create" then
    local dir = spec.abs:match("^(.*)/[^/]+$")
    if dir then
      pcall(function()
        vim.fn.mkdir(dir, "p")
      end)
    end
  end
  local f = io.open(spec.abs, "w")
  if not f then
    return { error = "cannot write " .. spec.path }
  end
  f:write(table.concat(spec.new_lines, "\n"))
  f:write("\n")
  f:close()
  return { result = (spec.kind == "create" and "created " or "wrote ") .. spec.path }
end

-- ===== Review UI ==============================================================

--- Pick a window to host the review: the first one not showing skip_bufnr.
local function host_window(skip_bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) ~= skip_bufnr then
      return win
    end
  end
  return vim.api.nvim_get_current_win()
end

--- Show a pending edit as a native diff and wait for accept/reject.
--- done({ result }|{ error }) fires exactly once. opts: { panel_bufnr }.
function M.review(spec, ctx, done, opts)
  local Config = require("llm.config")
  local km = Config.keymaps or {}
  local key_accept = km.diff_accept or "<leader>da"
  local key_reject = km.diff_reject or "<leader>dr"

  local prev_win = vim.api.nvim_get_current_win()
  local host = host_window(opts and opts.panel_bufnr)
  vim.api.nvim_set_current_win(host)

  -- Left: the target file (current content; empty scratch for a new file).
  local target_bufnr
  if spec.kind == "create" then
    target_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(host, target_bufnr)
  else
    vim.cmd("edit " .. vim.fn.fnameescape(spec.abs))
    target_bufnr = vim.api.nvim_get_current_buf()
  end

  -- Right: scratch with the proposed content.
  vim.cmd("vsplit")
  local scratch_win = vim.api.nvim_get_current_win()
  local scratch_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(scratch_win, scratch_bufnr)
  vim.bo[scratch_bufnr].buftype = "nofile"
  vim.bo[scratch_bufnr].swapfile = false
  vim.bo[scratch_bufnr].bufhidden = "wipe"
  pcall(function()
    vim.bo[scratch_bufnr].filetype = vim.bo[target_bufnr].filetype
  end)
  vim.api.nvim_buf_set_lines(scratch_bufnr, 0, -1, false, spec.new_lines)

  vim.api.nvim_set_current_win(host)
  vim.cmd("diffthis")
  vim.api.nvim_set_current_win(scratch_win)
  vim.cmd("diffthis")

  vim.notify(
    "LLM agent proposes: " .. spec.summary .. " — " .. key_accept .. ": accept  " .. key_reject .. ": reject",
    vim.log.levels.WARN
  )

  local settled = false
  local function settle(accepted)
    if settled then
      return
    end
    settled = true
    for _, b in ipairs({ target_bufnr, scratch_bufnr }) do
      pcall(vim.keymap.del, "n", key_accept, { buffer = b })
      pcall(vim.keymap.del, "n", key_reject, { buffer = b })
    end
    pcall(vim.cmd, "diffoff!")
    pcall(vim.api.nvim_win_close, scratch_win, true)
    if vim.api.nvim_win_is_valid(prev_win) then
      pcall(vim.api.nvim_set_current_win, prev_win)
    end
    if accepted then
      done(M.apply(spec, ctx))
    else
      local reason = ""
      pcall(function()
        reason = vim.fn.input("Reject reason (optional): ")
      end)
      done({ error = "user rejected the edit" .. (reason ~= "" and (": " .. reason) or "") })
    end
  end

  for _, b in ipairs({ target_bufnr, scratch_bufnr }) do
    pcall(vim.keymap.set, "n", key_accept, function()
      settle(true)
    end, { buffer = b, nowait = true, silent = true, desc = "LLM edit: accept" })
    pcall(vim.keymap.set, "n", key_reject, function()
      settle(false)
    end, { buffer = b, nowait = true, silent = true, desc = "LLM edit: reject" })
  end

  -- Closing the scratch window manually counts as reject.
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = scratch_bufnr,
    once = true,
    callback = function()
      settle(false)
    end,
  })
end

return M
