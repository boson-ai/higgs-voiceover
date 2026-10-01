--- Vectors for the WAV and raw-PCM helpers in util.lua.
--
-- The Lua works on files; these cases write small synthetic files, call it,
-- and read the result back. Files travel as base64 (`wav`, `pcm`). A result
-- of false (left untouched) is false; nil is a missing `expect`.

local U = require("higgs.util")

local cases = {}
local function case(name, fn, input, expect)
  cases[#cases + 1] = { name = name, fn = fn, input = input, expect = expect }
end

local function u16(v) v = v % 65536 return string.char(v % 256, math.floor(v / 256) % 256) end
local function u32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
local function s16(v) return u16(v % 65536) end

local function samples(list)
  local out = {}
  for i, v in ipairs(list) do out[i] = s16(v) end
  return table.concat(out)
end

local function ramp(n, step)
  local out = {}
  for i = 1, n do out[i] = s16(((i - 1) * (step or 1)) % 65536) end
  return table.concat(out)
end

local function fmt_chunk(channels, rate, bits, format)
  local block = channels * bits / 8
  return "fmt " .. u32(16) .. u16(format or 1) .. u16(channels) .. u32(rate) .. u32(rate * block)
      .. u16(block) .. u16(bits)
end

local function wav(data, opts)
  opts = opts or {}
  local body = "WAVE" .. (opts.before or "") .. (opts.fmt or fmt_chunk(opts.channels or 1, opts.rate or 24000, opts.bits or 16, opts.format))
            .. (opts.between or "") .. "data" .. u32(opts.size or #data) .. data .. (opts.after or "")
  return "RIFF" .. u32(#body) .. body
end

local tmp = os.tmpname()
local tmp2 = tmp .. ".out"
local function put(bytes) U.write_file(tmp, bytes) return tmp end
local function got(path) return U.b64_encode(U.read_file(path) or "") end
local b64 = U.b64_encode

local JUNK = "JUNK" .. u32(28) .. string.rep("\0", 28)
local LIST = "LIST" .. u32(5) .. "INFOx" .. "\0"   -- odd size, padded

local mono = wav(ramp(240, 7))                                -- 10 ms
local stereo = wav(ramp(480, 3), { channels = 2, rate = 48000 })
local mono8 = wav(string.rep("\128", 240), { bits = 8 })
local float = wav(string.rep("\0", 960), { bits = 32, format = 3 })
local junk = wav(ramp(240, 11), { before = JUNK })
local tailed = wav(ramp(240, 5), { after = LIST })
local odd = wav(ramp(240, 9) .. "\7")
local nofmt = "RIFF" .. u32(4 + 8 + 480) .. "WAVE" .. "data" .. u32(480) .. ramp(240)
local zero_rate = wav(ramp(240), { fmt = "fmt " .. u32(16) .. u16(1) .. u16(1) .. u32(24000) .. u32(0) .. u16(2) .. u16(16) })
local short_fmt = wav(ramp(240), { fmt = "fmt " .. u32(10) .. string.rep("\1", 10) })
local listed = wav(ramp(240), { before = LIST })
local killed = wav(ramp(240, 13), { size = 0 })
local stale = wav(ramp(240, 13), { size = 100000 })

local files = {
  { "mono 16-bit", mono }, { "stereo 48 kHz", stereo }, { "8-bit", mono8 }, { "float", float },
  { "a JUNK chunk before fmt", junk }, { "a LIST chunk after the data", tailed },
  { "an odd data size", odd }, { "no fmt chunk", nofmt }, { "a zero byte rate", zero_rate },
  { "a short fmt chunk", short_fmt }, { "an odd-sized chunk before fmt", listed },
  { "a data size of 0 from a killed recorder", killed }, { "a data size larger than the file", stale },
  { "not a RIFF", "hello, this is not a wav file at all, not even close to it......" },
  { "RIFF but not WAVE", "RIFF" .. u32(40) .. "AVI " .. string.rep("\0", 40) },
  { "shorter than a header", "RIFF" },
}

------------------------------------------------------------------ wav_seconds

for _, f in ipairs(files) do
  case("wav_seconds: " .. f[1], "wav_seconds", { wav = b64(f[2]) }, U.wav_seconds(put(f[2])))
end

------------------------------------------------------------------ wav_to_stereo

for _, f in ipairs(files) do
  local ok = U.wav_to_stereo(put(f[2]))
  case("wav_to_stereo: " .. f[1], "wav_to_stereo", { wav = b64(f[2]) }, ok and got(tmp) or false)
end

------------------------------------------------------------------ wav_append_silence

for _, c in ipairs({
  { "4 ms to mono", mono, 0.004 },
  { "40 ms to mono", mono, 0.04 },
  { "a fraction of a sample rounds down to whole blocks", mono, 0.0001 },
  { "less than one sample adds nothing", mono, 0.00001 },
  { "to stereo, in whole frames", stereo, 0.0021 },
  { "after a JUNK chunk", junk, 0.002 },
  { "keeps a chunk after the data", tailed, 0.002 },
  { "zero seconds", mono, 0 },
  { "negative seconds", mono, -1 },
  { "not PCM", float, 0.01 },
  { "not a wav", files[14][2], 0.01 },
  { "no fmt chunk", nofmt, 0.01 },
}) do
  local ok = U.wav_append_silence(put(c[2]), c[3])
  case("wav_append_silence: " .. c[1], "wav_append_silence", { wav = b64(c[2]), seconds = c[3] },
       ok and got(tmp) or false)
end
case("wav_append_silence: no seconds", "wav_append_silence", { wav = b64(mono) },
     U.wav_append_silence(put(mono), nil) and got(tmp) or false)

------------------------------------------------------------------ wav_slice

for _, c in ipairs({
  { "from the start", mono, 0 },
  { "from 5 ms", mono, 0.005 },
  { "from part of a sample", mono, 0.00003 },
  { "past the end keeps the last sample", mono, 5 },
  { "negative is the start", mono, -2 },
  { "stereo in whole frames", stereo, 0.0021 },
  { "drops a chunk after the data", tailed, 0.001 },
  { "after a JUNK chunk", junk, 0.002 },
  { "not a wav", files[14][2], 0 },
}) do
  local ok = U.wav_slice(put(c[2]), tmp2, c[3])
  case("wav_slice: " .. c[1], "wav_slice", { wav = b64(c[2]), from_seconds = c[3] }, ok and got(tmp2) or false)
end
case("wav_slice: no position", "wav_slice", { wav = b64(mono) },
     U.wav_slice(put(mono), tmp2, nil) and got(tmp2) or false)

------------------------------------------------------------------ data range and stats

for _, f in ipairs(files) do
  local from, size = U.wav_data_range(put(f[2]))
  case("wav_data_range: " .. f[1], "wav_data_range", { wav = b64(f[2]) }, from and { from = from, size = size } or nil)
end

local loud = wav(samples({ 32700, -32700, 32767, -32768, 100, -100, 32112, 32111 }))
local quiet = wav(samples({ 10, -12, 8, 0, -3, 5 }), { before = JUNK })
for _, f in ipairs({
  { "a ramp", mono }, { "after a JUNK chunk", quiet }, { "loud with clipped samples", loud },
  { "a killed recorder's file", killed }, { "an odd data size", odd }, { "an empty data chunk", wav("") },
  { "not a wav", files[14][2] },
}) do
  case("wav_stats: " .. f[1], "wav_stats", { wav = b64(f[2]) }, U.wav_stats(put(f[2])))
end

------------------------------------------------------------------ raw pcm

for _, n in ipairs({ 0, 1, 2, 48000, 12345 }) do
  case("pcm_seconds of " .. n .. " bytes", "pcm_seconds", { size = n }, U.pcm_seconds(put(string.rep("\0", n))))
end

-- 0.2 s, quiet throughout, one loud sample near the end so the tail window
-- is the only place a peak meter can find it.
local parts = {}
for i = 1, 4800 do parts[i] = 100 end
parts[4700] = 16384
local take = samples(parts)
for _, c in ipairs({
  { "the tail window finds the loud sample", take, 0.1 },
  { "a short window misses it", take, 0.002 },
  { "a window longer than the take", take, 1 },
  { "a zero window reads nothing", take, 0 },
  { "the default window", take, nil },
  { "an odd byte count never starts mid-sample", take .. "\255", 0.001 },
  { "full-scale negative", samples({ 0, -32768, 0 }), 0.1 },
  { "an empty capture", "", 0.1 },
}) do
  case("pcm_peak: " .. c[1], "pcm_peak", { pcm = b64(c[2]), window = c[3] }, U.pcm_peak(put(c[2]), c[3]))
end

for _, c in ipairs({
  { "a quiet take with one peak", take },
  { "a take at the ceiling", samples({ 32700, 32700, -32700, 32700 }) },
  { "mixed signs", samples({ 1000, -2000, 3000, -4000, 0 }) },
  { "an odd trailing byte", samples({ 500, -500 }) .. "\9" },
  { "an empty capture", "" },
}) do
  case("pcm_stats: " .. c[1], "pcm_stats", { pcm = b64(c[2]) }, U.pcm_stats(put(c[2])))
end

local small = ramp(100, 37)
for _, c in ipairs({
  { "wraps the whole capture", small, nil },
  { "skips the count-in", small, 40 },
  { "an odd skip never starts mid-sample", small, 41 },
  { "a fractional skip", small, 40.7 },
  { "a negative skip is none", small, -8 },
  { "a skip past the end gives nothing", small, 400 },
  { "an odd trailing byte is dropped", small .. "\7", 0 },
  { "a single byte is nothing", "\1", 0 },
  { "an empty capture is nothing", "", 0 },
}) do
  local secs = U.pcm_to_wav(put(c[2]), tmp2, c[3])
  case("pcm_to_wav: " .. c[1], "pcm_to_wav", { pcm = b64(c[2]), skip_bytes = c[3] },
       secs and { wav = got(tmp2), seconds = secs } or nil)
end

case("constants", "constants", { none = true }, { PCM_RATE = U.PCM_RATE, PCM_BITS = U.PCM_BITS, PCM_CHANNELS = U.PCM_CHANNELS })

os.remove(tmp)
os.remove(tmp2)

return {
  about = "WAV and raw 16-bit PCM: length, stereo, silence, slicing, levels, wrapping. Files are base64.",
  source = "src/higgs/util.lua",
  cases = cases,
}
