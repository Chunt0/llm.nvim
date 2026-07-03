local Proc = require("llm.util.proc")

-- Run a shell command from the project root. Review-gated on EVERY call: the
-- registry refuses to resolve this tool's policy to "allow" (never_allow),
-- and the exact command is shown in the confirmation prompt before exec runs.
return {
  name = "bash",
  description = "Run a shell command from the project root and return its output. "
    .. "The user must confirm every command before it runs. Keep commands short and non-interactive.",
  policy = "review",
  review_kind = "confirm",
  never_allow = true,
  input_schema = {
    type = "object",
    properties = {
      command = { type = "string", description = "The shell command to run (bash -c)" },
      timeout_s = { type = "integer", description = "Timeout in seconds (default 30, max 300)" },
    },
    required = { "command" },
  },
  describe = function(input)
    return "Run in project root:\n$ " .. tostring(input.command)
  end,
  exec = function(input, ctx)
    if type(input.command) ~= "string" or input.command == "" then
      return { error = "command must be a non-empty string" }
    end
    local timeout_s = math.min(math.max(math.floor(tonumber(input.timeout_s) or 30), 1), 300)
    local run = ctx.exec_cmd or Proc.run
    local res = run({ "bash", "-c", input.command }, ctx.root, { timeout_ms = timeout_s * 1000 })
    if res.timeout then
      return { error = "command timed out after " .. timeout_s .. "s" }
    end
    local out = (res.stdout or "")
    if res.stderr and res.stderr ~= "" then
      out = out .. (out ~= "" and "\n" or "") .. "[stderr]\n" .. res.stderr
    end
    if #out > ctx.max_bytes then
      out = out:sub(1, ctx.max_bytes) .. "\n[output truncated]"
    end
    if out == "" then
      out = "(no output)"
    end
    return { result = "exit " .. tostring(res.code) .. "\n" .. out }
  end,
}
