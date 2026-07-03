-- Path resolution and project-root confinement for model-supplied paths.
-- Every tool that touches the filesystem goes through confine() — the security
-- invariants in SPEC.md §F1 live here and nowhere else.
local M = {}

--- Best-effort project root: nearest ancestor with a .git marker, else cwd.
function M.project_root()
  local ok, root = pcall(function()
    return vim.fs.root(0, { ".git" })
  end)
  if ok and root and root ~= "" then
    return root
  end
  local ok_cwd, cwd = pcall(function()
    return (vim.uv or vim.loop).cwd()
  end)
  if ok_cwd and cwd then
    return cwd
  end
  return "."
end

local function strip_trailing_slash(p)
  if #p > 1 then
    p = p:gsub("/+$", "")
  end
  return p
end

--- Lexically resolve a path: collapse "//" and "/./", apply "..".
--- Input must be absolute. Returns nil if ".." climbs above "/".
local function lexical_resolve(path)
  local segs = {}
  for seg in path:gmatch("[^/]+") do
    if seg == ".." then
      if #segs == 0 then
        return nil
      end
      table.remove(segs)
    elseif seg ~= "." then
      table.insert(segs, seg)
    end
  end
  return "/" .. table.concat(segs, "/")
end

local function is_inside(path, root)
  return path == root or path:sub(1, #root + 1) == (root .. "/")
end

local function parent(p)
  local par = p:match("^(.*)/[^/]+$")
  if par == "" then
    return "/"
  end
  return par
end

local function default_realpath(p)
  local uv = vim.uv or vim.loop
  if uv and uv.fs_realpath then
    return uv.fs_realpath(p)
  end
  return nil
end

--- Resolve a model-supplied path and require it to stay inside root.
--- path may be relative (to root) or absolute; root must be absolute.
--- opts.realpath: injectable fs_realpath(path) -> string|nil (for tests).
--- Returns the resolved absolute path, or nil + reason.
function M.confine(path, root, opts)
  if type(path) ~= "string" or path == "" then
    return nil, "path must be a non-empty string"
  end
  if type(root) ~= "string" or root:sub(1, 1) ~= "/" then
    return nil, "project root unavailable"
  end
  root = strip_trailing_slash(root)
  path = path:gsub("\\", "/")

  local abs = (path:sub(1, 1) == "/") and path or (root .. "/" .. path)
  local resolved = lexical_resolve(abs)
  if not resolved or not is_inside(resolved, lexical_resolve(root)) then
    return nil, "path escapes the project root: " .. path
  end

  -- Symlink guard: the realpath of the deepest existing ancestor of the
  -- resolved path must also stay inside the (real) root. Any non-existing
  -- suffix below that ancestor cannot be a symlink.
  local realpath = (opts and opts.realpath) or default_realpath
  local real_root = realpath(root) or root
  local probe = resolved
  while probe ~= "/" do
    local rp = realpath(probe)
    if rp then
      if not is_inside(rp, real_root) then
        return nil, "path escapes the project root via symlink: " .. path
      end
      break
    end
    probe = parent(probe)
  end

  return resolved
end

--- Files the model must never read, even inside the root: secret-bearing
--- dotfiles plus everything in constants.excluded_extensions.
function M.is_denied(path)
  local base = path:gsub("\\", "/"):match("([^/]+)$") or path
  if base:lower():match("^%.env") then
    return true, "refusing to read secret file: " .. base
  end
  local ok, Utils = pcall(require, "llm.utils")
  if ok and not Utils.should_include_file(path) then
    return true, "file type is excluded from LLM access: " .. base
  end
  return false
end

--- Convert one glob (no "**/" handling — see glob_match) to an anchored Lua
--- pattern. "\1" is an internal marker meaning "one or more directories".
function M.glob_to_pattern(glob)
  local out = { "^" }
  local i = 1
  while i <= #glob do
    local c = glob:sub(i, i)
    if c == "\1" then
      table.insert(out, ".*")
      i = i + 1
    elseif c == "*" then
      if glob:sub(i + 1, i + 1) == "*" then
        table.insert(out, ".*")
        i = i + 2
      else
        table.insert(out, "[^/]*")
        i = i + 1
      end
    elseif c == "?" then
      table.insert(out, "[^/]")
      i = i + 1
    else
      table.insert(out, (c:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")))
      i = i + 1
    end
  end
  table.insert(out, "$")
  return table.concat(out)
end

--- Does relative path rel match a shell-style glob?
--- `**` crosses directory separators, `*` and `?` do not. Globs without a "/"
--- match against basenames (like rg -g); globs with one match the whole
--- relative path. Lua patterns have no optional groups, so each "**/" is
--- expanded into both a zero-directory and a one-or-more-directory variant.
function M.glob_match(rel, glob)
  local subject = rel
  if not glob:find("/", 1, true) then
    subject = rel:match("([^/]+)$") or rel
  end
  local variants = {}
  local function expand(g)
    local pre, post = g:match("^(.-)%*%*/(.*)$")
    if not pre then
      table.insert(variants, g)
      return
    end
    expand(pre .. post) -- "**/" spanning zero directories
    expand(pre .. "\1/" .. post) -- or one-or-more
  end
  expand(glob)
  for _, g in ipairs(variants) do
    if subject:match(M.glob_to_pattern(g)) then
      return true
    end
  end
  return false
end

--- Relative form of an absolute path under root (for display).
function M.relative(path, root)
  root = strip_trailing_slash(root or "")
  if is_inside(path, root) and path ~= root then
    return path:sub(#root + 2)
  end
  return path
end

return M
