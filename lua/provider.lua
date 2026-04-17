local llm = require("llm")

local P = {}

-- Factory to generate common provider wrappers to reduce duplication.
-- Accepts either:
--   opts.constants + opts.provider_key  (preferred — values read lazily at call time)
--   opts.url + opts.model + opts.prompts + opts.vars  (legacy / direct)
function P.create(opts)
  local api_key_name = opts.api_key_name
  local framework    = opts.framework
  local make_curl    = opts.make_curl
  local handle_data  = opts.handle_data

  -- Resolve url/model/prompts/vars either from a live constants table or from
  -- the values passed directly, so that constants.setup() overrides take effect.
  local function get_url()
    if opts.constants and opts.provider_key then
      return opts.constants.api_endpoints[opts.provider_key]
    end
    return opts.url
  end
  local function get_model()
    if opts.constants and opts.provider_key then
      return opts.constants.models[opts.provider_key]
    end
    return opts.model
  end
  local function get_prompts()
    if opts.constants then return opts.constants.prompts end
    return opts.prompts or { system_prompt = "", code_prompt = "" }
  end
  local function get_vars()
    if opts.constants then return opts.constants.vars end
    return opts.vars or {}
  end

  local M = {}

  function M.invoke()
    local p, v = get_prompts(), get_vars()
    llm.invoke_llm_and_stream_into_editor({
      url              = get_url(),
      model            = get_model(),
      system_prompt    = p.system_prompt,
      replace          = false,
      code_chat        = true,
      all_buffers      = false,
      framework        = framework,
      api_key_name     = api_key_name,
      temp             = v.temp,
      presence_penalty = v.presence_penalty,
      top_p            = v.top_p,
    }, make_curl, handle_data)
  end

  function M.code()
    local p, v = get_prompts(), get_vars()
    llm.invoke_llm_and_stream_into_editor({
      url              = get_url(),
      model            = get_model(),
      system_prompt    = p.code_prompt,
      replace          = true,
      code_chat        = false,
      all_buffers      = false,
      framework        = framework,
      api_key_name     = api_key_name,
      temp             = v.temp,
      presence_penalty = v.presence_penalty,
      top_p            = v.top_p,
    }, make_curl, handle_data)
  end

  function M.code_all_buf()
    local p, v = get_prompts(), get_vars()
    llm.invoke_llm_and_stream_into_editor({
      url              = get_url(),
      model            = get_model(),
      system_prompt    = p.code_prompt,
      replace          = true,
      code_chat        = false,
      all_buffers      = true,
      framework        = framework,
      api_key_name     = api_key_name,
      temp             = v.temp,
      presence_penalty = v.presence_penalty,
      top_p            = v.top_p,
    }, make_curl, handle_data)
  end

  function M.code_chat()
    local p, v = get_prompts(), get_vars()
    llm.invoke_llm_and_stream_into_editor({
      url              = get_url(),
      model            = get_model(),
      system_prompt    = p.code_prompt,
      replace          = false,
      code_chat        = true,
      all_buffers      = false,
      framework        = framework,
      api_key_name     = api_key_name,
      temp             = v.temp,
      presence_penalty = v.presence_penalty,
      top_p            = v.top_p,
    }, make_curl, handle_data)
  end

  function M.code_chat_all_buf()
    local p, v = get_prompts(), get_vars()
    llm.invoke_llm_and_stream_into_editor({
      url              = get_url(),
      model            = get_model(),
      system_prompt    = p.code_prompt,
      replace          = false,
      code_chat        = true,
      all_buffers      = true,
      framework        = framework,
      api_key_name     = api_key_name,
      temp             = v.temp,
      presence_penalty = v.presence_penalty,
      top_p            = v.top_p,
    }, make_curl, handle_data)
  end

  function M.code_diff()
    local p, v = get_prompts(), get_vars()
    llm.invoke_llm_and_stream_into_diff({
      url              = get_url(),
      model            = get_model(),
      api_key_name     = api_key_name,
      system_prompt    = p.code_prompt,
      framework        = framework,
      temp             = v.temp,
      presence_penalty = v.presence_penalty,
      top_p            = v.top_p,
    }, make_curl, handle_data)
  end

  return M
end

return P
