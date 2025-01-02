return {
	models = {
		perplexity = "llama-3.1-sonar-large-128k-chat",
		openai = "gpt-4o-mini",
		anthropic = "claude-3-5-haiku-latest",
		groq = "llama-3.3-70b-versatile",
		ollama = "llama3.3:latest",
	},
	price = {
		openai = {
			gpt_4o = { name = "gpt-4o", input = 2.5, output = 10.0 },
			gpt_4o_mini = { name = "gpt-4o-mini", input = 0.15, output = 0.6 },
		},
		anthropic = {
			haiku = { name = "claude-3-5-haiku-latest", input = 0.8, output = 4.0 },
			sonnet = { name = "claude-3-5-sonnet-latest", input = 3.0, output = 15.0 },
		},
		perplexity = {},
		groq = {},
	},
	api_endpoints = {
		anthropic = "https://api.anthropic.com/v1/messages",
		openai = "https://api.openai.com/v1/chat/completions",
		perplexity = "https://api.perplexity.ai/chat/completions",
		dalle = "https://api.openai.com/v1/images/generations",
		ollama = "http://localhost:11434/api/generate",
		groq = "https://api.groq.com/openai/v1/chat/completions",
	},
	prompts = {
		system_prompt = "",
		code_prompt = "You should replace the code that you are sent, only following the comments. Do not talk at all. Only output valid code. Do not provide any backticks that surround the code. Never ever output backticks like this ```. Any comment that is asking you for something should be removed after you satisfy them. Other comments should left alone. Do not output backticks",
		helpful_prompt = "You are a helpful assistant. What I have sent are my notes so far. You are very curt, yet helpful. You will always adjust your attitude as I request it.",
		en2ch_prompt = "You are a helpful assistant. Your goal is to translate text. You will never add anything to the text or output and you will never add commentary about the text you generate. Translate the following into Chinese: ",
		ch2en_prompt = "You are a helpful assistant. Your goal is to translate text. You will never add anything to the text or output and you will never add commentary about the text you generate. Translate the following into English: ",
		en2ar_prompt = "You are a helpful assistant. Your goal is to translate text. You will never add anything to the text or output and you will never add commentary about the text you generate. Translate the following into Arabic: ",
	},
	vars = {
		temp = 0.7,
		presence_penalty = nil,
		top_p = nil,
		frequency_penalty = nil,
		max_tokens = nil,
	},
	included_extensions = {
		".py",
		".pyc",
		".pyd",
		".pyo",
		".pyw",
		".pyx", -- Python variants
		".js",
		".ts",
		".jsx",
		".tsx",
		".mjs",
		".cjs", -- JavaScript and TypeScript
		".java",
		".kt",
		".scala",
		".groovy",
		".jav", -- Java family
		".cpp",
		".c",
		".h",
		".hpp",
		".hxx",
		".cxx",
		".cc", -- C/C++
		".php",
		".phtml",
		".phar",
		".phps", -- PHP
		".html",
		".htm",
		".xhtml",
		".jsp", -- HTML
		".css",
		".scss",
		".less",
		".sass",
		".stylus", -- Styling
		".rb",
		".erb",
		".rhtml",
		".ru", -- Ruby
		".swift",
		".m",
		".mm", -- Swift and Objective-C
		".go",
		".mod",
		".sum", -- Go
		".json",
		".jsonc",
		".geojson",
		".topojson", -- JSON
		".xml",
		".xsd",
		".rdf",
		".rss", -- XML
		".sql",
		".ddl",
		".dml", -- SQL
		".sh",
		".bash",
		".zsh",
		".fish",
		".csh", -- Shell scripts
		".pl",
		".pm",
		".t",
		".pod", -- Perl
		".r",
		".rmd",
		".rmarkdown", -- R
		".dart", -- Dart
		".lua",
		".rockspec", -- Lua
		".md",
		".markdown",
		".mdown",
		".mkdn", -- Markdown
		".txt",
		".log",
		".text", -- Text files
		".yml",
		".yaml",
		".eyaml", -- YAML
		".csv",
		".tsv", -- CSV and Tab-Separated Values
		".config",
		".ini",
		".cfg",
		".conf", -- Config files
		".toml", -- TOML
		".bat",
		".cmd",
		".ps1", -- Windows batch and PowerShell
		".psm1",
		".psd1", -- PowerShell modules
		".asm",
		".s",
		".nasm",
		".asm", -- Assembly
		".vue",
		".svelte",
		".angular", -- Frontend frameworks
		".erl",
		".hrl", -- Erlang
		".clj",
		".cljs",
		".cljc", -- Clojure
		".groovy",
		".gvy",
		".gradle", -- Groovy
		".coffee",
		".litcoffee", -- CoffeeScript
		".rs",
		".rlib", -- Rust
		".hs",
		".lhs", -- Haskell
		".ex",
		".exs", -- Elixir
		".elm", -- Elm
		".nim",
		".nims", -- Nim
		".fsx",
		".fs",
		".fsi", -- F# script
		".ml",
		".mli",
		".mll",
		".mly", -- OCaml
		".proto", -- Protocol Buffers
		".graphql",
		".gql", -- GraphQL
		".dockerfile", -- Docker
		".tf",
		".tfvars", -- Terraform
		".wasm", -- WebAssembly
		".ipynb", -- Jupyter Notebook
		".sol", -- Solidity
		".zig", -- Zig
		".tcl", -- Tcl
		".vb", -- Visual Basic
		".pl1",
		".pli", -- PL/I
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
