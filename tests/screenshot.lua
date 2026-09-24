--- Launch the window in a chosen state, for screenshots and design review.
--
--   HIGGS_SCENARIO=<name> fuscript -l lua tests/screenshot.lua
--
-- Scenarios:
--   onboarding   setup · setup-error · setup-skipped · connect
--   generate     quick · quickrun · quickdone · quicklate · quicktag · quickerror · quickstopped · palette
--   settings     settings · settings-sentence · update · update-generate (a newer release found)
--   add a voice  addvoice · addvoice-recording · addvoice-take · addvoice-short · addvoice-own ·
--                addvoice-file · addvoice-norecord (and the variants handled below)
--
-- Runs against a live Resolve (a project must be open) but sandboxes every
-- write into HIGGS_SHOT_DIR, so the user's real config, key and takes are never
-- touched. The window closes itself after HIGGS_SHOT_SECONDS (default 8): a
-- script killed from outside leaves its window orphaned inside Resolve.

_G.HIGGS_VO_NO_AUTORUN = true
dofile("Higgs VoiceOver.lua")

local P      = require("higgs.platform")
local U      = require("higgs.util")
local Config = require("higgs.config")
local Api    = require("higgs.api")
local R      = require("higgs.resolve")
local Tags   = require("higgs.tags")
local UI     = require("higgs.ui")

local sandbox = os.getenv("HIGGS_SHOT_DIR") or "/tmp/higgsvo-shots"
P.config_dir = function() return sandbox .. "/config" end
Config.ensure_dirs()
require("higgs.log").start()

local scenario = os.getenv("HIGGS_SCENARIO") or "populated"

assert(R.connect())
if not _G.fusion then _G.fusion = R.app():Fusion() end
if not _G.fu then _G.fu = _G.fusion end

local cfg = Config.load()
cfg.default_voice = "voice_8f3a1c92e7b4d0a6f5c8"
cfg.voices = {
  { id = "voice_8f3a1c92e7b4d0a6f5c8", name = "Alex — narration",  created = os.time() - 86400 * 2 },
  { id = "voice_2b91d4e806cafe1379a2", name = "Client — promo read", created = os.time() - 86400 * 9 },
  { id = "voice_c05e77b1a94d3f28e6b0", name = "Documentary low",     created = os.time() - 86400 * 20 },
}
if not scenario:match("^setup") then
  Config.set_api_key(cfg, "sk-demo-0000-0000-0000-0000-0000")
else
  Config.set_api_key(cfg, "")
end

local api = Api.new({ get_key = function() return Config.get_api_key(cfg) end,
                      tmp_dir = Config.tmp_dir() })

local ctx = { cfg = cfg, api = api, project_id = "demo-project", skip_sync = true, demo_connected = true,
              window_geometry = os.getenv("HIGGS_SHOT_X") and { tonumber(os.getenv("HIGGS_SHOT_X")), 80, 1000, 780 } or nil,
              dialog_geometry = os.getenv("HIGGS_SHOT_X") and { tonumber(os.getenv("HIGGS_SHOT_X")) + 150, 110, 700, 556 } or nil,
              demo_exit_at = os.time() + tonumber(os.getenv("HIGGS_SHOT_SECONDS") or "8"),
              -- Resolve keeps a killed script's widgets under its window ID and
              -- merges them into the next window that reuses it.
              window_id = "HiggsVOShot" .. tostring(os.time()),
              dialog_id = "HiggsVOAddVoiceShot" .. tostring(os.time()) }

if scenario == "setup" then
  ctx.demo_connected = false
elseif scenario == "setup-error" then
  -- A rejected key: the message has its own line and nothing moves.
  ctx.demo_connected = false
  ctx.demo_setup = { key = "sk-live-wrong-key-0000", status = "Boson didn't accept that key. Check that you copied all of it.", kind = "error" }
elseif scenario == "setup-skipped" then
  ctx.demo_connected = false
  ctx.demo_setup = { skip = true }
elseif scenario == "quick" then
  ctx.demo_quick = {
    text = "Welcome back to the channel! <|emotion:elation|> Today we're grading a sunset timelapse shot entirely on the iPhone.\nHonestly, the footage blew me away.",
    last = { takes = { { path = "/tmp/Welcome_back_to_the.wav", seconds = 6.1 }, { path = "/tmp/Honestly_the_footage_blew.wav", seconds = 2.4 } } },
    status = "Generated · about <span style='font-family:Menlo, monospace; font-size:12px; color:#dcdce0'>8</span> s · playing now", status_kind = "text",
  }
elseif scenario == "quickrun" then
  ctx.demo_quick = {
    text = "Welcome back to the channel! <|emotion:elation|> Today we're grading a sunset timelapse shot entirely on the iPhone.\nHonestly, the footage blew me away.\nDrop a comment if you want the node tree.\nStick around until the end.\nThere's a little surprise.",
    busy = { index = 3, total = 5 },
  }
