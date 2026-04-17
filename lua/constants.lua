local M = {
  models = {
    openai = "gpt-5.4-mini",
    anthropic = "claude-haiku-4-5-20251001",
    ollama = "qwen3.6:latest",
  },
  api_endpoints = {
    anthropic = "https://api.anthropic.com/v1/messages",
    openai = "https://api.openai.com/v1/responses",
    dalle = "https://api.openai.com/v1/images/generations",
    ollama = "https://ollama.putty-ai.com/api/chat",
  },
  prompts = {
    system_prompt = "",
    code_prompt = "You are a code-replacement engine. Output ONLY raw source code — no markdown, no code fences, no backticks, no triple backticks, no language tags, no explanations, no prose. Your output is written verbatim into a source file, so any non-code character will break the file. Remove any comment that gave you an instruction once you have satisfied it. Keep all other comments. If the input is code, improve it. If the input is an instruction, follow it exactly.",
    code_instruction = "OUTPUT ONLY RAW CODE — no markdown fences, no backticks, no explanations, no prose outside comments. Keep comments minimal. Remove instruction comments once satisfied. Task:\n",
    helpful_prompt = "You are a helpful assistant. What I have sent are my notes so far. You are very curt, yet helpful. You will always adjust your attitude as I request it.",
  },
  vars = {
    temp = 1,
    presence_penalty = nil,
    top_p = nil,
    frequency_penalty = nil,
    max_tokens = nil,
  },
  excluded_extensions = {
    -- Configuration files
    ".env",
    ".gitignore",
    ".dockerignore",
    ".editorconfig",
    -- Database files
    ".db",
    ".sqlite",
    ".sqlite3",
    -- Binary files
    ".exe",
    ".dll",
    ".so",
    ".dylib",
    -- Image files
    ".jpg",
    ".jpeg",
    ".png",
    ".gif",
    ".bmp",
    ".svg",
    -- Audio files
    ".mp3",
    ".wav",
    ".ogg",
    -- Video files
    ".mp4",
    ".avi",
    ".mov",
    -- Compressed files
    ".zip",
    ".rar",
    ".7z",
    ".tar",
    ".gz",
    -- Document files
    ".pdf",
    ".doc",
    ".docx",
    ".xls",
    ".xlsx",
    ".ppt",
    ".pptx",
    -- Log files
    ".log",
    -- Temporary files
    ".tmp",
    ".temp",
    -- Backup files
    ".bak",
    ".backup",
    -- Cache files
    ".cache",
    -- Package lock files
    "package-lock.json",
    "yarn.lock",
    "Gemfile.lock",
    -- Compiled files
    ".pyc",
    ".class",
    ".o",
  },
}

function M.setup(opts)
  if type(opts) ~= "table" then return end
  local function merge(dst, src)
    for k, v in pairs(src) do
      if type(v) == "table" and type(dst[k]) == "table" then
        merge(dst[k], v)
      else
        dst[k] = v
      end
    end
  end
  merge(M, opts)
end

return M
