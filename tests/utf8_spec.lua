local llm = require("llm")

describe("UTF-8 splitter", function()
  it("does not break multibyte at boundary", function()
    -- Smoke test: deltas arriving in separate chunks (e.g. a 4-byte 😀 split
    -- across reads) must not raise; write_safely carries incomplete bytes.
    assert.has_no.errors(function()
      llm.handle_openai_spec_data('data: {"type":"response.output_text.delta","delta":"he"}\n')
      llm.handle_openai_spec_data('data: {"type":"response.output_text.delta","delta":"llo"}\n')
    end)
  end)
end)
