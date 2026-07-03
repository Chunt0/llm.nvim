-- Tool registry: schemas for each provider's wire format, approval policy,
-- and a dispatch that never raises (SPEC.md §F1).
local Config = require("llm.config")
local Fs = require("llm.util.fs")

local M = { _tools = {}, _order = {} }

--- tool = { name, description, input_schema, policy = "allow"|"review"|"disabled",
---          exec = function(input, ctx) -> { result = string } | { error = string } }
function M.register(tool)
  assert(type(tool) == "table" and type(tool.name) == "string", "invalid tool")
  if not M._tools[tool.name] then
    table.insert(M._order, tool.name)
  end
  M._tools[tool.name] = tool
end

function M.get(name)
  return M._tools[name]
end

--- Effective approval policy for a tool: config override, then the tool's
--- default, then "review" (fail safe for anything unspecified).
function M.policy(name)
  local cfg = (Config.tools and Config.tools.policy) or {}
  local tool = M._tools[name]
  return cfg[name] or (tool and tool.policy) or "review"
end

--- Tools enabled by config (Config.tools.enabled), in registration order.
function M.enabled()
  local allow = {}
  for _, n in ipairs((Config.tools and Config.tools.enabled) or {}) do
    allow[n] = true
  end
  local out = {}
  for _, name in ipairs(M._order) do
    if allow[name] and M.policy(name) ~= "disabled" then
      table.insert(out, M._tools[name])
    end
  end
  return out
end

--- Provider-specific schema list for the request body.
--- shape "anthropic":  { name, description, input_schema }
--- shape "openai":     { type = "function", function = { name, description, parameters } }
--- (Ollama uses the openai function shape.)
function M.schemas(shape)
  local out = {}
  for _, tool in ipairs(M.enabled()) do
    if shape == "anthropic" then
      table.insert(out, {
        name = tool.name,
        description = tool.description,
        input_schema = tool.input_schema,
      })
    else
      table.insert(out, {
        type = "function",
        ["function"] = {
          name = tool.name,
          description = tool.description,
          parameters = tool.input_schema,
        },
      })
    end
  end
  return out
end

--- Run a tool. Never raises: failures come back as { error = "…" } so the
--- caller can hand them to the model as an is_error tool_result.
--- ctx: { root, max_bytes, exec_cmd } — filled with defaults when omitted.
function M.dispatch(name, input, ctx)
  local tool = M._tools[name]
  if not tool then
    return { error = "unknown tool: " .. tostring(name) }
  end
  if M.policy(name) == "disabled" then
    return { error = "tool is disabled by config: " .. name }
  end
  ctx = ctx or {}
  ctx.root = ctx.root or Fs.project_root()
  ctx.max_bytes = ctx.max_bytes or (Config.tools and Config.tools.max_result_bytes) or 60 * 1024
  if type(input) ~= "table" then
    input = {}
  end
  local ok, res = pcall(tool.exec, input, ctx)
  if not ok then
    return { error = "tool failed: " .. tostring(res) }
  end
  if type(res) ~= "table" then
    return { error = "tool returned no result" }
  end
  return res
end

--- Register the built-in tools once.
function M.setup_builtin()
  M.register(require("llm.tools.read_file"))
  M.register(require("llm.tools.list_files"))
  M.register(require("llm.tools.grep"))
end

return M
