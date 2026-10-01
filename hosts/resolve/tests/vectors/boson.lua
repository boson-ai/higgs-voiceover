--- Vectors for the pure parts of api.lua: constants, request building,
-- what a response means (every error path), timestamped responses, retries,
-- voice names — plus util.lua's base64, which carries the audio both ways.
--
-- Nothing here reaches the network: requests are captured from a fake
-- client, responses are written to temporary files the way curl leaves them,
-- and curl itself is never run. Keys are fake. Bytes travel as base64.

local A = require("higgs.api")
local P = require("higgs.platform")
local U = require("higgs.util")

local cases = {}
local function case(name, fn, input, expect)
  cases[#cases + 1] = { name = name, fn = fn, input = input, expect = expect }
end

local function upvalue(fn, name)
  for i = 1, 60 do
    local n, v = debug.getupvalue(fn, i)
    if n == nil then break end
    if n == name then return v end
  end
  error("no upvalue " .. name)
end
local interpret = upvalue(A._finish, "interpret")
local friendly_error = upvalue(interpret, "friendly_error")
local short_url = upvalue(A._finish, "short_url")
local should_retry = upvalue(A.poll, "should_retry")

local function bytes(s) local t = {} for i = 1, #s do t[i] = s:byte(i) end return t end

------------------------------------------------------------------ constants

for _, k in ipairs({ "BASE_URL", "MODEL", "MAX_INPUT_CHARS", "PRICE_PER_1K_CHARS", "PRESET_VOICES",
                     "REF_MIN_SECONDS", "REF_MAX_SECONDS", "REF_MAX_BYTES", "RETRY_DELAYS" }) do
  case("constant " .. k, k, { none = true }, A[k])
end

------------------------------------------------------------------ cost

for _, n in ipairs({ 0, 1, 1000, 1234, 5000, 1000000 }) do
  case("cost_for " .. n, "cost_for", { chars = n }, A.cost_for(n))
end
case("cost_for nothing", "cost_for", { none = true }, A.cost_for(nil))
case("cost_for text", "cost_for", { chars = "2000" }, A.cost_for("2000"))
for _, usd in ipairs({ 0, 0.000015, 0.00015, 0.0099, 0.00999, 0.01, 0.015, 0.125, 1.234, 75 }) do
  case("format_cost " .. usd, "format_cost", { usd = usd }, A.format_cost(usd))
end

------------------------------------------------------------------ small helpers

for _, u in ipairs({ "https://api.boson.ai/v1/audio/speech", "https://x.test/a?key=secret&b=2", "", "?only" }) do
  case("short_url " .. u, "short_url", { url = u }, short_url(u))
end
for _, id in ipairs({ "nora", "eleanor", "chloe", "marcus", "oliver", "jake", "default", "Nora", "voice_abc", "" }) do
  case("is_preset " .. id, "is_preset", { id = id }, A.is_preset(id))
end
case("is_preset nothing", "is_preset", { none = true }, A.is_preset(nil))

for _, c in ipairs({
  { "the description is the name", { voice = "voice_ab", description = "Alex — narration" } },
  { "a padded description is trimmed", { voice = "voice_ab", description = "  Alex \n" } },
  { "a name when there is no description", { voice = "voice_ab", name = "Old name" } },
  { "a local name survives a blank description", { voice = "voice_ab", description = "  " }, "Alex" },
  { "a local name survives no description", { voice = "voice_ab" }, "Alex" },
  { "a local name that is only the id does not", { voice = "voice_ab", created_at = "2026-09-17T01:02:03Z" }, "voice_ab" },
  { "an empty local name does not", { voice = "voice_ab", created_at = "2026-01-05" }, "" },
  { "the date drops a leading zero", { created_at = "2025-03-09T00:00:00Z" } },
  { "an impossible month is shown as written", { created_at = "2026-13-01" } },
  { "a date it cannot read", { created_at = "yesterday" } },
  { "never the raw id", { voice = "voice_ab" } },
}) do case("voice_label: " .. c[1], "voice_label", { voice = c[2], existing = c[3] }, A.voice_label(c[2], c[3])) end

------------------------------------------------------------------ friendly_error

for _, c in ipairs({
  { "", "" }, { "", "curl: (6) Could not resolve host: api.boson.ai" },
  { "", "curl: (28) Operation timed out after 300000 milliseconds" }, { "", "Operation too slow" },
  { "", "TIMEOUT" },
  { "401", "Invalid API key" },
  { "402", "Payment required" }, { "402", "" },
  { "403", "Forbidden" }, { "403", "Insufficient BALANCE" }, { "403", "quota exceeded" },
  { "404", "Voice not found" }, { "404", "Not Found" },
  { "413", "Payload too large" },
  { "422", "Invalid voice id" }, { "422", "input:\n  must be  at most 5000 characters" },
  { "422", "" }, { "422", "   " },
  { "422", "The request body could not be validated because " .. string.rep("field after field ", 10) },
  { "400", "timestamps_streaming_unsupported" }, { "400", "unknown VOICE" },
  { "429", "Too many requests" }, { "429", "insufficient credit balance" }, { "429", "Quota" },
  { "500", "Internal Server Error" }, { "502", "<html>Bad Gateway</html>" }, { "503", "" },
  { "418", "I'm a teapot" }, { "418", "" }, { "000", "" }, { "302", "  moved\n\there " },
  { "422", "Ungültige Stimme: «nora»" },
}) do
  case(("friendly_error %s %q"):format(c[1] == "" and "none" or c[1], c[2]), "friendly_error",
       { code = c[1], raw = c[2] }, friendly_error(c[1], c[2]))
end
case("friendly_error with no text", "friendly_error", { code = "418" }, friendly_error("418", nil))

------------------------------------------------------------------ interpret

local dir_base = os.tmpname()   -- os.tmpname creates the file; removed below
local dir = dir_base .. "-vectors"
P.mkdirs(dir)
local function interp(name, status, body, err, expect)
  local base = P.join(dir, "job")
  local paths = { cfg = base .. ".cfg", body = base .. ".body.json", out = base .. ".out",
                  status = base .. ".status", err = base .. ".err", marker = base .. ".done" }
  if status then U.write_file(paths.status, status) end
  if body then U.write_file(paths.out, body) end
  if err then U.write_file(paths.err, err) end
  local out_path = P.join(dir, "take.wav")
  os.remove(out_path)
  local res = interpret({ paths = paths, expect = expect, out_path = out_path })
  if res.path then
    res.audio = U.b64_encode(U.read_file(res.path) or "")
    res.path = nil
    os.remove(out_path)
  end
  case("interpret: " .. name, "interpret",
       { code = status, body = body, err = err, expect = expect }, res)
end

local timed = '{"audio":"' .. U.b64_encode("RIFFdata") .. '","response_format":"wav","input":"Hi there.",'
           .. '"timestamps":[{"word":"Hi","start":0.08,"end":0.3},{"word":"there","start":0.32,"end":0.7}]}'

interp("no answer at all (000) reads as no connection", "000", "", "curl: (6) Could not resolve host: api.boson.ai", "binary")
interp("no status at all", nil, nil, nil, "json")
interp("a timeout", "000", nil, "curl: (28) Operation timed out after 300000 milliseconds\n", "binary")
interp("a status with stray whitespace", " 200\n", '{"data":[{"voice":"voice_1","description":"A"}],"object":"list"}', nil, "json")
interp("JSON that is not JSON", "200", "<html>ok</html>", nil, "json")
interp("a JSON list is still JSON", "201", '[1,2,3]', nil, "json")
interp("an empty JSON body", "200", "", nil, "json")
interp("speech audio", "200", "RIFFxxxxWAVE", nil, "binary")
interp("a downloaded file", "200", "PK\3\4zip", nil, "file")
interp("no audio", "200", "", nil, "binary")
interp("timestamped speech", "200", timed, nil, "speech_json")
interp("timestamped speech without alignment", "200", '{"audio":"' .. U.b64_encode("RIFF") .. '","timestamps":null}', nil, "speech_json")
interp("timestamped speech without audio", "200", '{"error":"x"}', nil, "speech_json")
interp("timestamped speech with empty audio", "200", '{"audio":"","timestamps":[]}', nil, "speech_json")
interp("a rejected key", "401", '{"error":{"message":"Invalid API key","type":"auth"}}', nil, "binary")
interp("payment required", "402", '{"error":"Payment required"}', nil, "binary")
interp("payment required with no body", "402", "", nil, "binary")
interp("out of credit in a message field", "403", '{"message":"insufficient credit"}', nil, "binary")
interp("a plan without TTS", "403", '{"error":{"message":"forbidden"}}', nil, "binary")
interp("a missing voice says what to do", "404", '{"error":"voice not found"}', nil, "binary")
interp("too long", "413", "<html><body>413 Request Entity Too Large</body></html>", nil, "binary")
interp("a validation error in FastAPI's shape", "422",
       '{"detail":[{"loc":["body","input"],"msg":"String should have at most 5000 characters","type":"string_too_long"}]}', nil, "binary")
interp("a voice the service would not take", "422", '{"error":{"message":"Invalid voice id"}}', nil, "binary")
interp("an error object without a message", "400", '{"error":{"code":5}}', nil, "binary")
interp("an empty message falls back to the body", "400", '{"error":"","message":"x"}', nil, "binary")
interp("too many requests", "429", '{"error":"Too many requests"}', nil, "binary")
interp("out of credit is not a rate limit", "429", '{"error":"insufficient credit balance"}', nil, "binary")
interp("a server error", "500", "Internal Server Error", nil, "binary")
interp("a gateway error page", "502", "<html>\n<head><title>502 Bad Gateway</title></head>\n</html>", nil, "speech_json")
interp("an unknown status with a long body", "418", string.rep("teapot ", 60), nil, "binary")
interp("an unknown status with nothing", "418", "", nil, "json")

os.execute("rm -rf " .. P.quote(dir))
os.remove(dir_base)

------------------------------------------------------------------ unpack_timed

local function unpack(name, raw)
  local audio, words = A.unpack_timed(raw)
  case("unpack_timed: " .. name, "unpack_timed", { raw = raw },
       audio and { audio = U.b64_encode(audio), words = words } or nil)
end
unpack("audio and words", timed)
unpack("no alignment is nil, not empty", '{"audio":"' .. U.b64_encode("x") .. '","timestamps":null}')
unpack("an empty list is nil too", '{"audio":"' .. U.b64_encode("x") .. '","timestamps":[]}')
unpack("no timestamps field", '{"audio":"' .. U.b64_encode("xyz") .. '"}')
unpack("escaped slashes in the audio are undone", '{"input":"x","audio":"TW\\/u"}')
unpack("spaces around the colon", '{ "audio" :\n "TWFu" , "timestamps" : [ {"word":"a","start":0,"end":1} ] }')
unpack("audio last", '{"timestamps":[{"word":"Hi","start":0.1,"end":0.2}],"audio":"TWFu"}')
unpack("times given as text", '{"audio":"TWFu","timestamps":[{"word":"x","start":"0.5","end":"1.25"}]}')
unpack("a word without times is skipped", '{"audio":"TWFu","timestamps":[{"word":"a"},{"word":"b","start":1,"end":2}]}')
unpack("a time without a word is skipped", '{"audio":"TWFu","timestamps":[{"start":1,"end":2},{"word":"c","start":2,"end":3}]}')
unpack("nothing usable is nil", '{"audio":"TWFu","timestamps":[{"word":"a"},{"start":1}]}')
unpack("a number as a word", '{"audio":"TWFu","timestamps":[{"word":5,"start":1,"end":2}]}')
unpack("CJK words, one per character", '{"audio":"TWFu","timestamps":[{"word":"你","start":0,"end":0.2},{"word":"好","start":0.2,"end":0.4}]}')
unpack("a null entry is skipped", '{"audio":"TWFu","timestamps":[null,{"word":"d","start":0,"end":1}]}')
unpack("timestamps that are not a list", '{"audio":"TWFu","timestamps":{"word":"a","start":0,"end":1}}')
unpack("a cut-off envelope still gives its audio", '{"audio":"TWFu","timestamps":[{"word":"a","sta')
unpack("no audio field is nil", '{"error":"x"}')
unpack("an unclosed audio string is nil", '{"audio":"TWFu')
unpack("not JSON at all", "RIFF....WAVE")
unpack("base64 with line breaks", '{"audio":"TW\\nFu\\r\\nTWE="}')

------------------------------------------------------------------ retries

for _, c in ipairs({
  { "a rate limit is retried", { ok = false, code = "429", error = "Too many requests at once. Wait a few seconds and try again." }, 0 },
  { "the second time too", { ok = false, code = "429", error = "Too many requests" }, 1 },
  { "and the third", { ok = false, code = "429", error = "Too many requests" }, 2 },
  { "but not a fourth", { ok = false, code = "429", error = "Too many requests" }, 3 },
  { "out of credit is not retried", { ok = false, code = "429", error = "Your Boson account is out of credit. Top up at boson.ai." }, 0 },
  { "other failures are not retried", { ok = false, code = "500", error = "x" }, 0 },
  { "no connection is not retried", { ok = false, code = "", error = "x" }, 0 },
  { "success is not retried", { ok = true, code = "200" }, 0 },
  { "no count yet is the first try", { ok = false, code = "429", error = "slow down" }, nil },
}) do
  case("should_retry: " .. c[1], "should_retry", { res = c[2], retries = c[3] }, should_retry({ retries = c[3] }, c[2]))
end

------------------------------------------------------------------ requests

-- A client whose queue only records what it was given.
local function capture(method, spec)
  local got, done
  local fake = { request = function(_, r) got = r return r end }
  spec.on_done = function(res) done = res end
  method(fake, spec)
  spec.on_done = nil
  if got then
    local r = { method = got.method, path = got.path, url = A.BASE_URL .. got.path, expect = got.expect,
                label = got.label, meta = got.meta, body = got.body }
    return { ok = true, request = r }, got
  end
  return done
end

local function speech(name, spec)
  local input = {}
  for k, v in pairs(spec) do input[k] = v end
  case("speech: " .. name, "speech", input, (capture(A.speech, spec)))
end
speech("a plain line", { text = "Hello there.", voice = "nora" })
speech("with no voice the body says default and the log says cloned", { text = "Hi." })
speech("a cloned voice is not named in the log", { text = "Hi.", voice = "voice_0123abcd" })
speech("word timings ask for JSON", { text = "Hi.", voice = "jake", timestamps = true })
speech("another format and a label", { text = "Hi.", voice = "default", format = "mp3", label = "speech 3/12" })
speech("an empty line", { text = "", voice = "nora" })
speech("a line of spaces", { text = "  \n\t", voice = "nora" })
speech("no text at all", { voice = "nora" })
speech("one over the limit", { text = string.rep("a", A.MAX_INPUT_CHARS + 1) })
speech("characters, not bytes, count", { text = string.rep("你", 2000) })
speech("tags count as characters", { text = "<|emotion:awe|> " .. string.rep("b", 4984) })

local ref_base = os.tmpname()
local ref = ref_base .. ".wav"
local function create(name, spec, audio)
  local input = {}
  for k, v in pairs(spec) do input[k] = v end
  if type(audio) == "string" then
    U.write_file(ref, audio)
    spec.ref_audio_path = ref
    input.audio = U.b64_encode(audio)
  elseif type(audio) == "number" then
    U.write_file(ref, string.rep("\0", audio))
    spec.ref_audio_path = ref
    input.audio_zeros = audio
  else
    spec.ref_audio_path = ref .. ".missing"
  end
  case("create_voice: " .. name, "create_voice", input, (capture(A.create_voice, spec)))
end
create("name and transcript", { name = "Alex — narration", ref_text = "Hello, this is me." }, "RIFF\0\1\2\3WAVE")
create("no name is Voice", { ref_text = "Hi." }, "RIFFabc")
create("no transcript is a single stop", { name = "A" }, "RIFFabc")
create("a blank transcript too", { name = "A", ref_text = "  \n" }, "RIFFabc")
create("a transcript keeps its own spacing", { name = "A", ref_text = "  spaced  " }, "RIFFabc")
create("a missing recording", { name = "A" }, nil)
create("just over the size limit", { name = "A" }, A.REF_MAX_BYTES + 1)
create("well over it", { name = "A" }, 12345678)
create("exactly at the limit is fine", { name = "A" }, A.REF_MAX_BYTES)
os.remove(ref)
os.remove(ref_base)
-- The 10 MB case's base64 would swamp the file; its body is checked by size.
for _, c in ipairs(cases) do
  if c.fn == "create_voice" and c.input.audio_zeros and c.expect.ok then
    c.expect.request.body.ref_audio = ("<%d base64 characters>"):format(#c.expect.request.body.ref_audio)
  end
end

case("list_voices", "list_voices", { none = true }, (capture(A.list_voices, {})))
do
  local outer, got = capture(A.test, {})
  case("test", "test", { none = true }, outer)
  for _, c in ipairs({
    { "voices in a data list", { ok = true, code = "200", data = { data = { { voice = "a" }, { voice = "b" }, { voice = "c" } } } } },
    { "voices in a voices list", { ok = true, code = "200", data = { voices = { { voice = "a" } } } } },
    { "a bare list", { ok = true, code = "200", data = { { voice = "a" }, { voice = "b" } } } },
    { "a record with no list", { ok = true, code = "200", data = { object = "list" } } },
    { "a list that is not a list", { ok = true, code = "200", data = { data = "none" } } },
    { "a failure", { ok = false, code = "401", error = "That API key was rejected. Check it in Settings." } },
  }) do
    local out
    local spec = { on_done = function(r) out = r end }
    -- M:test wraps the caller's on_done; call the wrapper the way poll would.
    local fake = { request = function(_, r) got = r return r end }
    A.test(fake, spec)
    got.on_done(c[2])
    case("test outcome: " .. c[1], "test_outcome", { res = c[2] }, out)
  end
end

------------------------------------------------------------------ transport

local tdir_base = os.tmpname()
local tdir = tdir_base .. "-transport"
local saved = { async = P.supports_async, run = P.run_detached, version = _G.HIGGS_VO_VERSION }
local cmd
P.supports_async = function() return true end
P.run_detached = function(c) cmd = c return true end
_G.HIGGS_VO_VERSION = "1.2.3"
local function transport(name, key, spec, version)
  _G.HIGGS_VO_VERSION = version
  cmd = nil
  local res
  spec.on_done = function(r) res = r end
  local api = A.new({ get_key = function() return key end, tmp_dir = tdir })
  local job = spec.url and api:fetch(spec) or api:request(spec)
  local out
  if res then
    out = { refused = res }
  else
    local headers = {}
    for line in (U.read_file(job.paths.cfg) or ""):gmatch("[^\n]+") do
      local ua = line:match('^user%-agent = "(.*)"$')
      if ua then headers["User-Agent"] = ua end
      local k, v = line:match('^header = "([^:]+): (.*)"$')
      if k then headers[k] = v end
    end
    out = { headers = headers, follow_redirects = cmd:find(" -L ", 1, true) ~= nil }
  end
  case("transport: " .. name, "transport",
       { key = key, no_auth = spec.url ~= nil, has_body = spec.body ~= nil, version = version }, out)
end
transport("a Boson request carries the key", "bai-test-0000-fake", { method = "GET", path = "/audio/voices" }, "1.2.3")
transport("a body adds its type", "bai-test-0000-fake", { method = "POST", path = "/audio/speech", body = { input = "x" } }, "1.2.3")
transport("quotes and backslashes never reach the header", 'bai-te"st\\fake', { method = "GET", path = "/audio/voices" }, "1.2.3")
transport("a public request never carries it and follows redirects", "bai-test-0000-fake",
          { url = "https://api.github.com/repos/x/y/releases/latest" }, "1.2.3")
transport("without a version it is dev", "bai-test-0000-fake", { method = "GET", path = "/audio/voices" }, nil)
transport("no key, no request", "", { method = "GET", path = "/audio/voices" }, "1.2.3")
transport("no key is fine for a public request", "", { url = "https://example.test/file.json" }, "1.2.3")
P.supports_async, P.run_detached, _G.HIGGS_VO_VERSION = saved.async, saved.run, saved.version
os.execute("rm -rf " .. P.quote(tdir))
os.remove(tdir_base)

------------------------------------------------------------------ base64

for _, s in ipairs({ "", "M", "Ma", "Man", "Many", "RIFF\0\255\128\7\9", string.char(0, 0, 0), string.char(251, 255, 191) }) do
  case("b64_encode of " .. #s .. " bytes", "b64_encode", { bytes = bytes(s) }, U.b64_encode(s))
end
for _, s in ipairs({ "TWFu", "TWE=", "TQ==", "TQ", "TWE", "T", "", "TW\nFu", "TW Fu\r\n", "TW!!Fu", "AP+A/w==",
                     "TQ==TWFu", "////", "=", "4pyTIMOgIGxhIG1vZGU=" }) do
  case("b64_decode " .. s:gsub("[\r\n]", "~"), "b64_decode", { s = s }, bytes(U.b64_decode(s)))
end

return {
  about = "Boson API: requests, error wording, timestamped responses, retries, voice names; base64.",
  source = "src/higgs/api.lua",
  cases = cases,
}
