--- Shared helpers: JSON, base64, file IO, text segmentation, ids.
--
-- Nothing here knows about Resolve, the Boson API, or the UI. The JSON codec and
-- base64 encoder are carried over from the proof of concept, where they were
-- covered by its self-tests.

local M = {}

------------------------------------------------------------------------ json

local json = {}
do
  local esc_map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
                    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

  local function esc_str(s)
    return (s:gsub('[%z\1-\31"\\]', function(c)
      return esc_map[c] or string.format("\\u%04x", c:byte())
    end))
  end

  --- Encode a Lua value as JSON.
  -- A table with a positive length encodes as an array, otherwise as an object,
  -- so an empty table becomes {} — never send an empty array through this.
  function json.encode(v)
    local t = type(v)
    if v == nil then return "null"
    elseif t == "boolean" then return tostring(v)
    elseif t == "number" then return string.format("%.14g", v)
    elseif t == "string" then return '"' .. esc_str(v) .. '"'
    elseif t == "table" then
      if #v > 0 then
        local parts = {}
        for i = 1, #v do parts[i] = json.encode(v[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
      end
      local parts = {}
      for k, val in pairs(v) do
        parts[#parts + 1] = '"' .. esc_str(tostring(k)) .. '":' .. json.encode(val)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
  end

  local function utf8_char(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then
      return string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64)
    end
    return string.char(0xE0 + math.floor(code / 4096),
                       0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
  end

  local decode_value

  local function skip_ws(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return j + 1
  end

  local function decode_string(s, i)
    local out, n = {}, i + 1
    while n <= #s do
      local c = s:sub(n, n)
      if c == '"' then return table.concat(out), n + 1 end
      if c == "\\" then
        local e = s:sub(n + 1, n + 1)
        if e == "u" then
          out[#out + 1] = utf8_char(tonumber(s:sub(n + 2, n + 5), 16) or 63)
          n = n + 6
        else
          local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
                        f = "\f", n = "\n", r = "\r", t = "\t" }
          out[#out + 1] = map[e] or e
          n = n + 2
        end
      else
        out[#out + 1] = c
        n = n + 1
      end
    end
    error("unterminated string")
  end

  decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "{" then
      local obj = {}
      i = skip_ws(s, i + 1)
      if s:sub(i, i) == "}" then return obj, i + 1 end
      while true do
        local key
        key, i = decode_string(s, skip_ws(s, i))
        i = skip_ws(s, i)
        assert(s:sub(i, i) == ":", "expected ':'")
        local val
        val, i = decode_value(s, i + 1)
        obj[key] = val
        i = skip_ws(s, i)
        local d = s:sub(i, i)
        if d == "," then i = i + 1
        elseif d == "}" then return obj, i + 1
        else error("bad object") end
      end
    elseif c == "[" then
      local arr = {}
      i = skip_ws(s, i + 1)
      if s:sub(i, i) == "]" then return arr, i + 1 end
      while true do
        local val
        val, i = decode_value(s, i)
        arr[#arr + 1] = val
        i = skip_ws(s, i)
        local d = s:sub(i, i)
        if d == "," then i = i + 1
        elseif d == "]" then return arr, i + 1
        else error("bad array") end
      end
    elseif c == '"' then
      return decode_string(s, i)
    elseif s:sub(i, i + 3) == "true" then return true, i + 4
    elseif s:sub(i, i + 4) == "false" then return false, i + 5
    elseif s:sub(i, i + 3) == "null" then return nil, i + 4
    end
    local num = s:match("^-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
    if num and #num > 0 then return tonumber(num), i + #num end
    error("unexpected character '" .. c .. "' at " .. i)
  end

  --- Decode JSON. Returns nil plus a message on malformed input.
  function json.decode(s)
    local ok, val = pcall(function() return (decode_value(s, 1)) end)
    if ok then return val end
    return nil, tostring(val)
  end
end

M.json = json

---------------------------------------------------------------------- base64

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--- Base64-encode a binary string (used for voice-clone reference audio).
function M.b64_encode(data)
  local out, byte, len = {}, string.byte, #data
  local i, chars = 1, B64_CHARS
  while i + 2 <= len do
    local a, b, c = byte(data, i, i + 2)
    local n = a * 65536 + b * 256 + c
    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096) % 64
    local c3 = math.floor(n / 64) % 64
    local c4 = n % 64
    out[#out + 1] = chars:sub(c1 + 1, c1 + 1) .. chars:sub(c2 + 1, c2 + 1)
                 .. chars:sub(c3 + 1, c3 + 1) .. chars:sub(c4 + 1, c4 + 1)
    i = i + 3
  end
  local rem = len - i + 1
  if rem == 1 then
    local n = byte(data, i) * 65536
    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096) % 64
    out[#out + 1] = chars:sub(c1 + 1, c1 + 1) .. chars:sub(c2 + 1, c2 + 1) .. "=="
  elseif rem == 2 then
    local a, b = byte(data, i, i + 1)
    local n = a * 65536 + b * 256
    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096) % 64
    local c3 = math.floor(n / 64) % 64
    out[#out + 1] = chars:sub(c1 + 1, c1 + 1) .. chars:sub(c2 + 1, c2 + 1)
                 .. chars:sub(c3 + 1, c3 + 1) .. "="
  end
  return table.concat(out)
end

--- Decode base64 (the audio inside a timestamped speech response). Line
-- breaks and anything else outside the alphabet are skipped.
local B64_VALUES
function M.b64_decode(data)
  if not B64_VALUES then
    B64_VALUES = {}
    for i = 1, #B64_CHARS do B64_VALUES[B64_CHARS:byte(i)] = i - 1 end
  end
  local vals, byte, char = B64_VALUES, string.byte, string.char
  local clean = tostring(data or ""):gsub("[^%w%+/]", "")
  local out, len, floor = {}, #clean, math.floor
  local i = 1
  while i + 3 <= len do
    local a, b, c, d = byte(clean, i, i + 3)
    local n = vals[a] * 262144 + vals[b] * 4096 + vals[c] * 64 + vals[d]
    out[#out + 1] = char(floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
    i = i + 4
  end
  local rem = len - i + 1
  if rem == 2 then
    local a, b = byte(clean, i, i + 1)
    out[#out + 1] = char(floor((vals[a] * 262144 + vals[b] * 4096) / 65536) % 256)
  elseif rem == 3 then
    local a, b, c = byte(clean, i, i + 2)
    local n = vals[a] * 262144 + vals[b] * 4096 + vals[c] * 64
    out[#out + 1] = char(floor(n / 65536) % 256, floor(n / 256) % 256)
  end
  return table.concat(out)
end

--------------------------------------------------------------------- file io

function M.read_file(path, mode)
  local f = io.open(path, mode or "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

function M.write_file(path, contents, mode)
  local f = io.open(path, mode or "wb")
  if not f then return false end
  f:write(contents)
  f:close()
  return true
end

function M.file_size(path)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local n = f:seek("end")
  f:close()
  return n or 0
end

------------------------------------------------------------------------ text

function M.trim(s)
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Strip inline control tags, leaving only spoken words.
-- Character counts are billed on the full input, but the user reasons about the
-- words, so both counts exist and callers pick the right one.
function M.strip_tags(s)
  return (tostring(s):gsub("<|.-|>", ""))
end

function M.word_count(s)
  local n = 0
  for _ in M.strip_tags(s):gmatch("%S+") do n = n + 1 end
  return n
end

--- Rough spoken duration, for estimates before a take exists.
-- 150 wpm is a common narration pace; this is a hint in the UI, never a value
-- anything downstream depends on.
--- Length of a PCM WAV file in seconds from its header, or nil for
-- anything else (compressed formats need a decoder to know).
function M.wav_seconds(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local head = f:read(12)
  if not head or head:sub(1, 4) ~= "RIFF" or head:sub(9, 12) ~= "WAVE" then f:close() return nil end
  local function u32(s) local a, b, c2, d = s:byte(1, 4) return a + b * 256 + c2 * 65536 + d * 16777216 end
  local byte_rate
  while true do
    local chunk = f:read(8)
    if not chunk or #chunk < 8 then break end
    local id, size = chunk:sub(1, 4), u32(chunk:sub(5, 8))
    if id == "fmt " then
      local fmt = f:read(size)
      if not fmt or #fmt < 12 then break end
      byte_rate = u32(fmt:sub(9, 12))
    elseif id == "data" then
      f:close()
      if byte_rate and byte_rate > 0 then return size / byte_rate end
      return nil
    else
      f:seek("cur", size + (size % 2))
    end
  end
  f:close()
  return nil
end

--- Rewrite the fields of a WAV `fmt ` chunk inside a whole-file string.
local function wav_rewrite_fmt(all, fmt_at, channels, byte_rate, block_align)
  local function p16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
  local function p32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
  return all:sub(1, fmt_at + 9) .. p16(channels) .. all:sub(fmt_at + 12, fmt_at + 15)
       .. p32(byte_rate) .. p16(block_align) .. all:sub(fmt_at + 22)
end

--- Walk the chunks of a WAV, returning where fmt and data are.
local function wav_chunks(all)
  if not all or #all < 44 or all:sub(1, 4) ~= "RIFF" or all:sub(9, 12) ~= "WAVE" then return nil end
  local function u32(s) local a, b, c, d = s:byte(1, 4) return a + b * 256 + c * 65536 + d * 16777216 end
  local pos, out = 13, {}
  while pos + 8 <= #all do
    local id, size = all:sub(pos, pos + 3), u32(all:sub(pos + 4, pos + 7))
    if id == "fmt " then
      out.fmt_at = pos
      out.channels = all:byte(pos + 10) + all:byte(pos + 11) * 256
      out.rate = u32(all:sub(pos + 12, pos + 15))
      out.byte_rate = u32(all:sub(pos + 16, pos + 19))
      out.block = all:byte(pos + 20) + all:byte(pos + 21) * 256
      out.bits = all:byte(pos + 22) + all:byte(pos + 23) * 256
    elseif id == "data" then
      out.data_at, out.data_size = pos, size
      return out
    end
    pos = pos + 8 + size + (size % 2)
  end
  return nil
end

--- Make a mono 16-bit PCM WAV two-channel, the same audio in both. Resolve
-- lays a mono clip on one side of a stereo track; a real stereo file plays
-- centred everywhere. Already-stereo or non-PCM files are left alone.
function M.wav_to_stereo(path)
  local f = io.open(path, "rb")
  if not f then return false end
  local all = f:read("*a")
  f:close()
  local c = wav_chunks(all)
  if not c or not c.data_at or c.channels ~= 1 or c.bits ~= 16 then return false end
  local data = all:sub(c.data_at + 8, c.data_at + 7 + c.data_size)
  -- Every 16-bit sample written twice: left and right carry the same audio.
  local stereo = data:gsub("(..)", "%1%1")
  local function p32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
  local head = wav_rewrite_fmt(all:sub(1, c.data_at - 1), c.fmt_at, 2, c.byte_rate * 2, c.block * 2)
  local tail = all:sub(c.data_at + 8 + c.data_size)
  local out = io.open(path, "wb")
  if not out then return false end
  out:write("RIFF", p32(#head - 8 + 8 + #stereo + #tail), head:sub(9), "data", p32(#stereo), stereo, tail)
  out:close()
  return true
end

--- Append `seconds` of silence to a PCM WAV file in place. Returns true on
-- success; anything that is not a plain PCM WAV is left untouched.
function M.wav_append_silence(path, seconds)
  if not seconds or seconds <= 0 then return false end
  local f = io.open(path, "rb")
  if not f then return false end
  local all = f:read("*a")
  f:close()
  if not all or #all < 44 or all:sub(1, 4) ~= "RIFF" or all:sub(9, 12) ~= "WAVE" then return false end
  local function u32(s) local a, b, c2, d = s:byte(1, 4) return a + b * 256 + c2 * 65536 + d * 16777216 end
  local function p32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
  local pos, byte_rate, block, data_at, data_size = 13, nil, nil, nil, nil
  while pos + 8 <= #all do
    local id, size = all:sub(pos, pos + 3), u32(all:sub(pos + 4, pos + 7))
    if id == "fmt " then
      if u32(all:sub(pos + 8, pos + 9) .. "\0\0") % 65536 ~= 1 then return false end   -- PCM only
      byte_rate = u32(all:sub(pos + 16, pos + 19))
      block = all:byte(pos + 20) + all:byte(pos + 21) * 256
    elseif id == "data" then
      data_at, data_size = pos, size
      break
    end
    pos = pos + 8 + size + (size % 2)
  end
  if not (byte_rate and block and data_at) then return false end
  local pad = math.floor(byte_rate * seconds / block) * block
  if pad <= 0 then return true end
  local out = io.open(path, "wb")
  if not out then return false end
  out:write("RIFF", p32(#all - 8 + pad), all:sub(9, data_at + 3), p32(data_size + pad),
            all:sub(data_at + 8, data_at + 7 + data_size), string.rep("\0", pad),
            all:sub(data_at + 8 + data_size))
  out:close()
  return true
end

--- Write the part of a PCM WAV from `from_seconds` to the end into `out`.
-- Seeking with a player that cannot seek: play the remainder instead.
function M.wav_slice(path, out, from_seconds)
  local f = io.open(path, "rb")
  if not f then return false end
  local all = f:read("*a")
  f:close()
  if not all or #all < 44 or all:sub(1, 4) ~= "RIFF" or all:sub(9, 12) ~= "WAVE" then return false end
  local function u32(s) local a, b, c2, d = s:byte(1, 4) return a + b * 256 + c2 * 65536 + d * 16777216 end
  local function p32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
  local pos, byte_rate, block, data_at, data_size = 13, nil, nil, nil, nil
  while pos + 8 <= #all do
    local id, size = all:sub(pos, pos + 3), u32(all:sub(pos + 4, pos + 7))
    if id == "fmt " then
      byte_rate = u32(all:sub(pos + 16, pos + 19))
      block = all:byte(pos + 20) + all:byte(pos + 21) * 256
    elseif id == "data" then
      data_at, data_size = pos, size
      break
    end
    pos = pos + 8 + size + (size % 2)
  end
  if not (byte_rate and block and data_at) then return false end
  local skip = math.floor(byte_rate * math.max(0, from_seconds or 0) / block) * block
  if skip >= data_size then skip = math.max(0, data_size - block) end
  local rest = all:sub(data_at + 8 + skip, data_at + 7 + data_size)
  local o = io.open(out, "wb")
  if not o then return false end
  o:write("RIFF", p32(4 + (data_at - 13) + 8 + #rest), all:sub(9, data_at + 3), p32(#rest), rest)
  o:close()
  return true
end

function M.estimate_seconds(s)
  return M.word_count(s) / 150 * 60
end

------------------------------------------------------------------ raw PCM

-- A recording is captured as headerless 16-bit little-endian PCM rather than
-- a WAV, because the header's length fields are only correct once the encoder
-- has exited cleanly — and the user stops a recording by killing it. With raw
-- PCM every byte on disk is audio, so a recording interrupted at any moment is
-- still whole, the elapsed time is arithmetic on the file size, and the header
-- is written here at the end, where the true length is known.

M.PCM_RATE = 24000     -- Boson generates at 24 kHz; matching it avoids a resample
M.PCM_BITS = 16
M.PCM_CHANNELS = 1

local function pcm_byte_rate()
  return M.PCM_RATE * M.PCM_CHANNELS * (M.PCM_BITS / 8)
end

--- Bytes on disk, or 0. Used to read a recording's length while it grows.
function M.file_size(path)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local size = f:seek("end") or 0
  f:close()
  return size
end

--- Seconds of audio in a raw PCM file, from its size alone.
function M.pcm_seconds(path)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local size = f:seek("end") or 0
  f:close()
  return size / pcm_byte_rate()
end

--- Loudest sample in the last `window` seconds of a raw PCM file, as 0–1.
-- Reads only the tail, so it costs the same on a 3-second take as a 30-second
-- one and can be called on every tick of the UI loop.
function M.pcm_peak(path, window)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local size = f:seek("end") or 0
  local want = math.floor(pcm_byte_rate() * (window or 0.1))
  local from = math.max(0, size - want)
  if from % 2 == 1 then from = from - 1 end   -- never start mid-sample
  f:seek("set", from)
  local tail = f:read(size - from) or ""
  f:close()
  local peak = 0
  for i = 1, #tail - 1, 2 do
    local lo, hi = tail:byte(i), tail:byte(i + 1)
    local v = lo + hi * 256
    if v >= 32768 then v = v - 65536 end
    if v < 0 then v = -v end
    if v > peak then peak = v end
  end
  return peak / 32768
end

--- Where the samples are in a PCM WAV: byte offset and length of `data`.
-- AVAudioRecorder writes a JUNK chunk before `fmt `, so nothing may assume
-- the samples start at byte 45.
function M.wav_data_range(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local head = f:read(12)
  if not head or head:sub(1, 4) ~= "RIFF" or head:sub(9, 12) ~= "WAVE" then f:close() return nil end
  local function u32(x) local a, b, c, d = x:byte(1, 4) return a + b * 256 + c * 65536 + d * 16777216 end
  local pos = 12
  while true do
    local chunk = f:read(8)
    if not chunk or #chunk < 8 then break end
    local id, size = chunk:sub(1, 4), u32(chunk:sub(5, 8))
    if id == "data" then
      local here = pos + 8
      -- A recorder killed mid-write leaves the length field at 0 or stale, so
      -- trust the file rather than the header when the header claims more.
      local real = (f:seek("end") or 0) - here
      f:close()
      if size == 0 or size > real then size = math.max(0, real) end
      return here, size
    end
    pos = pos + 8 + size + (size % 2)
    f:seek("set", pos)
  end
  f:close()
  return nil
end

--- Peak, clipped-sample ratio and length over a span of 16-bit samples.
-- Shared by the raw-PCM and WAV paths so there is one loop to be right.
local function scan_samples(path, from, count)
  local f = io.open(path, "rb")
  if not f then return { seconds = 0, peak = 0, rms = 0, hot_ratio = 0 } end
  if from > 0 then f:seek("set", from) end
  local left = count
  local peak, hot, total, energy = 0, 0, 0, 0
  local CLIP = 32112   -- 0.98 of full scale, matching recorder.HOT_PEAK
  while left > 0 do
    local chunk = f:read(math.min(65536, left))
    if not chunk or #chunk < 2 then break end
    left = left - #chunk
    for i = 1, #chunk - 1, 2 do
      local v = chunk:byte(i) + chunk:byte(i + 1) * 256
      if v >= 32768 then v = 65536 - v end
      total = total + 1
      if v > peak then peak = v end
      if v >= CLIP then hot = hot + 1 end
      local n = v / 32768
      energy = energy + n * n
    end
  end
  f:close()
  return {
    seconds = total / M.PCM_RATE,
    peak = peak / 32768,
    rms = (total > 0) and math.sqrt(energy / total) or 0,
    hot_ratio = (total > 0) and (hot / total) or 0,
  }
end

--- Stats over the samples of a PCM WAV, whatever chunks precede them.
function M.wav_stats(path)
  local from, size = M.wav_data_range(path)
  if not from then return { seconds = 0, peak = 0, rms = 0, hot_ratio = 0 } end
  return scan_samples(path, from, size)
end

--- Peak, clipped-sample ratio and length over a whole raw PCM file.
-- Called once, when a take ends — it reads every sample, which the tail-only
-- meter above deliberately does not.
function M.pcm_stats(path)
  local f = io.open(path, "rb")
  if not f then return { seconds = 0, peak = 0, hot_ratio = 0 } end
  local peak, hot, total, energy = 0, 0, 0, 0
  local CLIP = 32112   -- 0.98 of full scale, matching recorder.HOT_PEAK
  while true do
    -- In blocks: a whole 30-second take is 1.4 MB, and string.byte over a
    -- chunk is far cheaper than a call per sample.
    local chunk = f:read(65536)
    if not chunk or #chunk < 2 then break end
    for i = 1, #chunk - 1, 2 do
      local v = chunk:byte(i) + chunk:byte(i + 1) * 256
      if v >= 32768 then v = 65536 - v end
      total = total + 1
      if v > peak then peak = v end
      if v >= CLIP then hot = hot + 1 end
      -- Squared in normalised units: 30 s of samples would overflow a double's
      -- precision long before the end if summed as raw 16-bit squares.
      local n = v / 32768
      energy = energy + n * n
    end
  end
  f:close()
  return {
    seconds = total / M.PCM_RATE,
    peak = peak / 32768,
    -- Average level, which is what "too quiet" really means: a single door
    -- slam can put the peak where a whispered take's peak should be.
    rms = (total > 0) and math.sqrt(energy / total) or 0,
    hot_ratio = (total > 0) and (hot / total) or 0,
  }
end

--- Wrap a raw PCM file in a WAV header, written to `out`.
-- `skip_bytes` drops that much from the front, which is how the count-in is
-- thrown away: capture starts while "3… 2… 1…" is still on screen, so the
-- device is already open and warm by the time the user speaks.
-- Returns the duration in seconds, or nil if there was nothing to wrap.
function M.pcm_to_wav(path, out, skip_bytes)
  local f = io.open(path, "rb")
  if not f then return nil end
  local skip = math.floor(tonumber(skip_bytes) or 0)
  if skip > 0 then
    if skip % 2 == 1 then skip = skip - 1 end   -- never start mid-sample
    f:seek("set", skip)
  end
  local data = f:read("*a")
  f:close()
  if not data or #data < 2 then return nil end
  if #data % 2 == 1 then data = data:sub(1, #data - 1) end   -- drop a half sample
  local function p16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
  local function p32(v) return string.char(v % 256, math.floor(v / 256) % 256,
                                           math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
  local block = M.PCM_CHANNELS * (M.PCM_BITS / 8)
  local w = io.open(out, "wb")
  if not w then return nil end
  w:write("RIFF", p32(36 + #data), "WAVE",
          "fmt ", p32(16), p16(1), p16(M.PCM_CHANNELS), p32(M.PCM_RATE),
          p32(M.PCM_RATE * block), p16(block), p16(M.PCM_BITS),
          "data", p32(#data), data)
  w:close()
  return #data / pcm_byte_rate()
end

--- Split a script into segments on line breaks.
--
-- Line breaks are the only delimiter, deliberately. The TTS service handles
-- long input itself, so there is no reason to guess at sentence boundaries or
-- chunk sizes here — a script with no line breaks is one segment and one
-- request. Writers already break their scripts where the beats are, and that
-- is a better signal than anything inferred.
--
-- Blank lines collapse rather than producing empty segments, so text separated
-- by single or double line breaks both behave the way it looks.
function M.split_lines(text)
  local out = {}
  for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    line = M.trim(line)
    if line ~= "" then out[#out + 1] = line end
  end
  return out
end

--- Split one segment into sentences, for users who want finer control.
-- Abbreviations are not handled; splitting is a user-visible action they can
-- undo by merging, so a wrong guess is cheap.
function M.split_sentences(text)
  local out = {}
  for piece in (M.trim(text) .. " "):gmatch("(.-[%.%?!]+[\"')%]]*)%s+") do
    piece = M.trim(piece)
    if piece ~= "" then out[#out + 1] = piece end
  end
  local consumed = table.concat(out, " ")
  local rest = M.trim(M.trim(text):sub(#consumed + 1))
  if rest ~= "" then out[#out + 1] = rest end
  if #out == 0 then out[1] = M.trim(text) end
  return out
end

--- Make a string safe for use as a filename component.
--- The first few words of a line, joined for a file or clip name:
-- "Welcome back to the channel!" → "Welcome_back_to_the".
--- Does this codepoint belong to a script that writes without spaces?
-- Chinese, Japanese kana and Thai run words together, so a "word" cannot be
-- found by splitting on spaces and each character has to count for itself.
-- Cyrillic, Greek, Arabic, Hebrew and Hangul all use spaces and are words like
-- any other — the test is the script, not whether the bytes are multi-byte.
local function is_ideographic(cp)
  return (cp >= 0x3040 and cp <= 0x30FF)     -- hiragana, katakana
      or (cp >= 0x3400 and cp <= 0x4DBF)     -- CJK extension A
      or (cp >= 0x4E00 and cp <= 0x9FFF)     -- CJK unified ideographs
      or (cp >= 0xF900 and cp <= 0xFAFF)     -- CJK compatibility
      or (cp >= 0xFF66 and cp <= 0xFF9D)     -- half-width katakana
      or (cp >= 0x0E00 and cp <= 0x0E7F)     -- Thai
end
M.is_ideographic = is_ideographic

--- Is this codepoint punctuation rather than a letter?
-- Covers ASCII punctuation and the full-width and CJK marks that sit between
-- characters in Chinese and Japanese — 。、，！？「」and the rest.
local function is_punct(cp)
  if cp == 39 then return false end          -- an apostrophe is inside a word
  if cp < 128 then return not (cp >= 48 and cp <= 57)
                      and not (cp >= 65 and cp <= 90)
                      and not (cp >= 97 and cp <= 122) end
  return (cp >= 0x2000 and cp <= 0x206F)     -- general punctuation
      or (cp >= 0x3000 and cp <= 0x303F)     -- CJK symbols and punctuation
      or (cp >= 0xFF00 and cp <= 0xFF0F)     -- full-width ASCII punctuation
      or (cp >= 0xFF1A and cp <= 0xFF20)
      or (cp >= 0xFF3B and cp <= 0xFF40)
      or (cp >= 0xFF5B and cp <= 0xFF65)
end
M.is_punct = is_punct

--- The opening of a line, for a clip or file name.
-- Scripts that separate words with spaces give up whole words. Scripts that do
-- not — Chinese, Japanese, Thai — have no words to give, so their characters
-- count as half a word each: four English words and eight Chinese characters
-- carry about the same amount of a sentence, and naming every clip after one
-- syllable helps nobody. A line that mixes the two spends one budget across
-- both, so "iPhone 拍摄的日落" does not get filed as "iPhone".
function M.clip_words(text, count)
  count = count or 4
  local clean = M.strip_tags(tostring(text or ""))
  local parts, used, word = {}, 0, {}

  local function flush()
    if #word > 0 then
      -- "It's" is one word and reads better in a filename without the mark.
      local w = table.concat(word):gsub("'", "")
      word = {}
      if w ~= "" then
        parts[#parts + 1] = w
        used = used + 1
      end
    end
  end

  for i, ch in M.utf8_chars(clean) do
    if used >= count then break end
    local cp = M.utf8_codepoint(clean, i)
    if is_punct(cp) then
      flush()                                -- a space or a mark ends a word
    elseif is_ideographic(cp) then
      flush()
      parts[#parts + 1] = ch                 -- one character, half a word
      used = used + 0.5
    else
      word[#word + 1] = ch                   -- a letter in a spaced script
    end
  end
  flush()

  if #parts == 0 then return "take" end
  -- Characters run together; words are separated. A single ideographic
  -- character is a `part` of one character, which is how they are told apart.
  local function is_char_part(x)
    return M.utf8_len(x) == 1 and is_ideographic(M.utf8_codepoint(x, 1))
  end
  local out = parts[1]
  for i = 2, #parts do
    local sep = (is_char_part(parts[i - 1]) or is_char_part(parts[i])) and "" or "_"
    out = out .. sep .. parts[i]
  end
  return out
end

--- Make a string safe for use as a filename component.
-- Lua's `%w` is ASCII, so the old rule ("keep word characters") deleted every
-- Chinese, Japanese, Korean, Cyrillic, Greek and accented character and left
-- nothing to name the file with. Modern filesystems store filenames as
-- Unicode, so the honest rule is the opposite: keep everything except what a
-- filesystem actually refuses.
function M.sanitize(name)
  local s = tostring(name or "")
  -- Characters any common filesystem refuses (clips may sit on shared or
  -- external drives, not only APFS), plus control bytes.
  s = s:gsub('[<>:"/\\|%?%*]', ""):gsub("%c", "")
  s = s:gsub("%s+", "_"):gsub("_+", "_")
  -- Some filesystems also refuse a trailing dot or space.
  s = s:gsub("^[%._]+", ""):gsub("[%._]+$", "")
  -- Cut on a character boundary: a byte cut corrupts the last codepoint.
  if #s > 48 then s = s:sub(1, M.utf8_floor(s, 49) - 1) end
  return s
end

------------------------------------------------------------------------ utf8

-- Lua strings are bytes and Resolve's interpreter has no utf8 library, so text
-- handling has to decode UTF-8 by hand. Splitting a string mid-codepoint
-- corrupts it, which matters the moment a script is not plain ASCII.

--- Byte length of the UTF-8 sequence starting at byte i.
function M.utf8_seq_len(s, i)
  local b = s:byte(i)
  if not b then return 0 end
  if b < 0x80 then return 1 end
  if b >= 0xF0 then return 4 end
  if b >= 0xE0 then return 3 end
  if b >= 0xC0 then return 2 end
  return 1  -- continuation byte encountered out of place; treat as one byte
end

--- Is byte i the start of a character (not a continuation byte)?
function M.utf8_is_start(s, i)
  local b = s:byte(i)
  return b ~= nil and (b < 0x80 or b >= 0xC0)
end

--- Number of characters, not bytes.
function M.utf8_len(s)
  local n, i, len = 0, 1, #s
  while i <= len do
    i = i + M.utf8_seq_len(s, i)
    n = n + 1
  end
  return n
end

--- Iterate characters as (byte_index, char).
function M.utf8_chars(s)
  local i, len = 1, #s
  return function()
    if i > len then return nil end
    local start = i
    local n = M.utf8_seq_len(s, i)
    i = i + n
    return start, s:sub(start, start + n - 1)
  end
end

--- Nearest byte index at or before `i` that starts a character.
-- Use before cutting a string at an arbitrary byte offset.
function M.utf8_floor(s, i)
  if i < 1 then return 1 end
  if i > #s then return #s + 1 end
  while i > 1 and not M.utf8_is_start(s, i) do i = i - 1 end
  return i
end

--- Codepoint of the character starting at byte i.
function M.utf8_codepoint(s, i)
  local n = M.utf8_seq_len(s, i)
  local b1 = s:byte(i)
  if n == 1 then return b1 end
  if n == 2 then return (b1 - 0xC0) * 64 + (s:byte(i + 1) - 0x80) end
  if n == 3 then
    return (b1 - 0xE0) * 4096 + (s:byte(i + 1) - 0x80) * 64 + (s:byte(i + 2) - 0x80)
  end
  return (b1 - 0xF0) * 262144 + (s:byte(i + 1) - 0x80) * 4096
       + (s:byte(i + 2) - 0x80) * 64 + (s:byte(i + 3) - 0x80)
end

-------------------------------------------------------------------------- id

local id_counter = 0

--- Short unique id for segments and takes.
-- Resolve gives us no randomness source beyond os.time/os.clock, so ids combine
-- time, a process-lifetime counter and math.random, which is enough for keys
-- that only need to be unique within one project.
function M.new_id()
  id_counter = id_counter + 1
  return string.format("%x%03x%03x", os.time() % 0xFFFFFF, id_counter % 0xFFF,
                       math.random(0, 0xFFF))
end

--- Seconds as m:ss — a counter, not a timeline position.
function M.format_clock(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

--- Seconds as m:ss.t — the form editors read on a timeline.
function M.format_duration(seconds)
  seconds = tonumber(seconds) or 0
  local m = math.floor(seconds / 60)
  local s = seconds - m * 60
  return string.format("%d:%04.1f", m, s)
end

return M
