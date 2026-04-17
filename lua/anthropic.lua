local constants = require("constants")
local provider  = require("provider")
local llm       = require("llm")

local ANTHROPIC_API_KEY_NAME = "ANTHROPIC_API_KEY"
local FRAMEWORK              = "ANTHROPIC"

return provider.create({
    constants    = constants,
    provider_key = "anthropic",
    api_key_name = ANTHROPIC_API_KEY_NAME,
    framework    = FRAMEWORK,
    make_curl    = llm.make_anthropic_spec_curl_args,
    handle_data  = llm.handle_anthropic_spec_data,
})
