local constants = require("constants")
local provider = require("provider")
local llm = require("llm")

local PERPLEXITY_URL = constants.api_endpoints.perplexity
local PERPLEXITY_API_KEY = "PERPLEXITY_API_KEY"
local FRAMEWORK = "PERPLEXITY"

return provider.create({
    url = PERPLEXITY_URL,
    model = constants.models.perplexity,
    api_key_name = PERPLEXITY_API_KEY,
    framework = FRAMEWORK,
    prompts = constants.prompts,
    vars = constants.vars,
    make_curl = llm.make_perplexity_spec_curl_args,
    handle_data = llm.handle_perplexity_spec_data,
})
