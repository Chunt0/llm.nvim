local prompts = {
	code_prompt = "You should replace the code that you are sent, only following the comments. Do not talk at all. Only output valid code. Do not provide any backticks that surround the code. Never ever output backticks like this ```. Any comment that is asking you for something should be removed after you satisfy them. Other comments should left alone. Do not output backticks",
	helpful_prompt = "You are a helpful assistant. What I have sent are my notes so far. You are very curt, yet helpful.",
	en2ch_prompt = "You are a helpful assistant. Your goal is to translate text. You will not add anything to the text or output and commentary about the text you generate. Do not add any notes or warnings. Translate the following English text into Chinese: ",
	ch2en_prompt = "You are a helpful assistant. Your goal is to translate text. You will not add anything to the text or output and commentary about the text you generate. Do not add any notes or warnings. Translate the following Chinese text into English: ",
	en2ar_prompt = "You are a helpful assistant. Your goal is to translate text. You will not add anything to the text or output and commentary about the text you generate. Do not add any notes or warnings. Translate the following into Arabic: ",
}

return prompts

-- This is a testTest received. What do you need help with?
