local constants = require("constants")
local provider  = require("provider")
local llm       = require("llm")

local FRAMEWORK = "OLLAMA"

local M = provider.create({
    constants    = constants,
    provider_key = "ollama",
    framework    = FRAMEWORK,
    make_curl    = llm.make_ollama_spec_curl_args,
    handle_data  = llm.handle_ollama_spec_data,
})

return M
