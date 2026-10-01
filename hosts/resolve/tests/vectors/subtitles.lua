--- Vectors for subtitles.lua: reading a line, tokens, word timing, both
-- split modes, frames and .srt.
--
-- Token indices (a cue's first/last, a token's word) are written from 0, as
-- other hosts count them; the Lua counts from 1. Input timings are rounded to
-- the millisecond so they survive the trip through JSON exactly.

local S = require("higgs.subtitles")
local U = require("higgs.util")

local cases = {}
local function case(name, fn, input, expect)
  cases[#cases + 1] = { name = name, fn = fn, input = input, expect = expect }
end

local function r3(x) return tonumber(string.format("%.3f", x)) end

local function copy(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = copy(x) end
  return o
end

local function tok_out(t)
  return { text = t.text, key = t.key, space = t.space, cjk = t.cjk, width = t.width,
           s = t.s, e = t.e, word = t.word and t.word - 1 }
end
local function toks_out(list)
  local o = {}
  for i, t in ipairs(list) do o[i] = tok_out(t) end
  return o
end
local function cues_out(list)
  local o = {}
  for i, c in ipairs(list) do
    local x = copy(c)
    if x.first then x.first = x.first - 1 end
    if x.last then x.last = x.last - 1 end
    o[i] = x
  end
  return o
end

--- Boson-style word timings: each word 0.2 s long and 0.05 s after the one
-- before; "~" is a short breath (0.27 s between the words), "|" a breath
-- (0.45 s), "||" a long pause (1.25 s). `dur` and
-- `gap` change the pace.
local function timed(list, dur, gap, at)
  dur, gap = dur or 0.2, gap or 0.05
  local out, t = {}, at or 0.1
  for w in list:gmatch("%S+") do
    if w == "|" then t = t + 0.4
    elseif w == "~" then t = t + 0.22
    elseif w == "||" then t = t + 1.2
    else
      out[#out + 1] = { word = w, start = r3(t), ["end"] = r3(t + dur) }
      t = t + dur + gap
    end
  end
  return out
end

--- One timed word per character, as Boson times Chinese and Japanese.
local function per_char(text, dur, gap)
  local chars = {}
  for _, ch in U.utf8_chars(text) do
    if not U.is_punct(U.utf8_codepoint(ch, 1)) then chars[#chars + 1] = ch end
  end
  return timed(table.concat(chars, " "), dur or 0.15, gap or 0.02)
end

local LONG = "When we started this project, nobody on the team believed that a four-person studio could ship a feature film in under a year, but here we are, and the premiere is next Friday in Toronto."
local LONG2 = "When we started this project, nobody on the team believed a four-person studio could ship a feature film in under a year. But here we are."
local ZH = "我们今天要调色一段完全用手机拍摄的日落延时视频，效果真的让我大吃一惊。"
local ES = "Cuando empezamos este proyecto, nadie en el equipo creía que un estudio de cuatro personas pudiera terminar una película en menos de un año, pero aquí estamos."
local JA = "今日はとても良い天気ですね散歩に行きましょうか"

------------------------------------------------------------------ constants

case("constants", "constants", {}, {
  MODES = S.MODES, LIMIT = S.LIMIT, LIMIT_CJK = S.LIMIT_CJK, LIMIT_JA = S.LIMIT_JA,
  LIMIT_TH = S.LIMIT_TH, MIN_SECONDS = S.MIN_SECONDS, MAX_SECONDS = S.MAX_SECONDS,
  FILL_SECONDS = S.FILL_SECONDS, LAG_SECONDS = S.LAG_SECONDS,
})

------------------------------------------------------------------ reading the line

for _, c in ipairs({
  { "tags are not shown", "<|emotion:joy|> Hello  there <|sfx:laugh|>!" },
  { "a sound effect before a word", "<|sfx:laughter|>Haha, that was fun." },
  { "line breaks and tabs collapse", "  several\n\nlines\tand tabs  " },
  { "only a tag shows nothing", "<|emotion:happy|>" },
  { "Chinese keeps its marks", "<|emotion:joy|>你好，世界！" },
}) do case("display_text: " .. c[1], "display_text", { text = c[2] }, S.display_text(c[2])) end
case("display_text: nothing", "display_text", {}, S.display_text(nil))

--- One case for many short inputs: `fn` over input.texts, false for nil.
local function map_case(name, fn, texts)
  local out = {}
  for i, t in ipairs(texts) do
    local v = S[fn](t)
    if v == nil then v = false end
    out[i] = v
  end
  case(name, fn, { texts = texts }, out)
end

-- Apostrophes, quotes, separators and every script's marks go; only A–Z
-- are lowered (Lua's string.lower in the C locale).
map_case("key_of: letters and digits only", "key_of",
  { "We're,", "it’s", "“Well,”", "ÉCOLE Привет ABC", "1,250.50", "e.g.", "我们，", "¿Qué?", "a·b", "" })

-- Chinese and Hangul 42/16 a character, kana 42/13, Thai 42/35, Latin 1.
map_case("text_width: per script, mixed lines share", "text_width",
  { "拍摄", "iPhone拍摄", "こんにちは", "สวัสดี", "안녕하세요", "ＡＢＣ", "Hello, world", "" })

do
  local cps = { 0x41, 0xE9, 0x0410, 0x0E01, 0x1100, 0x3000, 0x3042, 0x30FF, 0x3131, 0x4E00,
                0xAC00, 0xD7AF, 0xF900, 0xFF01, 0xFF65, 0xFF66, 0xFF9D, 0xFF9E, 0x1F600 }
  local w = {}
  -- char_width is local in the Lua; one character's width is text_width of it.
  local function utf8(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    if cp < 0x10000 then
      return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
                       0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  end
  for i, cp in ipairs(cps) do w[i] = S.text_width(utf8(cp)) end
  case("char_width across scripts", "char_width", { cps = cps }, w)
end

map_case("ending: sentence, clause or none, in many scripts", "ending", {
  "today.", "Dr.", "Mr.", "e.g.", "vs.", "well,", "fine.”", "so...", "so…", "end?", "end!",
  "Hmm?!", "(fine.)", "«Bien».", "wait—", "a;", "x:", "word", "好。", "好！", "好？", "好，", "好、",
  "नमस्ते।", "حالك؟", "بخير،", "Ok.\"", "", ".",
})

------------------------------------------------------------------ tokens

for _, c in ipairs({
  { "quotes, a lone dash, an apostrophe", "“Well,” she said — it's fine." },
  { "Chinese splits into characters", "我们今天，好吗？" },
  { "Spanish opening marks and guillemets", "¿Qué tal? «Bien»." },
  { "an opening bracket after Chinese opens the next", "他说「好」吧。" },
  { "a straight quote after Chinese closes", "他说\"好\"吧" },
  { "mixed scripts", "iPhone拍摄的日落" },
  { "Japanese kana", "こんにちは、世界。" },
  { "Korean keeps its words", "안녕하세요 여러분, 반갑습니다." },
  { "Thai is one character a token", "สวัสดี ครับ" },
  { "rock 'n' roll", "rock 'n' roll" },
  { "numbers keep their separators", "We paid 1,250.50 dollars." },
  { "a leading quote", "\"Hello\" she said" },
  { "only marks", "..." },
  { "marks at the end with nothing after", "Done ( " },
  { "nothing", "" },
  { "tabs and line breaks are spaces", "one\ttwo\nthree" },
  { "an ellipsis standing alone", "Well … maybe" },
}) do case("tokenize: " .. c[1], "tokenize", { text = c[2] }, toks_out(S.tokenize(c[2]))) end

------------------------------------------------------------------ timing

local function align_case(name, text, words, seconds)
  local toks = S.tokenize(text)
  local method = S.align(toks, copy(words), seconds)
  case("align: " .. name, "align", { text = text, words = words, seconds = seconds },
       { method = method, tokens = toks_out(toks) })
end

align_case("tags and punctuation do not stop a match", "Hello, World! It's <b>fine</b>.", timed("hello world it's b fine b"), 3)
align_case("a number read as words is placed between its neighbours", "We paid 1,250 dollars today.",
           timed("we paid one thousand two hundred fifty dollars today"), 4)
align_case("an unrelated list is an estimate", "Something else entirely here now.", timed("hola que tal"), 3)
align_case("no list is an estimate", "No timings at all.", nil, 2)
align_case("an estimate with a tiny clip", "Quick.", nil, 0)
align_case("no tokens", "", timed("hello"), 2)
align_case("a word Boson adds is skipped", "Hello there friend.", timed("hello um there friend"))
align_case("a typed word Boson skipped is filled", "Hello big world today.", timed("hello world today"), 2)
align_case("unmatched at the start is filled backwards", "Um, hello world.", timed("hello world", nil, nil, 1.0), 2)
align_case("unmatched at the end is filled forwards", "Hello world, okay then.", timed("hello world"), 3)
align_case("no room between anchors", "one two three",
           { { word = "one", start = 0.1, ["end"] = 0.5 }, { word = "three", start = 0.5, ["end"] = 0.8 } }, 1)
align_case("a word found inside another is passed over", "the scatter cat", timed("the cat"), 2)
align_case("timings as strings", "Hi there.", { { word = "hi", start = "0.1", ["end"] = "0.3" }, { word = "there", start = "0.35", ["end"] = "0.7" } }, "1")
align_case("a word without timing is ignored", "Hi there you.", { { word = "hi", start = 0.1, ["end"] = 0.3 }, { word = "there" }, { word = "you", start = 0.5, ["end"] = 0.7 } }, 1)
align_case("fewer than half matched is an estimate", "one two three four five", timed("one zzz yyy"), 2)
align_case("Chinese timed per character", "我们今天要调色一段视频。", per_char("我们今天要调色一段视频"), 3)
align_case("Chinese timed per word shares the word", "我们今天要调色一段视频。", timed("我们 今天 要 调色 一段 视频"), 3)
align_case("Japanese timed per character", "こんにちは、世界。", per_char("こんにちは世界"), 2)
align_case("a jump ahead within 48 bytes resyncs",
           "一二三四五六七八九十甲乙丙丁戊己庚辛壬癸",
           timed("一 九 十 甲 乙 丙 丁 戊 己 庚 辛 壬 癸"), 4)
align_case("a jump ahead past 48 bytes is not followed",
           "一二三四五六七八九十甲乙丙丁戊己庚辛壬癸",
           timed("一 壬 二 三 四 五 六 七 八 九 十 甲 乙 丙 丁 戊 己 庚 辛 癸"), 6)
align_case("an English jump past 48 bytes is not followed",
           "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu",
           timed("alpha mu beta gamma delta epsilon zeta eta theta iota kappa lambda"), 4)
align_case("Spanish with accents", "¿Qué tal? Muy bien, gracias.", timed("qué tal muy bien gracias"), 2)
align_case("a tag word in the timings", "<|sfx:laughter|>Haha, great.", timed("haha great"), 1.5)

------------------------------------------------------------------ splitting

local function split_case(name, text, mode, words, seconds)
  local toks = S.tokenize(S.display_text(text))
  S.align(toks, copy(words), seconds)
  case(("split (%s): %s"):format(mode, name), "split", { text = text, mode = mode, words = words, seconds = seconds },
       cues_out(S.split(toks, mode)))
end

for _, mode in ipairs(S.MODES) do
  split_case("a long first Chinese word is not broken", "中华人民共和国国务院总理今天发表讲话了。", mode,
             timed("中华人民共和国国务院总理 今天 发表 讲话 了"), 4)
  split_case("a long English sentence", LONG, mode, nil, 12)
  split_case("a long sentence, then a short one", LONG2, mode, nil, 10)
  split_case("timed from Boson's words", LONG2, mode,
             timed("when we started this project nobody on the team believed a four person studio could ship a feature film in under a year but here we are"), 10)
  split_case("a pause in the voice is a place to break", "Nobody on the team believed a small studio could ship this feature film in a year.", mode,
             timed("nobody on the team believed a small | studio could ship this feature film in a year"), 6)
  split_case("a short breath (0.27 s) is a place to break too", "I think we should all go down to the beach together tomorrow.", mode,
             timed("i think we should all go down to the beach ~ together tomorrow"), 4)
  split_case("slow speech is cut before 7 seconds", "We waited for hours and nobody came back.", mode,
             timed("we waited for hours and nobody came back", 1.5, 0.1), 14)
  split_case("slow speech with natural breaks", "We will now read the list of every name on the wall, slowly and with care for each one.", mode,
             timed("we will now read the list of every name on the wall slowly and with care for each one", 1.4, 0.1), 30)
  split_case("two short sentences", "Yes. I agree.", mode, nil, 2)
  split_case("two Chinese sentences", "你好。我很好。", mode, nil, 2)
  split_case("a long Chinese sentence", ZH, mode, nil, 8)
  split_case("Chinese timed per word", ZH, mode,
             timed("我们 今天 要 调色 一段 完全 用 手机 拍摄 的 日落 延时 视频 效果 真的 让 我 大吃一惊"), 8)
  split_case("Chinese timed per character", ZH, mode, per_char(ZH), 8)
  split_case("Japanese", JA, mode, nil, 5)
  split_case("a long Spanish sentence", ES, mode, nil, 12)
  split_case("Thai", "สวัสดีครับทุกคนวันนี้เราจะมาพูดถึงการตัดต่อวิดีโอด้วยโปรแกรมใหม่ที่น่าสนใจมาก", mode, nil, 6)
  split_case("Korean", "안녕하세요 여러분, 오늘은 새로운 프로그램으로 동영상을 편집하는 방법에 대해 이야기해 보겠습니다.", mode, nil, 6)
  split_case("abbreviations do not end sentences", "Mr. Smith met Dr. Jones at the studio, e.g. for the final mix of the documentary vs. the trailer.", mode, nil, 8)
  split_case("an ellipsis trails on", "Well... I think so, but we should ask the whole team before we decide anything at all. Maybe tomorrow.", mode, nil, 8)
  split_case("tags inside the line", "<|emotion:happy|>Welcome back to the channel! <|sfx:laughter|>Haha, today we are grading a sunset timelapse, shot entirely on the iPhone.", mode, nil, 8)
  split_case("a word wider than a line", "Visit https://example.com/a/very/long/path/that/never/ends/at/all/really today.", mode, nil, 4)
  split_case("a very long sentence pairs its phrases", "When we started this project in the spring, nobody on the team believed that a four-person studio working out of a garage in the east end could ship a feature film in under a year without any outside money, but here we are, and the premiere is next Friday in Toronto at the big theatre on Queen Street.", mode, nil, 20)
  split_case("no closing stop", "and then we went home without a word to anyone about what we had seen that night", mode, nil, 5)
  split_case("Hindi and Arabic stops", "नमस्ते। आप कैसे हैं? كيف حالك؟ أنا بخير.", mode, nil, 4)
  split_case("nothing", "", mode, nil, 1)
end
split_case("an unknown mode splits short", "Welcome back to the channel! Today we're grading a sunset timelapse, shot entirely on the iPhone.", "other", nil, 6)

------------------------------------------------------------------ takes

local TAKE = { text = "Hello there, friend.", seconds = 2.4, pause = 0.4,
               words = { { word = "Hello", start = 0.1, ["end"] = 0.4 }, { word = "there", start = 0.45, ["end"] = 0.8 },
                         { word = "friend", start = 1.0, ["end"] = 1.6 } } }

local function take_case(name, take, mode)
  local cues, method = S.for_take(copy(take), mode)
  case(("for_take (%s): %s"):format(tostring(mode), name), "for_take", { take = take, mode = mode },
       { cues = cues_out(cues), method = method })
end

take_case("a take with timings is timed from them", TAKE, "short")
take_case("no word timings, no subtitles", { text = "Hello there, friend.", seconds = 2, pause = 0.4 }, "short")
take_case("an empty list, no subtitles", { text = "Hello there, friend.", seconds = 2, words = {} }, "short")
take_case("timings that do not match give none", { text = "Hello there, friend.", seconds = 2, words = { { word = "bonjour", start = 0, ["end"] = 1 } } }, "short")
take_case("tags and a sound effect", { text = "<|sfx:laughter|>Haha, that was great. <|emotion:happy|>Really great!", seconds = 3, pause = 0.2,
                                       words = timed("haha that was great really great") }, "short")
take_case("a long take in sentences", { text = LONG2, seconds = 9, words = timed("when we started this project nobody on the team believed a four person studio could ship a feature film in under a year but here we are") }, "sentence")
take_case("a Chinese take", { text = ZH, seconds = "4.5", pause = "0.3", words = timed("我们 今天 要 调色 一段 完全 用 手机 拍摄 的 日落 延时 视频 效果 真的 让 我 大吃一惊", 0.18, 0.02) }, "short")
take_case("text with nothing to show", { text = "<|emotion:joy|>", seconds = 1, words = timed("hi") }, "short")

for _, c in ipairs({
  { "a long line wraps onto two balanced lines", "A line in a language Boson cannot time, long enough to need two lines here.", 4.2 },
  { "a short line is one line", "Hello there.", 1.5 },
  { "nothing to show", "<|emotion:joy|>", 2 },
  { "a long Chinese line", ZH, 6 },
  { "three lines", LONG, 12 },
  { "no length is a tenth of a second", "Hello.", nil },
  { "a length as a string", "Hello.", "2.5" },
}) do case("whole: " .. c[1], "whole", { text = c[2], seconds = c[3] }, S.whole(c[2], c[3])) end

------------------------------------------------------------------ frames

local function frames_case(name, cues, fps)
  case("frames: " .. name, "frames", { cues = cues, fps = fps }, S.frames(copy(cues), fps))
end

local BASIC = {
  { start = 0.08, finish = 1.2, text = "One" },
  { start = 1.35, finish = 1.6, text = "Two" },
  { start = 4.0, finish = 5.0, text = "Three", bound = 5.2 },
}
for _, fps in ipairs({ 24, 25, 29.97, 30, 60, 23.976 }) do frames_case("three subtitles at " .. fps .. " fps", BASIC, fps) end
frames_case("no rate is 24 fps", BASIC, nil)
frames_case("a rate as a string", BASIC, "30")
frames_case("subtitles never overlap", { { start = 1.0, finish = 1.1, text = "a" }, { start = 1.05, finish = 2, text = "b" } }, 25)
frames_case("a 1.2 s pause leaves 0.7 s after the lag — filled", { { start = 0, finish = 1.0, text = "a" }, { start = 2.2, finish = 3, text = "b" } }, 24)
frames_case("a 1.4 s pause leaves 0.9 s — kept", { { start = 0, finish = 1.0, text = "a" }, { start = 2.4, finish = 3, text = "b" } }, 24)
frames_case("the last never runs past its clip", { { start = 0, finish = 2.0, text = "a", bound = 2.2 } }, 24)
frames_case("a clip shorter than the minimum", { { start = 0, finish = 0.2, text = "a", bound = 0.3 } }, 24)
frames_case("a bound at zero still bounds", { { start = 0, finish = 0.5, text = "a", bound = 0 } }, 24)
frames_case("a bound inside the voice", { { start = 0, finish = 2.0, text = "a", bound = 1.5 } }, 25)
frames_case("a short one borrows from the gap before", {
  { start = 0, finish = 1.0, text = "a" }, { start = 3.0, finish = 3.1, text = "b" }, { start = 3.3, finish = 4, text = "c" },
}, 24)
frames_case("crowded short subtitles", {
  { start = 0, finish = 0.1, text = "a" }, { start = 0.15, finish = 0.25, text = "b" },
  { start = 0.3, finish = 0.4, text = "c" }, { start = 0.45, finish = 0.55, text = "d" },
}, 30)
frames_case("a voice of no length still gets a frame", { { start = 1.0, finish = 1.0, text = "a" } }, 60)
frames_case("two clips, each bounded", {
  { start = 0.1, finish = 1.9, text = "a", bound = 2.0 }, { start = 2.05, finish = 3.5, text = "b", bound = 3.6 },
}, 25)
frames_case("nothing", {}, 24)

------------------------------------------------------------------ srt

local function srt_case(name, cues, fps, lead)
  local text, origin = S.srt(copy(cues), fps, lead)
  case("srt: " .. name, "srt", { cues = cues, fps = fps, lead = lead }, { text = text, origin = origin })
end

local FRAMED = { { from = 1, to = 31, text = "One" }, { from = 31, to = 58, text = "Two\nlines" }, { from = 96, to = 124, text = "Three" } }
srt_case("starts at its first subtitle", FRAMED, 24)
srt_case("with a lead-in", FRAMED, 24, 48)
srt_case("at 29.97 fps", FRAMED, 29.97, 10)
srt_case("past an hour", { { from = 90000, to = 90050, text = "Late" }, { from = 180000, to = 180025, text = "Later" } }, 25, 90000)
srt_case("Chinese text", { { from = 0, to = 20, text = "你好。" } }, 30)
srt_case("nothing", {}, 24)

------------------------------------------------------------------ placing takes (ui.lua's path)

--- What ui.lua does with takes placed at `starts` … `ends` (frames): split or
-- whole, offset, bounded by the clip, framed, written with a lead-in.
local function place_case(name, takes, starts, ends, fps, mode, lead)
  local origin = starts[1]
  local all = {}
  for i, take in ipairs(copy(takes)) do
    local cues, method = S.for_take(take, mode)
    if method ~= "words" then cues = S.whole(take.text, (ends[i] - starts[i]) / fps) end
    local offset = (starts[i] - origin) / fps
    for _, cue in ipairs(cues) do
      cue.start, cue.finish = cue.start + offset, cue.finish + offset
      cue.bound = (ends[i] - origin) / fps
      all[#all + 1] = cue
    end
  end
  S.frames(all, fps)
  local text, first = S.srt(all, fps, lead)
  case("place: " .. name, "place", { takes = takes, starts = starts, ends = ends, fps = fps, mode = mode, lead = lead },
       { cues = cues_out(all), srt = text, origin = first })
end

place_case("two timed takes", {
  { text = "Welcome back to the channel!", seconds = 1.8, words = timed("welcome back to the channel") },
  { text = "Today we're grading a sunset timelapse, shot entirely on the iPhone.", seconds = 3.6,
    words = timed("today we're grading a sunset timelapse shot entirely on the iphone") },
}, { 100, 144 }, { 143, 230 }, 24, "short", 12)
place_case("a timed take and one shown whole", {
  { text = "Hello there, friend.", seconds = 2.4, pause = 0.4, words = TAKE.words },
  { text = "这是一段没有时间信息的旁白，所以整句显示。", seconds = 3 },
}, { 0, 60 }, { 60, 135 }, 25, "sentence", 0)
place_case("sentences at 29.97", {
  { text = LONG2, seconds = 9, words = timed("when we started this project nobody on the team believed a four person studio could ship a feature film in under a year but here we are") },
}, { 300 }, { 570 }, 29.97, "sentence", 30)

------------------------------------------------------------------ preview

for _, c in ipairs({
  { LONG, "short" }, { LONG, "sentence" },
  { "Welcome back to the channel! Today we're grading a sunset timelapse, shot entirely on the iPhone.", "sentence" },
  { "Nobody on the team believed a small studio could ship a feature film.", "sentence" },
  { LONG2, "short" }, { LONG2, "sentence" },
  { "Hello there, friend.", "short" },
  { "太好了！我们走吧。", "short" },
  { ZH, "short" }, { ZH, "sentence" },
  { JA, "short" },
  { ES, "sentence" },
}) do
  case(("preview (%s): %s"):format(c[2], U.clip_words(c[1], 4)), "preview",
       { text = c[1], mode = c[2] }, S.preview(c[1], c[2]))
end

return {
  about = "Subtitles from subtitles.lua. fn is the Lua function, or: align/split tokenize input.text "
    .. "(split through display_text) and align it to input.words over input.seconds first; char_width maps "
    .. "over cps; for_take returns {cues, method}; srt returns {text, origin}; place is ui.lua's path "
    .. "(for_take or whole per take, offset, bound, frames, srt). Token indices (first, last, word) count from 0.",
  source = "src/higgs/subtitles.lua",
  cases = cases,
}
