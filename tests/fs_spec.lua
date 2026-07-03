-- Path confinement (SPEC.md §F1 security invariants) and glob matching.
local Fs = require("llm.util.fs")

describe("util.fs.confine", function()
  local root = "/proj"

  local accepted = {
    { "src/main.lua", "/proj/src/main.lua" },
    { "./a/../b.lua", "/proj/b.lua" },
    { "a//b.lua", "/proj/a/b.lua" },
    { "/proj/sub/file.lua", "/proj/sub/file.lua" },
    { "a/./b/../c", "/proj/a/c" },
  }
  for _, case in ipairs(accepted) do
    it("accepts " .. case[1], function()
      assert.are.equal(case[2], (Fs.confine(case[1], root)))
    end)
  end

  local rejected = {
    "../etc/passwd",
    "/etc/passwd",
    "a/b/../../../x",
    "..",
    "/projx/evil.lua", -- sibling dir sharing the root as a string prefix
  }
  for _, path in ipairs(rejected) do
    it("rejects " .. path, function()
      local got, err = Fs.confine(path, root)
      assert.is_nil(got)
      assert.truthy(err:match("escapes"))
    end)
  end

  it("rejects empty and non-string paths", function()
    assert.is_nil((Fs.confine("", root)))
    assert.is_nil((Fs.confine(nil, root)))
    assert.is_nil((Fs.confine(42, root)))
  end)

  it("requires an absolute root", function()
    assert.is_nil((Fs.confine("a.lua", "relative/root")))
    assert.is_nil((Fs.confine("a.lua", nil)))
  end)

  it("tolerates a trailing slash on the root", function()
    assert.are.equal("/proj/a.lua", (Fs.confine("a.lua", "/proj/")))
  end)

  it("rejects a symlink that escapes the root", function()
    local fake = {
      ["/proj"] = "/proj",
      ["/proj/link"] = "/outside/target",
    }
    local got, err = Fs.confine("link/file.txt", root, {
      realpath = function(p)
        return fake[p]
      end,
    })
    assert.is_nil(got)
    assert.truthy(err:match("symlink"))
  end)

  it("accepts a symlink that stays inside the root", function()
    local fake = {
      ["/proj"] = "/proj",
      ["/proj/link"] = "/proj/real_dir",
    }
    assert.are.equal("/proj/link/file.txt", (Fs.confine("link/file.txt", root, {
      realpath = function(p)
        return fake[p]
      end,
    })))
  end)

  it("checks the deepest existing ancestor when the leaf does not exist", function()
    local fake = { ["/proj"] = "/proj", ["/proj/dir"] = "/elsewhere" }
    local got = Fs.confine("dir/new/deep/file.txt", root, {
      realpath = function(p)
        return fake[p]
      end,
    })
    assert.is_nil(got)
  end)
end)

describe("util.fs.is_denied", function()
  it("refuses .env and variants anywhere in the tree", function()
    assert.is_true((Fs.is_denied("/proj/.env")))
    assert.is_true((Fs.is_denied("/proj/config/.env.local")))
  end)

  it("refuses excluded extensions from constants", function()
    assert.is_true((Fs.is_denied("/proj/data.sqlite")))
    assert.is_true((Fs.is_denied("/proj/img/logo.png")))
    assert.is_true((Fs.is_denied("/proj/package-lock.json")))
  end)

  it("allows ordinary source files, including env-ish names", function()
    assert.is_false((Fs.is_denied("/proj/src/env.lua")))
    assert.is_false((Fs.is_denied("/proj/environment.ts")))
    assert.is_false((Fs.is_denied("/proj/README.md")))
  end)
end)

describe("util.fs.glob_match", function()
  local cases = {
    -- rel, glob, expected
    { "src/main.lua", "*.lua", true }, -- no "/" in glob → basename match
    { "src/main.lua", "*.ts", false },
    { "src/main.lua", "src/*.lua", true },
    { "src/deep/main.lua", "src/*.lua", false }, -- "*" does not cross "/"
    { "src/deep/main.lua", "src/**/*.lua", true },
    { "src/main.lua", "src/**/*.lua", true }, -- "**/" also spans zero dirs
    { "main.lua", "**/*.lua", true },
    { "a/b/c/d.lua", "**/*.lua", true },
    { "barfoo.lua", "**/foo.lua", false }, -- "**/" must end on a boundary
    { "a/foo.lua", "**/foo.lua", true },
    { "foo.lua", "**/foo.lua", true },
    { "test?.lua", "test?.lua", true },
    { "testX.lua", "test?.lua", true },
    { "test/x.lua", "test?.lua", false }, -- "?" does not match "/"
    { "a-b.lua", "a-b.lua", true }, -- magic chars escaped
    { "axb.lua", "a-b.lua", false },
  }
  for _, c in ipairs(cases) do
    it(string.format("%s vs %s → %s", c[1], c[2], tostring(c[3])), function()
      assert.are.equal(c[3], Fs.glob_match(c[1], c[2]))
    end)
  end
end)

describe("util.fs.relative", function()
  it("strips the root prefix", function()
    assert.are.equal("src/a.lua", Fs.relative("/proj/src/a.lua", "/proj"))
  end)
  it("returns paths outside the root unchanged", function()
    assert.are.equal("/other/x", Fs.relative("/other/x", "/proj"))
  end)
end)
