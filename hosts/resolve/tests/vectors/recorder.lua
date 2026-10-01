--- Vectors for recorder.lua: the meter, the verdict on a take and its
-- wording, the live notes. Thresholds are tested on both sides.

local R = require("higgs.recorder")

local cases = {}
local function case(name, fn, input, expect)
  cases[#cases + 1] = { name = name, fn = fn, input = input, expect = expect }
end

for _, k in ipairs({ "MIN_SECONDS", "GOOD_MIN", "GOOD_MAX", "IDEAL", "QUIET_RMS", "HOT_PEAK",
                     "HOT_RATIO", "SLOW_WPS", "FAST_WPS", "PASSAGES" }) do
  case("constant " .. k, k, { none = true }, R[k])
end

------------------------------------------------------------------ meter

for _, p in ipairs({ 0, -0.5, 0.001, 0.0019952623149689, 0.002, 0.01, 0.1, 0.25, 0.5, 0.999, 1, 1.5, "0.5" }) do
  case("meter at " .. tostring(p), "meter", { peak = p }, R.meter(p))
end
case("meter with nothing", "meter", { none = true }, R.meter(nil))

------------------------------------------------------------------ word_count

for _, c in ipairs({
  { "runs of space", "  one   two\nthree " },
  { "empty", "" },
  { "tabs and returns", "a\tb\r\nc" },
  { "Chinese without spaces is one word", "你好世界" },
  { "Chinese with spaces", "你好 世界" },
  { "punctuation alone counts", "wait — what" },
}) do case("word_count: " .. c[1], "word_count", { text = c[2] }, R.word_count(c[2])) end
case("word_count: nothing", "word_count", { none = true }, R.word_count(nil))

------------------------------------------------------------------ judge

-- A transcript the length a natural read of `sec` seconds would produce, so
-- these cases are not silently decided by the pace rule.
local function paced(sec) return string.rep("word ", math.floor(sec * 2.8)) end
local function judge(name, take, transcript)
  case("judge: " .. name, "judge", { take = take, transcript = transcript }, R.judge(take, transcript))
end
local function take(sec, rms, hot, peak)
  return { seconds = sec, peak = peak or math.min(1, rms * 8), rms = rms, hot_ratio = hot or 0 }
end

judge("under Boson's floor is refused", take(2.4, 0.1), paced(2.4))
judge("just under the floor", take(2.99, 0.1), paced(3))
judge("a tenth that rounds up in the message", take(2.25, 0.1), paced(2.25))
judge("exactly at the floor is not refused", take(3.0, 0.1), paced(3))
judge("no length at all", take(0, 0.1), "")
judge("no take at all", nil, "words")
judge("silence is refused and flagged", { seconds = 10, peak = 0, rms = 0, hot_ratio = 0 }, paced(10))
judge("a peak at the silence line is silence", { seconds = 10, peak = 0.0005, rms = 0.1, hot_ratio = 0 }, paced(10))
judge("just over the silence line", { seconds = 10, peak = 0.0006, rms = 0.1, hot_ratio = 0 }, paced(10))
judge("too quiet is refused", take(10, 0.01), paced(10))
judge("just under the quiet line", take(10, 0.0177), paced(10))
judge("exactly at the quiet line", take(10, 0.0178), paced(10))
judge("quiet is judged on the average, not one loud knock", { seconds = 10, peak = 0.9, rms = 0.005, hot_ratio = 0 }, paced(10))
judge("clipping warns but still sends", take(10, 0.3, 0.05), paced(10))
judge("exactly at the clipping ratio is not clipping", take(10, 0.3, 0.005), paced(10))
judge("just over the clipping ratio", take(10, 0.3, 0.0051), paced(10))
judge("clipping outranks pace", take(10, 0.3, 0.05), string.rep("word ", 60))
judge("an occasional peak is not clipping", take(10, 0.3, 0.001), paced(10))
judge("a good take is good", take(12, 0.2), paced(12))
judge("a good take rounds its seconds", take(22.5, 0.2), paced(22.5))
judge("a usable but short take is a warning", take(4, 0.2), paced(4))
judge("just under the good minimum", take(4.99, 0.2), paced(4.99))
judge("exactly at the good minimum", take(5, 0.2), paced(5))
judge("a long take is still good", take(30, 0.2), paced(30))
judge("fifty words in ten seconds is rushed", take(10, 0.2), string.rep("word ", 50))
judge("twenty words in twenty seconds is laboured", take(20, 0.2), string.rep("word ", 20))
judge("fifty-six words in twenty seconds is natural", take(20, 0.2), string.rep("word ", 56))
judge("exactly at the fast edge is still natural", take(10, 0.2), string.rep("word ", 40))
judge("just over the fast edge", take(10, 0.2), string.rep("word ", 41))
judge("exactly at the slow edge is still natural", take(10, 0.2), string.rep("word ", 18))
judge("just under the slow edge", take(10, 0.2), string.rep("word ", 17))
judge("no transcript means no pace verdict", take(20, 0.2), "")
judge("a missing transcript too", take(20, 0.2), nil)
judge("pace outranks a short take", take(4, 0.2), string.rep("word ", 30))
judge("numbers given as text", { seconds = "12", peak = "0.5", rms = "0.2", hot_ratio = "0" }, paced(12))

------------------------------------------------------------------ level_note

for _, p in ipairs({ 1, 0.98, 0.979, 0.5, 0.02, 0.0199, 0.001, 0, -0.1 }) do
  local msg, kind = R.level_note(p)
  case("level_note at " .. tostring(p), "level_note", { peak = p }, msg and { message = msg, kind = kind } or nil)
end

------------------------------------------------------------------ coach

for _, c in ipairs({
  { 0, 30 }, { 1.5, 30 }, { 2.99, 30 }, { 3, 30 }, { 4, 30 }, { 17.9, 30 }, { 18, 30 }, { 19, 30 },
  { 24.9, 30 }, { 25, 30 }, { 26, 30 }, { 16, 20 }, { 14, 20 }, { 10, 29.5 }, { 3 }, { 25 },
}) do
  case(("coach at %s of %s"):format(tostring(c[1]), tostring(c[2])), "coach",
       { seconds = c[1], limit = c[2] }, R.coach(c[1], c[2]))
end

return {
  about = "Judging a recorded voice reference: meter, verdict and wording, live coaching.",
  source = "src/higgs/recorder.lua",
  cases = cases,
}