elseif scenario == "quickdone" then
  -- Placing and subtitles ticked, as someone who wants both would leave them.
  cfg.auto_place, cfg.auto_subtitles = true, true
  ctx.demo_quick = {
    text = "Welcome back to the channel! <|emotion:elation|> Today we're grading a sunset timelapse shot entirely on the iPhone.\nHonestly, the footage blew me away.",
    last = { takes = { { path = "/tmp/Welcome_back_to_the.wav", seconds = 6.1 }, { path = "/tmp/Honestly_the_footage_blew.wav", seconds = 2.4 } } },
    note = { text = "2/2 generated", kind = "ok" },
    player = { index = 1, state = "stopped" },
  }
elseif scenario == "quicklate" then
  -- Takes land after the window is shown, as in a real run.
  ctx.demo_quick = {
    text = "Welcome back to the channel!\nHonestly, the footage blew me away.",
    late_last = { takes = { { path = "/tmp/Welcome_back_to_the.wav", seconds = 6.1 }, { path = "/tmp/Honestly_the_footage_blew.wav", seconds = 2.4 } } },
    note = { text = "2/2 generated", kind = "ok" },
  }
elseif scenario == "quicktag" then
  ctx.demo_quick = {
    text = "Welcome back to the channel!\nHonestly, the footage blew me away.",
    tag_type = "Speed",
  }
elseif scenario == "quickerror" then
  ctx.demo_quick = {
    text = "Welcome back to the channel!\nHonestly, the footage blew me away.",
    note = { text = "Line 2 — Your Boson account is out of credit. Top up at boson.ai.", kind = "error" },
  }
elseif scenario == "quickstopped" then
  ctx.demo_quick = {
    text = "Welcome back to the channel! <|emotion:elation|> Today we're grading a sunset timelapse shot entirely on the iPhone.\nHonestly, the footage blew me away.",
    last = { takes = { { path = "/tmp/Welcome_back_to_the.wav", seconds = 6.1 }, { path = "/tmp/Honestly_the_footage_blew.wav", seconds = 2.4 } } },
    player = { index = 2, state = "stopped" },
  }
elseif scenario == "palette" then
  ctx.demo_quick = { text = "Welcome back to the channel! " }
elseif scenario == "connect" then
  -- The path the user takes: setup page, key entered, then the Generate
  -- page replaces it while the window is already on screen.
  Config.set_api_key(cfg, "")
  ctx.demo_connected = false
  ctx.on_shown = function(itm, win, disp)
    for i = 1, 10 do disp:StepLoop(); _G.bmd.wait(0.05) end
    Config.set_api_key(cfg, "sk-demo-0000")
    UI.debug.route()
  end
