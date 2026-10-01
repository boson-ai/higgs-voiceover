--- Vectors for tags.lua: the taxonomy, kind, terminate, place_tag, compose.
--
-- Inputs are records; `fn` is the Lua function. place_tag's caret is given in
-- UTF-16 code units (a textarea's selectionStart), never as a byte offset.

local T = require("higgs.tags")
local U = require("higgs.util")

local cases = {}
local function case(name, fn, input, expect)
  cases[#cases + 1] = { name = name, fn = fn, input = input, expect = expect }
end

-- UTF-16 length: characters outside the BMP (4 UTF-8 bytes) count twice.
local function u16len(s)
  local n = 0
  for _, ch in U.utf8_chars(s) do n = n + (#ch == 4 and 2 or 1) end
  return n
end

------------------------------------------------------------------ taxonomy

for _, k in ipairs({ "EMOTIONS", "STYLES", "SFX", "SFX_WORDS", "SPEEDS", "PITCHES",
                     "EXPRESSIVENESS", "PAUSES", "MAX_CHARS" }) do
  case("constant " .. k, k, { none = true }, T[k])
end
case("categories in menu order", "categories", { none = true }, T.categories())
for _, c in ipairs({ "Emotion", "Style", "Prosody", "Sound effect", "Nope", "emotion" }) do
  case("values_for " .. c, "values_for", { category = c }, T.values_for(c))
end

for _, v in ipairs({
  "emotion:awe", "emotion:", "style:singing", "prosody:speed_fast", "prosody:speed_very_slow",
  "prosody:pitch_low", "prosody:pitch_high", "prosody:expressive_low", "prosody:expressive_high",
  "prosody:pause", "prosody:long_pause", "prosody:volume_up", "prosody:speed", "sfx:cough",
  "sfx:crying", "", "emotion", "Emotion:awe", " emotion:awe",
}) do
  case("kind of " .. (v == "" and "nothing" or v), "kind", { value = v }, T.kind(v))
end

for _, c in ipairs({ "emotion:awe", "prosody:pause", "" }) do
  case("token " .. c, "token", { value = c }, T.token(c))
end

------------------------------------------------------------------ terminate

for _, c in ipairs({
  { "adds a full stop to an unpunctuated line", "Dragging works" },
  { "after a digit", "Take 2" },
  { "leaves a full stop alone", "Already done." },
  { "leaves other punctuation alone", "Really?" },
  { "leaves a comma alone", "Well," },
  { "a trailing space is not a word", "Hello " },
  { "a closing bracket is not a word", "(aside)" },
  { "leaves a trailing tag alone", "Hi <|sfx:laughter|>" },
  { "leaves an empty line alone", "" },
  { "uses a CJK full stop for CJK", "你好" },
  { "and for kana", "こんにちは" },
  { "and for Hangul", "안녕하세요" },
  { "leaves CJK punctuation alone", "你好。" },
  { "leaves a fullwidth bang alone", "好！" },
  { "leaves a fullwidth bracket alone", "（注）" },
  { "an accented word still gets a stop", "café" },
  { "Cyrillic gets a plain stop", "Привет" },
  { "Arabic gets a plain stop", "مرحبا" },
  { "an ellipsis is left alone", "wait…" },
  { "a curly quote is left alone", "say “hi”" },
  { "an emoji gets a plain stop", "Smile 😀" },
  { "one short of the ceiling still gets one", string.rep("a", T.MAX_CHARS - 1) },
  { "never pushes a full line over the ceiling", string.rep("a", T.MAX_CHARS) },
}) do case("terminate: " .. c[1], "terminate", { text = c[2] }, T.terminate(c[2])) end

------------------------------------------------------------------ place_tag

local function place(name, before, after, value, line_start)
  local out, caret = T.place_tag(before, after, value, line_start)
  case("place_tag: " .. name, "place_tag",
       { before = before, after = after, value = value, line_start = line_start },
       { text = out, caret = u16len(out:sub(1, caret)) })
end

place("goes in at the point", "Hello ", "world", "emotion:elation", false)
place("replaces what was selected", "Hello ", " world", "emotion:elation", false)
place("into an empty box", "", "", "prosody:pause", false)
place("a pause goes in with its space", "Hello ", "world", "prosody:pause", false)
place("a long pause at the end", "The end", "", "prosody:long_pause", false)
place("a line-start tag moves to the front of its line", "one\ntwo three", " four", "prosody:speed_fast", true)
place("only its own line, not every line", "one\ntwo\nthree", "", "prosody:speed_fast", true)
place("replaces an existing speed", "<|prosody:speed_slow|> two", " three", "prosody:speed_fast", true)
place("replaces an existing pitch", "<|prosody:pitch_low|> two", "", "prosody:pitch_high", true)
place("replaces an existing expressiveness", "<|prosody:expressive_high|> go", "", "prosody:expressive_low", true)
place("leaves a different axis alone", "<|prosody:pitch_low|> two", "", "prosody:speed_fast", true)
place("the first line has no newline to find", "two three", "", "prosody:pitch_high", true)
place("emotion leads the line", "one\ntwo ", "three", "emotion:elation", true)
place("a new emotion replaces the old one", "<|emotion:sadness|> two ", "three", "emotion:elation", true)
place("and leaves other leading tags", "<|prosody:speed_fast|> <|emotion:sadness|> go", "", "emotion:elation", true)
place("style replaces style, not emotion", "<|emotion:awe|> <|style:shouting|> hey", "", "style:whispering", true)
place("a tag mid-line is left where it is", "go <|sfx:cough|>Ahem on", "", "emotion:awe", true)
place("the caret stays where it was in the text", "one\ntwo th", "ree", "prosody:speed_fast", true)
place("never inside the new tag when the old one was after the caret", "one\n", "<|prosody:speed_slow|> two", "prosody:speed_fast", true)
place("leading tags without spaces between them", "<|emotion:awe|><|prosody:pitch_low|>hi", "", "prosody:pitch_high", true)
place("leading tags separated by a tab", "<|emotion:awe|>\t<|style:singing|>text", "", "style:shouting", true)
place("a line of only spaces", "a\n   ", "text", "emotion:awe", true)
place("an empty line before the caret", "a\n", "", "emotion:awe", true)
place("a Windows line break keeps its return", "a\r\nb", " c", "prosody:speed_fast", true)
place("a positional tag at the front is dropped by a line-start positional value", "<|sfx:cough|>Ahem hi", "", "prosody:pause", true)
place("a sound effect brings its sound, as Boson advises", "That's funny. ", "Anyway.", "sfx:laughter", false)
place("a sound already typed is not added twice", "", " haha, sure.", "sfx:laughter", false)
place("whatever its case", "Oh ", "  AHEM, sorry", "sfx:cough", false)
place("nor when it runs on", "", "Hahaha", "sfx:laughter", false)
place("crying has no sound word", "", "I... I'm sorry.", "sfx:crying", false)
place("an unknown effect has no sound word", "x ", "y", "sfx:whistle", false)
for _, s in ipairs(T.SFX) do place("sfx " .. s, "So ", "anyway.", "sfx:" .. s, false) end
place("CJK before the caret", "你好，", "世界", "prosody:pause", false)
place("CJK with a sound effect", "真好笑", "。", "sfx:laughter", false)
place("CJK line start", "第一行\n第二", "行", "prosody:speed_fast", true)
place("CJK line start replacing an emotion", "<|emotion:awe|> 你好", "世界", "emotion:anger", true)
place("an emoji before the caret", "Hi 😀 ", "there", "prosody:pause", false)
place("an emoji on a line-start line", "a\n😀 b", "c", "emotion:awe", true)
place("accents and a sound effect", "Très drôle ", "", "sfx:laughter", false)

------------------------------------------------------------------ compose

local function compose(name, text, direction)
  case("compose: " .. name, "compose", { text = text, direction = direction }, T.compose(text, direction))
  case("billable_length: " .. name, "billable_length", { text = text, direction = direction },
       T.billable_length(text, direction))
end

compose("leaves the text as typed", "Dragging works", nil)
compose("trims the text", "  spaced out \n", nil)
compose("no text at all", nil, { emotion = "awe" })
compose("every field", "Hello.", { emotion = "awe", style = "whispering", speed = "speed_slow",
                                   pitch = "pitch_low", expressiveness = "expressive_high" })
compose("empty fields mean leave it alone", "Hello.", { emotion = "", style = "", speed = "speed_fast" })
compose("keeps hand-written tags where they are", "Wait <|prosody:pause|> now", { pitch = "pitch_high" })
compose("CJK counts bytes, as the Lua does", "你好", { emotion = "awe" })

------------------------------------------------------------------ has_leading_tag

for _, c in ipairs({
  { "an emotion", "<|emotion:awe|> hi" },
  { "a style after spaces", "   <|style:singing|> la" },
  { "prosody", "<|prosody:pause|> then" },
  { "a sound effect is not direction", "<|sfx:cough|>Ahem" },
  { "a tag mid-line is not leading", "hi <|emotion:awe|>" },
  { "no tags", "plain" },
  { "empty", "" },
  { "an unclosed tag", "<|emotion:awe" },
  { "an uppercase category", "<|Emotion:awe|> x" },
}) do case("has_leading_tag: " .. c[1], "has_leading_tag", { text = c[2] }, T.has_leading_tag(c[2])) end

return {
  about = "Higgs TTS control tags: taxonomy, placement and composition. Carets are UTF-16 code units.",
  source = "src/higgs/tags.lua",
  cases = cases,
}
