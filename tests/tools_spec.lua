-- Tool registry + built-in read-only tools (SPEC.md §F1).
local Tools = require("llm.tools")
local Config = require("llm.config")

Tools.setup_builtin()

-- A real on-disk fixture project for read_file.
local fixture = "/tmp/llm_nvim_tools_fixture"
local function write_file(rel, content)
  local f = assert(io.open(fixture .. "/" .. rel, "w"))
  f:write(content)
  f:close()
end

-- Created at load time (before any test runs); a stale dir from a previous
-- run is removed first, so no teardown is needed.
os.execute("rm -rf " .. fixture .. " && mkdir -p " .. fixture .. "/src")
write_file("src/main.lua", "local a = 1\nlocal b = 2\nreturn a + b\n")
write_file(".env", "SECRET=hunter2\n")

local function ctx(extra)
  local c = { root = fixture, max_bytes = 60 * 1024 }
  for k, v in pairs(extra or {}) do
    c[k] = v
  end
  return c
end

describe("tools registry", function()
  it("exposes the three read-only tools as enabled by default", function()
    local names = {}
    for _, t in ipairs(Tools.enabled()) do
      table.insert(names, t.name)
    end
    assert.are.same({ "read_file", "list_files", "grep" }, names)
  end)

  it("builds anthropic-shaped schemas", function()
    local schemas = Tools.schemas("anthropic")
    assert.are.equal(3, #schemas)
    assert.are.equal("read_file", schemas[1].name)
    assert.are.equal("object", schemas[1].input_schema.type)
    assert.is_string(schemas[1].description)
    assert.is_nil(schemas[1].parameters)
  end)

  it("builds openai/ollama-shaped schemas", function()
    local schemas = Tools.schemas("openai")
    assert.are.equal("function", schemas[1].type)
    assert.are.equal("read_file", schemas[1]["function"].name)
    assert.are.equal("object", schemas[1]["function"].parameters.type)
  end)

  it("read-only tools default to the allow policy", function()
    assert.are.equal("allow", Tools.policy("read_file"))
    assert.are.equal("allow", Tools.policy("grep"))
  end)

  it("unknown tools default to review (fail safe)", function()
    assert.are.equal("review", Tools.policy("bash"))
  end)

  it("dispatch returns an error result for unknown tools", function()
    local res = Tools.dispatch("no_such_tool", {}, ctx())
    assert.truthy(res.error:match("unknown tool"))
  end)

  it("dispatch never raises when a tool crashes", function()
    Tools.register({
      name = "crashy",
      description = "boom",
      input_schema = { type = "object", properties = {} },
      policy = "allow",
      exec = function()
        error("kaboom")
      end,
    })
    local res = Tools.dispatch("crashy", {}, ctx())
    assert.truthy(res.error:match("kaboom"))
  end)

  it("config policy can disable a tool", function()
    Config.tools.policy.grep = "disabled"
    local res = Tools.dispatch("grep", { pattern = "x" }, ctx())
    assert.truthy(res.error:match("disabled"))
    local names = {}
    for _, t in ipairs(Tools.enabled()) do
      table.insert(names, t.name)
    end
    assert.are.same({ "read_file", "list_files" }, names)
    Config.tools.policy.grep = nil
  end)

  it("treats non-table input as empty input", function()
    local res = Tools.dispatch("read_file", nil, ctx())
    assert.truthy(res.error) -- missing path, but no crash
  end)
end)

describe("read_file", function()
  it("returns line-numbered content from disk", function()
    local res = Tools.dispatch("read_file", { path = "src/main.lua" }, ctx())
    assert.is_nil(res.error)
    assert.truthy(res.result:match("    1| local a = 1"))
    assert.truthy(res.result:match("    3| return a %+ b"))
  end)

  it("honors start_line/end_line and reports the slice", function()
    local res = Tools.dispatch("read_file", { path = "src/main.lua", start_line = 2, end_line = 2 }, ctx())
    assert.is_nil(res.error)
    assert.truthy(res.result:match("    2| local b = 2"))
    assert.is_nil(res.result:match("local a"))
    assert.truthy(res.result:match("%[lines 2%-2 of 3%]"))
  end)

  it("rejects an inverted line range", function()
    local res = Tools.dispatch("read_file", { path = "src/main.lua", start_line = 3, end_line = 1 }, ctx())
    assert.truthy(res.error:match("empty line range"))
  end)

  it("errors on missing files", function()
    local res = Tools.dispatch("read_file", { path = "src/nope.lua" }, ctx())
    assert.truthy(res.error:match("file not found: src/nope.lua"))
  end)

  it("refuses paths that escape the root", function()
    local res = Tools.dispatch("read_file", { path = "../../etc/passwd" }, ctx())
    assert.truthy(res.error:match("escapes the project root"))
  end)

  it("refuses absolute paths outside the root", function()
    local res = Tools.dispatch("read_file", { path = "/etc/passwd" }, ctx())
    assert.truthy(res.error:match("escapes the project root"))
  end)

  it("refuses secret files even inside the root", function()
    local res = Tools.dispatch("read_file", { path = ".env" }, ctx())
    assert.truthy(res.error:match("secret file"))
  end)

  it("truncates at the byte cap and says how to continue", function()
    local res = Tools.dispatch("read_file", { path = "src/main.lua" }, ctx({ max_bytes = 20 }))
    assert.is_nil(res.error)
    assert.truthy(res.result:match("truncated at line 1 of 3"))
    assert.truthy(res.result:match("start_line=2"))
  end)
end)

describe("list_files", function()
  local fake_files = table.concat({
    "README.md",
    "lua/llm/init.lua",
    "lua/llm/agent.lua",
    "tests/agent_spec.lua",
    "docs/notes.txt",
  }, "\n") .. "\n"

  local function with_rg(fn)
    local orig = vim.fn.executable
    vim.fn.executable = function()
      return 1
    end
    local ok, err = pcall(fn)
    vim.fn.executable = orig
    assert(ok, err)
  end

  local function fake_run(res)
    return function(argv, cwd)
      assert.are.equal("rg", argv[1])
      assert.are.equal(fixture, cwd)
      return res
    end
  end

  it("lists files via rg, sorted", function()
    with_rg(function()
      local res = Tools.dispatch("list_files", {}, ctx({ exec_cmd = fake_run({ code = 0, stdout = fake_files }) }))
      assert.is_nil(res.error)
      local first = res.result:match("^([^\n]+)")
      assert.are.equal("README.md", first)
      assert.truthy(res.result:match("tests/agent_spec%.lua"))
    end)
  end)

  it("filters with a glob", function()
    with_rg(function()
      local res = Tools.dispatch(
        "list_files",
        { glob = "lua/**/*.lua" },
        ctx({ exec_cmd = fake_run({ code = 0, stdout = fake_files }) })
      )
      assert.truthy(res.result:match("lua/llm/init%.lua"))
      assert.is_nil(res.result:match("README"))
      assert.is_nil(res.result:match("tests/"))
    end)
  end)

  it("caps results and reports the remainder", function()
    with_rg(function()
      local res = Tools.dispatch(
        "list_files",
        { max_results = 2 },
        ctx({ exec_cmd = fake_run({ code = 0, stdout = fake_files }) })
      )
      local _, newlines = res.result:gsub("\n", "")
      assert.are.equal(2, newlines) -- 2 file lines + 1 notice line
      assert.truthy(res.result:match("%[3 more files not shown"))
    end)
  end)

  it("says so when nothing matches", function()
    with_rg(function()
      local res = Tools.dispatch(
        "list_files",
        { glob = "*.zig" },
        ctx({ exec_cmd = fake_run({ code = 0, stdout = fake_files }) })
      )
      assert.are.equal("no files matched", res.result)
    end)
  end)
end)

describe("grep", function()
  local vimgrep_out = table.concat({
    "./lua/llm/init.lua:12:5:local Config = require('llm.config')",
    "./lua/llm/agent.lua:8:1:local Config = require('llm.config')",
    "./tests/x_spec.lua:3:9:local Config = require('llm.config')",
  }, "\n") .. "\n"

  local function with_rg(fn)
    local orig = vim.fn.executable
    vim.fn.executable = function()
      return 1
    end
    local ok, err = pcall(fn)
    vim.fn.executable = orig
    assert(ok, err)
  end

  it("requires a pattern", function()
    local res = Tools.dispatch("grep", {}, ctx())
    assert.truthy(res.error:match("pattern"))
  end)

  it("passes the pattern and glob to rg and strips ./ prefixes", function()
    with_rg(function()
      local seen_argv
      local res = Tools.dispatch(
        "grep",
        { pattern = "Config", glob = "*.lua" },
        ctx({
          exec_cmd = function(argv, _)
            seen_argv = argv
            return { code = 0, stdout = vimgrep_out }
          end,
        })
      )
      assert.is_nil(res.error)
      assert.truthy(res.result:match("^lua/llm/init%.lua:12:5:"))
      local flat = table.concat(seen_argv, " ")
      assert.truthy(flat:match("%-%-vimgrep"))
      assert.truthy(flat:match("%-g %*%.lua"))
      assert.truthy(flat:match("%-e Config"))
    end)
  end)

  it("maps rg exit code 1 to 'no matches'", function()
    with_rg(function()
      local res = Tools.dispatch(
        "grep",
        { pattern = "nothing" },
        ctx({
          exec_cmd = function()
            return { code = 1, stdout = "" }
          end,
        })
      )
      assert.are.equal("no matches", res.result)
    end)
  end)

  it("surfaces rg errors (exit 2) with stderr", function()
    with_rg(function()
      local res = Tools.dispatch(
        "grep",
        { pattern = "[" },
        ctx({
          exec_cmd = function()
            return { code = 2, stdout = "", stderr = "regex parse error" }
          end,
        })
      )
      assert.truthy(res.error:match("regex parse error"))
    end)
  end)

  it("caps matches at max_results", function()
    with_rg(function()
      local res = Tools.dispatch(
        "grep",
        { pattern = "Config", max_results = 2 },
        ctx({
          exec_cmd = function()
            return { code = 0, stdout = vimgrep_out }
          end,
        })
      )
      assert.truthy(res.result:match("%[1 more match"))
    end)
  end)
end)
