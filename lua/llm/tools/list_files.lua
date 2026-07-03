local Fs = require("llm.util.fs")
local Proc = require("llm.util.proc")

--- List project files via `rg --files` (honors .gitignore), falling back to a
--- vim.fs.dir walk when ripgrep is missing.
local function rg_list(root, run)
  local ok, has_rg = pcall(function()
    return vim.fn.executable("rg") == 1
  end)
  if not ok or not has_rg then
    return nil
  end
  local res = run({ "rg", "--files", "--hidden", "--glob", "!.git/**" }, root)
  if res.code ~= 0 then
    return nil
  end
  local files = {}
  for line in (res.stdout or ""):gmatch("([^\n]+)") do
    table.insert(files, line)
  end
  return files
end

local function walk_list(root)
  local ok, files = pcall(function()
    local acc = {}
    for name, kind in vim.fs.dir(root, { depth = 12 }) do
      if kind == "file" and not name:match("^%.git/") then
        table.insert(acc, name)
      end
    end
    return acc
  end)
  if ok then
    return files
  end
  return nil
end

return {
  name = "list_files",
  description = "List files in the project (respects .gitignore). "
    .. "Optionally filter with a glob like '*.lua' or 'src/**/*.ts'.",
  policy = "allow",
  input_schema = {
    type = "object",
    properties = {
      glob = { type = "string", description = "Glob filter, e.g. '**/*.lua' (optional)" },
      max_results = { type = "integer", description = "Maximum number of paths to return (default 200)" },
    },
    required = {},
  },
  exec = function(input, ctx)
    local run = ctx.exec_cmd or Proc.run
    local files = rg_list(ctx.root, run) or walk_list(ctx.root)
    if not files then
      return { error = "no file lister available (install ripgrep)" }
    end
    table.sort(files)

    local glob = input.glob
    if type(glob) == "string" and glob ~= "" then
      local kept = {}
      for _, f in ipairs(files) do
        if Fs.glob_match(f, glob) then
          table.insert(kept, f)
        end
      end
      files = kept
    end

    local max = math.floor(tonumber(input.max_results) or 200)
    local shown = math.min(#files, math.max(1, max))
    local out = {}
    for i = 1, shown do
      table.insert(out, files[i])
    end
    local text = table.concat(out, "\n")
    if #files > shown then
      text = text .. string.format("\n[%d more files not shown — narrow with a glob]", #files - shown)
    elseif #files == 0 then
      text = "no files matched"
    end
    return { result = text }
  end,
}
