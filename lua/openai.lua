local constants = require("constants")
local provider  = require("provider")
local llm       = require("llm")

local OPENAI_API_KEY = "OPENAI_API_KEY"
local FRAMEWORK      = "OPENAI"

local M = provider.create({
    constants    = constants,
    provider_key = "openai",
    api_key_name = OPENAI_API_KEY,
    framework    = FRAMEWORK,
    make_curl    = llm.make_openai_spec_curl_args,
    handle_data  = llm.handle_openai_spec_data,
})

function M.dalle()
    llm.invoke_llm_and_stream_into_editor({
        url          = constants.api_endpoints.dalle,
        model        = "gpt-image-1",
        api_key_name = OPENAI_API_KEY,
        framework    = FRAMEWORK,
    }, llm.make_dalle_spec_curl_args, llm.handle_dalle_spec_data)
end

return M
