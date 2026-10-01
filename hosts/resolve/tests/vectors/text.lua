--- Vectors for the text helpers in util.lua: segmentation, tags, clip and
-- file names, the utf8 helpers (in characters), clocks.
--
-- Inputs are records; `fn` is the Lua function. Positions are character
-- indices from 0 (utf8_codepoint), never byte offsets.

local U = require("higgs.util")

local cases = {}
local function case(name, fn, input, expect)
  cases[#cases + 1] = { name = name, fn = fn, input = input, expect = expect }
end

-- The n-th character's byte offset (n from 0), for calling the byte-based Lua.
local function byte_of(s, n)
  local k = 0
  for i in U.utf8_chars(s) do
    if k == n then return i end
    k = k + 1
  end
  return nil
end

------------------------------------------------------------------ trim

for _, c in ipairs({
  { "strips both ends", "  padded \n" },
  { "empty stays empty", "" },
  { "only spaces", "   \t " },
  { "every ASCII space character", "\t\v\f\r x y \r\n" },
  { "inner spaces kept", "  two  words  " },
  { "an ideographic space is not ASCII whitespace", "\227\128\128全角\227\128\128" },
  { "nor is a no-break space", "\194\160nbsp\194\160" },
}) do case("trim: " .. c[1], "trim", { s = c[2] }, U.trim(c[2])) end

------------------------------------------------------------------ tags

for _, c in ipairs({
  { "between words", "<|emotion:awe|> Hello <|prosody:pause|> world" },
  { "at the start", "<|emotion:happy|>Hello" },
  { "a sound effect before a word", "<|sfx:laughter|>Haha, that was fun." },
  { "shortest match each time", "a <|x|> b <|y|> c" },
  { "an unclosed tag stays", "<|unclosed tag" },
  { "HTML is not a tag", "<b>bold</b>" },
  { "an empty tag", "x<||>y" },
  { "a bar inside a tag", "<|a|b|>z" },
  { "across a line break", "<|a\nb|>after" },
  { "Chinese around a tag", "你好<|emotion:joy|>世界" },
}) do case("strip_tags: " .. c[1], "strip_tags", { s = c[2] }, U.strip_tags(c[2])) end

for _, c in ipairs({
  { "ignores tags", "<|emotion:awe|> Hello there world" },
  { "empty", "" },
  { "only spaces", "  \n\t " },
  { "tabs and line breaks separate", "a\tb\nc  d" },
  { "Chinese without spaces is one run", "你好世界" },
  { "a tag glued to a word leaves the word", "<|sfx:laughter|>Haha ok" },
  { "punctuation alone is a word", "wait — what" },
}) do case("word_count: " .. c[1], "word_count", { s = c[2] }, U.word_count(c[2])) end

for _, c in ipairs({
  { "three words", "one two three" },
  { "empty", "" },
  { "tags are not spoken", "<|emotion:joy|> Hello world <|sfx:laughter|>" },
  { "a long line", string.rep("word ", 75) },
}) do case("estimate_seconds: " .. c[1], "estimate_seconds", { s = c[2] }, U.estimate_seconds(c[2])) end

------------------------------------------------------------------ segmentation

for _, c in ipairs({
  { "line breaks, blank lines collapse", "First line.\nSecond line.\n\n  \n\nThird line." },
  { "no line breaks is one segment", "One long block of narration with no breaks at all." },
  { "only blank lines is nothing", "   \n\n  " },
  { "empty is nothing", "" },
  { "Windows line ends are trimmed", "One\r\nTwo\r\n" },
  { "a trailing break adds nothing", "Only\n" },
  { "lines keep tags", "<|emotion:joy|> Hi\n你好。" },
}) do case("split_lines: " .. c[1], "split_lines", { text = c[2] }, U.split_lines(c[2])) end

for _, c in ipairs({
  { "four pieces with a tail", "One sentence here. And a second! A third? Trailing bit" },
  { "no punctuation is one piece", "No punctuation here" },
  { "empty gives one empty piece", "" },
  { "a closing quote stays with its stop", "He said \"Hi.\" Then he left." },
  { "a closing bracket too", "(An aside.) Back to it." },
  { "runs of marks", "Wait... what?! Yes." },
  { "abbreviations are not handled", "Mr. Smith arrived. Late." },
  { "a stop with no space after is not a split", "Version 1.5 is out.Now" },
  { "line breaks separate too", "First.\nSecond." },
  { "Chinese full stops are not ASCII stops", "你好。我很好。" },
  { "a run of spaces between sentences repeats the tail's start (Lua quirk)", "Hi.  Two spaces. End" },
}) do case("split_sentences: " .. c[1], "split_sentences", { text = c[2] }, U.split_sentences(c[2])) end

------------------------------------------------------------------ scripts

local cps = { 0x20, 0x27, 0x2C, 0x30, 0x41, 0x5F, 0x61, 0x7E, 0xE9, 0x0E01, 0x2014, 0x2019,
              0x3001, 0x3002, 0x3042, 0x30A2, 0x4E00, 0x9FFF, 0xAC00, 0xF900, 0xFF01, 0xFF0C,
              0xFF10, 0xFF1F, 0xFF21, 0xFF3B, 0xFF5B, 0xFF65, 0xFF66, 0xFF9D, 0x0410, 0x0627 }
local ideo, punct = {}, {}
for i, cp in ipairs(cps) do ideo[i], punct[i] = U.is_ideographic(cp), U.is_punct(cp) end
case("is_ideographic across scripts", "is_ideographic", { cps = cps }, ideo)
case("is_punct across scripts", "is_punct", { cps = cps }, punct)

for _, c in ipairs({
  { "English takes words", "Welcome back to the channel today", 4 },
  { "Chinese characters count half", "今天我们来聊聊调色这件事情", 4 },
  { "marks between characters are skipped", "你好，世界！这是一段旁白。", 4 },
  { "Japanese kana the same way", "こんにちは、ナレーションです", 3 },
  { "a mixed line spends one budget", "iPhone 拍摄的日落真的很美", 4 },
  { "Cyrillic keeps its words", "Привет, это закадровый голос", 4 },
  { "Korean is a spaced script", "안녕하세요 여러분 반갑습니다 오늘은", 2 },
  { "Thai characters count half", "สวัสดีครับทุกคน", 3 },
  { "nothing usable falls back", "...", 4 },
  { "empty falls back", "", 4 },
  { "apostrophes leave the word", "It's a dog's life", 3 },
  { "tags are not words", "<|emotion:joy|> Hello <|sfx:laughter|> there friend", 2 },
  { "a budget of zero gives nothing", "Hello world", 0 },
  { "the default budget is four", "one two three four five six", nil },
  { "accented letters stay", "Él está aquí, señor", 3 },
}) do case("clip_words: " .. c[1], "clip_words", { text = c[2], count = c[3] }, U.clip_words(c[2], c[3])) end

for _, c in ipairs({
  { "collapses whitespace runs", "Alex  —  narration/v2!" },
  { "keeps hyphen and underscore", "take-01_final" },
  { "keeps Chinese", "旁白 第一段" },
  { "removes only what a filesystem refuses", 'a<b>c:d"e/f\\g|h?i*j' },
  { "strips a trailing dot", "take." },
  { "strips leading dots and underscores", "..._hidden" },
  { "drops control characters", "\1tab\there\127" },
  { "a dot between words stays", "a . b" },
  { "underscore runs collapse", "a___b" },
  { "48 bytes of ASCII at most", string.rep("abcdefghij", 6) },
  { "Chinese is cut on a character", string.rep("旁", 30) },
  { "a mixed line is cut before the character that would cross 48 bytes", "a" .. string.rep("旁", 20) },
  { "four-byte characters too", string.rep("😀", 13) },
  { "empty", "" },
}) do case("sanitize: " .. c[1], "sanitize", { name = c[2] }, U.sanitize(c[2])) end

------------------------------------------------------------------ utf8 (in characters)

for _, s in ipairs({ "", "abc", "旁白", "é", "😀a", "Привет", "a旁😀é" }) do
  case("utf8_len of " .. (s == "" and "nothing" or s), "utf8_len", { s = s }, U.utf8_len(s))
end
for _, s in ipairs({ "a旁😀é", "Hola", "" }) do
  local chars = {}
  for _, ch in U.utf8_chars(s) do chars[#chars + 1] = ch end
  case("utf8_chars of " .. (s == "" and "nothing" or s), "utf8_chars", { s = s }, chars)
end
for _, c in ipairs({ { "a旁😀é", 0 }, { "a旁😀é", 1 }, { "a旁😀é", 2 }, { "a旁😀é", 3 }, { "Привет", 5 } }) do
  case(("utf8_codepoint of %s at %d"):format(c[1], c[2]), "utf8_codepoint", { s = c[1], index = c[2] },
       U.utf8_codepoint(c[1], byte_of(c[1], c[2])))
end

------------------------------------------------------------------ clocks

for _, v in ipairs({ 0, 9.9, 59.9, 60, 125.9, 3600, 3725.5, -5, "42" }) do
  case("format_clock " .. (type(v) == "string" and ("%q"):format(v) or tostring(v)), "format_clock", { seconds = v }, U.format_clock(v))
end
case("format_clock of nothing", "format_clock", {}, U.format_clock(nil))
for _, v in ipairs({ 7.2, 125.9, 0, 0.05, 0.25, 7.25, 12.75, 59.94, 59.96, 600, 3599.99, -5, "7.2" }) do
  case("format_duration " .. (type(v) == "string" and ("%q"):format(v) or tostring(v)), "format_duration", { seconds = v }, U.format_duration(v))
end
case("format_duration of nothing", "format_duration", {}, U.format_duration(nil))

return {
  about = "Text helpers from util.lua. fn names are the Lua's; input is a record of its arguments "
    .. "(utf8_codepoint takes a character index from 0, not a byte offset; is_ideographic and "
    .. "is_punct map over `cps`). new_id is random and has no vectors.",
  source = "src/higgs/util.lua",
  cases = cases,
}
