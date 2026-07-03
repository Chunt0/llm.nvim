-- Pending-edit engine (SPEC.md §F3): str_replace semantics, staleness guard,
-- and apply-to-disk. The review UI itself is exercised in the headless smoke
-- test; everything here is the pure logic under it.
local Apply = require("llm.edit.apply")

local fixture = "/tmp/llm_nvim_edit_fixture"
local function write_file(rel, content)
  local f = assert(io.open(fixture .. "/" .. rel, "w"))
  f:write(content)
  f:close()
end
local function read_file(rel)
  local f = assert(io.open(fixture .. "/" .. rel, "r"))
  local c = f:read("*a")
  f:close()
  return c
end

os.execute("rm -rf " .. fixture .. " && mkdir -p " .. fixture)
write_file("main.lua", "local a = 1\nlocal b = 2\nlocal c = a + b\nreturn c\n")
write_file("twice.lua", "print(1)\nprint(1)\n")

local ctx = { root = fixture }

describe("Apply.replace_plain", function()
  it("replaces only the first occurrence by default", function()
    local s, n = Apply.replace_plain("aXbXc", "X", "-", false)
    assert.are.equal("a-bXc", s)
    assert.are.equal(1, n)
  end)
  it("replaces all occurrences with all=true", function()
    local s, n = Apply.replace_plain("aXbXc", "X", "-", true)
    assert.are.equal("a-b-c", s)
    assert.are.equal(2, n)
  end)
  it("treats magic characters literally", function()
    local s = Apply.replace_plain("f(%d+)", "(%d+)", "[NUM]", false)
    assert.are.equal("f[NUM]", s)
  end)
end)

describe("Apply.compute_edit", function()
  it("builds a spec for a unique match", function()
    local spec, err = Apply.compute_edit({
      path = "main.lua",
      old_string = "local b = 2",
      new_string = "local b = 20",
    }, ctx)
    assert.is_nil(err)
    assert.are.equal("edit", spec.kind)
    assert.are.equal("main.lua", spec.path)
    assert.are.equal(fixture, spec.root)
    assert.are.equal("local b = 20", spec.new_lines[2])
    assert.truthy(spec.summary:match("1 replacement"))
  end)

  it("matches strings spanning multiple lines", function()
    local spec = Apply.compute_edit({
      path = "main.lua",
      old_string = "local b = 2\nlocal c = a + b",
      new_string = "local c = a + 2",
    }, ctx)
    assert.are.same({ "local a = 1", "local c = a + 2", "return c" }, spec.new_lines)
  end)

  it("errors on zero matches with actionable advice", function()
    local spec, err = Apply.compute_edit({
      path = "main.lua",
      old_string = "does not exist",
      new_string = "x",
    }, ctx)
    assert.is_nil(spec)
    assert.truthy(err:match("not found"))
    assert.truthy(err:match("read the file again"))
  end)

  it("errors on multiple matches unless replace_all", function()
    local spec, err = Apply.compute_edit({
      path = "twice.lua",
      old_string = "print(1)",
      new_string = "print(2)",
    }, ctx)
    assert.is_nil(spec)
    assert.truthy(err:match("^2 matches"))
    assert.truthy(err:match("replace_all"))

    local ok_spec = Apply.compute_edit({
      path = "twice.lua",
      old_string = "print(1)",
      new_string = "print(2)",
      replace_all = true,
    }, ctx)
    assert.truthy(ok_spec.summary:match("2 replacements"))
  end)

  it("errors on missing files, pointing at write_file", function()
    local _, err = Apply.compute_edit({ path = "nope.lua", old_string = "x", new_string = "y" }, ctx)
    assert.truthy(err:match("write_file"))
  end)

  it("enforces confinement and deny rules", function()
    local _, err = Apply.compute_edit({ path = "../outside.lua", old_string = "x", new_string = "y" }, ctx)
    assert.truthy(err:match("escapes"))
    write_file(".env", "S=1\n")
    local _, err2 = Apply.compute_edit({ path = ".env", old_string = "S=1", new_string = "S=2" }, ctx)
    assert.truthy(err2:match("secret"))
  end)

  it("rejects empty old_string", function()
    local _, err = Apply.compute_edit({ path = "main.lua", old_string = "", new_string = "y" }, ctx)
    assert.truthy(err:match("old_string"))
  end)
end)

describe("Apply.compute_write", function()
  it("flags overwrites of existing files", function()
    local spec = Apply.compute_write({ path = "main.lua", content = "-- gone\n" }, ctx)
    assert.are.equal("overwrite", spec.kind)
    assert.truthy(spec.summary:match("^OVERWRITE"))
  end)
  it("marks new files as create", function()
    local spec = Apply.compute_write({ path = "fresh.lua", content = "return 1\n" }, ctx)
    assert.are.equal("create", spec.kind)
    assert.truthy(spec.summary:match("^create"))
  end)
  it("refuses denied and escaping paths", function()
    local _, err = Apply.compute_write({ path = "/etc/hosts", content = "" }, ctx)
    assert.truthy(err:match("escapes"))
    local _, err2 = Apply.compute_write({ path = "x.png", content = "" }, ctx)
    assert.truthy(err2:match("excluded"))
  end)
end)

describe("Apply.apply", function()
  it("writes an edit to disk when the file is not loaded", function()
    write_file("apply_me.lua", "return 1\n")
    local spec = Apply.compute_edit({ path = "apply_me.lua", old_string = "return 1", new_string = "return 2" }, ctx)
    local res = Apply.apply(spec, ctx)
    assert.is_nil(res.error)
    assert.are.equal("return 2\n", read_file("apply_me.lua"))
  end)

  it("creates a new file", function()
    local spec = Apply.compute_write({ path = "brand_new.lua", content = "return 42" }, ctx)
    local res = Apply.apply(spec, ctx)
    assert.truthy(res.result:match("^created"))
    assert.are.equal("return 42\n", read_file("brand_new.lua"))
  end)

  it("re-anchors when the file changed but the target text still matches", function()
    write_file("moving.lua", "keep\nold\n")
    local spec = Apply.compute_edit({ path = "moving.lua", old_string = "old", new_string = "new" }, ctx)
    -- someone prepends a line before the user accepts
    write_file("moving.lua", "-- header\nkeep\nold\n")
    local res = Apply.apply(spec, ctx)
    assert.is_nil(res.error)
    assert.are.equal("-- header\nkeep\nnew\n", read_file("moving.lua"))
  end)

  it("fails as stale when the target text is gone", function()
    write_file("stale.lua", "target\n")
    local spec = Apply.compute_edit({ path = "stale.lua", old_string = "target", new_string = "hit" }, ctx)
    write_file("stale.lua", "rewritten completely\n")
    local res = Apply.apply(spec, ctx)
    assert.truthy(res.error:match("stale"))
    assert.are.equal("rewritten completely\n", read_file("stale.lua"))
  end)
end)
