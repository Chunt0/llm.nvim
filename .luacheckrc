-- Neovim embeds LuaJIT (5.1 + extensions); CI also runs busted under 5.4.
-- "max" accepts the union of all Lua standards (covers `unpack` in both).
std = "max"
globals = {
  "vim",
}
ignore = {
  "631", -- max line length
}
exclude_files = {
  ".lua",      -- toolchain installed by gh-actions-lua in CI
  ".luarocks", -- toolchain installed by gh-actions-luarocks in CI
  ".install",
}

codes = true
