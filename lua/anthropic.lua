local constants = require("constants")
local provider = require("provider")
local llm = require("llm")

local ANTHROPIC_URL = constants.api_endpoints.anthropic
local ANTHROPIC_API_KEY_NAME = "ANTHROPIC_API_KEY"
local FRAMEWORK = "ANTHROPIC"

return provider.create({
    url = ANTHROPIC_URL,
    model = constants.models.anthropic,
    api_key_name = ANTHROPIC_API_KEY_NAME,
    framework = FRAMEWORK,
    prompts = constants.prompts,
    vars = constants.vars,
    make_curl = llm.make_anthropic_spec_curl_args,
    handle_data = llm.handle_anthropic_spec_data,
})
