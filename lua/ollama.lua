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

function M.en2ch()
    llm.invoke_llm_and_stream_into_editor({
        url           = constants.api_endpoints.ollama,
        model         = constants.models.ollama,
        system_prompt = constants.prompts.en2ch_prompt,
        replace       = false,
        code_chat     = false,
        context       = false,
        framework     = FRAMEWORK,
    }, llm.make_ollama_spec_curl_args, llm.handle_ollama_spec_data)
end

function M.ch2en()
    llm.invoke_llm_and_stream_into_editor({
        url           = constants.api_endpoints.ollama,
        model         = constants.models.ollama,
        system_prompt = constants.prompts.ch2en_prompt,
        replace       = false,
        code_chat     = false,
        context       = false,
        framework     = FRAMEWORK,
    }, llm.make_ollama_spec_curl_args, llm.handle_ollama_spec_data)
end

return M
