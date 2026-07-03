-- Minimal external-command runner for tools. Injectable via ctx.exec_cmd in
-- tests; the real implementation needs Neovim ≥ 0.10 (vim.system).
local M = {}

--- run(argv, cwd) -> { code = integer, stdout = string, stderr = string }
function M.run(argv, cwd)
  local ok, res = pcall(function()
    return vim.system(argv, { cwd = cwd, text = true }):wait()
  end)
  if ok and type(res) == "table" then
    return { code = res.code or 0, stdout = res.stdout or "", stderr = res.stderr or "" }
  end
  return { code = 127, stdout = "", stderr = "vim.system unavailable (Neovim ≥ 0.10 required)" }
end

return M
