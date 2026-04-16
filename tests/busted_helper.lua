-- Stubs out Neovim-only globals so pure-logic tests run under standalone busted.
-- Loaded before any spec via the .busted config helper= option.

-- ── 1. Minimal pure-Lua JSON decoder/encoder ──────────────────────────────────

local function json_decode(s)
  local pos = 1

  local function skip_ws()
    while pos <= #s and s:sub(pos, pos):match("%s") do pos = pos + 1 end
  end

  local parse_value  -- forward declaration

  local function parse_string()
    pos = pos + 1  -- skip opening "
    local buf = {}
    while pos <= #s do
      local c = s:sub(pos, pos)
      if c == "\\" then
        pos = pos + 1
        local e = s:sub(pos, pos)
        local esc = { ['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t' }
        table.insert(buf, esc[e] or e)
        pos = pos + 1
      elseif c == '"' then
        pos = pos + 1
        return table.concat(buf)
      else
        table.insert(buf, c)
        pos = pos + 1
      end
    end
    error("unterminated string")
  end

  local function parse_object()
    pos = pos + 1  -- skip {
    local obj = {}
    skip_ws()
    if s:sub(pos, pos) == "}" then pos = pos + 1; return obj end
    while true do
      skip_ws()
      local key = parse_string()
      skip_ws()
      assert(s:sub(pos, pos) == ":", "expected ':'")
      pos = pos + 1
      local val = parse_value()
      obj[key] = val
      skip_ws()
      local c = s:sub(pos, pos); pos = pos + 1
      if c == "}" then break end
      assert(c == ",", "expected ',' or '}'")
    end
    return obj
  end

  local function parse_array()
    pos = pos + 1  -- skip [
    local arr = {}
    skip_ws()
    if s:sub(pos, pos) == "]" then pos = pos + 1; return arr end
    while true do
      local val = parse_value()
      table.insert(arr, val)
      skip_ws()
      local c = s:sub(pos, pos); pos = pos + 1
      if c == "]" then break end
      assert(c == ",", "expected ',' or ']'")
    end
    return arr
  end

  parse_value = function()
    skip_ws()
    local c = s:sub(pos, pos)
    if c == '"'                        then return parse_string()
    elseif c == "{"                    then return parse_object()
    elseif c == "["                    then return parse_array()
    elseif s:sub(pos, pos+3) == "true" then pos = pos + 4; return true
    elseif s:sub(pos, pos+4) == "false"then pos = pos + 5; return false
    elseif s:sub(pos, pos+3) == "null" then pos = pos + 4; return nil
    elseif c:match("[%-%d]")           then
      local n = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
      pos = pos + #n
      return tonumber(n)
    else
      error("unexpected '" .. c .. "' at pos " .. pos)
    end
  end

  return parse_value()
end

local function json_encode(v)
  local t = type(v)
  if t == "nil"     then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number"  then return tostring(v)
  elseif t == "string"  then
    return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
                        :gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
  elseif t == "table" then
    if #v > 0 then
      local parts = {}
      for _, item in ipairs(v) do table.insert(parts, json_encode(item)) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, val in pairs(v) do
        table.insert(parts, '"' .. tostring(k) .. '":' .. json_encode(val))
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

-- ── 2. vim global stub ────────────────────────────────────────────────────────

vim = {
  json = { decode = json_decode, encode = json_encode },

  api = {
    nvim_create_namespace      = function(...) return 0 end,
    nvim_get_current_buf       = function() return 1 end,
    nvim_get_current_win       = function() return 1 end,
    nvim_win_get_cursor        = function() return {1, 0} end,
    nvim_buf_set_extmark       = function() return 1 end,
    nvim_buf_is_loaded         = function() return true end,
    nvim_buf_get_extmark_by_id = function() return {0, 0} end,
    nvim_buf_line_count        = function() return 1 end,
    nvim_buf_get_lines         = function() return {""} end,
    nvim_buf_set_lines         = function() end,
    nvim_buf_set_text          = function() end,
    nvim_buf_set_option        = function() end,
    nvim_echo                  = function() end,
    nvim_create_buf            = function() return 2 end,
    nvim_open_win              = function() return 3 end,
    nvim_create_augroup        = function() return 0 end,
    nvim_clear_autocmds        = function() end,
    nvim_create_autocmd        = function() end,
    nvim_set_current_win       = function() end,
    nvim_win_set_buf           = function() end,
    nvim_win_set_cursor        = function() end,
    nvim_win_close             = function() end,
    nvim_win_is_valid          = function() return true end,
    nvim_buf_is_valid          = function() return true end,
    nvim_list_bufs             = function() return {} end,
    nvim_feedkeys              = function() end,
    nvim_replace_termcodes     = function(s) return s end,
    nvim_put                   = function() end,
  },

  fn = {
    fnamemodify = function() return "" end,
    expand      = function() return "" end,
    mkdir       = function() return 1 end,
    stdpath     = function() return "/tmp" end,
    input       = function() return "" end,
    getpos      = function() return { 0, 0, 0, 0 } end,
    mode        = function() return "n" end,
  },

  -- vim.bo[bufnr].key — reads return "" / false, writes are no-ops.
  bo = setmetatable({}, {
    __index = function(_, _)
      return setmetatable({}, {
        __index    = function(_, k)
          if k == "swapfile" then return false end
          return ""
        end,
        __newindex = function() end,
      })
    end,
  }),

  o        = { columns = 80, lines = 24 },
  log      = { levels = { DEBUG = 0, INFO = 1, WARN = 2, ERROR = 3 } },
  schedule = function(_fn) end,    -- skip async side-effects in tests
  defer_fn = function(_fn, _ms) end,
  notify   = function() end,
  cmd      = function() end,

  split = function(str, sep, opts)
    local result = {}
    if opts and opts.plain then
      local start = 1
      while true do
        local i = str:find(sep, start, true)
        if not i then table.insert(result, str:sub(start)); break end
        table.insert(result, str:sub(start, i - 1))
        start = i + #sep
      end
    else
      for part in str:gmatch("([^" .. (sep or "%s") .. "]*)") do
        table.insert(result, part)
      end
    end
    return result
  end,
}

-- ── 3. plenary.job stub ───────────────────────────────────────────────────────

package.preload["plenary.job"] = function()
  local Job = {}
  Job.__index = Job
  function Job.new(cls, opts) return setmetatable({ opts = opts or {} }, cls) end
  function Job:start()    end
  function Job:shutdown() end
  return Job
end
