--- Higgs VoiceOver test suite.
--
-- Runs against the built bundle with Resolve's own interpreter — no toolchain:
--   "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript" -l lua tests/run.lua
--
-- Tests live outside src/ so they are never shipped inside the installed script.
-- Anything requiring a running Resolve belongs in tests/resolve.lua instead;
-- this file must pass with Resolve closed.

-- Load the bundle for its modules without launching the window.
_G.HIGGS_VO_NO_AUTORUN = true
dofile("Higgs VoiceOver.lua")

local U = require("higgs.util")
local P = require("higgs.platform")

local passed, failed = 0, 0
local group = ""

local function describe(name) group = name; print("\n" .. name) end

local function check(label, cond, detail)
  if cond then
    passed = passed + 1
    print("  ok    " .. label)
  else
    failed = failed + 1
    print("  FAIL  " .. label .. (detail and ("  -> " .. tostring(detail)) or ""))
  end
end

local function eq(label, got, want)
  check(label, got == want, string.format("got %q, want %q", tostring(got), tostring(want)))
end

--------------------------------------------------------------------------- json

describe("util.json")
local rt = U.json.decode(U.json.encode({
  a = 1, b = 'quote" and \\', c = true, d = { "x", "y" }, e = { f = 2.5 },
}))
check("round-trips numbers, bools, nesting", rt.a == 1 and rt.c == true and rt.d[2] == "y" and rt.e.f == 2.5)
eq("round-trips escaped strings", rt.b, 'quote" and \\')
check("returns nil on malformed input", (U.json.decode("{bad")) == nil)
eq("decodes nested error shape", U.json.decode('{"error":{"message":"boom"}}').error.message, "boom")
check("decodes empty array", #U.json.decode('{"data":[]}').data == 0)
eq("escapes control characters", U.json.encode("a\nb"), '"a\\nb"')

--------------------------------------------------------------------------- base64

describe("util.b64_encode")
eq("3-byte group", U.b64_encode("Man"), "TWFu")
eq("2-byte remainder pads once", U.b64_encode("Ma"), "TWE=")
eq("1-byte remainder pads twice", U.b64_encode("M"), "TQ==")
eq("empty input", U.b64_encode(""), "")
eq("binary bytes", U.b64_encode(string.char(0, 255, 128)), "AP+A")

--------------------------------------------------------------------------- text

describe("util segmentation")
-- Line breaks are the only delimiter: the TTS service handles long input, so
-- nothing here guesses at sentence boundaries.
local lines = U.split_lines("First line.\nSecond line.\n\n  \n\nThird line.")
eq("splits on line breaks", #lines, 3)
eq("trims each line", lines[2], "Second line.")
eq("blank lines collapse", lines[3], "Third line.")
eq("no line breaks means one segment", #U.split_lines("One long block of narration with no breaks at all."), 1)
eq("empty input yields nothing", #U.split_lines("   \n\n  "), 0)
eq("a single line survives", U.split_lines("Just one line.")[1], "Just one line.")

local sents = U.split_sentences("One sentence here. And a second! A third? Trailing bit")
eq("manual sentence split still available", #sents, 4)
eq("keeps terminal punctuation", sents[2], "And a second!")
eq("keeps an unterminated tail", sents[4], "Trailing bit")

describe("util text helpers")
eq("strips inline tags", U.strip_tags("<|emotion:awe|> Hello <|prosody:pause|> world"), " Hello  world")
eq("word count ignores tags", U.word_count("<|emotion:awe|> Hello there world"), 3)
eq("duration formats as m:ss.t", U.format_duration(7.2), "0:07.2")
eq("duration crosses a minute", U.format_duration(125.9), "2:05.9")
eq("duration of zero", U.format_duration(0), "0:00.0")
eq("sanitize collapses whitespace runs", U.sanitize("Alex  —  narration/v2!"), "Alex_—_narrationv2!")
eq("sanitize keeps hyphen and underscore", U.sanitize("take-01_final"), "take-01_final")
eq("sanitize keeps characters a filesystem accepts", U.sanitize("旁白 第一段"), "旁白_第一段")
eq("sanitize removes only what a filesystem refuses",
  U.sanitize('a<b>c:d"e/f\\g|h?i*j'), "abcdefghij")
eq("sanitize strips a trailing dot, which some filesystems refuse", U.sanitize("take."), "take")
check("sanitize cuts on a character boundary, never mid-codepoint", (function()
  local long = string.rep("旁", 30)          -- 90 bytes, 30 characters
  local cut = U.sanitize(long)
  return #cut <= 48 and U.utf8_len(cut) * 3 == #cut
end)())

describe("clip names in any script")
eq("English takes words", U.clip_words("Welcome back to the channel today", 4), "Welcome_back_to_the")
eq("Chinese has no words, so each character is half of one",
  U.clip_words("今天我们来聊聊调色这件事情", 4), "今天我们来聊聊调")
eq("and the marks between them are skipped",
  U.clip_words("你好，世界！这是一段旁白。", 4), "你好世界这是一段")
eq("Japanese kana the same way", U.clip_words("こんにちは、ナレーションです", 3), "こんにちはナ")
eq("a mixed line spends one budget across both",
  U.clip_words("iPhone 拍摄的日落真的很美", 4), "iPhone拍摄的日落真")
eq("Cyrillic is a spaced script and keeps its words",
  U.clip_words("Привет, это закадровый голос", 4), "Привет_это_закадровый_голос")
eq("nothing usable falls back", U.clip_words("...", 4), "take")
check("ids are unique", U.new_id() ~= U.new_id())
eq("trim strips both ends", U.trim("  padded \n"), "padded")

--------------------------------------------------------------------------- platform

describe("platform contract")
check("a backend loaded", P.name ~= nil)
check("this release runs on macOS", P.is_mac and P.name == "macos")
eq("join uses the host separator", P.join("a", "b", "c"), "a" .. P.sep .. "b" .. P.sep .. "c")
eq("join collapses duplicate separators", P.join("/tmp/", "/higgs/", "x.wav"), "/tmp" .. P.sep .. "higgs" .. P.sep .. "x.wav")
eq("basename", P.basename("/a/b/take_01.wav"), "take_01.wav")
eq("dirname", P.dirname("/a/b/take_01.wav"), "/a/b")
check("config_dir is absolute", P.config_dir():match("^/") ~= nil)
check("wav is previewable on every platform", P.can_play("a.wav"))
check("can_play is case-insensitive", P.can_play("A.WAV"))
check("can_play rejects unknown extensions", not P.can_play("a.xyz"))

describe("platform_macos (cross-checked from any host)")
local Mac = require("higgs.platform_macos")
eq("quotes POSIX style", Mac.quote("it's"), [['it'\''s']])
check("playback uses afplay", Mac.audio_play_cmd("/t/x.wav"):find("afplay", 1, true) ~= nil)
check("recording needs nothing installed", Mac.can_record())
check("so there is nothing to explain", Mac.record_unavailable() == nil)

describe("macOS recorder — the script and what it reports")
local RM = require("higgs.record_macos")
local script = RM.script_text()
check("the sample format is substituted in, not written twice",
  script:find("$(24000)", 1, true) ~= nil and script:find("SAMPLE_RATE", 1, true) == nil)
check("it reaches AVAudioRecorder", script:find("AVAudioRecorder", 1, true) ~= nil)
check("it stops cleanly rather than being killed", script:find("rec.stop", 1, true) ~= nil)
check("a status line becomes seconds and a 0-1 peak",
  (function() local r = RM.parse_status("4.250 -6.0") return r and math.abs(r.seconds - 4.25) < 0.001
     and math.abs(r.peak - 0.501) < 0.01 end)())
eq("silence reads as zero, not as a tiny number", RM.parse_status("1.000 -160.0").peak, 0)
check("full scale reads as one", RM.parse_status("1.000 0.0").peak == 1)
check("the end of a take is reported", RM.parse_status("done").done == true)
check("a refused microphone is a failure, not a take",
  RM.parse_status("fail the microphone was refused").failed == true)
eq("and it carries the reason", RM.parse_status("fail the microphone was refused").message,
  "the microphone was refused")
check("the count-in is reported by the recorder, not timed by the interface",
  math.abs(RM.parse_status("wait 1.75").waiting - 1.75) < 0.001)
check("a take counting in has no elapsed time yet", RM.parse_status("wait 1.75").seconds == nil)
check("capture is scheduled against the audio clock, not started and trimmed",
  script:find("recordAtTimeForDuration", 1, true) ~= nil and
  script:find("deviceCurrentTime", 1, true) ~= nil)
check("nothing written yet is nil, not zero", RM.parse_status(nil) == nil)
check("a half-written line is nil, not a wrong answer", RM.parse_status("4.2") == nil)

------------------------------------------------------------------------- config

describe("config — where clips are written")
local Config = require("higgs.config")
check("the default folder is the user's own video folder",
  Config.default_output_dir():find("Higgs VoiceOver", 1, true) ~= nil and
  Config.default_output_dir():find(P.config_dir(), 1, true) == nil)
eq("a project gets its own subfolder",
  Config.project_output_dir({ output_dir = "/base" }, "Sunset Grade"),
  P.join("/base", "Sunset_Grade"))
eq("no project open means the base folder",
  Config.project_output_dir({ output_dir = "/base" }, ""), "/base")
eq("a name that sanitises away means the base folder",
  Config.project_output_dir({ output_dir = "/base" }, "///"), "/base")
eq("an empty setting falls back to the default",
  Config.project_output_dir({ output_dir = "" }, ""), Config.default_output_dir())

describe("update: which release file is the script")
do
  check("the release name with app and OS", Config.is_script_asset("Higgs-VoiceOver-1.0.0-DaVinci-Resolve-macOS.lua"))
  check("as GitHub may rewrite it", Config.is_script_asset("Higgs.VoiceOver.1.0.0.DaVinci.Resolve.macOS.lua"))
  check("the plain name of 0.1.0", Config.is_script_asset("Higgs-VoiceOver.lua"))
  check("the old short name", Config.is_script_asset("Higgs VO.lua"))
  check("not the installer", not Config.is_script_asset("Higgs-VoiceOver-1.0.0-DaVinci-Resolve-macOS.pkg"))
  check("not a Windows build", not Config.is_script_asset("Higgs-VoiceOver-1.1.0-DaVinci-Resolve-Windows.lua"))
  check("not another editor's", not Config.is_script_asset("Higgs-VoiceOver-1.1.0-Premiere-Pro-macOS.lua"))
end

describe("config — migration")
local moved = Config.migrate({ schema = 2, output_dir = Config.takes_dir() })
eq("a config still on the old default folder is moved", moved.output_dir, Config.default_output_dir())
eq("and is stamped with the current schema", moved.schema, Config.SCHEMA)
local chosen = Config.migrate({ schema = 2, output_dir = "/Volumes/Work/VO" })
eq("a folder the user picked is left alone", chosen.output_dir, "/Volumes/Work/VO")
eq("the old 400 ms default stays 400",
  Config.migrate({ schema = 1, pause_ms = 400 }).pause_ms, 400)
eq("the 240 ms default of schema 2–3 follows back to 400",
  Config.migrate({ schema = 3, pause_ms = 240 }).pause_ms, 400)
eq("a pause the user chose is kept",
  Config.migrate({ schema = 1, pause_ms = 900 }).pause_ms, 900)
eq("Place on timeline, off by the old default, turns on",
  Config.migrate({ schema = 4, auto_place = false }).auto_place, true)
eq("but stays off when turned off since",
  Config.migrate({ schema = 5, auto_place = false }).auto_place, false)
local newer = Config.migrate({ schema = 99, output_dir = Config.takes_dir() })
eq("a newer schema is left untouched", newer.output_dir, Config.takes_dir())

describe("clip names")
eq("first four words joined", U.clip_words("Welcome back to the channel! Today we grade.", 4), "Welcome_back_to_the")
eq("tags and punctuation ignored", U.clip_words("<|emotion:elation|> It's here, now — really.", 4), "Its_here_now_really")
eq("short text keeps what it has", U.clip_words("Hi there", 4), "Hi_there")
eq("empty text falls back", U.clip_words("   ", 4), "take")


describe("wav silence")
do
  local rate, n = 24000, 24000   -- 1.0 s mono 16-bit
  local function u32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
  local function u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
  local data = string.rep("\1\0", n)
  local fmt = u16(1) .. u16(1) .. u32(rate) .. u32(rate * 2) .. u16(2) .. u16(16)
  local wav = "RIFF" .. u32(36 + #data) .. "WAVE" .. "fmt " .. u32(16) .. fmt .. "data" .. u32(#data) .. data
  local path = os.tmpname() .. ".wav"
  U.write_file(path, wav)
  check("appends 0.4 s", U.wav_append_silence(path, 0.4))
  local secs = U.wav_seconds(path)
  check("length is 1.4 s", secs and math.abs(secs - 1.4) < 0.001, secs)
  local back = U.read_file(path)
  check("original samples intact", back:sub(45, 44 + #data) == data)
  check("padding is silence", back:sub(-2) == "\0\0")
  os.remove(path)
end


describe("recorder — judging a take")
local Rec = require("higgs.recorder")
local function take(sec, rms, hot) return { seconds = sec, peak = math.min(1, rms * 8), rms = rms, hot_ratio = hot } end
-- A transcript the length a natural read of `sec` seconds would produce, so
-- these cases are not silently decided by the pace rule.
local function paced(sec) return string.rep("word ", math.floor(sec * 2.8)) end
local function judge(t, script) return Rec.judge(t, script or paced(t.seconds)) end

check("under Boson's floor is refused", not judge(take(2.4, 0.1)).ok)
check("and the message says how short it was", judge(take(2.4, 0.1)).message:find("2.4", 1, true) ~= nil)
check("exactly at the floor is not refused", judge(take(3.0, 0.1)).ok)
local silent = judge({ seconds = 10, peak = 0, rms = 0, hot_ratio = 0 })
check("silence is refused", not silent.ok)
check("silence is flagged for the caller to explain", silent.silent == true)
check("too quiet is refused", not judge(take(10, 0.01)).ok)
check("a quiet take is judged on its average, not one loud knock",
  not judge({ seconds = 10, peak = 0.9, rms = 0.005, hot_ratio = 0 }).ok)
check("clipping warns but still sends", judge(take(10, 0.3, 0.05)).ok)
eq("clipping is a warning", judge(take(10, 0.3, 0.05)).kind, "warn")
check("and it is marked, because it is the one warning still shown",
  judge(take(10, 0.3, 0.05)).clipped == true)
check("a pace warning is not", judge(take(10, 0.3, 0), "word word word word word word word word word word "
  .. "word word word word word word word word word word word word word word word word "
  .. "word word word word word word word word word word word word word word word word "
  .. "word word word word word word word word word word").clipped == nil)
eq("an occasional peak is not clipping", judge(take(10, 0.3, 0.001)).kind, "ok")
eq("a good take is good", judge(take(12, 0.2, 0)).kind, "ok")
eq("a usable but short take is a warning", judge(take(4, 0.2, 0)).kind, "warn")

describe("recorder — pace, which only the required transcript makes measurable")
local rushed = Rec.judge(take(10, 0.2, 0), string.rep("word ", 50))    -- 5.0 words/s
eq("fifty words in ten seconds is rushed", rushed.kind, "warn")
check("and it says so", rushed.message:find("quickly", 1, true) ~= nil)
local laboured = Rec.judge(take(20, 0.2, 0), string.rep("word ", 20))  -- 1.0 words/s
eq("twenty words in twenty seconds is laboured", laboured.kind, "warn")
check("and it says so", laboured.message:find("slowly", 1, true) ~= nil)
eq("fifty-six words in twenty seconds is natural",
  Rec.judge(take(20, 0.2, 0), string.rep("word ", 56)).kind, "ok")
eq("exactly at the fast edge is still natural",
  Rec.judge(take(10, 0.2, 0), string.rep("word ", 40)).kind, "ok")
eq("no transcript means no pace verdict", Rec.judge(take(20, 0.2, 0), "").kind, "ok")
eq("word_count ignores runs of space", Rec.word_count("  one   two\nthree "), 3)
eq("word_count of nothing is zero", Rec.word_count(nil), 0)

describe("recorder — the passages, which are now opt-in")
check("there is more than one, because identical audio is the same voice", #Rec.PASSAGES > 1)
for i, passage in ipairs(Rec.PASSAGES) do
  local words = Rec.word_count(passage)
  check(("passage %d reads in the target range at a natural pace"):format(i),
    words / 2.8 > Rec.GOOD_MIN and words / 2.8 < Rec.GOOD_MAX, words .. " words")
end

describe("recorder — coaching while a take runs")
check("below the floor it says so", Rec.coach(1.5, 30):find("minimum", 1, true) ~= nil)
eq("early on, it names the target", Rec.coach(4, 30), "Around 20 seconds is ideal.")
check("near the target it stops nagging", Rec.coach(19, 30):find("enough", 1, true) ~= nil)
check("near the limit it warns about the cut-off", Rec.coach(26, 30):find("stops at 30", 1, true) ~= nil)
check("the limit is not hard-coded in the message", Rec.coach(16, 20):find("stops at 20", 1, true) ~= nil)

describe("raw pcm capture")
do
  local function s16(v) v = v % 65536 return string.char(v % 256, math.floor(v / 256) % 256) end
  local path = os.tmpname() .. ".pcm"
  -- 0.5 s at 24 kHz: quiet throughout, with one loud sample near the end so
  -- the tail window is the only place a peak meter could find it.
  local parts = {}
  for i = 1, 12000 do parts[#parts + 1] = s16(100) end
  parts[11900] = s16(16384)
  U.write_file(path, table.concat(parts))

  local secs = U.pcm_seconds(path)
  check("length comes from the file size alone", math.abs(secs - 0.5) < 0.0001, secs)
  local peak = U.pcm_peak(path, 0.1)
  check("the tail window finds the loud sample", math.abs(peak - 0.5) < 0.001, peak)
  check("a short window misses it", U.pcm_peak(path, 0.002) < 0.01)
  check("a missing file is silence, not an error", U.pcm_peak("/no/such.pcm", 0.1) == 0)
  eq("a missing file has no length", U.pcm_seconds("/no/such.pcm"), 0)

  local stats = U.pcm_stats(path)
  check("whole-file stats find the same peak", math.abs(stats.peak - 0.5) < 0.001, stats.peak)
  check("and the same length", math.abs(stats.seconds - 0.5) < 0.0001, stats.seconds)
  check("one loud sample in 12000 is not clipping", stats.hot_ratio < 0.001, stats.hot_ratio)
  check("rms is the average, well under that one peak",
    stats.rms > 0.002 and stats.rms < 0.01, stats.rms)
  local loud = os.tmpname() .. ".pcm"
  U.write_file(loud, string.rep(s16(32700), 12000))
  local loud_stats = U.pcm_stats(loud)
  check("a take at the ceiling reports clipping", loud_stats.hot_ratio > 0.99, loud_stats.hot_ratio)
  os.remove(loud)
  eq("a missing file has no stats", U.pcm_stats("/no/such.pcm").seconds, 0)

  local wav = os.tmpname() .. ".wav"
  local dur = U.pcm_to_wav(path, wav)
  check("wrapping reports the duration", dur and math.abs(dur - 0.5) < 0.0001, dur)
  local back = U.wav_seconds(wav)
  check("and the header agrees", back and math.abs(back - 0.5) < 0.0001, back)
  eq("the samples survive byte for byte", U.read_file(wav):sub(45), U.read_file(path))

  -- The count-in is thrown away by starting the wrap part-way in.
  local trimmed = os.tmpname() .. ".wav"
  local short = U.pcm_to_wav(path, trimmed, 24000 * 2 * 0.2)
  check("skipping the count-in shortens the take", short and math.abs(short - 0.3) < 0.0001, short)
  eq("and drops exactly those bytes", U.read_file(trimmed):sub(45), U.read_file(path):sub(9601))
  os.remove(trimmed)

  -- A capture killed mid-sample leaves an odd byte count; it must still wrap.
  local odd = os.tmpname() .. ".pcm"
  U.write_file(odd, table.concat(parts) .. "\7")
  local odd_wav = os.tmpname() .. ".wav"
  local odd_dur = U.pcm_to_wav(odd, odd_wav)
  check("an odd trailing byte is dropped, not written",
    odd_dur and math.abs(odd_dur - 0.5) < 0.0001, odd_dur)
  check("nothing is produced from an empty capture",
    U.pcm_to_wav("/no/such.pcm", odd_wav) == nil)
  for _, f in ipairs({ path, wav, odd, odd_wav }) do os.remove(f) end
end


describe("mono to stereo")
do
  local rate, n = 24000, 12000   -- 0.5 s mono 16-bit, rising sample values
  local function u32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
  local function u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
  local parts = {}
  for i = 0, n - 1 do parts[#parts + 1] = u16(i % 65536) end
  local data = table.concat(parts)
  local fmt = u16(1) .. u16(1) .. u32(rate) .. u32(rate * 2) .. u16(2) .. u16(16)
  local path = os.tmpname() .. ".wav"
  U.write_file(path, "RIFF" .. u32(36 + #data) .. "WAVE" .. "fmt " .. u32(16) .. fmt .. "data" .. u32(#data) .. data)

  check("converts", U.wav_to_stereo(path))
  local out = U.read_file(path)
  eq("two channels", out:byte(23) + out:byte(24) * 256, 2)
  eq("byte rate doubled", out:byte(29) + out:byte(30) * 256 + out:byte(31) * 65536 + out:byte(32) * 16777216, rate * 4)
  eq("block align doubled", out:byte(33) + out:byte(34) * 256, 4)
  eq("still 16 bit", out:byte(35) + out:byte(36) * 256, 16)
  eq("data doubled", out:byte(41) + out:byte(42) * 256 + out:byte(43) * 65536 + out:byte(44) * 16777216, #data * 2)
  local l1 = out:byte(45) + out:byte(46) * 256
  local r1 = out:byte(47) + out:byte(48) * 256
  local l2 = out:byte(49) + out:byte(50) * 256
  check("both channels carry the same sample", l1 == r1 and l1 == 0, l1 .. "/" .. r1)
  eq("next frame is the next sample", l2, 1)
  eq("duration unchanged", math.floor(U.wav_seconds(path) * 1000 + 0.5), 500)
  check("already stereo is left alone", U.wav_to_stereo(path) == false)
  os.remove(path)
end


describe("sentence termination")
local Tags = require("higgs.tags")
eq("adds a full stop to an unpunctuated line", Tags.terminate("Dragging works"), "Dragging works.")
eq("leaves a full stop alone", Tags.terminate("Already done."), "Already done.")
eq("leaves other punctuation alone", Tags.terminate("Really?"), "Really?")
eq("leaves a trailing tag alone", Tags.terminate("Hi <|sfx:laughter|>"), "Hi <|sfx:laughter|>")
eq("leaves an empty line alone", Tags.terminate(""), "")
eq("uses a CJK full stop for CJK", Tags.terminate("\228\189\160\229\165\189"), "\228\189\160\229\165\189。")
eq("leaves CJK punctuation alone", Tags.terminate("\228\189\160\229\165\189。"), "\228\189\160\229\165\189。")
do
  local at_limit = string.rep("a", Tags.MAX_CHARS)
  eq("never pushes a full line over the ceiling", Tags.terminate(at_limit), at_limit)
end
eq("compose leaves the text as typed", Tags.compose("Dragging works", nil), "Dragging works")
eq("an accented word still gets a stop", Tags.terminate("caf\195\169"), "caf\195\169.")
eq("an ellipsis is left alone", Tags.terminate("wait\226\128\166"), "wait\226\128\166")


describe("placing a tag")
eq("goes in at the point", Tags.place_tag("Hello ", "world", "emotion:elation", false),
   "Hello <|emotion:elation|> world")
eq("replaces what was selected", Tags.place_tag("Hello ", " world", "emotion:elation", false),
   "Hello <|emotion:elation|>  world")
eq("a line-start tag moves to the front of its line",
   Tags.place_tag("one\ntwo three", " four", "prosody:speed_fast", true),
   "one\n<|prosody:speed_fast|> two three four")
eq("only its own line, not every line",
   Tags.place_tag("one\ntwo\nthree", "", "prosody:speed_fast", true),
   "one\ntwo\n<|prosody:speed_fast|> three")
eq("replaces an existing tag on the same axis",
   Tags.place_tag("<|prosody:speed_slow|> two", " three", "prosody:speed_fast", true),
   "<|prosody:speed_fast|> two three")
eq("leaves a different axis alone",
   Tags.place_tag("<|prosody:pitch_low|> two", "", "prosody:speed_fast", true),
   "<|prosody:speed_fast|> <|prosody:pitch_low|> two")
eq("the first line has no newline to find",
   Tags.place_tag("two three", "", "prosody:pitch_high", true),
   "<|prosody:pitch_high|> two three")
do
  local out, caret = Tags.place_tag("Hello ", "world", "prosody:pause", false)
  eq("the caret goes right after an inserted tag and its space", out:sub(1, caret), "Hello <|prosody:pause|> ")
  out, caret = Tags.place_tag("That's funny. ", "Anyway.", "sfx:laughter", false)
  eq("a sound effect brings its sound, as Boson advises", out, "That's funny. <|sfx:laughter|>Haha Anyway.")
  eq("and the caret goes after the sound", out:sub(1, caret), "That's funny. <|sfx:laughter|>Haha ")
  out = Tags.place_tag("", " haha, sure.", "sfx:laughter", false)
  eq("a sound already typed is not added twice", out, "<|sfx:laughter|>haha, sure.")
  eq("crying has no sound word", (Tags.place_tag("", "I... I'm sorry.", "sfx:crying", false)), "<|sfx:crying|>I... I'm sorry.")
  for _, s in ipairs(Tags.SFX) do
    check("sfx " .. s .. " has Boson's word or is crying", Tags.SFX_WORDS[s] ~= nil or s == "crying")
  end
  eq("emotion leads the line", (Tags.place_tag("one\ntwo ", "three", "emotion:elation", true)), "one\n<|emotion:elation|> two three")
  eq("a new emotion replaces the old one", (Tags.place_tag("<|emotion:sadness|> two ", "three", "emotion:elation", true)), "<|emotion:elation|> two three")
  eq("and leaves other leading tags", (Tags.place_tag("<|prosody:speed_fast|> <|emotion:sadness|> go", "", "emotion:elation", true)),
     "<|emotion:elation|> <|prosody:speed_fast|> go")
  eq("style replaces style, not emotion", (Tags.place_tag("<|emotion:awe|> <|style:shouting|> hey", "", "style:whispering", true)),
     "<|style:whispering|> <|emotion:awe|> hey")
  eq("a tag mid-line is left where it is", (Tags.place_tag("go <|sfx:cough|>Ahem on", "", "emotion:awe", true)),
     "<|emotion:awe|> go <|sfx:cough|>Ahem on")
  out, caret = Tags.place_tag("Hello ", "world", "sfx:cough", false)
  out, caret = Tags.place_tag("one\ntwo th", "ree", "prosody:speed_fast", true)
  eq("a line-start tag leaves the caret where it was in the text", out:sub(caret + 1), "ree")
  out, caret = Tags.place_tag("one\n", "<|prosody:speed_slow|> two", "prosody:speed_fast", true)
  eq("and never inside the new tag when the old one was after the caret", out:sub(1, caret), "one\n<|prosody:speed_fast|> ")
end


describe("voice names from the list endpoint")
do
  local A = require("higgs.api")
  eq("the description is the name", A.voice_label({ voice = "voice_ab", description = "Alex — narration" }), "Alex — narration")
  eq("a local name survives a blank description", A.voice_label({ voice = "voice_ab" }, "Alex"), "Alex")
  eq("a local name that is only the id does not", A.voice_label({ voice = "voice_ab", created_at = "2026-09-17T01:02:03Z" }, "voice_ab"), "Cloned voice · Sep 17, 2026")
  eq("never the raw id", A.voice_label({ voice = "voice_ab" }), "Cloned voice")
end

describe("log: what can leave the machine")
do
  local Log = require("higgs.log")
  eq("user content is marked", Log.q("My Project"), "‹My Project›")
  eq("marks inside content cannot close it early", Log.q("a›b"), "‹ab›")
  eq("marked content is removed", Log.redact("project=‹Secret Film› tracks=2"), "project=‹› tracks=2")
  eq("a name in curly quotes is removed", Log.redact("Deleted “Alex — zh” from your list."), "Deleted “” from your list.")
  eq("a home path loses the user name", Log.redact("folder /Users/alex/Movies/x"), "folder /Users/~/Movies/x")
  eq("CJK inside marks survives until redaction", Log.q("配音"), "‹配音›")
  eq("text around a mark is untouched", Log.redact("a — b ‹c› d"), "a — b ‹› d")
  eq("fields are sorted and quoted", Log.fields({ b = 2, a = "x y" }), 'a="x y" b=2')
  eq("fractions are trimmed", Log.fields({ s = 1.5 }), "s=1.5")
  Log.counts, Log.sums = {}, {}
  Log.metric("t.run", { ms = 100, kind = "x" })
  Log.metric("t.run", { ms = 50 })
  eq("metrics count", Log.counts["t.run"], 2)
  eq("metrics sum numeric fields", Log.sums["t.run.ms"], 150)
  eq("text fields are not summed", Log.sums["t.run.kind"], nil)
  local b = Log.bundle()
  check("the report bundle carries a redacted log", type(b.log) == "string" and not b.log:find("/Users/[^~]"))
end

describe("base64 decode")
do
  eq("3-byte group", U.b64_decode("TWFu"), "Man")
  eq("one pad", U.b64_decode("TWE="), "Ma")
  eq("two pads", U.b64_decode("TQ=="), "M")
  eq("binary round trip", U.b64_decode(U.b64_encode(string.char(0, 255, 128, 7, 9))), string.char(0, 255, 128, 7, 9))
  eq("line breaks are ignored", U.b64_decode("TW\nFu"), "Man")
end

describe("timestamped speech response")
do
  local A = require("higgs.api")
  local raw = '{"audio":"' .. U.b64_encode("RIFFdata") .. '","response_format":"wav","input":"Hi there.",'
           .. '"timestamps":[{"word":"Hi","start":0.08,"end":0.3},{"word":"there","start":0.32,"end":0.7}]}'
  local audio, words = A.unpack_timed(raw)
  eq("audio is decoded", audio, "RIFFdata")
  eq("words come through", words and #words, 2)
  eq("with their times", words and words[2]["end"], 0.7)
  local _, none = A.unpack_timed('{"audio":"' .. U.b64_encode("x") .. '","timestamps":null}')
  eq("no alignment is nil, not empty", none, nil)
  local _, empty = A.unpack_timed('{"audio":"' .. U.b64_encode("x") .. '","timestamps":[]}')
  eq("an empty list is nil too", empty, nil)
  local a2 = A.unpack_timed('{"input":"x","audio":"TW\\/u"}')
  eq("escaped slashes in the audio are undone", a2, U.b64_decode("TW/u"))
  eq("no audio field is nil", (A.unpack_timed('{"error":"x"}')), nil)
end

describe("subtitles — reading the line")
do
  local S = require("higgs.subtitles")
  eq("tags are not shown", S.display_text("<|emotion:joy|> Hello  there <|sfx:laugh|>!"), "Hello there !")
  local t = S.tokenize("“Well,” she said — it's fine.")
  eq("an opening quote rides on its word", t[1].text, "“Well,”")
  eq("a lone dash rides on the word before", t[3].text, "said —")
  eq("apostrophes stay in the word", t[4].text, "it's")
  eq("keys are letters only", t[4].key, "its")
  local z = S.tokenize("我们今天，好吗？")
  eq("Chinese splits into characters", #z, 6)
  eq("punctuation rides on the character", z[4].text, "天，")
  eq("no spaces between characters", z[2].space, false)
  eq("a sentence ends at a full stop", S.ending("today."), "sentence")
  eq("a title is not a sentence end", S.ending("Dr."), nil)
  eq("a comma is a clause", S.ending("well,"), "clause")
  eq("a closing quote after the stop still ends it", S.ending("fine.”"), "sentence")
  eq("an ellipsis trails, it does not end", S.ending("so..."), "clause")
end

describe("subtitles — word timings")
do
  local S = require("higgs.subtitles")
  local function words(list)
    local out, t = {}, 0.1
    for w in list:gmatch("%S+") do out[#out + 1] = { word = w, start = t, ["end"] = t + 0.2 }; t = t + 0.25 end
    return out
  end
  local toks = S.tokenize("Hello, World! It's <b>fine</b>.")
  eq("aligned from words", S.align(toks, words("hello world it's b fine b"), 3), "words")
  local toks2 = S.tokenize("Hello, World!")
  S.align(toks2, words("hello world"), 3)
  eq("first word starts on its timing", toks2[1].s, 0.1)
  eq("punctuation does not stop a match", toks2[2].e, 0.55)
  local toks3 = S.tokenize("We paid 1,250 dollars today.")
  S.align(toks3, words("we paid one thousand two hundred fifty dollars today"), 4)
  check("a word read differently is placed between its neighbours",
        toks3[3].s and toks3[3].s >= toks3[2].e and toks3[3].e <= toks3[4].s, tostring(toks3[3].s))
  local toks4 = S.tokenize("Something else entirely here now.")
  eq("an unrelated list falls back to an estimate", S.align(toks4, words("hola que tal"), 3), "estimate")
  local toks5 = S.tokenize("No timings at all.")
  eq("no list is an estimate", S.align(toks5, nil, 2), "estimate")
  check("an estimate stays inside the speech", toks5[#toks5].e <= 2 + 1e-9 and toks5[1].s >= 0)
end

describe("subtitles — splitting")
do
  local S = require("higgs.subtitles")
  local long = "When we started this project, nobody on the team believed that a four-person studio could ship a feature film in under a year, but here we are, and the premiere is next Friday in Toronto."
  local short = S.preview(long, "short")
  local fits, dangling = true, nil
  for _, line in ipairs(short) do
    if #line > S.LIMIT then fits = false end
    local last = line:match("(%S+)$"):lower()
    if last == "the" or last == "a" or last == "of" or last == "to" then dangling = line end
  end
  check("every short subtitle fits one line", fits)
  check("no subtitle ends on an article or a preposition", dangling == nil, dangling)
  eq("the first break is at the comma", short[1], "When we started this project,")
  local sent = S.preview("Welcome back to the channel! Today we're grading a sunset timelapse, shot entirely on the iPhone.", "sentence")
  eq("one subtitle per sentence", #sent, 2)
  eq("a short sentence stays on one line", sent[1], "Welcome back to the channel!")
  check("a long sentence wraps onto two lines", select(2, sent[2]:gsub("\n", "")) == 1, sent[2])
  local lines = {}
  for l in (sent[2] .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
  eq("punctuation outranks the shape of the lines", lines[1], "Today we're grading a sunset timelapse,")
  local even = S.preview("Nobody on the team believed a small studio could ship a feature film.", "sentence")[1]
  local l1, l2 = even:match("^(.-)\n(.*)$")
  check("without punctuation the lines are even, the longer underneath", l1 and #l1 <= #l2 + 2, even)
  local huge = S.preview(long, "sentence")
  local most = 0
  for _, cue in ipairs(huge) do most = math.max(most, select(2, cue:gsub("\n", "")) + 1) end
  check("a sentence never takes more than two lines", most <= 2, most)
  local long2 = "When we started this project, nobody on the team believed a four-person studio could ship a feature film in under a year. But here we are."
  local s2 = S.preview(long2, "sentence")
  eq("a sentence too long for two lines is paired from natural phrases", s2[1], "When we started this project,\nnobody on the team believed")
  eq("the next pair starts at the noun phrase", s2[2], "a four-person studio could ship\na feature film in under a year.")
  local hanging
  for _, cue in ipairs(S.preview(long2, "short")) do
    if cue:match("[,;:] %S+$") then hanging = cue end
  end
  check("no subtitle ends with one word of the next clause", hanging == nil, hanging)
  eq("words that finish a sentence after a comma stay with it", #S.preview("Hello there, friend.", "short"), 1)
  eq("two short sentences never share a subtitle", #S.preview("Yes. I agree.", "short"), 2)
  eq("nor do two Chinese ones", #S.preview("你好。我很好。", "short"), 2)
  eq("an exclamation in full-width ends one too", #S.preview("太好了！我们走吧。", "short"), 2)
  eq("a Hindi danda ends a sentence", #S.preview("नमस्ते। आप कैसे हैं?", "short"), 2)
  eq("an Arabic question mark ends a sentence", #S.preview("كيف حالك؟ أنا بخير.", "short"), 2)
  eq("a Chinese character is 42/16 of a line", S.text_width("拍摄"), 2 * 42 / 16)
  eq("mixed scripts share one line fairly", S.text_width("iPhone拍摄"), 6 + 2 * 42 / 16)
  local ja = S.preview("今日はとても良い天気ですね散歩に行きましょうか", "short")
  local ja_ok = true
  for _, l in ipairs(ja) do if S.text_width(l) > S.LIMIT + 1e-6 then ja_ok = false end end
  check("Japanese lines stay within 13 kana-widths", ja_ok and #ja >= 2, #ja)
  local es = S.tokenize("¿Qué tal? «Bien».")
  eq("Spanish opening marks ride on their word", es[1].text, "¿Qué")
  eq("and are not part of its letters", es[1].key, "qué")
  eq("guillemets open the word after them", es[3].text, "«Bien».")
  local zh = S.preview("我们今天要调色一段完全用手机拍摄的日落延时视频，效果真的让我大吃一惊。", "short")
  local ok = true
  for _, l in ipairs(zh) do if require("higgs.util").utf8_len(l) > S.LIMIT_CJK then ok = false end end
  check("Chinese lines stay within 16 characters", ok)
  eq("and break at the comma", zh[#zh], "效果真的让我大吃一惊。")
end

describe("subtitles — frames and .srt")
do
  local S = require("higgs.subtitles")
  local cues = S.frames({
    { start = 0.08, finish = 1.2, text = "One" },
    { start = 1.35, finish = 1.6, text = "Two" },
    { start = 4.0, finish = 5.0, text = "Three", bound = 5.2 },
  }, 24)
  eq("in on the first frame of the voice", cues[1].from, 1)
  eq("a gap under 0.8 s is filled up to the next subtitle", cues[1].to, cues[2].from)
  check("a subtitle stays up at least 20 frames", cues[2].to - cues[2].from >= 20, cues[2].to - cues[2].from)
  check("a gap of 0.8 s or more is kept", cues[3].from - cues[2].to >= math.floor(0.8 * 24 + 0.5))
  eq("the last one stays up past the voice, to the end of its clip", cues[3].to, math.floor(5.2 * 24))
  local srt, origin = S.srt(cues, 24)
  eq("the file starts at its first subtitle", origin, 1)
  eq("SubRip timing", srt:match("^1\n([^\n]+)"), "00:00:00,000 --> 00:00:01,292")
  eq("numbered in order", select(2, srt:gsub("\n%d+\n%d%d:", "")), 2)
  local tight = S.frames({ { start = 1.0, finish = 1.1, text = "a" }, { start = 1.05, finish = 2, text = "b" } }, 25)
  check("subtitles never overlap", tight[2].from >= tight[1].to)
  local near = S.frames({ { start = 0, finish = 1.0, text = "a" }, { start = 2.2, finish = 3, text = "b" } }, 24)
  eq("with the half-second lag, a 1.2 s pause leaves 0.7 s — filled", near[1].to, near[2].from)
  local far = S.frames({ { start = 0, finish = 1.0, text = "a" }, { start = 2.4, finish = 3, text = "b" } }, 24)
  eq("a 1.4 s pause leaves 0.9 s after the lag — kept", far[2].from - far[1].to, math.floor(2.4 * 24) - (24 + 12))
  local last = S.frames({ { start = 0, finish = 2.0, text = "a", bound = 2.2 } }, 24)
  eq("the last subtitle never runs past its clip", last[1].to, math.floor(2.2 * 24))
  local take = { text = "Hello there, friend.", seconds = 2.4, pause = 0.4,
                 words = { { word = "Hello", start = 0.1, ["end"] = 0.4 }, { word = "there", start = 0.45, ["end"] = 0.8 },
                           { word = "friend", start = 1.0, ["end"] = 1.6 } } }
  local tc, how = S.for_take(take, "short")
  eq("a take with timings is timed from them", how, "words")
  eq("a short line is one subtitle", #tc, 1)
  eq("starting with its first word", tc[1].start, 0.1)
  local none, why = S.for_take({ text = "Hello there, friend.", seconds = 2, pause = 0.4 }, "short")
  check("no word timings, no subtitles — never guessed", #none == 0 and why == "none")
  local w = S.whole("A line in a language Boson cannot time, long enough to need two lines here.", 4.2)
  check("without timings the whole line is one subtitle over the clip", #w == 1 and w[1].start == 0 and w[1].finish == 4.2)
  check("wrapped onto lines that fit", #w[1].lines == 2 and S.text_width(w[1].lines[1]) <= S.LIMIT, w[1].text)
  local off = S.for_take({ text = "Hello there, friend.", seconds = 2, words = { { word = "bonjour", start = 0, ["end"] = 1 } } }, "short")
  eq("timings that do not match the text give none either", #off, 0)
end

describe("API client — retries and failures (curl faked)")
do
  local A = require("higgs.api")
  local dir = os.tmpname() .. "-api"
  P.mkdirs(dir)
  local script = {}   -- what each successive curl run "returns": { status, body }
  local real = P.run_detached
  P.run_detached = function(cmd)
    local id = tonumber(cmd:match("job_(%d+)%.cfg"))
    local step = table.remove(script, 1) or { "200", "ok" }
    local base = P.join(dir, "job_" .. id)
    U.write_file(base .. ".status", step[1])
    U.write_file(base .. ".out", step[2])
    U.write_file(base .. ".done", "done")
    return true
  end
  local saved = A.RETRY_DELAYS
  A.RETRY_DELAYS = { 0, 0, 0 }
  local function run(steps, spec)
    script = steps
    local api = A.new({ get_key = function() return "sk-test" end, tmp_dir = dir })
    local res
    spec.on_done = function(r) res = r end
    api:speech(spec)
    for _ = 1, 50 do if res then break end; api:poll() end
    return res
  end
  local out = P.join(dir, "a.wav")
  local r = run({ { "429", '{"error":"Too many requests"}' }, { "200", "RIFFxxxxWAVE" } }, { text = "Hi.", out_path = out })
  check("a 429 is retried and then succeeds", r and r.ok, r and r.error)
  r = run({ { "429", "{}" }, { "429", "{}" }, { "429", "{}" }, { "429", '{"error":"slow down"}' } }, { text = "Hi.", out_path = out })
  check("after three retries the error reaches the caller", r and not r.ok and r.code == "429", r and r.code)
  r = run({ { "429", '{"error":"insufficient credit balance"}' } }, { text = "Hi.", out_path = out })
  eq("out of credit is not retried", #script, 0)
  check("and says so", r and r.error:find("credit", 1, true) ~= nil, r and r.error)
  r = run({ { "000", "" } }, { text = "Hi.", out_path = out })
  check("no answer at all (000) reads as no connection", r and r.error:find("internet", 1, true) ~= nil, r and r.error)
  r = run({ { "404", '{"error":"voice not found"}' } }, { text = "Hi.", out_path = out })
  eq("a missing voice says what to do", r and r.error, "That voice is no longer on your account. Pick another voice.")
  A.RETRY_DELAYS = saved
  P.run_detached = real
  os.execute("rm -rf " .. P.quote(dir))
end

print(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
