local constants = require("constants")
local provider = require("provider")
local llm = require("llm")

local GROQ_URL = constants.api_endpoints.groq
local GROQ_API_KEY = "GROQ_API_KEY"
local FRAMEWORK = "GROQ"

return provider.create({
    url = GROQ_URL,
    model = constants.models.groq,
    api_key_name = GROQ_API_KEY,
    framework = FRAMEWORK,
    prompts = constants.prompts,
    vars = constants.vars,
    make_curl = llm.make_groq_spec_curl_args,
    handle_data = llm.handle_groq_spec_data,
})
