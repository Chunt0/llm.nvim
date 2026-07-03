local Proc = require("llm.util.proc")

--- Search the project with ripgrep (`rg --vimgrep`), falling back to plain
--- `grep -rn`. Exit code 1 from either means "no matches", not failure.
local function build_argv(pattern, glob)
  local ok, has_rg = pcall(function()
    return vim.fn.executable("rg") == 1
  end)
  if ok == false then
    has_rg = false
  end
  if has_rg then
    local argv = { "rg", "--vimgrep", "--no-heading", "-S", "--max-columns", "300" }
    if type(glob) == "string" and glob ~= "" then
      table.insert(argv, "-g")
      table.insert(argv, glob)
    end
    table.insert(argv, "-e")
    table.insert(argv, pattern)
    table.insert(argv, ".")
    return argv
  end
  return { "grep", "-rn", "--exclude-dir=.git", "-e", pattern, "." }
end

return {
  name = "grep",
  description = "Search file contents in the project with a regex. "
    .. "Returns matches as path:line:col: text. Optionally restrict to a glob.",
  policy = "allow",
  input_schema = {
    type = "object",
    properties = {
      pattern = { type = "string", description = "Regex to search for (ripgrep syntax)" },
      glob = { type = "string", description = "Only search files matching this glob, e.g. '*.lua' (optional)" },
      max_results = { type = "integer", description = "Maximum number of matching lines to return (default 100)" },
    },
    required = { "pattern" },
  },
  exec = function(input, ctx)
    if type(input.pattern) ~= "string" or input.pattern == "" then
      return { error = "pattern must be a non-empty string" }
    end
    local run = ctx.exec_cmd or Proc.run
    local res = run(build_argv(input.pattern, input.glob), ctx.root)
    if res.code == 1 then
      return { result = "no matches" }
    end
    if res.code ~= 0 then
      local why = (res.stderr and res.stderr ~= "") and res.stderr or ("search failed (exit " .. res.code .. ")")
      return { error = why }
    end

    local max = math.floor(tonumber(input.max_results) or 100)
    local out, total, bytes = {}, 0, 0
    for line in (res.stdout or ""):gmatch("([^\n]+)") do
      total = total + 1
      if #out < max and bytes <= ctx.max_bytes then
        line = line:gsub("^%./", "")
        table.insert(out, line)
        bytes = bytes + #line + 1
      end
    end
    if total == 0 then
      return { result = "no matches" }
    end
    local text = table.concat(out, "\n")
    if total > #out then
      text = text .. string.format("\n[%d more matches not shown — narrow the pattern or glob]", total - #out)
    end
    return { result = text }
  end,
}
