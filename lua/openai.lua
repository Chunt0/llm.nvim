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

function M.en2ch()
    llm.invoke_llm_and_stream_into_editor({
        url              = constants.api_endpoints.openai,
        model            = constants.models.openai,
        system_prompt    = constants.prompts.en2ch_prompt,
        replace          = false,
        code_chat        = false,
        framework        = FRAMEWORK,
        temp             = constants.vars.temp,
        presence_penalty = constants.vars.presence_penalty,
        top_p            = constants.vars.top_p,
    }, llm.make_openai_spec_curl_args, llm.handle_openai_spec_data)
end

function M.en2ar()
    llm.invoke_llm_and_stream_into_editor({
        url              = constants.api_endpoints.openai,
        model            = constants.models.openai,
        system_prompt    = constants.prompts.en2ar_prompt,
        replace          = false,
        code_chat        = false,
        framework        = FRAMEWORK,
        temp             = constants.vars.temp,
        presence_penalty = constants.vars.presence_penalty,
        top_p            = constants.vars.top_p,
    }, llm.make_openai_spec_curl_args, llm.handle_openai_spec_data)
end

return M
