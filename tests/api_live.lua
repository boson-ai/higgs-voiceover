--- Live checks against Boson's API: speech in every format, word timestamps
-- in each language they cover, the error paths users meet, the request
-- queue, and how the API key is handled on this machine.
--
--   fuscript -l lua tests/api_live.lua
--
-- Uses the API key saved by the app on this Mac (read only — nothing is
-- written back), or HIGGS_TEST_KEY. Costs a few cents of credit: every line
-- is short. Resolve may be closed. The key is never printed.

_G.HIGGS_VO_NO_AUTORUN = true
dofile("Higgs VoiceOver.lua")

local P      = require("higgs.platform")
local U      = require("higgs.util")
local Config = require("higgs.config")
local Api    = require("higgs.api")
local Log    = require("higgs.log")
local Subs   = require("higgs.subtitles")

local passed, failed, notes = 0, 0, {}
local function check(label, cond, detail)
  if cond then passed = passed + 1; print("  ok    " .. label)
  else failed = failed + 1; print("  FAIL  " .. label .. (detail and ("  -> " .. tostring(detail)) or "")) end
end
local function note(text) notes[#notes + 1] = text; print("  ..    " .. text) end

local cfg = Config.load()
local KEY = os.getenv("HIGGS_TEST_KEY") or Config.get_api_key(cfg)
if KEY == "" then print("No API key: save one in the app or set HIGGS_TEST_KEY.") os.exit(1) end

local real_dir = Config.dir()
local work = P.join(os.getenv("TMPDIR") or "/tmp", "higgsvo-apilive-" .. os.time())
P.mkdirs(work)
P.make_private(work)
-- This run's log goes to the scratch folder, not among the app's own.
P.config_dir = function() return P.join(work, "config") end
P.mkdirs(P.join(work, "config", "logs"))
Log.start()

local function new_api(key)
  local a = Api.new({ get_key = function() return key end, tmp_dir = P.join(work, "tmp") })
  return a
end

--- Run one request to completion (the app polls the same way).
local function wait(api, start)
  local res
  start(function(r) res = r end)
  local t0 = os.time()
  while not res and os.time() - t0 < 120 do api:poll(); bmd.wait(0.05) end
  return res or { ok = false, error = "timed out in the test" }
end

local function speech(api, text, extra)
  local spec = { text = text, voice = "nora", format = "wav", out_path = P.join(work, ("s%d.%s"):format(math.random(1, 1e9), (extra and extra.format) or "wav")) }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return wait(api, function(done) spec.on_done = done; api:speech(spec) end)
end

local function head(path, n)
  local f = io.open(path, "rb"); if not f then return "" end
  local b = f:read(n or 16) or ""; f:close(); return b
end

local api = new_api(KEY)

----------------------------------------------------------------- key handling
print("\nAPI key on this machine")
do
  -- Watch the command curl is started with, and the process list while it runs.
  local real = P.run_detached
  local seen_cmd
  P.run_detached = function(cmd) seen_cmd = cmd; return real(cmd) end
  local res
  api:speech({ text = "Checking how the key travels.", voice = "nora", format = "wav",
               out_path = P.join(work, "key.wav"), on_done = function(r) res = r end })
  local ps = P.run_capture("ps -axww -o command") or ""
  local cfg_file
  for _, f in ipairs({ P.join(work, "tmp", "job_1.cfg") }) do if P.exists(f) then cfg_file = f end end
  local mode = cfg_file and (P.run_capture("stat -f %Lp " .. P.quote(cfg_file)) or ""):gsub("%s", "")
  local dir_mode = (P.run_capture("stat -f %Lp " .. P.quote(work)) or ""):gsub("%s", "")
  local t0 = os.time()
  while not res and os.time() - t0 < 60 do api:poll(); bmd.wait(0.05) end
  P.run_detached = real
  check("the key is not on curl's command line", seen_cmd and not seen_cmd:find(KEY, 1, true), "")
  check("curl reads it from a config file (-K)", seen_cmd and seen_cmd:find(" -K ", 1, true) ~= nil)
  check("no running process shows the key", not ps:find(KEY, 1, true))
  check("the folder holding that file is private to the user", dir_mode == "700", dir_mode)
  if mode then note("curl config file mode while in flight: " .. mode .. " (inside the private folder)") end
  check("the request went through", res and res.ok, res and res.error)
  local left = {}
  for f in (P.run_capture("ls " .. P.quote(P.join(work, "tmp")) .. " 2>/dev/null") or ""):gmatch("[^\n]+") do left[#left + 1] = f end
  check("nothing is left in the scratch folder afterwards", #left == 0, table.concat(left, ", "))
  check("a Boson request never follows redirects", seen_cmd and not seen_cmd:find(" -L", 1, true))
  local cfg_mode = (P.run_capture("stat -f %Lp " .. P.quote(real_dir)) or ""):gsub("%s", "")
  check("the app's settings folder is private to the user", cfg_mode == "700", cfg_mode)
end

print("\nno key, bad key")
do
  local none = new_api("")
  local r = speech(none, "Hello.")
  check("no key: refused before any request", not r.ok and r.code == "nokey", r.code)
  local bad = new_api("sk-not-a-real-key-000000000000")
  r = speech(bad, "Hello.")
  check("a wrong key is answered 401", r.code == "401", r.code)
  check("and told in plain words", r.error and r.error:find("rejected", 1, true) ~= nil, r.error)
  local q = new_api('sk-a"b\\c')
  r = speech(q, "Hello.")
  check("quotes in a key cannot break curl's config", r.code == "401", r.code .. " " .. tostring(r.error))
end

---------------------------------------------------------------------- speech
print("\nspeech")
do
  local r = speech(api, "Welcome back to the channel. Today we are grading a sunset timelapse.")
  check("wav: generated", r.ok, r.error)
  check("wav: a RIFF/WAVE file", r.ok and head(r.path, 12):sub(1, 4) == "RIFF" and head(r.path, 12):sub(9, 12) == "WAVE")
  local secs = r.ok and U.wav_seconds(r.path)
  check("wav: a plausible length", secs and secs > 2 and secs < 15, secs)
  for _, f in ipairs({ { "mp3", function(h) return h:sub(1, 3) == "ID3" or (h:byte(1) == 0xFF and h:byte(2) >= 0xE0) end },
                       { "flac", function(h) return h:sub(1, 4) == "fLaC" end },
                       { "aac", function(h) return (h:byte(1) == 0xFF and (h:byte(2) == 0xF1 or h:byte(2) == 0xF9)) or h:sub(5, 8) == "ftyp" end } }) do
    local rf = speech(api, "One short line for the format check.", { format = f[1] })
    check(f[1] .. ": generated and looks like " .. f[1], rf.ok and f[2](head(rf.path, 12)), rf.error or ("head " .. U.b64_encode(head(rf.path, 8))))
  end
  local long = ("This sentence is here to make a longer line. "):rep(30)
  r = speech(api, long)
  check("a 1,350-character line", r.ok, r.error)
  local over = ("x"):rep(Api.MAX_INPUT_CHARS + 1)
  local sent = false
  local real = P.run_detached
  P.run_detached = function(cmd) sent = true; return real(cmd) end
  r = speech(api, over)
  P.run_detached = real
  check("over 5,000 characters is refused before sending", not r.ok and not sent, r.error)
  r = speech(api, "Unicode test: café, naïve, 日本語, 👋 done.")
  check("accents, CJK and an emoji in one line", r.ok, r.error)
  r = speech(api, "Hello.", { voice = "voice_0000000000000000000000000000000000000000000000000000000000000000" })
  check("an unknown voice fails", not r.ok, r.code)
  note("unknown voice answered " .. tostring(r.code) .. ": " .. tostring(r.error))
end

---------------------------------------------------------------- timestamps
print("\nword timestamps")
local function timed(text, label)
  local r = speech(api, text, { timestamps = true })
  if not r.ok then check(label .. ": generated", false, r.error) return end
  check(label .. ": generated with timestamps", r.ok)
  local secs = U.wav_seconds(r.path) or 0
  local words = r.words or {}
  note(("%s: %d words, %.2f s audio"):format(label, #words, secs))
  local mono, inside = true, true
  for i, w in ipairs(words) do
    if i > 1 and w.start + 1e-6 < words[i - 1].start then mono = false end
    if w["end"] > secs + 0.05 or w.start < 0 then inside = false end
  end
  if #words > 0 then
    check(label .. ": words in order", mono)
    check(label .. ": words inside the audio", inside)
    local shown = {}
    for i = 1, math.min(#words, 8) do shown[#shown + 1] = ("%s[%.2f]"):format(words[i].word, words[i].start) end
    note(label .. " first words: " .. table.concat(shown, " "))
  end
  local cues, how = Subs.for_take({ text = text, words = r.words, seconds = secs, pause = 0 }, "short")
  local toks = Subs.tokenize(Subs.display_text(text))
  Subs.align(toks, r.words, secs)
  local with = 0
  for _, t in ipairs(toks) do if t.word then with = with + 1 end end
  note(("%s: aligned by %s, %d/%d typed words matched, %d subtitles"):format(label, how, with, #toks, #cues))
  for _, c in ipairs(cues) do note(("    %5.2f–%5.2f  %s"):format(c.start, c.finish, (c.text:gsub("\n", " / ")))) end
  return r, how, with / math.max(1, #toks)
end
do
  -- Boson may answer "timestamps": null ("alignment unavailable"). That is
  -- the service, not this app: say so once, and check the fallback instead.
  local en, how, share = timed("When we started this project, nobody believed a four-person studio could ship a feature film.", "English")
  local service = en and en.words ~= nil
  check("SERVICE: Boson returns word timestamps for English", service,
        "timestamps were null — each line becomes one subtitle")
  if service then
    check("English: subtitles timed from Boson's words", how == "words")
    check("English: nearly every typed word matched", share and share >= 0.9, share)
  else
    check("without timestamps the line is not split by guesswork", how == "none")
  end
  for _, t in ipairs({ { "我们今天要调色一段完全用手机拍摄的日落延时视频。效果真的让我大吃一惊！", "Chinese" },
                       { "Cuando empezamos este proyecto, nadie creía que podríamos terminar a tiempo.", "Spanish" },
                       { "<|emotion:elation|> Great news, everyone! <|sfx:applause|> We made it.", "tags" } }) do
    local r, h, sh = timed(t[1], t[2])
    if r and r.words then
      check(t[2] .. ": subtitles timed from Boson's words", h == "words" and sh >= 0.8, sh)
    elseif r then
      note(t[2] .. ": no timestamps from Boson; one subtitle per line")
    end
  end
  timed("The total is $1,250.75, due on 3/17 at 5 PM.", "numbers")
  local short = speech(api, "Hi.", { timestamps = true })
  check("a one-word line still generates with timestamps asked for", short.ok, short.error)
  note("one-word line: timestamps " .. (short.words and (#short.words .. " words") or "null"))
  timed("Bonjour tout le monde, nous allons commencer.", "French (not covered)")
end

------------------------------------------------------------ queue and faults
print("\nqueue and faults")
do
  local order, results = {}, {}
  for i = 1, 3 do
    api:speech({ text = ("Line number %d."):format(i), voice = "nora", format = "wav", out_path = P.join(work, ("q%d.wav"):format(i)),
                 on_done = function(r) order[#order + 1] = i; results[i] = r end })
  end
  local t0 = os.time()
  while #order < 3 and os.time() - t0 < 90 do api:poll(); bmd.wait(0.05) end
  check("three lines come back in the order sent", table.concat(order, ",") == "1,2,3", table.concat(order, ","))
  local fired = 0
  api:speech({ text = "First, left running.", voice = "nora", format = "wav", out_path = P.join(work, "c1.wav"), on_done = function() fired = fired + 1 end })
  api:speech({ text = "Second, cancelled.", voice = "nora", format = "wav", out_path = P.join(work, "c2.wav"), on_done = function() fired = fired + 1 end })
  local dropped = api:cancel_pending()
  t0 = os.time()
  while api:pending() > 0 and os.time() - t0 < 60 do api:poll(); bmd.wait(0.05) end
  check("Stop drops what is queued and ignores what was in flight", dropped == 1 and fired == 0, ("dropped %d fired %d"):format(dropped, fired))
  local off = new_api(KEY)
  local saved = Api.BASE_URL
  Api.BASE_URL = "https://api.invalid.higgs-test.example/v1"
  local r = speech(off, "Hello.")
  Api.BASE_URL = saved
  check("no network: a plain message", not r.ok and r.error and r.error:find("internet", 1, true) ~= nil, r.error)
  local lv = wait(api, function(done) api:test({ on_done = done }) end)
  check("the connection test works", lv.ok, lv.error)
end

------------------------------------------------------------------ the log
print("\nthe log")
do
  local text = U.read_file(Log.path()) or ""
  check("the key is nowhere in this run's log", not text:find(KEY, 1, true))
  local leaked
  local kept = P.join(real_dir, "logs")
  for f in (P.run_capture("ls " .. P.quote(kept)) or ""):gmatch("[^\n]+") do
    local body = U.read_file(P.join(kept, f)) or ""
    if body:find(KEY, 1, true) then leaked = f end
  end
  check("no kept log contains the key", leaked == nil, leaked)
  check("the voiced text is not logged", not text:find("grading a sunset timelapse", 1, true))
end

os.execute("rm -rf " .. P.quote(work))
print(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
