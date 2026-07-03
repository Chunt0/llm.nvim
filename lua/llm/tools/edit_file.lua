local Apply = require("llm.edit.apply")

-- str_replace-style edit. exec is side-effect-free: it validates and returns
-- a pending edit; the agent's executor routes it through diff review (or
-- applies it directly under an explicit "allow" policy).
return {
  name = "edit_file",
  description = "Propose an exact string replacement in a project file. "
    .. "old_string must match the current content exactly (including whitespace) and exactly once — "
    .. "add surrounding lines for uniqueness, or set replace_all. The user reviews the change as a diff.",
  policy = "review",
  review_kind = "diff",
  input_schema = {
    type = "object",
    properties = {
      path = { type = "string", description = "File path, relative to the project root" },
      old_string = { type = "string", description = "Exact text to replace (must be unique unless replace_all)" },
      new_string = { type = "string", description = "Replacement text" },
      replace_all = { type = "boolean", description = "Replace every occurrence (default false)" },
    },
    required = { "path", "old_string", "new_string" },
  },
  exec = function(input, ctx)
    local spec, err = Apply.compute_edit(input, ctx)
    if not spec then
      return { error = err }
    end
    return { pending_edit = spec }
  end,
}
