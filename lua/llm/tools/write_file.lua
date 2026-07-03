local Apply = require("llm.edit.apply")

-- Whole-file create/overwrite. exec is side-effect-free (returns a pending
-- edit); overwriting an existing file is flagged in the review summary.
return {
  name = "write_file",
  description = "Propose creating a new file, or overwriting an existing one, with the given content. "
    .. "Prefer edit_file for changes to existing files. The user reviews the result as a diff.",
  policy = "review",
  review_kind = "diff",
  input_schema = {
    type = "object",
    properties = {
      path = { type = "string", description = "File path, relative to the project root" },
      content = { type = "string", description = "Full file content" },
    },
    required = { "path", "content" },
  },
  exec = function(input, ctx)
    local spec, err = Apply.compute_write(input, ctx)
    if not spec then
      return { error = err }
    end
    return { pending_edit = spec }
  end,
}