elseif scenario:sub(1, 8) == "addvoice" then
  local which = scenario:sub(10)
  ctx.demo_addvoice = { name = "Alex — narration" }
  -- A real PCM take so the meter and the counter read from the same file the
  -- product does, rather than from numbers invented for the picture.
  local function fake_pcm(seconds, amplitude, swell)
    local U2, P2 = require("higgs.util"), require("higgs.platform")
    local parts, n = {}, math.floor(U2.PCM_RATE * seconds)
    for i = 1, n do
      -- A slow swell makes a speech-like meter; the clipping fixture needs the
      -- tail hot, because that is the window the meter reads.
      local env = (swell == false) and 1 or (0.55 + 0.45 * math.sin(i / U2.PCM_RATE * 3))
      local v = math.floor(math.sin(i * 0.039) * 32760 * amplitude * env)
      if v < 0 then v = v + 65536 end
      parts[#parts + 1] = string.char(v % 256, math.floor(v / 256) % 256)
    end
    U2.write_file(P2.join(Config.tmp_dir(), "voice-take.pcm"), table.concat(parts))
    U2.pcm_to_wav(P2.join(Config.tmp_dir(), "voice-take.pcm"),
                  P2.join(Config.tmp_dir(), "voice-take-1.wav"), 0)
  end
  --- The dialog reads elapsed time and level from the recorder's status file,
  -- so a captured "recording" state has to write one.
  local function fake_status(text)
    local U2, P2 = require("higgs.util"), require("higgs.platform")
    U2.write_file(P2.join(Config.tmp_dir(), "voice-take-1.wav.status"), text)
  end
  local function take(seconds, rms, hot)
    return { seconds = seconds, peak = math.min(1, rms * 7), rms = rms, hot_ratio = hot or 0 }
  end
  if which == "recording" then
    fake_pcm(9.4, 0.32); fake_status("9.400 -12.0"); ctx.demo_addvoice.recording = 9.4
  elseif which == "hot" then
    fake_pcm(11.5, 1.0, false); fake_status("11.500 -0.2"); ctx.demo_addvoice.recording = 11.5
  elseif which == "take" then
    fake_pcm(21, 0.34)
    ctx.demo_addvoice.take = take(21.2, 0.09)
    ctx.demo_addvoice.consent = true
  elseif which == "warn" then
    fake_pcm(19, 0.95)
    ctx.demo_addvoice.take = take(19.4, 0.31, 0.04)
    ctx.demo_addvoice.consent = true
  elseif which == "short" then
    fake_pcm(2.2, 0.3); ctx.demo_addvoice.take = take(2.2, 0.08)
  elseif which == "script" then
    -- The transcript unfolded and filled in by hand.
    ctx.demo_addvoice.transcript_on = true
    ctx.demo_addvoice.transcript = "This is what I said, typed out word for word, because I chose to."
  elseif which == "stale" then
    fake_pcm(21, 0.34)
    ctx.demo_addvoice.transcript_on = true
    ctx.demo_addvoice.transcript = "This is what I said, typed out word for word, because I chose to."
    ctx.demo_addvoice.take = take(21.2, 0.09)
    ctx.demo_addvoice.stale = true
    ctx.demo_addvoice.consent = true
  elseif which == "recovery" then
    fake_pcm(21, 0.34)
    ctx.demo_addvoice.script = 1
    ctx.demo_addvoice.take = take(21.2, 0.09)
    ctx.demo_addvoice.stale, ctx.demo_addvoice.previous = true, true
    ctx.demo_addvoice.consent = true
  elseif which == "noperm" then
    ctx.demo_addvoice.no_permission = true
  elseif which == "file" then
    ctx.demo_addvoice.source = "file"
    ctx.demo_addvoice.file = "/Users/alex/Movies/VO references/alex-read-01.wav"
    ctx.demo_addvoice.transcript_on = true
    ctx.demo_addvoice.transcript = "Welcome back to the channel. Today we are grading a sunset timelapse, shot entirely on the iPhone."
  elseif which == "norecord" then
    ctx.demo_addvoice.no_record = true
  end
elseif scenario == "settings" then
  ctx.initial_tab = 1
elseif scenario == "settings-sentence" then
  -- The other way to split subtitles, previewed on the first line of a draft.
  ctx.initial_tab = 1
  cfg.subtitle_split = "sentence"
  ctx.demo_quick = { text = "When we started this project, nobody on the team believed a four-person studio could ship a feature film in under a year. But here we are." }
elseif scenario == "update" then
  ctx.initial_tab = 1
  ctx.demo_update = "0.2.0"
elseif scenario == "update-generate" then
  ctx.demo_update = "0.2.0"
end

if os.getenv("HIGGS_SHOT_PROBE") then
  -- Print the laid-out geometry of the widgets named in HIGGS_SHOT_PROBE.
  ctx.on_shown = function(itm, win, disp)
    io.stdout:setvbuf("no")
    local function geo(w)
      local ok, g = pcall(function() return w.Geometry end)
      if ok and type(g) == "table" then return ("x=%s y=%s w=%s h=%s"):format(g[1], g[2], g[3], g[4]) end
      return "n/a"
    end
    print("window " .. geo(win))
    if os.getenv("HIGGS_SHOT_POSTSHOW") then
      assert(loadstring("local itm, win = ...; " .. os.getenv("HIGGS_SHOT_POSTSHOW")))(itm, win)
      for i = 1, 10 do disp:StepLoop(); _G.bmd.wait(0.05) end
      print("after post-show change: window " .. geo(win))
    end
    if os.getenv("HIGGS_SHOT_RESIZE") then
      for i = 1, 20 do disp:StepLoop(); _G.bmd.wait(0.05); if i % 5 == 0 then print("after " .. i .. " steps: window " .. geo(win) .. "  MainStack " .. geo(itm.MainStack)) end end
      print("RecalcLayout ->", pcall(function() win:RecalcLayout() end))
      for i = 1, 5 do disp:StepLoop(); _G.bmd.wait(0.05) end
      print("after recalc: window " .. geo(win) .. "  MainStack " .. geo(itm.MainStack))
      print("Resize ->", pcall(function() win:Resize({ 1000, 780 }) end))
      for i = 1, 5 do disp:StepLoop(); _G.bmd.wait(0.05) end
      print("after resize: window " .. geo(win) .. "  MainStack " .. geo(itm.MainStack))
      print("SetGeometry ->", pcall(function() win:SetGeometry({ 160, 80, 1000, 780 }) end))
      for i = 1, 5 do disp:StepLoop(); _G.bmd.wait(0.05) end
      print("after setgeometry: window " .. geo(win) .. "  MainStack " .. geo(itm.MainStack))
    end
    for id in os.getenv("HIGGS_SHOT_PROBE"):gmatch("[^,]+") do
      print(id .. " " .. (itm[id] and geo(itm[id]) or "missing"))
    end
  end
end

if os.getenv("HIGGS_SHOT_PRESHOW") then
  -- Run a Lua snippet (with `itm` in scope) just before the window is shown.
  ctx.before_show = function(itm, win)
    local f = assert(loadstring("local itm, win = ...; " .. os.getenv("HIGGS_SHOT_PRESHOW")))
    f(itm, win)
  end
end

UI.run(ctx)
