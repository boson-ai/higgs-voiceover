--- Entry point. Wires the modules together and opens the window.
--
-- Runs from Resolve's Workspace › Scripts menu, where `resolve`, `fusion` and
-- `bmd` are provided as globals.

local P      = require("higgs.platform")
local Log    = require("higgs.log")
local T      = require("higgs.theme")
local U      = require("higgs.util")
local Config = require("higgs.config")
local Api    = require("higgs.api")
local R      = require("higgs.resolve")
local UI     = require("higgs.ui")

--- Report a startup failure where the user will see it. Before the window
-- exists there is nowhere to show a message, so use Resolve's own dialog if it
-- is reachable and fall back to the console.
-- Lua starts from the same seed every run, so without this the "random"
-- passage on the Add-a-voice dialog would be the same one every launch.
math.randomseed(os.time() + math.floor((os.clock() * 1000) % 1000))

local function fatal(message)
  Log.error("fatal: " .. message)
  local shown = pcall(function()
    local ui = _G.fu and _G.fu.UIManager or _G.fusion.UIManager
    local disp = _G.bmd.UIDispatcher(ui)
    local dlg = disp:AddWindow({
      ID = "HiggsVOError",
      WindowTitle = Config.APP_NAME,
      Geometry = { 300, 300, 460, 170 },
      Events = { Close = true },
    }, ui:VGroup{
      Spacing = 0,
      ui:Label{ Weight = 0, MinimumSize = { 0, 10 }, MaximumSize = { 4000, 10 } },
      ui:HGroup{
        Weight = 1, Spacing = 0,
        ui:Label{ Weight = 0, MinimumSize = { 16, 0 }, MaximumSize = { 16, 4000 } },
        ui:VGroup{
          Weight = 1, Spacing = 12,
          ui:Label{ Text = message, Weight = 1, WordWrap = true, StyleSheet = T.label(),
                    Alignment = { AlignLeft = true, AlignTop = true } },
          ui:HGroup{ Weight = 0,
            ui:Label{ Weight = 1 },
            ui:Button{ ID = "OkBtn", Text = "OK", Weight = 0, StyleSheet = T.button("primary") } },
        },
        ui:Label{ Weight = 0, MinimumSize = { 16, 0 }, MaximumSize = { 16, 4000 } },
      },
      ui:Label{ Weight = 0, MinimumSize = { 0, 16 }, MaximumSize = { 4000, 16 } },
    })
    dlg.On.OkBtn.Clicked = function() disp:ExitLoop() end
    dlg.On.HiggsVOError.Close = function() disp:ExitLoop() end
    dlg:Show()
    disp:RunLoop()
    dlg:Hide()
  end)
  if not shown then print(Config.APP_NAME .. ": " .. message) end
end

local function main()
  local connected, err = R.connect()
  if not connected then
    fatal(err or "Could not reach DaVinci Resolve.")
    return
  end

  -- Inside Resolve, `fusion` and `fu` are provided. When launched from an
  -- external interpreter during development they are not, but the same objects
  -- are reachable from the app handle.
  if not _G.fusion then _G.fusion = R.app():Fusion() end
  if not _G.fu then _G.fu = _G.fusion end

  -- A project must be open: without one there is no media pool to import into
  -- and no timeline to place on.
  if not R.project() then
    fatal("Open a project in DaVinci Resolve, then run " .. Config.APP_NAME .. " again.")
    return
  end

  Config.ensure_dirs()
  Log.start()
  local product, resolve_version = R.product()
  local os_version = "?"
  pcall(function()
    local v = P.run_capture("sw_vers -productVersion 2>/dev/null")
    os_version = (tostring(v or "?"):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
  end)
  Log.info(Config.APP_NAME .. " start", { version = tostring(_G.HIGGS_VO_VERSION or "dev"),
    os = (_G.jit and _G.jit.os or "?") .. " " .. os_version, resolve = tostring(product or "Resolve") .. " " .. tostring(resolve_version or "?"),
    lua = _G.jit and _G.jit.version or _VERSION, session = Log.session })
  pcall(function()
    local proj, tl = R.project(), R.timeline()
    Log.info("project", { project = Log.q(proj and proj:GetName() or "-"), timeline = Log.q(tl and tl:GetName() or "-"),
                          tracks = tl and tl:GetTrackCount("audio") or 0,
                          fps = proj and proj:GetSetting("timelineFrameRate") or "?" })
  end)
  local cfg, cfg_warning = Config.load()
  if cfg_warning then Log.warn(cfg_warning) end
  local names = cfg.clip_name or {}
  Log.info("config", { key = Config.get_api_key(cfg) ~= "" and "set" or "missing", format = cfg.output_format,
    track = Log.q(cfg.vo_track_name), replace = cfg.replace_mode,
    names = (names.words ~= false and "words" or "") .. (names.date and "+date" or "") .. (names.time and "+time" or "") .. (names.take and "+take" or ""),
    updates = tostring(cfg.check_updates ~= false),
    auto_preview = tostring(cfg.auto_preview ~= false), auto_place = tostring(cfg.auto_place == true),
    cloned_voices = #(cfg.voices or {}) })

  local api = Api.new({
    get_key = function() return Config.get_api_key(cfg) end,
    tmp_dir = Config.tmp_dir(),
  })

  -- The Generate draft is kept per project. With no timeline open the window
  -- still runs; placing reports the missing timeline when it is attempted.
  local project_id = R.ids()

  if Config.lock_is_live() then
    -- Never open a second window, not even a dialog: every script shares
    -- Resolve's one event queue, so a second loop swallows the running
    -- copy's clicks and makes a working window look frozen. Ask the running
    -- copy to bring its own window forward instead.
    os.remove(Config.raised_path())
    U.write_file(Config.raise_path(), tostring(os.time()))
    local t0 = _G.bmd.gettime()
    while _G.bmd.gettime() - t0 < 2.5 do
      if P.exists(Config.raised_path()) then
        os.remove(Config.raised_path())
        Log.info("already open: the running window was brought forward")
        return
      end
      if not Config.lock_is_live() then break end   -- it let go: open normally
      _G.bmd.wait(0.1)
    end
    os.remove(Config.raise_path())
    Log.warn("already open but it did not answer; opening a fresh window")
  end
  Config.touch_lock()
  -- xpcall, not pcall: a crash report without a stack says where it ended
  -- up, not how it got there.
  local ok, err = xpcall(function() return UI.run( { cfg = cfg, api = api, project_id = project_id or "", warning = cfg_warning,
                                  heartbeat = Config.touch_lock,
                                  raise_path = Config.raise_path(), raised_path = Config.raised_path(),
                                  release_lock = Config.release_lock }) end,
                          function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end)
  Config.release_lock()
  if ok then Log.info("exit") else Log.error("crash", { detail = tostring(err) }) end
  Log.summary()
  -- The user gets the first line; the stack is for the log.
  if not ok then error((tostring(err):match("^[^\n]*")), 0) end
end

local ok, run_error = pcall(main)
if not ok then
  fatal(Config.APP_NAME .. " hit an unexpected error:\n\n" .. tostring(run_error))
end
