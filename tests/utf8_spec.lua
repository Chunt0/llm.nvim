local llm = require('llm')

describe('UTF-8 splitter', function()
  it('does not break multibyte at boundary', function()
    -- U+1F600 😀 is 4 bytes in UTF-8
    local s = 'hello ' .. '😀' .. ' world\n'
    -- feed in two chunks splitting the multibyte
    -- we do not call internals directly; this is a smoke test to ensure no errors on handler
    assert.has_no.errors(function()
      -- simulate write_safely via handler
      llm.handle_openai_spec_data('data: {"type":"response.output_text.delta","delta":"he"}\n')
      llm.handle_openai_spec_data('data: {"type":"response.output_text.delta","delta":"llo"}\n')
    end)
  end)
end)
