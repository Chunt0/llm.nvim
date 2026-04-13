local llm = require("llm")

local P = {}

-- Factory to generate common provider wrappers to reduce duplication
function P.create(opts)
  local url = opts.url
  local model = opts.model
  local api_key_name = opts.api_key_name
  local framework = opts.framework
  local prompts = opts.prompts or { system_prompt = "", code_prompt = "" }
  local make_curl = opts.make_curl
  local handle_data = opts.handle_data
  local vars = opts.vars or {}

  local common = {
    framework = framework,
  }
  if api_key_name then
    common.api_key_name = api_key_name
  end

  local M = {}

  function M.invoke()
    llm.invoke_llm_and_stream_into_editor({
      url = url,
      model = model,
      system_prompt = prompts.system_prompt,
      replace = false,
      code_chat = true,
      all_buffers = false,
      framework = framework,
      temp = vars.temp,
      presence_penalty = vars.presence_penalty,
      top_p = vars.top_p,
    }, make_curl, handle_data)
  end

  function M.code()
    llm.invoke_llm_and_stream_into_editor({
      url = url,
      model = model,
      system_prompt = prompts.code_prompt,
      replace = true,
      code_chat = false,
      all_buffers = false,
      framework = framework,
      temp = vars.temp,
      presence_penalty = vars.presence_penalty,
      top_p = vars.top_p,
    }, make_curl, handle_data)
  end

  function M.code_all_buf()
    llm.invoke_llm_and_stream_into_editor({
      url = url,
      model = model,
      system_prompt = prompts.code_prompt,
      replace = true,
      code_chat = false,
      all_buffers = true,
      framework = framework,
      temp = vars.temp,
      presence_penalty = vars.presence_penalty,
      top_p = vars.top_p,
    }, make_curl, handle_data)
  end

  function M.code_chat()
    llm.invoke_llm_and_stream_into_editor({
      url = url,
      model = model,
      system_prompt = prompts.code_prompt,
      replace = false,
      code_chat = true,
      all_buffers = false,
      framework = framework,
      temp = vars.temp,
      presence_penalty = vars.presence_penalty,
      top_p = vars.top_p,
    }, make_curl, handle_data)
  end

  function M.code_chat_all_buf()
    llm.invoke_llm_and_stream_into_editor({
      url = url,
      model = model,
      system_prompt = prompts.code_prompt,
      replace = false,
      code_chat = true,
      all_buffers = true,
      framework = framework,
      temp = vars.temp,
      presence_penalty = vars.presence_penalty,
      top_p = vars.top_p,
    }, make_curl, handle_data)
  end

  return M
end

return P
