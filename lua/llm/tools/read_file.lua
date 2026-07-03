local Fs = require("llm.util.fs")

-- Read a file inside the project root, preferring the loaded buffer over
-- disk so the model sees unsaved edits. Output is line-numbered.
return {
  name = "read_file",
  description = "Read a file in the project. Returns its content with line numbers. "
    .. "For large files pass start_line/end_line to read a slice.",
  policy = "allow",
  input_schema = {
    type = "object",
    properties = {
      path = { type = "string", description = "File path, relative to the project root" },
      start_line = { type = "integer", description = "First line to read, 1-based (optional)" },
      end_line = { type = "integer", description = "Last line to read, 1-based inclusive (optional)" },
    },
    required = { "path" },
  },
  exec = function(input, ctx)
    local abs, err = Fs.confine(input.path, ctx.root, ctx)
    if not abs then
      return { error = err }
    end
    local denied, why = Fs.is_denied(abs)
    if denied then
      return { error = why }
    end

    local lines = Fs.read_lines(abs)
    if not lines then
      return { error = "file not found: " .. Fs.relative(abs, ctx.root) }
    end

    local total = #lines
    local first = math.max(1, math.floor(tonumber(input.start_line) or 1))
    local last = math.min(total, math.floor(tonumber(input.end_line) or total))
    if first > last then
      return { error = string.format("empty line range %d-%d (file has %d lines)", first, last, total) }
    end

    local out, bytes, truncated_at = {}, 0, nil
    for i = first, last do
      local numbered = string.format("%5d| %s", i, lines[i])
      bytes = bytes + #numbered + 1
      if bytes > ctx.max_bytes then
        truncated_at = i - 1
        break
      end
      table.insert(out, numbered)
    end

    local text = table.concat(out, "\n")
    if truncated_at then
      text = text
        .. string.format(
          "\n[truncated at line %d of %d — call read_file again with start_line=%d]",
          truncated_at,
          total,
          truncated_at + 1
        )
    elseif first > 1 or last < total then
      text = text .. string.format("\n[lines %d-%d of %d]", first, last, total)
    end
    return { result = text }
  end,
}
