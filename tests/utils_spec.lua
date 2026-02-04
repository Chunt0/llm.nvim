-- Minimal tests for utils.lua

local utils = require("utils")

describe("utils.should_include_file", function()
  it("excludes explicit filenames like chat.md regardless of path", function()
    assert.is_false(utils.should_include_file("chat.md"))
    assert.is_false(utils.should_include_file("/tmp/chat.md"))
    assert.is_false(utils.should_include_file("C:/proj/notes.md"))
  end)

  it("excludes based on extension list", function()
    assert.is_false(utils.should_include_file("image.png"))
    assert.is_false(utils.should_include_file("/home/user/archive.tar.gz"))
  end)

  it("excludes lock files from constants list", function()
    assert.is_false(utils.should_include_file("package-lock.json"))
    assert.is_false(utils.should_include_file("/app/yarn.lock"))
  end)

  it("includes normal source files", function()
    assert.is_true(utils.should_include_file("main.lua"))
    assert.is_true(utils.should_include_file("src/app.ts"))
  end)
end)

describe("utils.trim_context", function()
  it("returns last N items when exceeding max length", function()
    local ctx = {1,2,3,4,5}
    local out = utils.trim_context(ctx, 3)
    assert.are.same({3,4,5}, out)
  end)

  it("returns same table when within limit", function()
    local ctx = {"a","b"}
    local out = utils.trim_context(ctx, 5)
    assert.are.same(ctx, out)
  end)
end)
