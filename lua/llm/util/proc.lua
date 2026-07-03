-- Minimal external-command runner for tools. Injectable via ctx.exec_cmd in
-- tests; the real implementation needs Neovim ≥ 0.10 (vim.system).
local M = {}

--- run(argv, cwd, opts) -> { code, stdout, stderr, timeout? }
--- opts.timeout_ms kills the process after the deadline (timeout = true).
function M.run(argv, cwd, opts)
  local ok, res = pcall(function()
    return vim.system(argv, { cwd = cwd, text = true, timeout = opts and opts.timeout_ms or nil }):wait()
  end)
  if ok and type(res) == "table" then
    return {
      code = res.code or 0,
      stdout = res.stdout or "",
      stderr = res.stderr or "",
      -- vim.system reports SIGTERM after a timeout as signal 15 / code 124
      timeout = (res.signal == 15 or res.code == 124) and opts and opts.timeout_ms ~= nil or nil,
    }
  end
  return { code = 127, stdout = "", stderr = "vim.system unavailable (Neovim ≥ 0.10 required)" }
end

return M
