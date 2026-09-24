--- The Higgs VoiceOver window.
--
-- Built with Resolve's own UIManager (Qt), styled through theme.lua so it reads
-- as a Resolve panel: one accent for the primary action, three greys for
-- everything else, state expressed as glyph + colour + word.
--
-- The Script tab is a stack of three pages that mirror the first-time journey:
-- connect an account → add a script → work the segments. The segment list is
-- the hero; the editor beneath it is where one line is written, directed,
-- auditioned and placed. Voices and Settings are tabs.

local P      = require("higgs.platform")
local U      = require("higgs.util")
local Config = require("higgs.config")
local Tags   = require("higgs.tags")
local Api    = require("higgs.api")
local R      = require("higgs.resolve")
local T      = require("higgs.theme")
local Log    = require("higgs.log")
local Icons  = require("higgs.icons")
local Rec    = require("higgs.recorder")
local Subs   = require("higgs.subtitles")

local M = {}

local WIN_ID = "HiggsVOWindow"   -- the harness overrides this per run (see M.run)
local GEN_SETUP, GEN_QUICK = 0, 1          -- Generate tab
-- This release has two tabs. Script and Voices live on the
-- feature/script-and-voices branch until they are ready to ship.
local TAB_GENERATE, TAB_SETTINGS = 0, 1

local ui, disp, win, itm
local app        -- { cfg, api, doc, ... }
local suppress   -- guard against handlers firing while widgets are updated
--- The Generate tab: one box, the delivery controls, one take at a time.
local quick = {
  text = "",
  voice = nil,      -- nil means the default voice
  last = nil,       -- { path=, seconds= } of the most recent take
  busy = false,
  place_one_hidden = true,   -- mirrors QuickPlaceOneBtn.Hidden as built
}
local reload_quick_voices   -- defined with the Generate tab's lists, used by the voice combos above them
local refresh_quick_tag_foot, refresh_quick_delete   -- defined after the lists they read
local refresh_preview_where   -- defined with the output folder it names
local quick_note            -- defined with the status line, called by the player above it
local paint = {}            -- per text box: which tags were last coloured (see repaint_box)
local repaint_box, insert_tag   -- defined with the tag colouring, used by the editor above it
local saved_at   -- when Settings last confirmed a save, so the note can clear
local connected  -- true after a successful key test this session

--------------------------------------------------------------------- helpers

local c = T.color

--- Event loops are pumped by hand. Resolve's UIManager never delivers
-- Timer.Timeout, so RunLoop would leave the API queue unpolled forever; a
-- StepLoop + short wait gives the same idle behaviour plus a tick we control.
-- Loops nest (a dialog runs inside the window's), so each gets its own flag.
local loops = {}

local function stop_loop()
  local top = loops[#loops]
  if top then top.done = true end
end

--- Deliver every event that is waiting. Each GetEvent is a round trip to
-- Resolve, and StepLoop only takes one, so a burst of typing or mouse moves
-- would otherwise queue up behind the tick sleep and feel like a hang.
local typed_at = {}   -- last time typing in a box was logged, per widget
local shown_at        -- wall clock when the window first appeared
-- Events nobody performs: sliders report their own programmatic writes
-- (they deliver nothing for a real drag), and a tick-driven meter would put
-- fifty lines a second into the file.
local QUIET_EVENTS = { ValueChanged = true, Timeout = true }
local last_event = "none"   -- named in stall and handler-error lines
local picker_used = false   -- a file picker ran this tick (see pick)

local function log_event(ev)
  local who, what = tostring(ev.who), tostring(ev.what)
  if QUIET_EVENTS[what] then return end
  -- Building the window fires a burst of change events from code (combos
  -- filled, boxes restored). They say nothing about the user.
  local clock = _G.bmd.gettime()
  if not shown_at or clock - shown_at < 1.0 then return end
  last_event = who .. " " .. what
  if what == "TextChanged" then
    if clock - (typed_at[who] or 0) < 3 then return end
    typed_at[who] = clock
    Log.ui("typing in " .. who)
    return
  end
  Log.ui(last_event)
end

local function pump_events()
  for _ = 1, 500 do
    local got, ev = pcall(ui.GetEvent, ui, false)
    if not got or not ev then return end
    pcall(log_event, ev)
    -- The queue is shared across every script Resolve is running; an event
    -- for a window this dispatcher never registered makes Dispatch throw
    -- ("attempt to index local 'ontbl'"). Not ours; must not take us down.
    local t0 = _G.bmd.gettime()
    local ok, err = pcall(disp.Dispatch, disp, ev)
    local ms = (_G.bmd.gettime() - t0) * 1000
    if not ok and not tostring(err):find("ontbl", 1, true) then
      Log.error("event loop: " .. tostring(err), { event = tostring(ev.who) .. " " .. tostring(ev.what) })
    end
    -- A handler that holds the loop this long is a freeze to the user.
    if ms > 400 and not picker_used then
      Log.warn("slow handler", { event = tostring(ev.who) .. " " .. tostring(ev.what), ms = math.floor(ms) })
    end
  end
end

--- A file picker holds the loop for as long as the user browses; that is
-- expected, and logged as a wait rather than a stall.
local function pick(fn, ...)
  picker_used = true
  local t0 = _G.bmd.gettime()
  local ok, result = pcall(fn, ...)
  local picked = ok and result and tostring(result) ~= ""
  Log.info("file picker", { seconds = _G.bmd.gettime() - t0, result = picked and "picked" or "cancelled" })
  return ok and result or nil
end

--- A tick that comes late means the loop was stuck — in a handler, in a
-- Resolve call, or in Resolve itself. A true hang can never write its own
-- line, but the stall that ends does, with what happened just before it.
local last_tick
local function note_stall()
  local t = _G.bmd.gettime()
  if last_tick and t - last_tick > 1.0 and not picker_used then
    Log.warn("loop stalled", { seconds = t - last_tick, after = last_event })
  end
  last_tick = t
  picker_used = false
end

local function run_loop(on_tick)
  local flag = { done = false }
  loops[#loops + 1] = flag
  while not flag.done do
    note_stall()
    pump_events()
    _G.bmd.wait(0.02)
    if on_tick then on_tick() end
    if app.demo_exit_at and os.time() >= app.demo_exit_at then
      for _, f in ipairs(loops) do f.done = true end
    end
  end
  loops[#loops] = nil
end

local function esc(s)
  return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function span(color, text)
  return ("<span style='color:%s'>%s</span>"):format(color, esc(text))
end

local function fmt_cost(chars)
  local usd = Api.cost_for(chars)
  if usd < 0.005 then return "less than $0.01" end
  return ("≈ $%.2f"):format(usd)
end

--- 5381 → "5,381". Every character count the user sees goes through here.
local function fmt_int(n)
  local digits = tostring(math.floor(tonumber(n) or 0))
  local out = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

local function title_case(text)
  return (tostring(text or ""):gsub("^%l", string.upper))
end

--- Numerals in a rich-text label, set the same way the list sets them.
local function mono_span(color, text)
  return ("<span style='color:%s; font-family:Menlo, monospace; font-size:12px'>%s</span>"):format(color, esc(text))
end

--- What the user was told, once per change: a status slot is repainted on
-- every refresh, and the log wants the message, not the repaint.
local told = {}
local function log_told(slot, text, kind)
  local key = tostring(kind) .. "|" .. tostring(text)
  if told[slot] == key then return end
  told[slot] = key
  if kind == "error" then Log.error("shown: " .. tostring(text), { where = slot })
  elseif kind == "ok" or kind == "warn" then Log.info("shown: " .. tostring(text), { where = slot }) end
end

--- A message with no screen of its own (update check, a link that would
-- not open) goes to the Generate tab's status line.
local function status(text, kind)
  if not itm or not quick_note then return end
  quick_note(text, kind)
end

local function combo_values(combo, entries, current)
  combo:Clear()
  local index = 0
  for i, e in ipairs(entries) do
    combo:AddItem(e.label)
    if e.value == current then index = i - 1 end
  end
  combo.CurrentIndex = index
end

local function ui_font(spec)
  local ok, font = pcall(function() return ui:Font(spec) end)
  return ok and font or nil
end
local function mono_font()      return ui_font({ Family = "Menlo", PixelSize = T.font.small }) end
local function mono_bold_font() return ui_font({ Family = "Menlo", PixelSize = T.font.small, Bold = true }) end
local function bold_font()      return ui_font({ PixelSize = T.font.body, Bold = true }) end

------------------------------------------------------------------ voice list

local function voice_name(id)
  for _, v in ipairs(Api.PRESET_VOICES) do if v.id == id then return v.label end end
  local v = Config.find_voice(app.cfg, id)
  return v and (v.name or v.id) or id
end

local function voice_entries()
  local out = {}
  for _, v in ipairs(app.cfg.voices) do
    out[#out + 1] = { value = v.id, label = v.name or v.id }
  end
  for _, v in ipairs(Api.PRESET_VOICES) do
    out[#out + 1] = { value = v.id, label = v.label }
  end
  return out
end

local function reload_voice_combos()
  if itm.QuickVoiceTree then reload_quick_voices() end
end

--------------------------------------------------------------- page routing

--- A Stack's CurrentIndex alone does not reliably hide the other pages
-- here: they occasionally stay visible and paint through the current one.
-- Hiding the siblings explicitly makes the switch deterministic.
local TAB_PAGES    = { "GenerateStack", "TabSettings" }
local GEN_PAGES    = { "PageSetup", "PageQuick" }

local shown = false   -- true once the window is on screen
local take_group_hidden = false

--- A group that was hidden when the window first laid out has never been
-- laid out itself; showing it later leaves its children piled at the origin
-- until the window recalculates.
local layout_check_at   -- when to look at geometry after a relayout (see check_layout)
local function relayout()
  if shown then
    pcall(function() win:RecalcLayout() end)
    layout_check_at = _G.bmd.gettime() + 0.1
  end
end

--- Layout bugs are invisible to everything but a screenshot — unless the
-- app looks at its own geometry. After each relayout, and once after the
-- window appears, these pairs are checked; a failure is logged with the
-- rectangles, so "the button drew at the wrong edge" is on record even when
-- nobody took a picture. Geometry is relative to the enclosing group (each
-- HGroup/VGroup is a widget underneath), so a pair must share one group. Pairs: { a, b, rule } with rule "left_of" (a ends
-- before b starts, same row) or "above" (a ends before b starts, vertically).
local LAYOUT_RULES = {
  { "QuickPlaceOneBtn", "QuickPlaceBtn", "left_of" },
  { "AutoPreviewChk", "PreviewSubsChk", "left_of" },
  { "PreviewSubsChk", "QuickPlaceOneBtn", "left_of" },
  { "PreviewSubsChk", "QuickPlaceBtn", "left_of" },
  { "AutoPlaceChk", "AutoSubsChk", "left_of" },
  { "AutoSubsChk", "QuickStopBtn", "left_of" },
  { "PlayerIndex", "PlayerName", "left_of" },
  { "PreviewTitle", "PreviewWhere", "left_of" },
  { "PlayerName", "PlayerPrev", "left_of" },
  { "PlayerPrev", "PlayerNext", "left_of" },
  { "PlayerTimeTotal", "PlayerPlay", "left_of" },
  { "QuickTagTree", "QuickTagFoot", "above" },
}

local function rect(id)
  local w = itm and itm[id]
  if not w then return nil end
  local ok, g = pcall(function() return w.Geometry end)
  if not ok or type(g) ~= "table" then return nil end
  local x, y, gw, gh = g[1] or g.x, g[2] or g.y, g[3] or g.w or g.width, g[4] or g.h or g.height
  if not (x and y and gw and gh) then return nil end
  return { x = x, y = y, w = gw, h = gh }
end

local function visible(id)
  local ok, hidden = pcall(function() return itm[id].Hidden end)
  return ok and not hidden
end

local layout_faults = {}   -- rule key -> true while failing, so each fault logs once
local function check_layout()
  layout_check_at = nil
  if not itm or itm.MainTabs.CurrentIndex ~= TAB_GENERATE then return end
  for _, r in ipairs(LAYOUT_RULES) do
    local a, b, rule = r[1], r[2], r[3]
    if visible(a) and visible(b) then
      local ra, rb = rect(a), rect(b)
      if ra and rb then
        local bad
        if ra.w <= 0 or ra.h <= 0 then bad = a .. " has no size"
        elseif rb.w <= 0 or rb.h <= 0 then bad = b .. " has no size"
        elseif rule == "left_of" then
          -- Children of different parents report in different frames, so
          -- only compare pairs that share a row (tops within a few pixels).
          if math.abs(ra.y - rb.y) <= 6 and ra.x + ra.w > rb.x + 1 then bad = a .. " is not left of " .. b end
        elseif rule == "above" then
          if ra.y + ra.h > rb.y + 1 then bad = a .. " is not above " .. b end
        end
        local key = a .. "|" .. b
        if bad and not layout_faults[key] then
          layout_faults[key] = true
          Log.warn("layout: " .. bad, { a = ("%d,%d %dx%d"):format(ra.x, ra.y, ra.w, ra.h),
                                         b = ("%d,%d %dx%d"):format(rb.x, rb.y, rb.w, rb.h) })
        elseif not bad and layout_faults[key] then
          layout_faults[key] = nil
          Log.info("layout: " .. a .. " / " .. b .. " back in place")
        end
      end
    end
  end
end

local function select_page(stack, pages, index)
  for i, id in ipairs(pages) do
    if itm[id] then itm[id].Hidden = (i - 1) ~= index end
  end
  itm[stack].CurrentIndex = index
  relayout()
end

local TAB_NAMES = { "Generate", "Settings" }
local function show_tab(index)
  Log.info("page", { tab = TAB_NAMES[index + 1] or tostring(index) })
  select_page("MainStack", TAB_PAGES, index)
end

local setup_skipped = false   -- "Skip for now" pressed this session
local function route()
  -- First run is one screen: no tabs, no status pill, just the key. Skip
  -- shows the product without one; generating still asks for it.
  local onboarding = Config.get_api_key(app.cfg) == "" and not setup_skipped
  if onboarding ~= itm.MainTabs.Hidden then
    itm.MainTabs.Hidden = onboarding
    itm.ConnLabel.Hidden = onboarding
    if onboarding and itm.MainTabs.CurrentIndex ~= TAB_GENERATE then
      itm.MainTabs.CurrentIndex = TAB_GENERATE
      show_tab(TAB_GENERATE)
    end
  end
  select_page("GenerateStack", GEN_PAGES, onboarding and GEN_SETUP or GEN_QUICK)
  -- Green is reserved for "on timeline"; the pill keeps a green dot and
  -- secondary text.
  if Config.get_api_key(app.cfg) == "" then
    itm.ConnLabel.Text = ("<span style='color:%s; font-size:8px'>○</span>&nbsp;&nbsp;"):format(c.text_3) .. span(c.text_2, "No API key")
  else
    -- A key is in place either way: a small green dot, and the word says
    -- whether this session has proved it.
    itm.ConnLabel.Text = ("<span style='color:%s; font-size:8px'>●</span>&nbsp;&nbsp;"):format(c.ok) ..
      span(c.text_2, connected and "Connected" or "Key saved")
  end
end

local function refresh_all()
  route()
end

------------------------------------------------------------------ generation

local function ext_for_preview()
  local chosen = app.cfg.output_format or "wav"
  if not P.can_play("x." .. chosen) then chosen = P.audio_play_formats()[1] or "wav" end
  return chosen
end

--- Put a take on the VO track at the playhead, or after whatever already
-- sits there. Used by the Generate tab, which keeps no script.
local function place_new(path, id, version)
  local track, terr = R.ensure_track(app.cfg.vo_track_name, "stereo")
  if not track then return nil, terr end
  local mpi, ierr = R.import(path)
  if not mpi then return nil, ierr end
  local playhead = R.playhead_frame()
  local _, cursor = R.gaps_after(track, playhead)
  local at = math.max(cursor, playhead)
  R.stamp(mpi, id, version)
  local clip, err = R.place(mpi, track, at)
  if not clip then return nil, err end
  R.save()
  return clip, nil, at > playhead, at
end

--- The bottom-left indicator. At rest it counts the text; while work is
-- happening it reports it — amber running, green finished, red failed.
-- `kind`: "run" | "ok" | "error" | nil (nil is the plain counter).
local function quick_status(text, kind)
  if kind ~= "run" then log_told("generate", text, kind) end
  quick.status_kind = kind
  local color = (kind == "error" and c.error) or (kind == "ok" and c.ok)
             or (kind == "run" and c.warn) or c.text_2
  itm.QuickStatus.StyleSheet = T.label(kind and "" or "mono")
  itm.QuickStatus.Text = kind and span(color, text) or tostring(text or "")
end

--- The last take is only worth placing while it still matches what is in
-- the box; the Script tab calls the same condition "Edited".
--- The box splits on line breaks like the Script tab: every line is its own
-- take and its own clip, in order. Returns the composed lines and the count
-- of characters the service will see.
local function quick_lines()
  local out, chars, over = {}, 0, nil
  for i, line in ipairs(U.split_lines(itm.QuickText.PlainText)) do
    local composed = Tags.compose(line, nil)   -- delivery is inline tags only here
    local n = U.utf8_len(U.trim(composed))
    chars = chars + n
    if n > Api.MAX_INPUT_CHARS and not over then over = i end
    out[i] = { text = line, composed = composed, chars = n }
  end
  return out, chars, over
end

local function quick_signature(lines)
  local parts = {}
  for i, l in ipairs(lines) do parts[i] = l.composed end
  return table.concat(parts, "\n") .. "\n" .. (quick.voice or app.cfg.default_voice)
end

local function quick_total_seconds()
  local t = 0
  for _, take in ipairs(quick.last and quick.last.takes or {}) do t = t + (take.seconds or 0) end
  return t
end

--- The preview player under the text box. It plays the takes of the latest
-- generation one at a time; progress is elapsed wall-clock time against the
-- take's length, since the system player reports nothing back.
-- badge_hidden mirrors PlayerIndex.Hidden, which the build starts at true;
-- start it true as well or the first refresh with a take sees no change
-- and the pill never appears.
local player = { index = 1, state = "stopped", started = 0, offset = 0, badge_hidden = true }

--- A voice preview owns the audio device the same way the player does, so
-- the two stop each other and only one button says "Stop".
local preview = { playing = false }

local function player_take()
  return quick.last and quick.last.takes[player.index] or nil
end

--- Sub-second wall clock (Fusion's; os.time is whole seconds).
local function now()
  local ok, t = pcall(function() return _G.bmd.gettime() end)
  return ok and tonumber(t) or os.time()
end

local function player_elapsed()
  if player.state == "playing" then return player.offset + (now() - player.started) end
  return player.offset
end

local function player_refresh()
  local take = player_take()
  local n = quick.last and #quick.last.takes or 0
  local badge = take and ("%d/%d"):format(player.index, n) or ""
  itm.PlayerIndex.Text = badge
  if take then
    -- Qt leaves stylesheet padding out of a label's size hint, so without a
    -- width of our own the text runs into the file name beside it.
    local w, h = 26 + #badge * 8, T.size.control + 2   -- +2: the pill's own borders
    itm.PlayerIndex.MinimumSize = { w, h }
    itm.PlayerIndex.MaximumSize = { w, h }
  end
  -- A widget hidden at the first layout has no geometry until the window
  -- lays out again; without this the pill and the name overlap.
  if (take == nil) ~= (player.badge_hidden == true) then
    player.badge_hidden = take == nil
    itm.PlayerIndex.Hidden = player.badge_hidden
    itm.PlayerIndexGap.Hidden = player.badge_hidden
    relayout()
  end
  itm.PlayerName.Text = take and P.basename(take.path)
    or "Nothing to preview yet — Generate to hear your lines."
  itm.PlayerName.StyleSheet = T.label(take and "" or "meta")
  itm.PlayerName.ToolTip = take and take.path or ""
  itm.PlayerPrev.Enabled = n > 1 and player.index > 1
  itm.PlayerNext.Enabled = n > 1 and player.index < n
  itm.PlayerPlay.Enabled = take ~= nil
  -- A PNG keeps its brightness through :disabled, so a control that cannot
  -- act swaps to its dim twin; so do the bar and its timecodes.
  pcall(function()
    itm.PlayerPrev.Icon = ui:Icon{ File = Icons.path(itm.PlayerPrev.Enabled and "prev" or "prev_dim") }
    itm.PlayerNext.Icon = ui:Icon{ File = Icons.path(itm.PlayerNext.Enabled and "next" or "next_dim") }
  end)
  if player.bar_live ~= (take ~= nil) then
    player.bar_live = take ~= nil
    itm.PlayerSlider.Enabled = player.bar_live
    itm.PlayerSlider.StyleSheet = T.progress(not player.bar_live, not player.bar_live)
    itm.PlayerTimeNow.StyleSheet = T.label(player.bar_live and "mono_strong" or "mono_dim")
    itm.PlayerTimeTotal.StyleSheet = T.label(player.bar_live and "mono" or "mono_dim")
  end
  local playing = player.state == "playing"
  pcall(function()
    itm.PlayerPlay.Icon = ui:Icon{ File = Icons.path(playing and "pause" or (take and "play" or "play_dim")) }
  end)
  itm.PlayerPlay.ToolTip = playing and "Pause" or "Play"
  itm.PlayerStop.ToolTip = "Stop"
  itm.PlayerStop.Enabled = player.state ~= "stopped"
  -- A PNG keeps its brightness through :disabled, so the asset has to change.
  pcall(function()
    itm.PlayerStop.Icon = ui:Icon{ File = Icons.path(itm.PlayerStop.Enabled and "stop" or "stop_dim") }
  end)
  local dur = take and take.seconds or 0
  local at = math.min(player_elapsed(), dur)
  if not player.seeking then
    player.written = (dur > 0) and math.floor(at / dur * 1000) or 0
    itm.PlayerSlider.Value = player.written
  end
  local function mmss(sec) return ("%d:%02d"):format(math.floor(sec / 60), math.floor(sec % 60)) end
  itm.PlayerTimeNow.Text = mmss(take and at or 0)
  itm.PlayerTimeTotal.Text = mmss(dur)
  -- The line being played stays lit while it plays, editing or not: the
  -- index still points at the line the take was made from.
  local hl = (player.state ~= "stopped" and quick.last) and player.index or false
  repaint_box("QuickText", false, hl)
end

local function player_stop(silent)
  if player.state ~= "stopped" then P.audio_stop() end
  player.state, player.offset = "stopped", 0
  if not silent then player_refresh() end
end

local function player_play()
  local take = player_take()
  if not take then return end
  if preview.playing then P.audio_stop(); preview.playing = false end
  if not P.exists(take.path) then quick_note("That take's audio file is missing.", "error") return end
  if not P.can_play(take.path) then
    quick_note(("This platform can only play %s files — change the format in Settings."):format(table.concat(P.audio_play_formats(), ", ")), "error")
    return
  end
  if player.state == "paused" and P.audio_resume() then
    player.state, player.started = "playing", now()
  elseif player.state == "paused" and player.offset > 0
     and tostring(take.path):lower():match("%.wav$")
     and U.wav_slice(take.path, P.join(Config.tmp_dir(), "seek.wav"), player.offset) then
    -- Paused after a seek: nothing to resume, so play the remainder from there.
    P.audio_stop()
    P.run_detached(P.audio_play_cmd(P.join(Config.tmp_dir(), "seek.wav")))
    player.state, player.started = "playing", now()
  else
    P.audio_stop()
    P.run_detached(P.audio_play_cmd(take.path))
    player.state, player.started, player.offset = "playing", now(), 0
  end
  player.started_at = now()
  player_refresh()
end

--- Jump to a position in the current take. The system player cannot seek,
-- so the remainder of the file is written out and played from there.
local function player_seek(seconds)
  local take = player_take()
  if not take or not tostring(take.path):lower():match("%.wav$") then return false end
  seconds = math.max(0, math.min(seconds, (take.seconds or 0) - 0.05))
  local tmp = P.join(Config.tmp_dir(), "seek.wav")
  if not U.wav_slice(take.path, tmp, seconds) then return false end
  local resume = player.state == "playing"
  P.audio_stop()
  player.offset = seconds
  if resume then
    P.run_detached(P.audio_play_cmd(tmp))
    player.started, player.started_at = now(), now()
  else
    player.state = "paused"
  end
  player.seeking = nil
  player_refresh()
  return true
end

local function player_pause()
  if player.state ~= "playing" then return end
  if P.audio_pause() then
    player.offset = player_elapsed()
    player.state = "paused"
  else
    player_stop(true)   -- no pause on this platform: stop instead
  end
  player_refresh()
end

local function player_select(i)
  if not quick.last or not quick.last.takes[i] then return end
  local was_playing = player.state == "playing"
  player_stop(true)
  player.index = i
  if was_playing then player_play() else player_refresh() end
end

--- Called every tick. Two jobs: notice the user dragging the bar, and move
-- on when a take ends. The second half is throttled — it asks the OS
-- whether the player is alive, and forking that often would stutter the
-- very audio it is watching.
local function player_tick()
  local take = player_take()
  if not take then return end

  -- Anything in the slider we did not write ourselves is the user dragging.
  local value = itm.PlayerSlider.Value
  if player.written and math.abs(value - player.written) > 4 then
    player.seeking = { value = value, at = now() }
    player.written = value
  end
  if player.seeking and now() - player.seeking.at > 0.3 then
    player_seek(player.seeking.value / 1000 * (take.seconds or 0))
    return
  end

  if player.state ~= "playing" then return end
  if now() - (player.ticked or 0) < 0.25 then return end
  player.ticked = now()

  -- The take is over when the player process has gone (macOS) or, where
  -- that cannot be known, when the clock says so plus a little grace.
  local alive = P.audio_is_playing()
  local ended
  if alive ~= nil and now() - (player.started_at or 0) > 0.5 then
    ended = not alive
  else
    ended = player_elapsed() >= (take.seconds or 0) + 0.3
  end
  if ended then
    if quick.last.takes[player.index + 1] then
      player_select(player.index + 1)
    else
      player_stop(true)
      player.index = 1   -- back to the start, so Play replays the whole set
      player_refresh()
    end
    return
  end
  player_refresh()
end

--- The status line is written from state in one place, so it always
-- un-writes itself when the state that produced it goes away. A message
-- about something that just happened (a placement, a failed request) is
-- kept in `quick.note` until the next edit.
local function quick_refresh(keep_note)
  if not keep_note then quick.note = nil end
  local lines, chars, over = quick_lines()
  local n = #lines
  local counter = (n == 0) and "" or table.concat({
    span(c.text_2, ("%d line%s"):format(n, n == 1 and "" or "s")),
    span(over and c.error or c.text_2, fmt_int(chars) .. " chars"),
  }, span(c.text_3, " · "))
  itm.QuickGenerateBtn.Enabled = n > 0 and not over and not quick.busy
  itm.QuickStopBtn.Enabled = quick.busy and true or false
  -- Nothing may change the text under a run that is already using it.
  itm.QuickText.ReadOnly = quick.busy and true or false
  itm.QuickClearBtn.Enabled = itm.QuickText.PlainText ~= "" and not quick.busy
  itm.QuickOpenBtn.Enabled = not quick.busy
  itm.QuickTagInsert.Enabled = not quick.busy
  -- One clip: a single "Place on timeline". Several: the clip on show, or
  -- all of them in order.
  -- The takes stay placeable while the text is edited: each carries its own
  -- line. Only a new run (which clears them) or having none greys them out.
  local count = quick.last and #quick.last.takes or 0
  local why = (count == 0) and "Generate something first." or nil
  -- Built hidden, so it has no geometry until the window re-lays out.
  if quick.place_one_hidden ~= (count < 2) then
    quick.place_one_hidden = count < 2
    itm.QuickPlaceOneBtn.Hidden = quick.place_one_hidden
    relayout()
  end
  itm.QuickPlaceOneBtn.Enabled = count > 1
  itm.QuickPlaceOneBtn.ToolTip = why or "Put only the clip shown above on the timeline at the playhead."
  itm.QuickPlaceBtn.Text = count > 1 and ("Place all %d clips"):format(count) or "Place on timeline"
  itm.QuickPlaceBtn.Enabled = count > 0
  refresh_preview_where()
  itm.QuickPlaceBtn.ToolTip = why or (count > 1 and "Put every clip from this run on the timeline, in order, starting at the playhead."
                                                 or "Put the clip on the timeline at the playhead.")

  if over then
    quick_status((n > 1 and ("Line %d is over the %s-character limit — split it with a line break.")
                        or "Over the %s-character limit — break it into lines; each line becomes its own clip.")
      :format(n > 1 and over or fmt_int(Api.MAX_INPUT_CHARS), fmt_int(Api.MAX_INPUT_CHARS)), "error")
  elseif quick.busy then
    local p = quick.progress
    -- The dots are the only thing that moves while a request is out; the
    -- poll loop advances them (quick_tick_dots) so a long line looks alive.
    local dots = ("."):rep(quick.dots or 0)
    quick_status(((p and p.total > 1) and ("Generating %d/%d"):format(p.index, p.total) or "Generating") .. dots, "run")
  elseif quick.note then
    quick_status(quick.note.text, quick.note.kind)
  else
    -- Editing the text returns the line to being a counter; that the takes
    -- are now out of date is carried by Place on timeline going grey.
    quick_status(counter)
  end
end

function quick_note(text, kind)
  quick.note = { text = text, kind = kind }
  quick_refresh(true)
end

--- A file name next to the first take that has never been used. Resolve
-- keeps serving whatever it once imported from a path — even after the file
-- is deleted from disk — so the name carries the time as well as a counter.
local function subtitle_path(take)
  local base = tostring(take.path):gsub("%.[%w]+$", "") .. "_subtitles_" .. os.date("%Y%m%d-%H%M%S")
  local path, n = base .. ".srt", 1
  while P.exists(path) do n = n + 1; path = ("%s_%d.srt"):format(base, n) end
  return path
end

--- Subtitles for takes just placed at `starts`, ending at `ends` (absolute
-- frames, as Resolve placed them), as one
-- .srt on a subtitle track named like the VO track. A take Boson gave word
-- timings for is split (Settings); one without gets its whole line as one
-- subtitle over the clip. Returns the number added (or nil and why), and
-- how many takes went whole.
local function place_subtitles(takes, starts, ends)
  local fps = R.fps()
  local origin = starts[1]
  local all, untimed, timed = {}, 0, 0
  for i, take in ipairs(takes) do
    if take.text then
      local cues, method = Subs.for_take(take, app.cfg.subtitle_split)
      if method == "words" then
        timed = timed + 1
      else
        untimed = untimed + 1
        local length = (ends[i] and starts[i]) and (ends[i] - starts[i]) / fps or tonumber(take.seconds) or 0
        cues = Subs.whole(take.text, length)
      end
      local offset = (starts[i] - origin) / fps
      for _, cue in ipairs(cues) do
        cue.start, cue.finish = cue.start + offset, cue.finish + offset
        -- Bounded by the clip as placed: Resolve rounds a clip's length down
        -- to whole frames, so the take's own length can overrun it by one,
        -- and the playhead then lands a frame past the clip.
        cue.bound = ends[i] and (ends[i] - origin) / fps or (offset + (tonumber(take.seconds) or 0))
        all[#all + 1] = cue
      end
    end
  end
  local function done(added, err)
    Log.metric("subtitles.place", { cues = #all, added = added or 0, ok = added and 1 or 0,
      split = app.cfg.subtitle_split, timed = timed, untimed = untimed, error = err })
    return added, err, untimed
  end
  if #all == 0 then return done(nil, "these lines have no text to show") end
  Subs.frames(all, fps)
  -- The gap rule across placements: subtitles already on the track cannot be
  -- lengthened through the API, so when this run starts less than
  -- FILL_SECONDS after them, its first subtitle starts where they end.
  local prev_end = R.subtitle_track_end_for(app.cfg.vo_track_name, origin + all[1].from)
  if prev_end then
    local rel = prev_end - origin
    local gap = all[1].from - rel
    if gap > 0 and gap < math.floor(Subs.FILL_SECONDS * fps + 0.5) then all[1].from = rel end
  end
  local first = all[1].from
  local function write(lead)
    local text = Subs.srt(all, fps, lead)
    local path = subtitle_path(takes[1])
    if not U.write_file(path, text) then return nil, "Could not write " .. P.basename(path) end
    return path
  end
  local added, why = R.place_subtitles(app.cfg.vo_track_name, origin + first, write, #all)
  if added then return done(added) end
  return done(nil, why)
end

--- Put takes on the timeline, each after the one before it; the first sits
-- at the playhead or after whatever is already there. With Add subtitles
-- on, their subtitles follow.
local function quick_place(takes, mode)
  local placed, pushed_first, starts, ends = 0, false, {}, {}
  -- Automatic placing follows the box beside Generate; the Place buttons
  -- follow the one in the audio preview.
  local subtitles
  if mode == "auto" then subtitles = app.cfg.auto_subtitles == true
  else subtitles = app.cfg.manual_subtitles == true end
  local function done(ok, err)
    Log.metric("place.quick", { mode = mode or "all", clips = #takes, placed = placed, ok = ok and 1 or 0,
                                subtitles = subtitles and 1 or 0, error = err })
  end
  -- No timeline: say what to do, and that nothing is lost — every take is
  -- imported into the bin when it is generated.
  if not R.timeline() then
    done(false, "no timeline")
    quick_note(#takes == 1 and "Open a timeline to place this clip. It's already in your bin."
                            or "Open a timeline to place these clips. They're already in your bin.", "error")
    return false
  end
  for i, take in ipairs(takes) do
    local clip, err, pushed, at = place_new(take.path, ("quick_%s"):format(U.new_id()), 1)
    if not clip then
      done(false, err or "no clip")
      quick_note((placed > 0 and ("Placed %d, then failed: "):format(placed) or "") .. (err or "Could not place the clip."), "error")
      return false
    end
    placed = placed + 1
    starts[i] = at
    ends[i] = select(2, pcall(function() return clip:GetEnd() end))
    if type(ends[i]) ~= "number" then ends[i] = nil end
    if i == 1 then pushed_first = pushed end
  end
  local where = pushed_first and "after the clip at the playhead" or "at the playhead"
  done(true)
  local track = app.cfg.vo_track_name
  local what = placed == 1 and ("Placed on “%s” %s"):format(track, where)
                            or ("Placed %d clips on “%s”, starting %s"):format(placed, track, where)
  if not subtitles then
    quick_note(what .. ".", "ok")
    return true
  end
  local added, serr, whole = place_subtitles(takes, starts, ends)
  if not added then
    quick_note(("%s, but no subtitles: %s."):format(what, (serr or "Resolve did not add them"):gsub("%.$", "")), "error")
  elseif whole > 0 then
    quick_note(("%s, with subtitles — %s without word timing, shown whole."):format(what,
      whole == 1 and "1 line" or (whole .. " lines")), "ok")
  else
    quick_note(what .. ", with subtitles.", "ok")
  end
  return true
end

--- Advance the "Generating..." dots: none, one, two, three, round again.
local function quick_tick_dots()
  if not quick.busy then quick.dots = 0 return end
  if now() - (quick.dots_at or 0) < 0.4 then return end
  quick.dots_at = now()
  quick.dots = ((quick.dots or 0) + 1) % 4
  quick_refresh(true)
end

------------------------------------------------------------- tag colouring

--- Tags inside a text box are shown in their type's colour. The box is a
-- rich-text widget underneath; PlainText still comes back clean.
local function tag_type(value)
  if value:find("^emotion:") then return "Emotion"
  elseif value:find("^style:") then return "Style"
  elseif value:find("^prosody:speed_") then return "Speed"
  elseif value:find("^prosody:pitch_") then return "Pitch"
  elseif value:find("^prosody:expressive_") then return "Expressiveness"
  elseif value:find("^prosody:") then return "Pause"
  elseif value:find("^sfx:") then return "Sound effect" end
  return nil
end

local function tag_html(value)
  local color = T.tag_color[tag_type(value) or ""] or c.text_2
  return ("<span style='color:%s'>%s</span>"):format(color, esc("<|" .. value .. "|>"))
end

local function tagged_line_html(line)
  local out, pos = {}, 1
  for a, value, b in line:gmatch("()<|([^|>]-)|>()") do
    out[#out + 1] = esc(line:sub(pos, a - 1))
    out[#out + 1] = tag_html(value)
    pos = b
  end
  out[#out + 1] = esc(line:sub(pos))
  return table.concat(out)
end

--- `highlight` is the 1-based index among non-blank lines (the take being
-- played); that line gets a tinted background.
local function tagged_html(text, highlight)
  local rows, nth = {}, 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local html = tagged_line_html(line)
    if U.trim(line) ~= "" then
      nth = nth + 1
      if nth == highlight then
        html = ("<span style='background-color:%s'>%s</span>"):format(c.highlight, html)
      end
    end
    rows[#rows + 1] = html
  end
  -- Each line is its own paragraph with a little space under it, so a
  -- paragraph break reads differently from a wrapped line. New paragraphs
  -- typed later inherit the block format.
  -- pre-wrap keeps every space as typed: HTML would collapse two spaces to
  -- one, and the box would no longer match the text the caret is placed in.
  -- An empty line needs Qt's own empty-paragraph marker: a bare
  -- <p><br></p> reads back as two line breaks, so blank lines doubled on
  -- every repaint, and an empty <p></p> is dropped altogether.
  for i, html in ipairs(rows) do
    if html == "" then
      rows[i] = ("<p style='-qt-paragraph-type:empty; margin:0 0 5px 0; white-space:pre-wrap; color:%s'><br /></p>"):format(c.text)
    else
      rows[i] = ("<p style='margin:0 0 5px 0; white-space:pre-wrap; color:%s'>%s</p>"):format(c.text, html)
    end
  end
  return table.concat(rows)
end

--- U+E000, a private-use character that never appears in real text.
local SENTINEL = "\238\128\128"

--- Which tags the text holds, in order — not where. With positions in it,
-- every keystroke before a tag changed the signature and rebuilt the box,
-- which throws the caret to the start.
local function tag_signature(text)
  local parts = {}
  for value in text:gmatch("<|([^|>]-)|>") do parts[#parts + 1] = value end
  return table.concat(parts, ";")
end

--- Put the caret at a byte offset of `text` (what the box now holds) and
-- scroll it into view. Rewriting a box's text or HTML leaves the caret at
-- the start; there is no call to read or set its position, only to move it
-- a step at a time, so it walks there: by lines, then by characters from
-- whichever end of the line is nearer.
local function place_caret(box, text, offset)
  offset = math.max(0, math.min(offset or 0, #text))
  local before = text:sub(1, offset)
  local line = select(2, before:gsub("\n", ""))
  local line_start = (before:match(".*()\n") or 0)
  local col = U.utf8_len(before:sub(line_start + 1))
  local line_end = text:find("\n", offset + 1, true) or (#text + 1)
  local len = U.utf8_len(text:sub(line_start + 1, line_end - 1))
  pcall(function()
    box:MoveCursor("Start", "MoveAnchor")
    for _ = 1, line do box:MoveCursor("NextBlock", "MoveAnchor") end
    if col <= len - col then
      for _ = 1, col do box:MoveCursor("NextCharacter", "MoveAnchor") end
    else
      box:MoveCursor("EndOfBlock", "MoveAnchor")
      for _ = 1, len - col do box:MoveCursor("PreviousCharacter", "MoveAnchor") end
    end
    box:EnsureCursorVisible()
  end)
end

-- Re-rendering moves the caret to the end, so it happens only when the set
-- of tags changed (one typed or deleted by hand) or once after typing past
-- a tag at the very end, where the colour would otherwise carry on.
-- `keep_caret`: the user is typing, so the caret must end up where it was
-- (found by dropping a marker at it; typing never leaves a selection).
-- `caret`: a byte offset to put it at instead (after an inserted tag).
function repaint_box(id, force, highlight, keep_caret, caret)
  local box = itm[id]
  local text = box.PlainText
  local st = paint[id] or {}
  paint[id] = st
  if highlight == nil then highlight = st.highlight end   -- keep; pass false to clear
  if highlight == false then highlight = nil end
  local sig = tag_signature(text)
  local ends_with_tag = text:sub(-2) == "|>"
  local need = force or sig ~= (st.sig or "") or (st.after_tag and not ends_with_tag)
    or (highlight or 0) ~= (st.highlight or 0)
  st.sig, st.after_tag = sig, ends_with_tag
  if not need or (sig == "" and not highlight and not force and not st.was_painted) then return end
  st.was_painted = (sig ~= "") or (highlight ~= nil)
  st.highlight = highlight
  local was = suppress
  suppress = true
  if keep_caret and not caret then
    box:InsertPlainText(SENTINEL)
    local marked = box.PlainText
    local at = marked:find(SENTINEL, 1, true)
    if at then
      text = marked:sub(1, at - 1) .. marked:sub(at + #SENTINEL)
      caret = at - 1
    end
  end
  box.HTML = tagged_html(text, highlight)
  if caret then place_caret(box, text, caret) end
  suppress = was
end


--- Insert a tag into a text box exactly once, replacing whatever is
-- selected. The edit is worked out here rather than left to the widget:
-- InsertPlainText is the one call that reliably collapses a selection, so
-- it drops a marker, and the surrounding text is rebuilt around it.
-- `line_start` tags (speed, pitch, expressiveness) move to the front of
-- the caret's line, replacing any tag already there on the same axis.
function insert_tag(id, value, line_start)
  local box = itm[id]
  local was = suppress
  suppress = true
  box:InsertPlainText(SENTINEL)
  local text = box.PlainText
  local pos = text:find(SENTINEL, 1, true)
  if not pos then suppress = was return nil end

  local out, caret = Tags.place_tag(text:sub(1, pos - 1), text:sub(pos + #SENTINEL), value, line_start)
  box.PlainText = out
  suppress = was
  return out, caret
end

--- Every new take passes through here: the trailing pause is appended (wav
-- only), and the file goes into the Higgs VO bin straight away so it is in
-- the media pool whether or not it is ever placed.
local function finish_take(path)
  local pause = 0
  -- Boson returns mono; both channels carry it so the clip is centred.
  if tostring(path):lower():match("%.wav$") then U.wav_to_stereo(path) end
  if app.cfg.pause_enabled ~= false and tostring(path):lower():match("%.wav$") then
    local ms = tonumber(app.cfg.pause_ms) or 400
    if ms > 0 then
      if U.wav_append_silence(path, ms / 1000) then pause = ms / 1000
      else Log.warn("could not append silence to " .. path) end
    end
  end
  if not app.skip_sync then
    local mpi, err = R.import(path)
    if not mpi then Log.warn("import failed: " .. tostring(err)) end
  end
  return pause
end

--- The folder this project's clips are written to: the folder chosen in
-- Settings, plus the project's own name, so two projects never mix takes.
-- The name is re-read from Resolve at most once a second — a settings field
-- asks for it on every keystroke, and each answer is three API round trips.
local project_name_cache = { at = -1, name = "" }

local function project_name()
  if now() - project_name_cache.at > 1 then
    project_name_cache.name = R.project_name()
    project_name_cache.at = now()
  end
  return project_name_cache.name
end

local function output_dir()
  return Config.project_output_dir(app.cfg, project_name())
end

--- Top right of the Audio preview card: the folder the clips are written
-- to and the media-pool bin they are imported into. The folder name is cut
-- short (a label's text sets the window's width); the tooltip has the path.
function refresh_preview_where()
  local dir = output_dir()
  local folder = P.basename(dir)
  if U.utf8_len(folder) > 18 then
    local chars = {}
    for _, ch in U.utf8_chars(folder) do
      if #chars == 17 then break end
      chars[#chars + 1] = ch
    end
    folder = table.concat(chars) .. "…"
  end
  itm.PreviewWhere.Text = ("Saved in “%s” and the %s bin"):format(folder, R.BIN_NAME)
  itm.PreviewWhere.ToolTip = dir .. "\nMedia pool › " .. R.BIN_NAME
end

--- Where a take is written, named after its text the way Settings asks:
-- the first four words, then date, time and take number as chosen. A
-- number is added only when that name is already on disk.
local function clip_path(text, take_version, dir, ext)
  local o = app.cfg.clip_name or {}
  local parts = {}
  if o.words ~= false then parts[#parts + 1] = U.clip_words(text, 4) end
  if o.date then parts[#parts + 1] = os.date("%Y%m%d") end
  if o.time then parts[#parts + 1] = os.date("%H%M%S") end
  if o.take and take_version then parts[#parts + 1] = ("v%d"):format(take_version) end
  if #parts == 0 then
    -- Nothing chosen: just count up from 1.
    local k = 1
    while P.exists(P.join(dir, k .. "." .. ext)) do k = k + 1 end
    return P.join(dir, k .. "." .. ext)
  end
  local base = table.concat(parts, "_")
  local name, k = base, 2
  while P.exists(P.join(dir, name .. "." .. ext)) do
    name = ("%s_%d"):format(base, k)
    k = k + 1
  end
  return P.join(dir, name .. "." .. ext)
end

--- A bordered box around related rows. Groups paint no background here, so
-- the frame is four 1 px labels and the inset is spacer widgets.
local function card(rows)
  local function h_rule() return ui:Label{ Weight = 0, MinimumSize = { 40, 1 }, MaximumSize = { 4000, 1 }, StyleSheet = T.rule() } end
  local function v_rule() return ui:Label{ Weight = 0, MinimumSize = { 1, 10 }, MaximumSize = { 1, 4000 }, StyleSheet = T.rule() } end
  local function gap(w, h) return ui:Label{ Weight = 0, MinimumSize = { w, h }, MaximumSize = { w > 0 and w or 4000, h > 0 and h or 4000 } } end
  local inner = { Weight = 1, Spacing = 0, gap(0, 10) }
  for i, row in ipairs(rows) do
    if i > 1 then inner[#inner + 1] = gap(0, 8) end
    inner[#inner + 1] = row
  end
  inner[#inner + 1] = gap(0, 10)
  return ui:VGroup{ Weight = 0, Spacing = 0,
    h_rule(),
    ui:HGroup{ Weight = 0, Spacing = 0, v_rule(), gap(10, 0), ui:VGroup(inner), gap(10, 0), v_rule() },
    h_rule(),
  }
end

local function icon_button(id, name, tip)
  return ui:Button{ ID = id, Text = "", Weight = 0, Icon = ui:Icon{ File = Icons.path(name) }, IconSize = { 12, 12 },
                    StyleSheet = T.button("icon"), ToolTip = tip }
end

--- Dialogs sit 16 px from their edges. Group margins break window sizing,
-- so the inset is spacer widgets around the content.
local function inset(content, top)
  local function gap(w, h) return ui:Label{ Weight = 0, MinimumSize = { w, h }, MaximumSize = { w > 0 and w or 4000, h > 0 and h or 4000 } } end
  -- The measured frame is 16 px at the sides and 26 top and bottom. Only the
  -- 16 is ours: Qt puts its own layout margin above and below the window's
  -- content and it already exceeds anything set here, so taking these spacers
  -- to 2 changes nothing on screen. Tried and measured; left at 6.
  return ui:VGroup{
    Spacing = 0,
    gap(0, top or 6),
    ui:HGroup{ Weight = 1, Spacing = 0, gap(6, 0), content, gap(6, 0) },
    gap(0, 6),
  }
end

--------------------------------------------------------------------- import

-------------------------------------------------------------- tag list

--- Tags the Generate tab's list can insert mid-text. Speed, pitch and
-- expressiveness only take effect at the start of a take, so they stay in
-- the Delivery controls.
local function tag_rows()
  local rows = {}
  local function add(cat, value, label, line_start)
    rows[#rows + 1] = { cat = cat, value = value, label = title_case(label), line_start = line_start }
  end
  -- Emotion, style, speed, pitch and expressiveness set up the whole line,
  -- so Boson's guidance is to lead the line with them; the inserter moves
  -- them there and replaces one of the same kind. Pauses and sound effects
  -- go where the caret is.
  for _, e in ipairs(Tags.EMOTIONS) do add("Emotion", "emotion:" .. e, e, true) end
  for _, st in ipairs(Tags.STYLES) do add("Style", "style:" .. st, st, true) end
  for _, v in ipairs(Tags.SPEEDS) do if v.value ~= "" then add("Speed", "prosody:" .. v.value, v.label, true) end end
  for _, v in ipairs(Tags.PITCHES) do if v.value ~= "" then add("Pitch", "prosody:" .. v.value, v.label, true) end end
  for _, v in ipairs(Tags.EXPRESSIVENESS) do if v.value ~= "" then add("Expressiveness", "prosody:" .. v.value, v.label, true) end end
  for _, v in ipairs(Tags.PAUSES) do add("Pause", v.value, v.label, false) end
  for _, x in ipairs(Tags.SFX) do add("Sound effect", "sfx:" .. x, x, false) end
  return rows
end

--- The highlighted row of a list. A click sets the current item; a row
-- selected from code (the voice in use, on load) is only selected, and
-- CurrentItem() does not see it — so fall back to the selection.
local function highlighted_row(tree)
  local row = tree:CurrentItem()
  if row then return row end
  local ok, items = pcall(function() return tree:SelectedItems() end)
  if ok and type(items) == "table" then
    for _, it in pairs(items) do return it end
  end
  return nil
end

local TAG_TYPES = { "All types", "Emotion", "Style", "Speed", "Pitch", "Expressiveness", "Pause", "Sound effect" }
local quick_tag_rows = {}   -- rows currently shown in the tag list, in order

local function reload_quick_tags()
  local tree = itm.QuickTagTree
  tree:Clear()
  quick_tag_rows = {}
  local want = itm.QuickTagType.CurrentText
  local needle = U.trim(itm.QuickTagSearch.Text or ""):lower()
  for _, r in ipairs(tag_rows()) do
    if (want == "All types" or want == r.cat)
       and (needle == "" or r.label:lower():find(needle, 1, true) or r.cat:lower():find(needle, 1, true)) then
      local it = tree:NewItem()
      it.Text[0], it.Text[1] = r.label, r.cat
      pcall(function() it.TextColor[1] = T.tag_cell[r.cat] or T.cell.text_2 end)
      tree:AddTopLevelItem(it)
      quick_tag_rows[#quick_tag_rows + 1] = r
    end
  end
  tree.ColumnWidth[0] = 300
  if itm.QuickTagFoot then refresh_quick_tag_foot() end
end

local function selected_quick_tag()
  local item = highlighted_row(itm.QuickTagTree)
  if not item then return nil end
  for _, r in ipairs(quick_tag_rows) do
    if r.label == item.Text[0] and r.cat == item.Text[1] then return r end
  end
  return nil
end

--- The voice list on the Generate tab: the same voices as the Voices tab,
-- built for picking rather than managing. The selected row is the voice
-- the next take uses.
function reload_quick_voices()
  local tree = itm.QuickVoiceTree
  suppress = true
  tree:Clear()
  local current = quick.voice or app.cfg.default_voice
  for _, e in ipairs(voice_entries()) do
    local row = tree:NewItem()
    row.Text[0] = (e.value == current) and "★" or ""   -- the voice this tab uses
    row.Text[1] = e.label
    pcall(function()
      row.TextColor[0] = T.cell.accent
      if e.value == current then row.TextColor[1] = T.cell.accent end
    end)
    tree:AddTopLevelItem(row)
    if e.value == current then pcall(function() row.Selected = true end) end
  end
  tree.ColumnWidth[0] = 24
  suppress = false
  if refresh_quick_delete then refresh_quick_delete() end
end

--- The highlighted row becomes the voice for this tab only when confirmed
-- (button or double-click), so browsing the list changes nothing.
local function selected_quick_voice()
  local row = highlighted_row(itm.QuickVoiceTree)
  if not row then return nil end
  for _, e in ipairs(voice_entries()) do
    if e.label == row.Text[1] then return e end
  end
  return nil
end

--- Tags that only count at the start of a line say so along the bottom of
-- the list while one is highlighted; Insert moves them there.
function refresh_quick_tag_foot()
  local r = selected_quick_tag()
  local show = r and r.line_start or false
  itm.QuickTagFoot.Text = show and ("%s tags go to the start of the line automatically."):format(r.cat) or ""
  if itm.QuickTagFoot.Hidden == show then
    itm.QuickTagFoot.Hidden = not show
    itm.QuickTagTree.StyleSheet = show and T.tree_open_bottom() or T.tree()
    relayout()
  end
end

--- Only voices this user added can come off the list; the built-in ones
-- belong to the service.
function refresh_quick_delete()
  local e = selected_quick_voice()
  local own = e and Config.find_voice(app.cfg, e.value) ~= nil
  itm.QuickDeleteVoice.Enabled = own and true or false
  itm.QuickDeleteVoice.ToolTip = own and "Remove this voice from your list. It stays on your Boson account."
    or (e and "Built-in voices cannot be deleted." or "Pick a voice in the list first.")
end

--------------------------------------------------------------------- voices

-- Recording lives in its own dialog state: the widgets are rebuilt each time
-- the dialog opens, so nothing here can outlive it except the chosen mic,
-- which is a setting.
local REC_LIMIT = Rec.GOOD_MAX          -- hard stop; the recorder enforces it too
local REC_COUNT_IN = 3                  -- seconds of "3… 2… 1…" before "go"

--- Where a take is captured and kept while the dialog is open. Raw PCM while
-- recording, wrapped into a WAV the moment it stops.
--- Two take slots, used alternately, so "Record again" never destroys the
-- take the user already has.
local function take_path(slot)
  return P.join(Config.tmp_dir(), ("voice-take-%d.wav"):format(slot or 1))
end

local function add_voice_dialog()
  Log.ui("clone voice dialog")
  -- Resolve remembers geometry per window ID, so the harness overrides the
  -- ID per run; otherwise a capture inherits wherever the last one sat.
  local id = app.dialog_id or "HiggsVOAddVoice"
  local S = T.size
  local can_record = P.can_record()
  local unavailable = P.record_unavailable()
  local SRC_RECORD, SRC_FILE = 0, 1
  local REC_READY, REC_UNAVAILABLE = 0, 1

  local dlg = disp:AddWindow({
    ID = id, WindowTitle = "Add a voice",
    -- Sized for the transcript folded away; ticking it open grows the
    -- window, which is what a disclosure should look like.
    -- Sized for the transcript open, and it never changes: Qt grew the window
    -- when the box appeared and would not shrink it again when the box went,
    -- so the dialog only ever got taller. One size, no resizing.
    Geometry = app.dialog_geometry or { 220, 120, 700, 556 },
    MinimumSize = { 700, 556 }, Events = { Close = true },
  -- top = 0: the main window has no spacer above its tab strip, and this
  -- dialog should not look like a different product.
  }, inset(ui:VGroup{
    -- The same rhythm the Settings page uses between its option rows.
    Spacing = S.rows,

    -- Two ways to give Boson a reference, as tabs, and the tabs come first:
    -- everything under them belongs to the one that is chosen.
    ui:HGroup{
      Weight = 0, Spacing = 0,
      ui:TabBar{ ID = "SourceTabs", Weight = 0, Expanding = false, DrawBase = false, UsesScrollButtons = false,
                 MinimumSize = { 320, S.tab + 2 }, StyleSheet = T.tabs() },
      ui:Label{ Weight = 1 },
    },
    ui:VGap(2),

    -- The source is the point of this dialog, so it leads: the transport is
    -- the first thing under the tabs, and the name and the transcript are
    -- fields below it rather than things it sits between.
    ui:HGroup{
      Weight = 0, Spacing = 0,
      ui:Stack{
        ID = "SourceStack", Weight = 1,

        ui:Stack{
          ID = "RecordStack", Weight = 1,
          ui:VGroup{ ID = "PageRecord",
            Spacing = S.gap,
            card({
              ui:HGroup{
                Weight = 0, Spacing = S.gap,
                ui:Button{ ID = "RecBtn", Text = "Record", Weight = 0, MinimumSize = { 150, 0 },
                           Icon = ui:Icon{ File = Icons.path("record") }, IconSize = { 10, 10 },
                           StyleSheet = T.button("secondary") },
                ui:Label{ Weight = 1 },
              },
              -- Between the button and the player: guidance before a take,
              -- and what the take turned out to be afterwards.
              ui:HGroup{
                Weight = 0, Spacing = 0,
                ui:Label{ ID = "RecHint", Weight = 0, StyleSheet = T.label("meta"),
                          Alignment = { AlignLeft = true, AlignVCenter = true },
                          Text = "Speak normally, in the language you want this voice to generate.  " },
                ui:Button{ ID = "CloneDocsBtn", Text = "Learn more", Weight = 0,
                           StyleSheet = T.button("link") .. "QPushButton { font-size: 11px; padding: 0; min-height: 16px; }",
                           Alignment = { AlignVCenter = true } },
                ui:Label{ Weight = 1 },
              },
              -- The same instrument the Generate tab's audio preview uses:
              -- transport first, then the bar between its two timecodes.
              ui:HGroup{
                Weight = 0, Spacing = S.gap,
                icon_button("RecPlayBtn", "play", "Play the take"),
                icon_button("RecStopBtn", "stop", "Stop"),
                ui:Label{ Weight = 0, MinimumSize = { S.group - S.gap, 0 } },
                ui:Label{ ID = "RecTimeNow", Text = "0:00", Weight = 0, MinimumSize = { 36, 0 },
                          StyleSheet = T.label("mono_strong") },
                ui:Slider{ ID = "LevelBar", Weight = 1, Minimum = 0, Maximum = 1000, Value = 0,
                           Orientation = "Horizontal", Enabled = false,
                           MinimumSize = { 120, S.control }, MaximumSize = { 4000, S.control },
                           StyleSheet = T.progress(true, true) },
                ui:Label{ ID = "RecTime", Text = "0:30", Weight = 0, MinimumSize = { 44, 0 },
                          Alignment = { AlignRight = true, AlignVCenter = true }, StyleSheet = T.label("mono") },
              },
            }),
            -- An option, not the point: which input the take comes from.
            ui:HGroup{
              Weight = 0, Spacing = S.gap,
              ui:Label{ Text = "Microphone", Weight = 0, MinimumSize = { 96, 0 }, StyleSheet = T.label("secondary") },
              ui:Label{ ID = "MicName", Text = "", Weight = 1, StyleSheet = T.label("secondary"),
                        Alignment = { AlignLeft = true, AlignVCenter = true } },
              ui:Button{ ID = "MicSettingsBtn", Text = "Audio settings…", Weight = 0,
                         MinimumSize = { 128, 0 }, StyleSheet = T.button("ghost"),
                         ToolTip = "Change which input macOS records from." },
            },
          },

          -- Say what is missing once, instead of letting the user press Record
          -- and get nothing. Shown when the platform reports it cannot record.
          ui:VGroup{ ID = "PageUnavailable",
            Spacing = S.gap,
            ui:Label{ Text = "Recording is unavailable", Weight = 0, StyleSheet = T.label("strong") },
            ui:HGroup{
              Weight = 0, Spacing = S.gap,
              ui:Label{ ID = "UnavailableWhy", Weight = 1, WordWrap = true, StyleSheet = T.label("secondary"),
                        MinimumSize = { 40, 44 }, MaximumSize = { 4000, 44 },
                        Alignment = { AlignLeft = true, AlignTop = true }, Text = "" },
              ui:Button{ ID = "RetryRecordBtn", Text = "Look again", Weight = 0, StyleSheet = T.button("ghost") },
            },
            ui:Label{ Weight = 1, MinimumSize = { 0, 0 } },
          },
        },

        ui:VGroup{ ID = "PageFile",
          Spacing = S.gap,
          ui:HGroup{
            Weight = 0, Spacing = S.gap,
            ui:Label{ Text = "Recording", Weight = 0, MinimumSize = { 96, 0 }, StyleSheet = T.label("secondary") },
            ui:LineEdit{ ID = "RefPath", Weight = 1, StyleSheet = T.input(), ReadOnly = true,
                         PlaceholderText = "No file chosen" },
            icon_button("RefPlayBtn", "play", "Play the chosen file"),
            ui:Button{ ID = "RefBrowseBtn", Text = "Choose file…", Weight = 0, StyleSheet = T.button("secondary") },
          },
          ui:HGroup{
            Weight = 0, Spacing = S.gap,
            ui:Label{ Weight = 0, MinimumSize = { 96, 0 }, MaximumSize = { 96, 4000 } },
            ui:Label{ ID = "RefFileNote", Weight = 1, StyleSheet = T.label("meta"),
                      Alignment = { AlignLeft = true, AlignTop = true },
                      Text = "3 to 30 seconds  ·  wav, mp3, flac, aac or opus  ·  under 10 MB" },
          },
        },
      },
    },

    ui:HGroup{
      Weight = 0, Spacing = S.gap,
      ui:Label{ Text = "Voice name", Weight = 0, MinimumSize = { 96, 0 }, StyleSheet = T.label("secondary") },
      ui:LineEdit{ ID = "NewVoiceName", Weight = 1, StyleSheet = T.input(),
                   PlaceholderText = "e.g. Alex — narration" },
    },

    -- Boson takes a transcript but does not need one, so it starts folded
    -- away: anyone who does not want to type is never asked to.
    ui:HGroup{
      Weight = 0, Spacing = S.gap,
      ui:Label{ Weight = 0, MinimumSize = { 96, 0 } },
      ui:CheckBox{ ID = "TranscriptChk", Text = "Include transcript (optional)", Weight = 1,
                   StyleSheet = T.checkbox() },
    },
    ui:HGroup{
      ID = "TranscriptRow", Weight = 0, Spacing = S.gap, Hidden = true,
      ui:Label{ Weight = 0, MinimumSize = { 96, 0 } },
      ui:TextEdit{ ID = "RefText", Weight = 1, AcceptRichText = false,
                   MinimumSize = { 100, 84 }, MaximumSize = { 4000, 84 },
                   StyleSheet = T.input() .. "QTextEdit { font-size: 14px; padding: 8px 10px; }",
                   PlaceholderText = "What is said, word for word. Speak clearly, in the language you want this voice to generate." },
    },

    ui:Label{ Weight = 1, MinimumSize = { 0, 0 } },
    ui:CheckBox{ ID = "ConsentChk", Weight = 0, StyleSheet = T.checkbox(),
                 Text = "This is my own voice, or I have the speaker's permission to make a synthetic copy of it." },
    ui:VGap(6),
    ui:HGroup{
      Weight = 0, Spacing = S.gap,
      ui:Label{ ID = "VoiceDlgStatus", Text = "", Weight = 1, WordWrap = true,
                MinimumSize = { 40, 32 }, MaximumSize = { 4000, 32 },
                Alignment = { AlignLeft = true, AlignVCenter = true }, StyleSheet = T.label("meta") },
      ui:Button{ ID = "VoiceCancel", Text = "Cancel", Weight = 0, StyleSheet = T.button("ghost") },
      -- The primary's 110 px floor is for a toolbar, not for a footer button
      -- whose label already fills it.
      ui:Button{ ID = "CreateVoiceBtn", Text = "Create voice", Weight = 0,
                 StyleSheet = T.button("primary") .. "QPushButton { min-width: 96px; padding: 0 12px; }" },
    },
  }, 0))
  local d = dlg:GetItems()
  d.SourceTabs:AddTab("Record")
  d.SourceTabs:AddTab("Use a file")

  local created
  local mic_name = ""
  local source = can_record and SRC_RECORD or SRC_FILE
  -- state: "idle" | "counting" | "recording" | "take"
  -- Two take slots, used alternately, so "Record again" never destroys the
  -- take the user already has: the previous file is still on disk and one
  -- button brings it back.
  local rec = { state = "idle", take = nil, previous = nil, verdict = nil, started = 0,
                count_in_at = 0, seconds = 0, finish_at = 0,
                last_tick = 0, last_check = 0, meter = "idle", playing = false, paused = false,
                play_at = 0, play_started = 0, slot = 1 }

  local function relayout_dlg() pcall(function() dlg:RecalcLayout() end) end

  local function transcript() return U.trim(d.RefText.PlainText) end

  local function stop_playback()
    if rec.playing then P.audio_stop() end
    rec.playing, rec.paused, rec.play_at = false, false, 0
  end

  --- Where playback has reached, in seconds. The elapsed time is banked at
  -- each pause, so resuming continues from there instead of the bar jumping
  -- to wherever the wall clock had got to.
  local function play_position()
    if not rec.take then return 0 end
    local at = rec.play_at or 0
    if rec.playing and not rec.paused then at = at + (now() - rec.play_started) end
    return math.min(rec.take.seconds, at)
  end

  --- A take is recorded *from* a set of words; Boson is told those words. If
  -- the words on screen change afterwards — another passage, a switch to own
  -- words, an edit — the pair no longer match, and sending them would make a
  -- permanently worse voice from a button that looked safe.
  local function take_stale()
    -- A take made with no transcript has nothing to differ from: typing one
    -- afterwards is the normal order, not a mismatch.
    return rec.take ~= nil and rec.take.transcript ~= ""
       and rec.take.transcript ~= transcript()
  end

  --- True while the take is loaded into the transport, playing or paused.
  local function playing_back() return rec.playing and rec.take ~= nil end

  local refresh   -- forward: the handlers below all end by calling it

  ----------------------------------------------------------------- recording

  local NO_MIC = "Nothing reached the microphone. macOS asks for permission per app: open System Settings › Privacy & Security › Microphone, switch on DaVinci Resolve and restart it — or bring in a file on the other tab."

  local function rec_finish()
    local path = take_path(rec.slot)
    -- The recorder writes the WAV itself; it only needs to have finished.
    local stats = U.wav_stats(path)
    if stats.seconds <= 0 then
      rec.verdict = { ok = false, kind = "error", message = NO_MIC }
      return
    end
    rec.take = { path = path, seconds = stats.seconds, stats = stats, transcript = transcript() }
    rec.verdict = Rec.judge(stats, rec.take.transcript)
    if rec.verdict.silent then
      rec.take = nil
      rec.verdict = { ok = false, kind = "error", message = NO_MIC }
    end
    Log.metric("record.take", { seconds = stats.seconds, peak = stats.peak, rms = stats.rms,
                                hot_pct = stats.hot_ratio * 100, verdict = rec.verdict.kind })
  end

  local function rec_stop(keep)
    if not keep then
      P.record_kill()
      rec.state = "idle"
      return
    end
    -- Ask rather than kill: the recorder writes the file's length fields as it
    -- stops, and a signalled one never gets there. "finishing" is the wait.
    P.record_stop(take_path(rec.slot))
    rec.state, rec.finish_at = "finishing", now() + 3
  end

  local function rec_start()
    stop_playback()
    -- The take that exists becomes the fallback, and the new one is written
    -- to the other slot, so nothing is overwritten until it is replaced.
    if rec.take then rec.previous = rec.take; rec.slot = (rec.slot == 1) and 2 or 1 end
    local path = take_path(rec.slot)
    os.remove(path); os.remove(path .. ".pcm"); os.remove(path .. ".status"); os.remove(path .. ".stop")
    Log.info("record start", { input = Log.q(P.default_input_name()) })
    if not P.record_start(path, REC_LIMIT, REC_COUNT_IN) then
      rec.verdict = { ok = false, kind = "error", message = "The recorder would not start." }
      return
    end
    rec.state = "counting"
    rec.started = now()
    rec.take, rec.verdict, rec.count_in_at, rec.seconds = nil, nil, 0, 0
  end

  --- Called from the dialog's loop. Everything expensive is throttled: the
  -- meter reads 4 KB of the growing file, which is cheap, but anything that
  -- forks a process is not.
  local function rec_tick()
    if rec.state == "counting" then
      -- The countdown is the recorder's: it opened the device and scheduled
      -- capture against the audio clock, so what it reports is when the take
      -- actually begins. Nothing here guesses.
      local status = P.record_status(take_path(rec.slot))
      if status and status.failed then
        rec_stop(false)
        rec.verdict = { ok = false, kind = "error", message = NO_MIC }
        Log.warn("record failed: " .. tostring(status.message))
      elseif status and status.waiting then
        rec.count_left = status.waiting
      elseif status and status.seconds then
        rec.state, rec.count_left = "recording", nil
      elseif now() - rec.started > REC_COUNT_IN + 4 then
        rec_stop(false)
        rec.verdict = { ok = false, kind = "error", message = NO_MIC }
        Log.warn("record never reported a start")
      end
      refresh()
      return
    end

    if rec.state == "finishing" then
      local status = P.record_status(take_path(rec.slot))
      if (status and status.done) or now() > rec.finish_at then
        rec.state = "idle"
        rec_finish()
        refresh()
      end
      return
    end

    if rec.state ~= "recording" then
      if rec.playing and rec.take then
        if not rec.paused and play_position() >= rec.take.seconds - 0.05 then
          -- Ended on its own: back to the start, like every other player.
          stop_playback()
        elseif now() - rec.last_check > 0.25 then
          rec.last_check = now()
          if not rec.paused and P.audio_is_playing() == false then stop_playback() end
        end
        refresh()
      end
      return
    end

    if now() - rec.last_tick < 0.1 then return end
    rec.last_tick = now()
    local status = P.record_status(take_path(rec.slot))
    if status and status.failed then
      rec_stop(false)
      rec.verdict = { ok = false, kind = "error", message = NO_MIC }
      Log.warn("record failed: " .. tostring(status.message))
      refresh()
      return
    end
    local seconds = math.max(0, ((status and status.seconds) or 0) - (rec.count_in_at or 0))
    rec.peak = (status and status.peak) or 0
    -- While recording the bar is progress towards the limit and the clock
    -- counts *down*, because what the speaker needs to know is how much
    -- longer they may talk.
    if rec.meter ~= "live" then rec.meter = "live"; d.LevelBar.StyleSheet = T.progress(false, true) end
    d.LevelBar.Value = math.floor(math.min(1, seconds / REC_LIMIT) * 1000)
    d.RecTimeNow.Text = U.format_clock(seconds)
    d.RecTime.Text = "−" .. U.format_clock(math.max(0, REC_LIMIT - seconds))
    rec.seconds = seconds
    refresh()

    -- A denied microphone is silent and produces nothing at all. Say so now
    -- rather than after twenty seconds of talking to nothing.
    if not status and now() - rec.started > 2.5 and not rec.demo then
      rec_stop(false)
      rec.verdict = { ok = false, kind = "error", message = NO_MIC }
      Log.warn("record produced no status — microphone permission or device")
      refresh()
      return
    end
    if seconds >= REC_LIMIT and not rec.demo then rec_stop(true); refresh(); return end
    if rec.demo then return end   -- a captured state holds still for the camera
    if now() - rec.last_check > 1 then
      rec.last_check = now()
      if not P.record_is_running() then rec_stop(true); refresh() end
    end
  end

  -------------------------------------------------------------------- state

  --- One function paints every widget from `source`, `say` and `rec`. Nothing
  -- else writes to the dialog, so no state can be shown twice and disagree.
  --- QSS cannot dim a PNG, so a disabled icon button needs a different asset
  -- or it reads as live and invites a click that does nothing. Playing shows
  -- *pause*, not stop: stop is the button next to it and two identical
  -- glyphs one gap apart say nothing.
  local function play_icon(live, playing)
    if not live then return "play_dim" end
    return playing and "pause" or "play"
  end

  function refresh()
    local page_changed = d.SourceStack.CurrentIndex ~= source
    d.SourceStack.CurrentIndex = source
    d.PageFile.Hidden = (source ~= SRC_FILE)
    local rec_page = can_record and REC_READY or REC_UNAVAILABLE
    if source == SRC_RECORD then
      page_changed = page_changed or d.RecordStack.CurrentIndex ~= rec_page
      d.RecordStack.CurrentIndex = rec_page
    end
    d.PageRecord.Hidden = (source ~= SRC_RECORD) or (rec_page ~= REC_READY)
    d.PageUnavailable.Hidden = (source ~= SRC_RECORD) or (rec_page ~= REC_UNAVAILABLE)

    -- The transcript is folded away until it is asked for.
    local want_text = d.TranscriptChk.Checked
    if d.TranscriptRow.Hidden == want_text then
      d.TranscriptRow.Hidden = not want_text
      page_changed = true
    end
    local counting = (rec.state == "counting")
    local recording = (rec.state == "recording" or counting)
    local finishing = (rec.state == "finishing")
    if counting then
      -- The one number the user is watching belongs on the button they just
      -- pressed, and it is the recorder's own count, not a second clock.
      local left = math.max(1, math.ceil(rec.count_left or REC_COUNT_IN))
      d.RecBtn.Text = ("Starting in %d…"):format(left)
    else
      d.RecBtn.Text = (rec.state == "recording" and "Stop")
        or (finishing and "Saving…") or (rec.take and "Record again" or "Record")
    end
    d.RecBtn.Icon = ui:Icon{ File = Icons.path(recording and "stop" or "record") }
    d.RecBtn.Enabled = not finishing
    d.RecBtn.ToolTip = counting and "Cancel" or ""
    d.MicSettingsBtn.Enabled = not recording
    d.MicName.Text = (mic_name ~= "") and mic_name or "the system default input"
    d.RefText.ReadOnly = recording
    d.RecPlayBtn.Enabled = (rec.take ~= nil) and not recording
    d.RecStopBtn.Enabled = (rec.take ~= nil) and rec.playing
    d.RecStopBtn.Icon = ui:Icon{ File = Icons.path(d.RecStopBtn.Enabled and "stop" or "stop_dim") }
    d.RecPlayBtn.Icon = ui:Icon{ File = Icons.path(
      play_icon(d.RecPlayBtn.Enabled, rec.playing and not rec.paused and source == SRC_RECORD)) }

    -- One bar, two honest jobs: how far a recording has run, then where
    -- playback is in the take it produced.
    -- One scale for the bar whenever a take exists: position within that
    -- take. It used to be the take's length against the 30-second limit at
    -- rest and the position within the take while playing, so pressing play
    -- made the green jump.
    if not recording then
      local kind = rec.take and "take" or "idle"
      if rec.meter ~= kind then
        rec.meter = kind
        d.LevelBar.StyleSheet = T.progress(not rec.take, true)
      end
      local total = rec.take and rec.take.seconds or REC_LIMIT
      local at = rec.take and play_position() or 0
      d.LevelBar.Value = math.floor((at / math.max(0.01, total)) * 1000)
      d.RecTimeNow.Text = U.format_clock(at)
      d.RecTime.Text = U.format_clock(total)
    end

    -- Create is live only when it can succeed. What is missing is said by the
    -- button's own tooltip: the fields are in front of the user and the
    -- pointer is on the button.
    local dead_end = (source == SRC_RECORD) and not can_record
    local missing = {}
    if U.trim(d.NewVoiceName.Text) == "" then missing[#missing + 1] = "a name" end
    if dead_end then
      missing[#missing + 1] = "a file — recording is unavailable"
    elseif source == SRC_RECORD then
      if not rec.take then missing[#missing + 1] = "a recording"
      elseif take_stale() or (rec.verdict and not rec.verdict.ok) then
        missing[#missing + 1] = "a usable recording"
      end
    else
      local path = U.trim(d.RefPath.Text)
      if path == "" then missing[#missing + 1] = "a file"
      elseif not P.exists(path) then missing[#missing + 1] = "a file that still exists"
      elseif not P.can_play(path) and not path:lower():match("%.opus$") then
        missing[#missing + 1] = "an audio file Boson reads"
      elseif U.file_size(path) > Api.REF_MAX_BYTES then
        missing[#missing + 1] = ("a file under %d MB"):format(Api.REF_MAX_BYTES / 1048576)
      end
    end
    if want_text and transcript() == "" then missing[#missing + 1] = "the transcript" end
    if not d.ConsentChk.Checked then missing[#missing + 1] = "the permission box" end

    d.CreateVoiceBtn.Enabled = (#missing == 0) and not recording and not finishing and not rec.busy_creating
    d.CreateVoiceBtn.ToolTip = (#missing == 0) and ""
      or ("Still needed: " .. table.concat(missing, ", "))

    -- Only a blocking fault is worth a line. A take the user can hear needs no
    -- commentary from us; one the dialog will refuse to send has to say why.
    if not rec.busy_creating then
      -- The card's line is a status indicator: guidance before a take, the
      -- level in words while one runs, and what the take turned out to be
      -- afterwards — including when it turned out fine, because with no meter
      -- that is the only way to know.
      -- Only the Record tab has anything to say about a take: the verdict is
      -- about the microphone, and switching tabs changes the subject.
      local text, role = "", "meta"
      if source ~= SRC_RECORD then
        text, role = "", "meta"
      elseif recording then
        local note, note_role = Rec.level_note(rec.peak)
        text = note or Rec.coach(rec.seconds or 0, REC_LIMIT)
        role = note and note_role or "meta"
      elseif take_stale() then
        text, role = "This take was recorded from different words.", "warn"
      elseif rec.verdict and rec.verdict.kind == "error" then
        text, role = rec.verdict.message, "error"
      elseif rec.verdict and rec.verdict.clipped then
        text, role = rec.verdict.message, "warn"
      elseif rec.verdict and rec.verdict.good then
        text, role = rec.verdict.message, "ok"
      end
      -- A fault about the take belongs in the card, where the eye is; the
      -- footer keeps create-time status. One line, never both — saying it
      -- twice is the clutter this dialog was stripped back to avoid.
      local in_card = (source == SRC_RECORD) and text ~= ""
        and (rec.take ~= nil or recording)
      if in_card then
        d.RecHint.StyleSheet = T.label(role)
        d.RecHint.Text = text
        d.CloneDocsBtn.Hidden = true
      else
        d.RecHint.StyleSheet = T.label("meta")
        d.RecHint.Text = "Speak normally, in the language you want this voice to generate.  "
        d.CloneDocsBtn.Hidden = false
      end
      d.VoiceDlgStatus.StyleSheet = T.label(role)
      d.VoiceDlgStatus.Text = in_card and "" or text
    end

    -- Nothing to play until a file is chosen, so nothing to show either.
    local ref_path = U.trim(d.RefPath.Text)
    local can_play_ref = (source == SRC_FILE) and P.exists(ref_path) and P.can_play(ref_path)
    if d.RefPlayBtn.Hidden ~= (not can_play_ref) then
      d.RefPlayBtn.Hidden = not can_play_ref
      page_changed = true
    end
    if can_play_ref then
      d.RefPlayBtn.Icon = ui:Icon{ File = Icons.path((rec.playing and source == SRC_FILE) and "stop" or "play") }
    end
    d.VoiceCancel.Enabled = not rec.busy_creating
    if page_changed then relayout_dlg() end
  end

  ----------------------------------------------------------------- handlers

  local function reload_mic()
    mic_name = P.default_input_name()
    d.UnavailableWhy.Text = unavailable or ""
  end
  reload_mic()

  dlg.On.SourceTabs.CurrentChanged = function()
    -- Setting CurrentIndex in code also raises this, and a spurious pass here
    -- would stop a recording that is running. Only a real change counts.
    if d.SourceTabs.CurrentIndex == source then return end
    source = d.SourceTabs.CurrentIndex
    -- Keep, never drop: losing audio to a navigation click is the one thing a
    -- voice-over tool must not do.
    if rec.state ~= "idle" then
      rec_stop(true)
      -- rec_stop has already judged the take, and the File page says a take
      -- is waiting, so nothing here needs to touch the verdict — which is
      -- what made a refused take come back from a tab click looking fine.
    end
    stop_playback()
    refresh()
  end
  dlg.On.NewVoiceName.TextChanged = refresh
  dlg.On.ConsentChk.Clicked = refresh
  dlg.On.TranscriptChk.Clicked = refresh
  dlg.On.RecStopBtn.Clicked = function()
    stop_playback()
    refresh()
  end
  dlg.On.CloneDocsBtn.Clicked = function()
    Log.ui("open cloning docs")
    pcall(function() bmd.openurl("https://docs.boson.ai/models/higgs-tts/voices") end)
  end
  dlg.On.RefText.TextChanged = refresh
  dlg.On.MicSettingsBtn.Clicked = function()
    Log.ui("open sound settings")
    P.open_sound_settings()
  end
  dlg.On.RefPlayBtn.Clicked = function()
    local path = U.trim(d.RefPath.Text)
    if rec.playing then stop_playback()
    elseif P.exists(path) and P.can_play(path) then
      P.audio_stop()
      P.run_detached(P.audio_play_cmd(path))
      rec.playing, rec.last_check = true, now()
    end
    refresh()
  end
  dlg.On.RetryRecordBtn.Clicked = function()
    can_record = P.can_record()
    unavailable = P.record_unavailable()
    reload_mic()
    refresh()
  end
  dlg.On.RecBtn.Clicked = function()
    if rec.state == "counting" then
      -- Nothing was said yet, so this is not a new take at all: give the one
      -- that was set aside straight back.
      rec_stop(false)
      if rec.previous and not rec.take then
        rec.take, rec.previous = rec.previous, nil
        rec.slot = (rec.slot == 1) and 2 or 1
        rec.verdict = Rec.judge(rec.take.stats, rec.take.transcript)
      end
    elseif rec.state == "recording" then rec_stop(true)
    else rec_start() end
    refresh()
  end
  dlg.On.RecPlayBtn.Clicked = function()
    if not rec.take then return end
    if rec.playing and not rec.paused then
      -- Pause where it is, and bank the position so resuming continues.
      rec.play_at, rec.paused = play_position(), true
      P.audio_pause()
    elseif rec.playing and rec.paused then
      rec.paused, rec.play_started = false, now()
      P.audio_resume()
    else
      P.audio_stop()
      P.run_detached(P.audio_play_cmd(rec.take.path))
      rec.playing, rec.paused, rec.play_at = true, false, 0
      rec.play_started, rec.last_check = now(), now()
    end
    refresh()
  end
  dlg.On.RefBrowseBtn.Clicked = function()
    local path = pick(function() return fu:RequestFile("") end)
    if path and path ~= "" then d.RefPath.Text = tostring(path) end
    refresh()
  end

  local function close_dialog()
    -- A create in flight has already reached Boson. Closing now would leave a
    -- voice on the account that this plugin never learns the id of, and Boson
    -- has no way to delete one, so the window stays until the reply lands.
    if rec.busy_creating then
      d.VoiceDlgStatus.StyleSheet = T.label("warn")
      d.VoiceDlgStatus.Text = "Creating the voice — this takes a moment. Closing now would leave a voice on your account that this list cannot show."
      return
    end
    if rec.state ~= "idle" then rec_stop(false) end
    stop_playback()
    stop_loop()
  end
  dlg.On.VoiceCancel.Clicked = close_dialog
  dlg.On[id].Close = close_dialog

  dlg.On.CreateVoiceBtn.Clicked = function()
    local name = U.trim(d.NewVoiceName.Text)
    local ref = (source == SRC_RECORD) and (rec.take and rec.take.path) or U.trim(d.RefPath.Text)
    if not ref or ref == "" or not P.exists(ref) then return end
    stop_playback()
    rec.busy_creating = true
    d.VoiceDlgStatus.StyleSheet = T.label("meta")
    d.VoiceDlgStatus.Text = "Creating the voice…"
    d.CreateVoiceBtn.Enabled = false
    local how = (source == SRC_RECORD) and "recorded" or "file"
    Log.info("create voice", { name = Log.q(name), source = how, transcript_chars = U.utf8_len(transcript()) })
    app.api:create_voice({
      name = name, ref_audio_path = ref, ref_text = transcript(),
      on_done = function(res)
        rec.busy_creating = false
        Log.metric("voice.create", { source = how, ok = res.ok and 1 or 0,
                                     transcript = U.trim(transcript()) ~= "" and 1 or 0 })
        if not res.ok then
          d.VoiceDlgStatus.StyleSheet = T.label("error")
          -- Boson returns the same id for the same audio, so pressing Create
          -- again after a failure cannot produce a second voice.
          d.VoiceDlgStatus.Text = (res.error or "Could not create the voice.") ..
            " Trying again is safe — the same recording always makes the same voice."
          d.CreateVoiceBtn.Enabled = true
          return
        end
        local vid = res.data.id or res.data.voice_id or res.data.voice
        if not vid then
          d.VoiceDlgStatus.StyleSheet = T.label("error")
          d.VoiceDlgStatus.Text = "Boson did not return a voice id."
          d.CreateVoiceBtn.Enabled = true
          return
        end
        created = { id = vid, name = name }
        close_dialog()
      end,
    })
  end

  -- The screenshot harness drives the dialog into a chosen state; nothing
  -- here runs in the product (app.demo_addvoice is only ever set by tests).
  if type(app.demo_addvoice) == "table" then
    local demo = app.demo_addvoice
    if demo.no_record then can_record = false; unavailable = "Recording isn't available on this Mac right now. Press Look again, or bring in a file on the other tab."; reload_mic() end
    if demo.source == "file" then source = SRC_FILE end
    if demo.name then d.NewVoiceName.Text = demo.name end
    if demo.consent then d.ConsentChk.Checked = true end
    if demo.file then d.RefPath.Text = demo.file end
    if demo.transcript_on then d.TranscriptChk.Checked = true end
    if demo.transcript then d.RefText.PlainText = demo.transcript end
    if demo.recording then
      rec.state, rec.demo, rec.count_in_at = "recording", true, 0
      rec.seconds, rec.started = demo.recording, now()
      rec.started = now() - demo.recording
    elseif demo.take then
      rec.take = { path = take_path(1), seconds = demo.take.seconds,
                   stats = demo.take, transcript = transcript() }
      rec.verdict = Rec.judge(demo.take, transcript())
      if rec.verdict.silent then rec.take = nil end
      -- Pretend the words moved after the take was made.
      if demo.stale then rec.take.transcript = Rec.PASSAGES[2] end
      if demo.previous then rec.previous = { seconds = 14.8, stats = demo.take, transcript = rec.take.transcript } end
    elseif demo.no_permission then
      rec.verdict = { ok = false, kind = "error", message = NO_MIC }
    end
  end

  refresh()
  d.SourceTabs.CurrentIndex = source
  -- The dialog runs its own loop, so it must keep the API polling alive and
  -- drive the recorder.
  dlg:Show()
  run_loop(function() app.api:poll(); rec_tick() end)
  dlg:Hide()
  if rec.state ~= "idle" then P.record_kill() end
  P.audio_stop()
  for slot = 1, 2 do
    local path = take_path(slot)
    for _, suffix in ipairs({ "", ".pcm", ".status", ".stop" }) do os.remove(path .. suffix) end
  end
  if created then
    Config.add_voice(app.cfg, created.id, created.name)
    Config.save(app.cfg)
    reload_voice_combos()
    quick_note(("Created “%s”. It's in your voice list."):format(created.name), "ok")
  end
end

--- Play a short sample of a voice. The first play generates and caches it;
-- later plays are instant. Only a failure says anything.
--- Both Preview buttons read "Stop" while a sample is playing.
local function refresh_preview_buttons()
  local label = preview.loading and "Loading…" or (preview.playing and "Stop" or "Preview")
  pcall(function() itm.QuickPreviewVoice.Text = label end)
end

local function preview_stop()
  if not preview.playing then return end
  P.audio_stop()
  preview.playing = false
  refresh_preview_buttons()
end

local function preview_start(path) end   -- replaced below; declared for clarity

function preview_start(path)
  P.audio_stop()        -- a second click restarts rather than layering
  P.run_detached(P.audio_play_cmd(path))
  preview.playing, preview.loading, preview.started = true, false, now()
  refresh_preview_buttons()
end

local function preview_voice(id, name, on_error)
  -- The first sample for a voice has to be generated, which takes a few
  -- seconds; the button says so and further clicks are ignored until it
  -- either plays or fails.
  if preview.loading then return end
  if preview.playing then preview_stop() return end
  player_stop(true)     -- one thing owns the speakers at a time
  local dir = P.join(Config.tmp_dir(), "previews")
  if not P.exists(dir) then P.mkdirs(dir) end
  local path = P.join(dir, U.sanitize(id) .. "." .. ext_for_preview())
  if P.exists(path) then preview_start(path) return end
  preview.loading = true
  refresh_preview_buttons()
  Log.metric("voice.preview", { voice = Api.is_preset(id) and tostring(id) or "cloned" })
  app.api:speech({
    text = "Here's how this voice sounds reading your script.",
    voice = id, format = ext_for_preview(), out_path = path,
    on_done = function(res)
      preview.loading = false
      refresh_preview_buttons()
      if not res.ok then
        local msg = res.error or ("Could not generate a preview of %s."):format(name)
        if on_error then on_error(msg) else quick_note(msg, "error") end
        return
      end
      preview_start(res.path)
    end,
  })
end

------------------------------------------------------------------ the window

local function field(label_text, widget)
  return ui:VGroup{ Weight = 1, Spacing = 3,
    ui:Label{ Text = label_text, Weight = 0, StyleSheet = T.label("secondary") },
    widget,
  }
end

--- Section heading with its rule, the thing that anchors an Inspector group.
local function section(text)
  return ui:VGroup{ Weight = 0, Spacing = 0,
    ui:Label{ Text = text, Weight = 0, StyleSheet = T.label("section") },
    ui:VGap(2),
  }
end

--- A section title with actions on the same row. The strut holds the row at
-- control height whether or not buttons are present, so a plain title in the
-- next column (see `section_row(text)` with no actions) lines up with it.
local function section_row(text, ...)
  local row = { Weight = 0, Spacing = T.size.gap,
    ui:Label{ Text = text, Weight = 0, StyleSheet = T.label("section") },
    -- A button renders 2 px taller than `control` (its border sits outside
    -- the size), measured; the strut matches it so both columns' boxes start
    -- on the same pixel row.
    ui:Label{ Weight = 1, MinimumSize = { 0, T.size.control + 2 } },
  }
  for _, w in ipairs({ ... }) do row[#row + 1] = w end
  return ui:HGroup(row)
end

local function settings_row(label_text, widget, trailing)
  local row = { Weight = 0, Spacing = T.size.gap,
    ui:Label{ Text = label_text, Weight = 0, MinimumSize = { 150, 0 }, StyleSheet = T.label("secondary") },
    widget,
  }
  if trailing then row[#row + 1] = trailing end
  return ui:HGroup(row)
end

local function build()
  local S = T.size
  -- Never set Margin on a group here: this UIManager build lays the window out
  -- for a different size than it draws, and content clips at the edges.
  win = disp:AddWindow({
    ID = WIN_ID,
    WindowTitle = Config.APP_NAME,
    Geometry = app.window_geometry or { 160, 80, 1000, 780 },   -- the harness may move it
    MinimumSize = { 1000, 780 },
    Events = { Close = true },
  }, ui:HGroup{
    -- Side padding for every page. Margin on a group breaks the window
    -- (above), so fixed-width labels hold the content in from Qt's own
    -- ~10 px frame.
    Spacing = 0,
    ui:Label{ Weight = 0, MinimumSize = { S.pad, 0 }, MaximumSize = { S.pad, 4000 } },
    ui:VGroup{
    Weight = 1, Spacing = S.gap,

    ------------------------------------------------------------- tab strip
    ui:HGroup{
      Weight = 0, Spacing = 0,
      ui:TabBar{ ID = "MainTabs", Weight = 0, Expanding = false, DrawBase = false, UsesScrollButtons = false,
                 MinimumSize = { 853, S.tab + 2 }, StyleSheet = T.tabs() },
      ui:Label{ Weight = 1 },
      -- The connection badge, a pill so it reads as a status chip rather than
      -- a stray line of text. Its width is fixed at the widest state's text:
      -- the window opens at the width its rows ask for (label text counts in
      -- full, MinimumSize on groups and stacks does not), so this row is the
      -- one that pins the width, with the window's own 1000 px minimum.
      ui:Label{ ID = "ConnLabel", Text = "", Weight = 0, FixedSize = { 96, T.PILL_H },
                Alignment = { AlignCenter = true }, StyleSheet = T.status_pill() },
    },
    ui:VGap(6),   -- with the group's spacing either side: 18 px from tabs to page

    ui:Stack{
      ID = "MainStack", Weight = 1,

      ----------------------------------------------------------- generate
      ui:Stack{
        ID = "GenerateStack", Weight = 1,

        -- page 0: setup ----------------------------------------------------
        ui:VGroup{ ID = "PageSetup",
          -- 2:3 above and below: centred measured low (the reserved error
          -- line weighs the bottom), so the block sits at the optical centre.
          ui:Label{ Weight = 2, MinimumSize = { 0, 0 } },
          ui:HGroup{
            Weight = 0,
            ui:Label{ Weight = 1, MinimumSize = { 0, 0 } },
            -- One 480 px column, built like a Settings row: what this is, where
            -- to get a key, the field, then the two ways on. Spacing is set
            -- gap by gap (the group's own is 0) so each step reads as a step.
            ui:VGroup{
              Weight = 0, Spacing = 0,
              ui:Label{ Text = "Connect your Boson account", Weight = 0, StyleSheet = T.label("hero") },
              -- Three gap sizes: ~8 inside a group, ~16–20 between rows, one
              -- ~37 break between the explanation and the form (art review r10).
              ui:VGap(6),
              -- Groups ignore MinimumSize for their width; this label pins the
              -- column to 480 so every row starts on the same left edge.
              -- A wrapped label does not grow to its text: the height is three
              -- lines at 18 px, set by hand (and re-measured when the copy changes).
              ui:Label{ Weight = 0, WordWrap = true, MinimumSize = { 480, 56 }, MaximumSize = { 480, 56 }, StyleSheet = T.label("secondary"),
                Text = "Higgs VoiceOver runs on Boson's Higgs TTS 3. To use it, get an API key from your Boson Workspace. New accounts include $10 of free credit, about 650,000 characters (roughly 12 hours of audio)." },
              ui:VGap(10),
              ui:HGroup{
                Weight = 0, Spacing = 0,
                ui:Button{ ID = "SetupGetKeyBtn", Text = "Get a key at boson.ai", Weight = 0, StyleSheet = T.button("link_flush") },
                ui:Label{ Weight = 1, MinimumSize = { 0, 0 } },
              },
              ui:VGap(28),
              ui:Label{ Text = "API key", Weight = 0, StyleSheet = T.label("secondary") },
              ui:VGap(6),
              ui:HGroup{
                Weight = 0, Spacing = S.gap,
                ui:LineEdit{ ID = "SetupKey", Weight = 1, EchoMode = "Password", StyleSheet = T.input(),
                             PlaceholderText = "Paste your Boson API key",
                             Events = { ReturnPressed = true, TextChanged = true } },
                ui:CheckBox{ ID = "SetupShowKey", Text = "Show", Weight = 0, StyleSheet = T.checkbox() },
              },
              ui:VGap(20),
              ui:HGroup{
                Weight = 0, Spacing = S.gap,
                ui:Button{ ID = "SetupTestBtn", Text = "Connect", Weight = 0,
                           StyleSheet = T.button("primary") .. "QPushButton { min-width: 96px; }" },
                ui:Button{ ID = "SetupSkipBtn", Text = "Skip for now", Weight = 0,
                           StyleSheet = T.button("secondary") .. "QPushButton { min-width: 96px; }",
                           ToolTip = "Look around first. You'll need a key before you can generate." },
                ui:Label{ Weight = 1, MinimumSize = { 0, 0 } },
              },
              ui:VGap(10),
              -- The result has a line of its own, held open even when empty,
              -- so a message appearing never moves anything above or below it.
              ui:Label{ ID = "SetupStatus", Text = "", Weight = 0, MinimumSize = { 480, 20 }, MaximumSize = { 480, 20 },
                        StyleSheet = T.label("meta") },
            },
            ui:Label{ Weight = 1, MinimumSize = { 0, 0 } },
          },
          ui:Label{ Weight = 3, MinimumSize = { 0, 0 } },
        },

        -- page 1: quick generate -------------------------------------------
        ui:VGroup{ ID = "PageQuick",
          Spacing = 8,
          ui:HGroup{
            Weight = 1, Spacing = S.group,
            -- left: pick a voice, insert tags
            ui:VGroup{
              Weight = 0, Spacing = 8,
              section_row("Voice"),
              ui:Tree{ ID = "QuickVoiceTree", Weight = 1, MinimumSize = { 460, 120 }, MaximumSize = { 460, 4000 },
                       StyleSheet = T.tree(), RootIsDecorated = false, AlternatingRowColors = false,
                       SelectionMode = "SingleSelection", ToolTip = "Double-click a voice to use it.",
                       Events = { ItemDoubleClicked = true, CurrentItemChanged = true } },
              ui:HGroup{
                Weight = 0, Spacing = S.gap,
                ui:Button{ ID = "QuickAddVoice", Text = "Add voice…", Weight = 0, StyleSheet = T.button("ghost") },
                ui:Button{ ID = "QuickPreviewVoice", Text = "Preview", Weight = 0, StyleSheet = T.button("ghost") },
                ui:Button{ ID = "QuickDeleteVoice", Text = "Delete", Weight = 0, StyleSheet = T.button("danger_ghost") },
                ui:Label{ Weight = 1 },
                ui:Button{ ID = "QuickVoiceUse", Text = "Use this voice", Weight = 0, StyleSheet = T.button("secondary") },
              },
              ui:VGap(8),
              section("Tags"),
              ui:HGroup{
                Weight = 0, Spacing = S.gap,
                ui:LineEdit{ ID = "QuickTagSearch", Weight = 1, MinimumSize = { 60, 0 }, StyleSheet = T.input(),
                             PlaceholderText = "Search tags" },
                ui:ComboBox{ ID = "QuickTagType", Weight = 0, MinimumSize = { 140, 0 }, StyleSheet = T.combo() },
                ui:Button{ ID = "QuickTagInsert", Text = "Insert", Weight = 0, StyleSheet = T.button("secondary") },
              },
              -- The list and its foot note are one box; the note appears only
              -- for tags that go at the start of the line.
              ui:VGroup{
                Weight = 1, Spacing = 0,
                ui:Tree{ ID = "QuickTagTree", Weight = 1, MinimumSize = { 460, 120 }, MaximumSize = { 460, 4000 },
                         StyleSheet = T.tree(), RootIsDecorated = false, AlternatingRowColors = false,
                         SelectionMode = "SingleSelection",
                         ToolTip = "Double-click a tag to insert it where the cursor is.",
                         Events = { ItemDoubleClicked = true, CurrentItemChanged = true } },
                ui:Label{ ID = "QuickTagFoot", Text = "", Weight = 0, Hidden = true,
                          MinimumSize = { 460, 32 }, MaximumSize = { 460, 32 }, StyleSheet = T.tree_foot() },
              },
            },
            -- right: the text, then the preview of what it made
            ui:VGroup{
              Weight = 1, Spacing = 8,
              section_row("Text",
                ui:Button{ ID = "QuickClearBtn", Text = "Clear", Weight = 0, StyleSheet = T.button("ghost"),
                           ToolTip = "Empty the text box." },
                ui:Button{ ID = "QuickOpenBtn", Text = "Import from file…", Weight = 0, StyleSheet = T.button("ghost") },
                ui:Button{ ID = "QuickExportBtn", Text = "Save as .txt…", Weight = 0, StyleSheet = T.button("ghost") }),
              ui:TextEdit{ ID = "QuickText", Weight = 1, MinimumSize = { 200, 200 }, AcceptRichText = false,
                           StyleSheet = T.input(),
                           PlaceholderText = "Type or paste what you want said. Each line becomes its own clip." },
              -- What Generate does besides generating, then the run itself.
              ui:HGroup{
                Weight = 0, Spacing = S.gap,
                ui:CheckBox{ ID = "AutoPlaceChk", Text = "Place on timeline", Weight = 0, StyleSheet = T.checkbox(),
                             ToolTip = "Put every clip from the run on the timeline at the playhead as soon as generation finishes." },
                ui:Label{ Weight = 0, MinimumSize = { S.group - S.gap, 0 } },
                ui:CheckBox{ ID = "AutoSubsChk", Text = "Add subtitles", Weight = 0, StyleSheet = T.checkbox(),
                             ToolTip = "When clips go on the timeline automatically, add their subtitles too. Set how they are split in Settings." },
                ui:Label{ Weight = 1 },
                ui:Button{ ID = "QuickStopBtn", Text = "Stop", Weight = 0, StyleSheet = T.button("ghost") },
                ui:Button{ ID = "QuickGenerateBtn", Text = "Generate", Weight = 0,
                           StyleSheet = T.button("primary") .. "QPushButton { min-width: 120px; }" },
              },
              ui:VGap(2),
              -- audio preview: the takes of the latest generation, in a card.
              -- Row 1 names the take and pages through them; row 2 is the
              -- transport. Both stay narrow: their hints set this column's width.
              card({
                -- The title, and where the clips of a run are kept.
                ui:HGroup{
                  Weight = 0, Spacing = S.gap,
                  ui:Label{ ID = "PreviewTitle", Text = "Audio preview", Weight = 0, StyleSheet = T.label("section") },
                  ui:Label{ Weight = 1 },
                  ui:Label{ ID = "PreviewWhere", Text = "", Weight = 0, StyleSheet = T.label("meta"),
                            Alignment = { AlignRight = true, AlignVCenter = true } },
                },
                -- The take's name reads first; its pager sits at the right end,
                -- above play and stop, so both rows end at the same edge.
                ui:HGroup{
                  Weight = 0, Spacing = S.gap,
                  ui:Label{ ID = "PlayerIndex", Text = "", Weight = 0, StyleSheet = T.pill(),
                            Alignment = { AlignCenter = true }, Hidden = true },
                  ui:Label{ ID = "PlayerIndexGap", Weight = 0, MinimumSize = { 6, 0 }, MaximumSize = { 6, 4000 }, Hidden = true },
                  ui:Label{ ID = "PlayerName", Text = "", Weight = 1, MinimumSize = { 40, 0 }, StyleSheet = T.label("meta") },
                  ui:Label{ Weight = 0, MinimumSize = { S.group - S.gap, 0 } },
                  icon_button("PlayerPrev", "prev", "Previous line"),
                  icon_button("PlayerNext", "next", "Next line"),
                },
                -- The bar between its two timecodes, then the transport.
                ui:HGroup{
                  Weight = 0, Spacing = S.gap,
                  ui:Label{ ID = "PlayerTimeNow", Text = "0:00", Weight = 0, MinimumSize = { 36, 0 }, StyleSheet = T.label("mono_strong") },
                  -- Drag the handle to move within the take. The widget sends
                  -- no events at all, so a drag is noticed by polling its value
                  -- against the last one written here; its track ignores clicks.
                  ui:Slider{ ID = "PlayerSlider", Weight = 1, Minimum = 0, Maximum = 1000, Value = 0,
                             Orientation = "Horizontal", ToolTip = "Drag to move within the take",
                             MinimumSize = { 120, T.size.control }, MaximumSize = { 4000, T.size.control },
                             StyleSheet = T.progress(false) },
                  ui:Label{ ID = "PlayerTimeTotal", Text = "0:00", Weight = 0, MinimumSize = { 36, 0 }, StyleSheet = T.label("mono"),
                            Alignment = { AlignRight = true, AlignVCenter = true } },
                  ui:Label{ Weight = 0, MinimumSize = { S.group - S.gap, 0 } },   -- air before the transport
                  icon_button("PlayerPlay", "play", "Play"),
                  icon_button("PlayerStop", "stop", "Stop"),
                },
                -- Playing a finished run, then placing: the clip on show, or the whole run.
                ui:HGroup{
                  Weight = 0, Spacing = S.gap,
                  ui:CheckBox{ ID = "AutoPreviewChk", Text = "Play audio when done", Weight = 0, StyleSheet = T.checkbox(),
                               ToolTip = "Start the audio preview as soon as generation finishes." },
                  ui:Label{ Weight = 0, MinimumSize = { S.group - S.gap, 0 } },
                  -- Its own setting: subtitles with the place buttons beside it.
                  -- The box by Generate is for automatic placing.
                  ui:CheckBox{ ID = "PreviewSubsChk", Text = "Add subtitles", Weight = 0, StyleSheet = T.checkbox(),
                               ToolTip = "When you place clips with these buttons, add their subtitles too. Set how they are split in Settings." },
                  ui:Label{ Weight = 1 },
                  ui:Button{ ID = "QuickPlaceOneBtn", Text = "Place this clip", Weight = 0, StyleSheet = T.button("ghost"), Hidden = true },
                  ui:Button{ ID = "QuickPlaceBtn", Text = "Place all clips", Weight = 0, StyleSheet = T.button("secondary") },
                },
              }),
            },
          },
          ui:VGap(4),
          ui:HGroup{
            Weight = 0, Spacing = S.gap,
            -- One indicator: the character count at rest, the run's progress,
            -- its result, or what went wrong.
            ui:Label{ ID = "QuickStatus", Text = "", Weight = 1, MinimumSize = { 300, T.size.control }, StyleSheet = T.label("mono") },
          },
        },
      },

      ------------------------------------------------------------ settings
      ui:VGroup{ ID = "TabSettings",
        Spacing = S.section,
        ui:VGroup{
          Weight = 0, Spacing = S.rows,
          section("Boson account"),
          settings_row("API key",
            ui:LineEdit{ ID = "ApiKeyEdit", Weight = 1, EchoMode = "Password", StyleSheet = T.input(),
                         PlaceholderText = "Paste your Boson API key" },
            ui:CheckBox{ ID = "ShowKeyChk", Text = "Show", Weight = 0, StyleSheet = T.checkbox() }),
          -- Second row: the action, where to get a key, and the test result.
          settings_row("", ui:HGroup{ Weight = 1, Spacing = S.gap,
            ui:Button{ ID = "TestKeyBtn", Text = "Test connection", Weight = 0, StyleSheet = T.button("secondary") },
            ui:Button{ ID = "GetKeyBtn", Text = "Get a key at boson.ai", Weight = 0, StyleSheet = T.button("link") },
            ui:Label{ ID = "SettingsKeyStatus", Text = "", Weight = 1, MinimumSize = { 40, 0 }, StyleSheet = T.label("meta") } }),
        },
        ui:VGroup{
          Weight = 0, Spacing = S.rows,
          section("Audio output"),
          settings_row("Format",
            ui:HGroup{ Weight = 1, Spacing = S.gap,
              ui:ComboBox{ ID = "FormatCombo", Weight = 0, MinimumSize = { 110, 0 }, StyleSheet = T.combo() },
              ui:Label{ Weight = 1 } }),
          settings_row("Pause after each clip",
            ui:HGroup{ Weight = 1, Spacing = S.gap,
              ui:CheckBox{ ID = "PauseChk", Text = "Add silence at the end of every clip", Weight = 0, StyleSheet = T.checkbox() },
              ui:LineEdit{ ID = "PauseMs", Weight = 0, MinimumSize = { 64, 0 }, MaximumSize = { 64, 4000 }, StyleSheet = T.input() },
              ui:Label{ Text = "ms", Weight = 0, StyleSheet = T.label("secondary") },
              ui:Label{ Weight = 0, MinimumSize = { 8, 0 } },
              ui:Label{ Text = "wav only", Weight = 1, MinimumSize = { 40, 0 }, StyleSheet = T.label("meta") } }),
        },
        ui:VGroup{
          Weight = 0, Spacing = S.rows,
          section("Files"),
          -- The field holds the folder; the label after it is the project's own
          -- subfolder, which Higgs VO adds so two projects never mix takes.
          settings_row("Save clips in",
            ui:HGroup{ Weight = 1, Spacing = 0,
              ui:LineEdit{ ID = "OutDir", Weight = 1, StyleSheet = T.input() },
              ui:Label{ ID = "OutDirProject", Text = "", Weight = 0, StyleSheet = T.label("secondary"),
                        Alignment = { AlignLeft = true, AlignVCenter = true } } },
            ui:Button{ ID = "BrowseOutBtn", Text = "Browse…", Weight = 0, StyleSheet = T.button("ghost") }),
          settings_row("Add to the name",
            ui:HGroup{ Weight = 1, Spacing = S.group,
              ui:CheckBox{ ID = "NameWordsChk", Text = "First words", Weight = 0, StyleSheet = T.checkbox() },
              ui:CheckBox{ ID = "NameDateChk", Text = "Date", Weight = 0, StyleSheet = T.checkbox() },
              ui:CheckBox{ ID = "NameTimeChk", Text = "Time", Weight = 0, StyleSheet = T.checkbox() },
              ui:Label{ Weight = 1 } }),
          settings_row("", ui:Label{ ID = "NamePreview", Text = "", Weight = 1, MinimumSize = { 40, 0 }, StyleSheet = T.label("meta") }),
        },
        ui:VGroup{
          Weight = 0, Spacing = S.rows,
          section("Timeline"),
          settings_row("Add clips to track", ui:LineEdit{ ID = "TrackName", Weight = 1, StyleSheet = T.input() }),
          -- Subtitles go on a subtitle track of the same name; how they are
          -- split, with what that means beside it.
          settings_row("Subtitles",
            ui:HGroup{ Weight = 1, Spacing = S.group,
              ui:ComboBox{ ID = "SubtitleSplitCombo", Weight = 0, MinimumSize = { 150, 0 }, StyleSheet = T.combo() },
              ui:Label{ ID = "SubtitleSplitHint", Text = "", Weight = 1, MinimumSize = { 40, 0 }, StyleSheet = T.label("meta") } }),
          -- Splitting needs Boson's word timings, which cover three languages.
          settings_row("", ui:Label{ Text = "Only English, Chinese and Spanish subtitles are split. Other languages show one subtitle per line.",
                                     Weight = 1, MinimumSize = { 40, 0 }, StyleSheet = T.label("meta") }),
        },
        ui:VGroup{
          Weight = 0, Spacing = S.rows,
          section("Support"),
          settings_row("Version",
            ui:HGroup{ Weight = 1, Spacing = S.gap,
              ui:Label{ ID = "VersionLabel", Text = "", Weight = 0, MinimumSize = { 40, 0 }, StyleSheet = T.label(),
                        Alignment = { AlignLeft = true, AlignVCenter = true } },
              -- One button: "Check for updates", which becomes "Update now" once
              -- a newer release is found. What happened reads to its right.
              ui:Button{ ID = "CheckUpdateBtn", Text = "Check for updates", Weight = 0, StyleSheet = T.button("ghost") },
              ui:Button{ ID = "InstallUpdateBtn", Text = "Update now", Weight = 0, StyleSheet = T.button("primary"), Hidden = true },
              ui:Label{ Weight = 0, MinimumSize = { 4, 0 }, MaximumSize = { 4, 4000 } },   -- a little air after the button
              ui:Label{ ID = "UpdateStatus", Text = "", Weight = 0, MinimumSize = { 40, 0 }, StyleSheet = T.label("secondary"),
                        Alignment = { AlignLeft = true, AlignVCenter = true } },
              ui:Button{ ID = "ReleaseNotesBtn", Text = "Release notes", Weight = 0, StyleSheet = T.button("link"), Hidden = true },
              ui:Label{ Weight = 1 } }),
          settings_row("", ui:CheckBox{ ID = "AutoUpdateChk", Text = "Check for updates when Higgs VoiceOver opens", Weight = 1, StyleSheet = T.checkbox() }),
          settings_row("Logs",
            ui:Label{ ID = "LogPathLabel", Text = "", Weight = 1, MinimumSize = { 40, 0 }, StyleSheet = T.label() },
            ui:Button{ ID = "OpenLogBtn", Text = "Open log folder", Weight = 0, StyleSheet = T.button("ghost"),
                       ToolTip = "One log per launch; the ten most recent are kept. Attach the latest when reporting a problem." }),
        },
        ui:Label{ Weight = 1 },
        -- Nothing applies until Save. Reset fills in the defaults (the key is
        -- left alone) for Save to keep or the user to change first.
        ui:HGroup{
          Weight = 0, Spacing = S.gap,
          ui:Label{ ID = "SettingsStatus", Text = "", Weight = 1, MinimumSize = { 40, 0 }, StyleSheet = T.label("meta") },
          ui:Button{ ID = "ResetSettingsBtn", Text = "Reset to default", Weight = 0, StyleSheet = T.button("ghost"),
                     ToolTip = "Put every setting on this page back to its default. Your API key is kept. Nothing changes until you save." },
          ui:Button{ ID = "SaveSettingsBtn", Text = "Save", Weight = 0,
                     StyleSheet = T.button("primary") .. "QPushButton { min-width: 88px; }" },
        },
      },
    },
    },
    ui:Label{ Weight = 0, MinimumSize = { S.pad, 0 }, MaximumSize = { S.pad, 4000 } },
  })

  itm = win:GetItems()

  -- Tab labels and TAB_PAGES / TAB_NAMES must stay in the same order.
  for _, name in ipairs(TAB_NAMES) do itm.MainTabs:AddTab(name) end

  local qv = itm.QuickVoiceTree
  qv.ColumnCount = 2
  local qvh = qv:NewItem()
  qvh.Text[0], qvh.Text[1] = "", "NAME"
  qv:SetHeaderItem(qvh)

  local qt = itm.QuickTagTree
  qt.ColumnCount = 2
  local qth = qt:NewItem()
  qth.Text[0], qth.Text[1] = "TAG", "TYPE"
  qt:SetHeaderItem(qth)
  for _, t in ipairs(TAG_TYPES) do itm.QuickTagType:AddItem(t) end
end

------------------------------------------------------------------- handlers

--- "Welcome_back_to_the_20260917_143012_v2" for the current choices; names
-- are the first four words plus whatever is ticked, and a number only when
-- a name is already taken.
--- The folder row: the field holds the folder the user chose, the label
-- after it the subfolder Higgs VO adds for the open project. Kept short so a
-- long project name cannot widen the window (see the notes on label sizing).
local function refresh_out_dir()
  -- sanitize() leaves plain ASCII, so a byte cut is safe here.
  local shown = U.sanitize(project_name())
  if #shown > 24 then shown = shown:sub(1, 23) .. "…" end
  itm.OutDirProject.Text = (shown ~= "") and ("  " .. P.sep .. "  " .. shown) or ""
  itm.OutDir.ToolTip = output_dir()
end

local function refresh_name_preview()
  -- Read from the boxes, so the example follows edits before they are saved.
  local o = { words = itm.NameWordsChk.Checked, date = itm.NameDateChk.Checked, time = itm.NameTimeChk.Checked }
  local parts = {}
  if o.words ~= false then parts[#parts + 1] = "Welcome_back_to_the" end
  if o.date then parts[#parts + 1] = os.date("%Y%m%d") end
  if o.time then parts[#parts + 1] = os.date("%H%M%S") end
  if o.take then parts[#parts + 1] = "v2" end
  if #parts == 0 then
    itm.NamePreview.Text = "Nothing ticked: clips are numbered — 1.wav, 2.wav, 3.wav…"
  else
    itm.NamePreview.Text = ("e.g. %s.wav"):format(table.concat(parts, "_"))
  end
end

--- The two ways to split subtitles (Settings › Timeline › Subtitles).
-- Short phrases is the default (Config).
local SUBTITLE_SPLITS = {
  { value = "short",    label = "Short phrases",   hint = "Split sentences into shorter segments." },
  { value = "sentence", label = "Whole sentences", hint = "Display a whole sentence at once." },
}

local function subtitle_split_value()
  local e = SUBTITLE_SPLITS[(itm.SubtitleSplitCombo.CurrentIndex or 0) + 1]
  return e and e.value or "short"
end

local function refresh_subtitle_hint()
  local mode = subtitle_split_value()
  for _, e in ipairs(SUBTITLE_SPLITS) do
    if e.value == mode then itm.SubtitleSplitHint.Text = e.hint end
  end
end

------------------------------------------------------------------- updates

--- Releases live on GitHub; a release carries Config.SCRIPT_FILE as an asset
-- (older releases: "Higgs VO.lua", still accepted).
-- Checking asks the public releases API (no key is sent); updating downloads
-- that asset, makes sure it at least compiles, and writes it over the
-- installed script. The running copy is untouched until the next launch.
local UPDATE_REPO = "boson-ai/higgs-voiceover"
local VERSION = tostring(_G.HIGGS_VO_VERSION or "dev")
local update = { latest = nil, url = nil, asset = nil, checking = false, checked_at = nil }

local function version_tuple(v)
  local a, b, c = tostring(v):match("(%d+)%.?(%d*)%.?(%d*)")
  return { tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0 }
end

local function is_newer(candidate, current)
  local x, y = version_tuple(candidate), version_tuple(current)
  for i = 1, 3 do
    if x[i] > y[i] then return true elseif x[i] < y[i] then return false end
  end
  return false
end

--- The Version row: the version, one button, then what happened.
local function update_status(text, color)
  itm.UpdateStatus.Text = (text and text ~= "") and span(color or c.text_2, text) or ""
end

local function refresh_update_ui()
  local before = { itm.CheckUpdateBtn.Hidden, itm.InstallUpdateBtn.Hidden, itm.ReleaseNotesBtn.Hidden }
  itm.VersionLabel.StyleSheet = T.label()
  itm.VersionLabel.Text = esc(VERSION)
  local found = update.latest ~= nil
  -- Once a newer release is known, checking again has nothing to add: the
  -- button becomes the update itself.
  itm.CheckUpdateBtn.Hidden = found
  itm.InstallUpdateBtn.Hidden = not (found and update.asset)
  itm.ReleaseNotesBtn.Hidden = not (found and update.url)
  if update.checking then
    update_status("Checking…")
  elseif update.error then
    -- A failed check or download; with a release found, Update now stays
    -- so it can be tried again.
    update_status((update.error:gsub("^%l", string.upper)), c.error_text)
  elseif found then
    update_status(("Version %s is available"):format(update.latest), c.ok)
  elseif update.checked_at then
    update_status("Up to date")
  else
    update_status("")
  end
  if before[1] ~= itm.CheckUpdateBtn.Hidden or before[2] ~= itm.InstallUpdateBtn.Hidden
     or before[3] ~= itm.ReleaseNotesBtn.Hidden then relayout() end
end

local function check_for_updates(quiet)
  if update.checking then return end
  update.checking, update.error = true, nil
  Log.info("update check" .. (quiet and " (automatic)" or ""))
  refresh_update_ui()
  app.api:fetch({
    url = "https://api.github.com/repos/" .. UPDATE_REPO .. "/releases/latest", label = "update check",
    on_done = function(res)
      update.checking = false
      update.checked_at = os.time()
      app.cfg.last_update_check = os.time()
      Config.save(app.cfg)
      if not res.ok or type(res.data) ~= "table" then
        -- In GitHub's words, short: the row has room for a few words, and the
        -- API client's messages are written about Boson.
        local code = tostring(res.code or "")
        if code == "404" then update.error = "no release published yet"
        elseif code == "403" or code == "429" then update.error = "GitHub is busy, try again later"
        elseif code == "" then update.error = "couldn't reach GitHub"
        else update.error = "couldn't check for updates" end
        Log.warn("update check failed", { code = code ~= "" and code or "none", error = tostring(res.error) })
        if quiet then update.error = nil end
        refresh_update_ui()
        return
      end
      local latest = tostring(res.data.tag_name or res.data.name or ""):gsub("^[vV]", "")
      update.url = res.data.html_url
      update.asset = nil
      -- GitHub will not keep a space in an asset's name ("Higgs VoiceOver.lua"
      -- is stored as "Higgs.VoiceOver.lua"), so names are compared by their
      -- letters and digits only. The file is always installed under its real
      -- name, whatever the asset is called.
      local function key(name) return (tostring(name or ""):lower():gsub("[^%w]", "")) end
      for _, a in ipairs(res.data.assets or {}) do
        if key(a.name) == key(Config.SCRIPT_FILE) then update.asset = a.browser_download_url end
      end
      if not update.asset then
        for _, a in ipairs(res.data.assets or {}) do
          for _, old in ipairs(Config.LEGACY_SCRIPT_FILES) do
            if key(a.name) == key(old) then update.asset = a.browser_download_url end
          end
        end
      end
      update.latest = is_newer(latest, VERSION) and latest or nil
      Log.info(("update check: latest %s, running %s%s"):format(latest, VERSION, update.latest and " → update available" or ""))
      refresh_update_ui()
      -- Announced once in the Generate tab's status line — never a
      -- system notification or a pop-up.
      if update.latest then
        status(("Higgs VoiceOver %s is available — update from Settings."):format(update.latest), "ok")
      end
    end,
  })
end

local function install_update()
  if not update.asset then return end
  local dest = P.join(P.scripts_dir(), Config.SCRIPT_FILE)
  local tmp = P.join(Config.tmp_dir(), "Higgs VO.update.lua")
  update.error = nil
  update_status(("Downloading %s…"):format(update.latest))
  Log.info("update: downloading " .. tostring(update.asset))
  app.api:fetch({
    url = update.asset, out_path = tmp, label = "update download",
    on_done = function(res)
      if not res.ok then
        update.error = "download failed, try again"
        Log.warn("update download failed", { code = tostring(res.code or ""), error = tostring(res.error) })
        refresh_update_ui()
        return
      end
      local body = U.read_file(tmp)
      local compiles = body and #body > 1000 and loadstring(body) ~= nil
      if not compiles then
        update.error = "the download was damaged, try again"
        Log.error("update: asset did not compile")
        refresh_update_ui()
        return
      end
      if not U.write_file(dest, body) then
        update.error = "couldn't replace the installed script"
        Log.warn("update: could not write", { to = Log.path_safe(dest) })
        refresh_update_ui()
        return
      end
      os.remove(tmp)
      -- The menu lists every script in the folder: an earlier name left
      -- behind would show the product twice.
      for _, old in ipairs(Config.LEGACY_SCRIPT_FILES) do
        local p = P.join(P.scripts_dir(), old)
        if p ~= dest and P.exists(p) then os.remove(p); Log.info("update: removed old menu entry " .. old) end
      end
      Log.info("update: installed", { version = update.latest, to = Log.path_safe(dest) })
      update_status(("%s installed — close and reopen Higgs VoiceOver"):format(update.latest), c.ok)
      itm.InstallUpdateBtn.Hidden = true
      relayout()
      status(("Higgs VoiceOver %s is installed. Restart Resolve, then open Higgs VoiceOver from Workspace › Scripts."):format(update.latest), "ok")
    end,
  })
end

--- The Settings page as values, in one shape whether read from the fields,
-- the saved config or the defaults — so "unsaved" and "already default" are
-- the same comparison.
local function settings_values(cfg)
  local o = cfg.clip_name or {}
  return {
    key = Config.get_api_key(cfg),
    output_dir = (cfg.output_dir and cfg.output_dir ~= "") and cfg.output_dir or Config.default_output_dir(),
    vo_track_name = cfg.vo_track_name,
    output_format = cfg.output_format,
    pause_enabled = cfg.pause_enabled ~= false,
    pause_ms = tonumber(cfg.pause_ms) or 400,
    check_updates = cfg.check_updates ~= false,
    subtitle_split = cfg.subtitle_split or "short",
    words = o.words ~= false, date = o.date and true or false, time = o.time and true or false,
  }
end

local function settings_from_fields()
  return {
    key = U.trim(itm.ApiKeyEdit.Text),
    output_dir = U.trim(itm.OutDir.Text) ~= "" and itm.OutDir.Text or Config.default_output_dir(),
    vo_track_name = U.trim(itm.TrackName.Text) ~= "" and itm.TrackName.Text or Config.DEFAULTS.vo_track_name,
    output_format = itm.FormatCombo.CurrentText,
    pause_enabled = itm.PauseChk.Checked and true or false,
    pause_ms = math.max(0, math.min(5000, tonumber(itm.PauseMs.Text) or 400)),
    check_updates = itm.AutoUpdateChk.Checked and true or false,
    subtitle_split = subtitle_split_value(),
    words = itm.NameWordsChk.Checked and true or false,
    date = itm.NameDateChk.Checked and true or false,
    time = itm.NameTimeChk.Checked and true or false,
  }
end

local function settings_equal(a, b, ignore_key)
  for k, v in pairs(a) do
    if not (ignore_key and k == "key") and b[k] ~= v then return false end
  end
  return true
end

--- Write values into the page's fields (the key only when `with_key`).
local function fill_settings(v, with_key)
  local was = suppress
  suppress = true
  if with_key then itm.ApiKeyEdit.Text = v.key end
  itm.NameWordsChk.Checked, itm.NameDateChk.Checked, itm.NameTimeChk.Checked = v.words, v.date, v.time
  itm.OutDir.Text = v.output_dir
  itm.PauseChk.Checked = v.pause_enabled
  itm.PauseMs.Text = tostring(v.pause_ms)
  itm.TrackName.Text = v.vo_track_name
  itm.AutoUpdateChk.Checked = v.check_updates
  for i, e in ipairs(SUBTITLE_SPLITS) do
    if e.value == v.subtitle_split then itm.SubtitleSplitCombo.CurrentIndex = i - 1 end
  end
  for i, f in ipairs({ "wav", "mp3", "aac", "flac" }) do
    if f == v.output_format then itm.FormatCombo.CurrentIndex = i - 1 end
  end
  suppress = was
end

--- Save is live only while the fields differ from what is saved; Reset only
-- while they differ from the defaults. The footer says there is something to save.
local function refresh_settings_state()
  local fields = settings_from_fields()
  local dirty = not settings_equal(fields, settings_values(app.cfg))
  itm.SaveSettingsBtn.Enabled = dirty
  itm.ResetSettingsBtn.Enabled = not settings_equal(fields, settings_values(Config.DEFAULTS), true)
  refresh_name_preview()
  refresh_subtitle_hint()
  refresh_out_dir()
  if dirty then
    saved_at = nil
    itm.SettingsStatus.StyleSheet = T.label("meta")
    itm.SettingsStatus.Text = "Unsaved changes"
  elseif not saved_at then
    itm.SettingsStatus.Text = ""
  end
end

local function push_settings_to_ui()
  suppress = true
  itm.ApiKeyEdit.Text = Config.get_api_key(app.cfg)
  local o = app.cfg.clip_name or {}
  itm.NameWordsChk.Checked = (o.words ~= false)
  itm.NameDateChk.Checked = o.date and true or false
  itm.NameTimeChk.Checked = o.time and true or false
  refresh_name_preview()
  itm.OutDir.Text = app.cfg.output_dir
  refresh_out_dir()
  itm.PauseChk.Checked = app.cfg.pause_enabled ~= false
  itm.AutoPreviewChk.Checked = app.cfg.auto_preview ~= false
  itm.AutoPlaceChk.Checked = app.cfg.auto_place == true
  itm.AutoSubsChk.Checked = app.cfg.auto_subtitles == true
  itm.PreviewSubsChk.Checked = app.cfg.manual_subtitles == true
  itm.SubtitleSplitCombo:Clear()
  for i, e in ipairs(SUBTITLE_SPLITS) do
    itm.SubtitleSplitCombo:AddItem(e.label)
    if e.value == app.cfg.subtitle_split then itm.SubtitleSplitCombo.CurrentIndex = i - 1 end
  end
  refresh_subtitle_hint()
  itm.PauseMs.Text = tostring(tonumber(app.cfg.pause_ms) or 400)
  itm.TrackName.Text = app.cfg.vo_track_name
  itm.AutoUpdateChk.Checked = app.cfg.check_updates ~= false
  refresh_update_ui()

  itm.FormatCombo:Clear()
  -- Only formats Resolve will import: an opus take generates fine and then
  -- cannot be placed, which is a dead end to offer.
  for i, f in ipairs({ "wav", "mp3", "aac", "flac" }) do
    itm.FormatCombo:AddItem(f)
    if f == app.cfg.output_format then itm.FormatCombo.CurrentIndex = i - 1 end
  end

  itm.SettingsKeyStatus.StyleSheet = T.label("meta")
  itm.SettingsKeyStatus.Text = ""
  itm.LogPathLabel.Text = "This session: " .. P.basename(Log.path())
  suppress = false
  refresh_settings_state()
end

--- Check a key against Boson. `context` "setup" keeps the key only if it
-- works (a first run must not remember a typo and then skip onboarding next
-- time); Settings saves as the user types, so it keeps it either way.
local function key_error(res, context)
  if res.code == "401" then
    return "Boson didn't accept that key. Check that you copied all of it."
  end
  return res.error or "Couldn't connect to Boson."
end

local function test_key(key, status_label, on_ok, context)
  if key == "" then
    status_label.StyleSheet = T.label("error")
    status_label.Text = "Paste your API key first."
    return
  end
  -- The request reads the key from the config, so it goes there for the
  -- test. Settings puts the saved one back afterwards: only Save keeps a key.
  local previous = Config.get_api_key(app.cfg)
  Config.set_api_key(app.cfg, key)
  status_label.StyleSheet = T.label("meta")
  status_label.Text = "Checking the key…"
  app.api:test({ on_done = function(res)
    Log.metric("key.test", { ok = res.ok and 1 or 0, where = context or "settings", code = res.code or "" })
    local is_saved = (context ~= "setup") and key == previous
    if context ~= "setup" then Config.set_api_key(app.cfg, previous) end
    if res.ok then
      -- The chip speaks for the saved key: a typed, unsaved one proves nothing about it.
      if context == "setup" or is_saved then connected = true end
      if context == "setup" then
        Config.save(app.cfg)
        -- Settings shows what is saved; without this its key field would
        -- read as an unsaved change.
        local was = suppress
        suppress = true
        itm.ApiKeyEdit.Text = key
        suppress = was
        refresh_settings_state()
      end
      local msg = "Connected"
      status_label.StyleSheet = T.label("ok")
      status_label.Text = "●  " .. msg
      if on_ok then on_ok() end
      -- Only a working key moves the user on; the message follows them to
      -- the Generate page, which replaces the setup page they were on.
      route()
      if context == "setup" or is_saved then quick_note(msg, "ok") end
    else
      if context == "setup" or is_saved then connected = false end
      if context == "setup" then Config.set_api_key(app.cfg, previous) end
      status_label.StyleSheet = T.label("error")
      status_label.Text = key_error(res, context)
    end
  end })
end

local KEY_URL = "https://www.boson.ai/workspace/api-key"
local function open_docs()
  Log.ui("open get-a-key page")
  local ok = pcall(function() bmd.openurl(KEY_URL) end)
  if not ok then status("Visit boson.ai/workspace/api-key to get an API key.") end
end

-- Handlers are wired in sections: LuaJIT allows a function 60 upvalues, and
-- one function holding every handler in the window went past that.

local function wire_window()
  win.On[WIN_ID].Close = function()
    if quick.dirty_at and quick.save_draft then quick.save_draft() end
    Config.save(app.cfg)
    P.audio_stop()
    stop_loop()
  end

  win.On.MainTabs.CurrentChanged = function()
    local index = itm.MainTabs.CurrentIndex
    show_tab(index)
    -- The folder row names the open project, which can change while the
    -- window is up, so re-read it whenever Settings comes forward.
    if index == TAB_SETTINGS then refresh_out_dir() end
  end

end

local function wire_setup()
  -------------------------------------------------------------------- setup
  win.On.SetupShowKey.Clicked = function()
    itm.SetupKey.EchoMode = itm.SetupShowKey.Checked and "Normal" or "Password"
  end
  local function connect()
    local key = U.trim(itm.SetupKey.Text)
    quick.setup_tested = itm.SetupKey.Text
    test_key(key, itm.SetupStatus, function()
      suppress = true
      itm.ApiKeyEdit.Text = key
      suppress = false
    end, "setup")
  end
  win.On.SetupTestBtn.Clicked = connect
  win.On.SetupKey.ReturnPressed = connect
  -- An old verdict about a different key is wrong the moment the key changes.
  -- (TextChanged is queued, so compare against what was tested rather than
  -- trusting the event: a write from code arrives here too.)
  win.On.SetupKey.TextChanged = function()
    if itm.SetupKey.Text ~= quick.setup_tested and itm.SetupStatus.Text ~= "" then itm.SetupStatus.Text = "" end
  end
  -- Saved as soon as it changes: the answer stands whether the user then
  -- connects or skips. (Settings shows the same value.)
  win.On.SetupSkipBtn.Clicked = function()
    Log.metric("setup.skip", {})
    setup_skipped = true
    route()
    quick_note("No API key yet — add one in Settings before you generate.", "warn")
  end
  win.On.SetupGetKeyBtn.Clicked = open_docs
  win.On.GetKeyBtn.Clicked = open_docs

end

local function wire_settings()
  ----------------------------------------------------------------- settings
  win.On.ShowKeyChk.Clicked = function()
    itm.ApiKeyEdit.EchoMode = itm.ShowKeyChk.Checked and "Normal" or "Password"
  end
  win.On.TestKeyBtn.Clicked = function()
    test_key(U.trim(itm.ApiKeyEdit.Text), itm.SettingsKeyStatus)
  end
  win.On.OpenLogBtn.Clicked = function()
    Log.ui("open log folder")
    P.open_folder(Log.dir())
  end
  win.On.BrowseOutBtn.Clicked = function()
    local path = pick(function() return fu:RequestDir(itm.OutDir.Text or "") end)
    if path and path ~= "" then itm.OutDir.Text = tostring(path) end
  end
  -- Nothing is kept until Save; every edit only updates the buttons and
  -- the footer.
  local function edited()
    if suppress then return end
    refresh_settings_state()
  end
  win.On.SaveSettingsBtn.Clicked = function()
    local v = settings_from_fields()
    local had_key = Config.get_api_key(app.cfg)
    Config.set_api_key(app.cfg, v.key)
    app.cfg.output_dir = v.output_dir
    app.cfg.vo_track_name = v.vo_track_name
    app.cfg.output_format = v.output_format
    app.cfg.pause_enabled, app.cfg.pause_ms = v.pause_enabled, v.pause_ms
    app.cfg.check_updates = v.check_updates
    app.cfg.subtitle_split = v.subtitle_split
    app.cfg.clip_name = { words = v.words, date = v.date, time = v.time, take = false }
    Config.save(app.cfg)
    Log.info("settings saved", { format = v.output_format, folder = Log.q(Log.path_safe(v.output_dir)),
      track = Log.q(v.vo_track_name),
      names = (v.words and "words" or "") .. (v.date and "+date" or "") .. (v.time and "+time" or ""),
      updates = tostring(v.check_updates), subtitles = v.subtitle_split,
      pause_ms = v.pause_enabled and v.pause_ms or 0, key = (v.key ~= had_key) and "changed" or "same" })
    if v.key ~= had_key then
      -- A different key has not been proved by this session.
      connected = false
      if v.key ~= "" then
        itm.SettingsKeyStatus.StyleSheet = T.label("meta")
        itm.SettingsKeyStatus.Text = "Key saved — test the connection to confirm it works."
      end
      route()
    end
    itm.SettingsStatus.StyleSheet = T.label("meta")
    itm.SettingsStatus.Text = "Saved"
    saved_at = os.time()
    refresh_settings_state()
  end
  win.On.ResetSettingsBtn.Clicked = function()
    Log.ui("settings: reset to default")
    fill_settings(settings_values(Config.DEFAULTS), false)
    refresh_settings_state()
  end
  win.On.ApiKeyEdit.TextChanged = edited
  win.On.OutDir.TextChanged = edited
  win.On.TrackName.TextChanged = edited
  win.On.PauseChk.Clicked = edited
  win.On.PauseMs.TextChanged = edited
  win.On.FormatCombo.CurrentIndexChanged = edited
  win.On.SubtitleSplitCombo.CurrentIndexChanged = edited
  win.On.AutoUpdateChk.Clicked = edited
  win.On.CheckUpdateBtn.Clicked = function() check_for_updates(false) end
  win.On.InstallUpdateBtn.Clicked = install_update
  win.On.ReleaseNotesBtn.Clicked = function()
    if update.url then pcall(function() bmd.openurl(update.url) end) end
  end
  win.On.NameWordsChk.Clicked = edited
  win.On.NameDateChk.Clicked = edited
  win.On.NameTimeChk.Clicked = edited

end

local function wire_generate()
  ----------------------------------------------------------------- generate
  win.On.QuickText.TextChanged = function()
    if suppress then return end
    -- Qt delivers this from the queue, so a programmatic write arrives here
    -- after the guard has lifted. Nothing changed, so leave any status
    -- message ("Imported…", "2/2 generated") standing.
    -- An empty box reports a lone line break once it has been painted;
    -- trailing line breaks are layout, not an edit (they were wiping the
    -- startup status line and saving a one-character draft).
    local function body(t) return (tostring(t or ""):gsub("[\r\n]+$", "")) end
    if body(itm.QuickText.PlainText) == body(quick.text) then return end
    quick.text = itm.QuickText.PlainText
    quick.dirty_at = now()
    quick_refresh()
    repaint_box("QuickText", false, nil, true)
  end
  local function insert_quick_tag()
    local r = selected_quick_tag()
    if not r then quick_note("Pick a tag in the list first.") return end
    local out, caret = insert_tag("QuickText", r.value, r.line_start)
    if not out then return end
    Log.metric("tag.insert", { type = r.cat, tag = r.value, moved_to_line_start = r.line_start and 1 or 0 })
    quick.text = out
    quick.dirty_at = now()
    quick_refresh()
    -- Colour it, and leave the caret after the tag so the next insert or
    -- keystroke carries on from there (it used to go back to the start).
    repaint_box("QuickText", true, nil, false, caret)
  end
  win.On.QuickTagInsert.Clicked = insert_quick_tag
  win.On.QuickTagTree.ItemDoubleClicked = insert_quick_tag
  win.On.QuickTagTree.CurrentItemChanged = function() refresh_quick_tag_foot() end
  win.On.QuickTagType.CurrentIndexChanged = function() if not suppress then reload_quick_tags() end end
  win.On.QuickTagSearch.TextChanged = function() if not suppress then reload_quick_tags() end end
  local function use_quick_voice()
    local e = selected_quick_voice()
    if not e then quick_note("Pick a voice in the list first.") return end
    Log.metric("voice.use", { voice = Api.is_preset(e.value) and e.value or "cloned" })
    quick.voice = e.value
    quick.dirty_at = now()
    reload_quick_voices()
    quick_refresh()
  end
  -- The draft lives with the Resolve project: same project, same text, on
  -- any later launch.
  --- Written a couple of seconds after the last edit, and on close: the
  -- draft follows the project without anyone pressing anything.
  local function save_draft()
    local path = Config.draft_path(app.project_id or "")
    P.mkdirs(P.dirname(path))
    local ok = U.write_file(path, U.json.encode({ text = itm.QuickText.PlainText, voice = quick.voice, saved = os.time() }))
    if ok then
      quick.saved_text, quick.saved_voice = itm.QuickText.PlainText, quick.voice
      quick.dirty_at = nil
      Log.info("draft saved", { chars = U.utf8_len(itm.QuickText.PlainText) })
    else
      quick_note("Could not save the draft.", "error")
    end
  end
  quick.save_draft = save_draft
  win.On.QuickExportBtn.Clicked = function()
    local path = pick(function()
      return fu:RequestFile("", "", { FReqB_SaveAs = true, FReqS_Title = "Save text as", FReqS_Filter = "Text (*.txt)|*.txt" })
    end)
    if not path or path == "" then return end
    path = tostring(path)
    if not path:lower():match("%.txt$") then path = path .. ".txt" end
    if U.write_file(path, itm.QuickText.PlainText) then
      Log.info("text exported", { path = Log.q(Log.path_safe(path)) })
      quick_note("Saved " .. P.basename(path) .. ".", "ok")
    else
      quick_note("Could not write " .. path, "error")
    end
  end
  win.On.QuickOpenBtn.Clicked = function()
    local path = pick(function() return fu:RequestFile("") end)
    if not path or path == "" then return end
    local text = U.read_file(tostring(path), "r")
    if not text then quick_note("Could not read that file.", "error") return end
    if text:find("%z") then quick_note("That does not look like a text file.", "error") return end
    suppress = true
    itm.QuickText.PlainText = text
    suppress = false
    quick.text = text
    quick_refresh()
    repaint_box("QuickText", true)
    quick_note(("Imported %s."):format(P.basename(tostring(path))), "ok")
  end
  win.On.QuickVoiceUse.Clicked = use_quick_voice
  win.On.QuickPreviewVoice.Clicked = function()
    local e = selected_quick_voice()
    if not e then quick_note("Pick a voice in the list first.") return end
    preview_voice(e.value, e.label, function(msg) quick_note(msg, "error") end)
  end
  win.On.QuickAddVoice.Clicked = function()
    add_voice_dialog()
    reload_quick_voices()
  end
  win.On.QuickVoiceTree.ItemDoubleClicked = use_quick_voice
  win.On.QuickVoiceTree.CurrentItemChanged = function() if not suppress then refresh_quick_delete() end end
  win.On.QuickDeleteVoice.Clicked = function()
    local e = selected_quick_voice()
    if not e or not Config.find_voice(app.cfg, e.value) then return end
    Config.remove_voice(app.cfg, e.value)
    -- A deleted voice cannot stay the one in use.
    if quick.voice == e.value then quick.voice = nil; quick.dirty_at = now() end
    if app.cfg.default_voice == e.value then app.cfg.default_voice = Config.DEFAULTS.default_voice end
    Config.save(app.cfg)
    Log.metric("voice.delete", { where = "generate" })
    reload_voice_combos()
    refresh_quick_delete()
    quick_note(("Deleted “%s” from your list."):format(e.label), "ok")
  end

  win.On.QuickGenerateBtn.Clicked = function()
    local lines, _, over = quick_lines()
    if #lines == 0 or over or quick.busy then return end
    if Config.get_api_key(app.cfg) == "" then
      quick_note("Add your Boson API key in Settings before you generate.", "error")
      return
    end
    local voice = quick.voice or app.cfg.default_voice
    local signature = quick_signature(lines)
    -- Word timings only when subtitles may be wanted, placed automatically
    -- or by hand later: asking for them changes the request (see Api.speech).
    local timed = app.cfg.auto_subtitles == true or app.cfg.manual_subtitles == true
    local dir = output_dir()
    if not P.exists(dir) then P.mkdirs(dir) end
    local takes = {}
    player_stop(true)
    local total_chars = 0
    for _, l in ipairs(lines) do total_chars = total_chars + l.chars end
    Log.info("generate", { lines = #lines, chars = total_chars, voice = Api.is_preset(voice) and tostring(voice) or "cloned",
                           timestamps = timed and 1 or 0 })
    local run_t0 = now()
    local function run_metric(result, made)
      local audio = 0
      for _, t in ipairs(takes) do audio = audio + (t.seconds or 0) end
      Log.metric("generate.quick", { lines = #lines, made = made, chars = total_chars, result = result,
        audio_seconds = audio, ms = math.floor((now() - run_t0) * 1000),
        auto_preview = app.cfg.auto_preview ~= false and 1 or 0, auto_place = app.cfg.auto_place and 1 or 0,
        subtitles = timed and 1 or 0 })
    end
    quick.run_metric = run_metric
    quick.busy, quick.stopped = true, false
    quick.last = nil
    -- Stop reads these to report what was finished before it was pressed.
    quick.run = { takes = takes, signature = signature, total = #lines }
    -- One line at a time, in order, so the clips land in order too.
    local function step(i)
      if quick.stopped then return end
      quick.progress = { index = i, total = #lines }
      quick_refresh()
      local line = lines[i]
      local path = clip_path(line.text, nil, dir, ext_for_preview())
      app.api:speech({
        text = Tags.terminate(line.composed), voice = voice, format = ext_for_preview(), out_path = path,
        timestamps = timed,
        on_done = function(res)
          if quick.stopped then return end
          if not res.ok then
            quick.busy, quick.progress = false, nil
            run_metric("failed", #takes)
            quick_note((#lines > 1 and ("Line %d — %s"):format(i, tostring(res.error)) or tostring(res.error)), "error")
            return
          end
          local pause = finish_take(res.path)
          -- The line and its word timings travel with the take, so placing it
          -- later can still add its subtitles.
          takes[#takes + 1] = { path = res.path, seconds = U.wav_seconds(res.path) or U.estimate_seconds(line.text),
                                text = line.text, words = res.words, pause = pause }
          if i < #lines then return step(i + 1) end
          quick.busy, quick.progress = false, nil
          player_stop(true)
          quick.last = { takes = takes, signature = signature }
          player.index = 1
          if app.cfg.auto_preview ~= false and P.can_play(takes[1].path) then player_play() else player_refresh() end
          run_metric("done", #takes)
          quick_note(#lines > 1 and ("%d/%d generated"):format(#lines, #lines) or "Generated", "ok")
          if app.cfg.auto_place then quick_place(takes, "auto") end
        end,
      })
    end
    step(1)
  end
  win.On.PlayerPlay.Clicked = function()
    Log.metric("preview.play", { action = player.state == "playing" and "pause" or "play", take = player.index })
    if player.state == "playing" then player_pause() else player_play() end
    quick_refresh(true)
  end
  win.On.PlayerStop.Clicked = function() player_stop(); quick_refresh(true) end
  win.On.QuickStopBtn.Clicked = function()
    if not quick.busy then return end
    app.api:cancel_pending()
    quick.stopped, quick.busy, quick.progress = true, false, nil
    local run = quick.run or {}
    local made = #(run.takes or {})
    if made > 0 then
      -- What was already generated is kept: it exists on disk and in the bin.
      quick.last = { takes = run.takes, signature = run.signature }
      player.index = 1
      player_refresh()
    end
    if quick.run_metric then quick.run_metric("stopped", made) end
    quick_note(made > 0 and ("Stopped — %d of %d generated"):format(made, run.total or made) or "Stopped", nil)
  end
  win.On.QuickClearBtn.Clicked = function()
    if itm.QuickText.PlainText == "" then return end
    suppress = true
    itm.QuickText.PlainText = ""
    suppress = false
    quick.text = ""
    repaint_box("QuickText", true)
    quick_refresh()
  end
  win.On.AutoPreviewChk.Clicked = function()
    app.cfg.auto_preview = itm.AutoPreviewChk.Checked and true or false
    Config.save(app.cfg)
  end
  win.On.PlayerPrev.Clicked = function() player_select(player.index - 1) end
  win.On.PlayerNext.Clicked = function() player_select(player.index + 1) end
  win.On.QuickPlaceBtn.Clicked = function()
    if quick.last then quick_place(quick.last.takes) end
  end
  win.On.QuickPlaceOneBtn.Clicked = function()
    local take = player_take()
    if take then quick_place({ take }, "one") end
  end
  win.On.AutoPlaceChk.Clicked = function()
    app.cfg.auto_place = itm.AutoPlaceChk.Checked and true or false
    Config.save(app.cfg)
  end
  win.On.AutoSubsChk.Clicked = function()
    app.cfg.auto_subtitles = itm.AutoSubsChk.Checked and true or false
    Log.ui("add subtitles when placed automatically " .. (app.cfg.auto_subtitles and "on" or "off"))
    Config.save(app.cfg)
  end
  win.On.PreviewSubsChk.Clicked = function()
    app.cfg.manual_subtitles = itm.PreviewSubsChk.Checked and true or false
    Log.ui("add subtitles when placed by hand " .. (app.cfg.manual_subtitles and "on" or "off"))
    Config.save(app.cfg)
  end
end

local function wire()
  wire_window()
  wire_setup()
  wire_settings()
  wire_generate()
end

--------------------------------------------------------------------- polling

--- A second launch asks to see this window. Bring it forward and confirm it
-- actually became active; if it could not (Resolve has thrown the window
-- away under us), let go of the lock and quit so the new launch opens one.
local last_raise_check = 0
local function answer_raise_request()
  if not app.raise_path or now() - last_raise_check < 0.3 then return end
  last_raise_check = now()
  if not P.exists(app.raise_path) then return end
  os.remove(app.raise_path)
  pcall(function() win:Show() end)
  pcall(function() win:Raise() end)
  pcall(function() win:ActivateWindow() end)
  -- Activation lands on a later pass of the event loop.
  local t0 = now()
  while now() - t0 < 0.3 do pump_events(); _G.bmd.wait(0.02) end
  local ok, active = pcall(function() return win:IsActiveWindow() end)
  if ok and active then
    U.write_file(app.raised_path, tostring(os.time()))
    Log.info("brought the window forward for a second launch")
  else
    Log.warn("asked to come forward but the window is gone; handing over")
    if app.release_lock then app.release_lock() end
    app.heartbeat = nil
    for _, f in ipairs(loops) do f.done = true end
  end
end

local last_beat = 0
local function on_tick()
  answer_raise_request()
  app.api:poll()
  if app.heartbeat and os.time() - last_beat >= 2 then
    last_beat = os.time()
    app.heartbeat()
  end
  if saved_at and os.time() - saved_at >= 2 then
    saved_at = nil
    itm.SettingsStatus.Text = ""
  end
  quick_tick_dots()
  if layout_check_at and now() >= layout_check_at then pcall(check_layout) end
  -- Screenshot harness: takes that arrive after the window is up, the way a
  -- real run's do (the controls they reveal were never laid out).
  -- ...and a tag highlighted once the type filter's own event has landed.
  if shown and app.demo_quick and app.demo_quick.tag_type and not quick.demo_tag_done
     and now() - (quick.shown_at or now()) > 0.5 then
    quick.demo_tag_done = true
    pcall(function() itm.QuickTagTree:TopLevelItem(1).Selected = true end)
    refresh_quick_tag_foot()
  end
  if shown and not quick.shown_at then quick.shown_at = now() end
  if shown and app.demo_quick and app.demo_quick.late_last and not quick.last then
    quick.last = app.demo_quick.late_last
    quick.last.signature = quick_signature(quick_lines())
    quick_refresh(true)
    player_refresh()
  end
  if quick.last then
    local before = player.state
    player_tick()
    if player.state ~= before then quick_refresh(true) end
  end
  -- A preview that has run out puts its button back to "Preview".
  if preview.playing and now() - (preview.checked or 0) > 0.25 then
    preview.checked = now()
    if now() - (preview.started or 0) > 0.5 and P.audio_is_playing() == false then
      preview.playing = false
      refresh_preview_buttons()
    end
  end
  if quick.dirty_at and now() - quick.dirty_at >= 2 and quick.save_draft then
    quick.save_draft()
  end
end

------------------------------------------------------------------ public api

function M.run(context)
  app = context
  if app.window_id then WIN_ID = app.window_id end
  ui = _G.fu and _G.fu.UIManager or _G.fusion.UIManager
  disp = _G.bmd.UIDispatcher(ui)

  -- The dispatcher pcalls every handler and reports failures through the
  -- global _ALERT; route those to the log so a broken click is on record.
  _G._ALERT = function(message)
    Log.error("handler: " .. tostring(message), { event = last_event })
    print("Higgs VoiceOver: " .. tostring(message))
  end

  build()
  wire()

  push_settings_to_ui()
  reload_voice_combos()

  if app.demo_connected then connected = true end

  suppress = true
  reload_quick_tags()
  if not app.demo_quick then
    local raw = U.read_file(Config.draft_path(app.project_id or ""))
    local draft = raw and U.json.decode(raw)
    if type(draft) == "table" and type(draft.text) == "string" and U.trim(draft.text) ~= "" then
      itm.QuickText.PlainText = draft.text
      quick.text = draft.text
      quick.voice = draft.voice
      quick.saved_text, quick.saved_voice = draft.text, draft.voice
      quick.note = { text = ("Restored the draft saved %s."):format(os.date("%Y-%m-%d %H:%M", draft.saved or os.time())), kind = "meta" }
      Log.info("draft restored", { chars = U.utf8_len(draft.text) })
    end
    repaint_box("QuickText", true)   -- paragraph layout, even for an empty box
  end
  if app.demo_quick then
    itm.QuickText.PlainText = app.demo_quick.text or ""
    quick.text = itm.QuickText.PlainText
    repaint_box("QuickText", true)
    if app.demo_quick.busy then
      quick.busy, quick.progress = true, app.demo_quick.busy
    elseif app.demo_quick.note then
      quick.note = app.demo_quick.note
    end
    quick.last = app.demo_quick.last
    if quick.last then
      quick.last.signature = quick_signature(quick_lines())
      local demo_player = app.demo_quick.player or { index = 1, state = "playing" }
      player.index, player.state, player.started, player.offset = demo_player.index, demo_player.state, now() - 2, 0
      player.started_at = now()
      quick.last.takes[1].seconds = 60   -- long enough for a capture
    end
  end
  if app.demo_quick and app.demo_quick.tag_type then
    for i, t in ipairs(TAG_TYPES) do
      if t == app.demo_quick.tag_type then itm.QuickTagType.CurrentIndex = i - 1 end
    end
    reload_quick_tags()
  end
  suppress = false
  quick_refresh(true)
  player_refresh()
  -- Screenshot harness: onboarding states.
  if app.demo_setup then
    if app.demo_setup.key then itm.SetupKey.Text = app.demo_setup.key; quick.setup_tested = app.demo_setup.key end
    if app.demo_setup.status then
      itm.SetupStatus.StyleSheet = T.label(app.demo_setup.kind or "meta")
      itm.SetupStatus.Text = app.demo_setup.status
    end
    if app.demo_setup.skip then
      setup_skipped = true
      quick_note("No API key yet — add one in Settings before you generate.", "warn")
    end
  end

  -- Generate is where work starts, and where setup lives.
  local start_tab = TAB_GENERATE
  if app.initial_tab then start_tab = app.initial_tab end
  itm.MainTabs.CurrentIndex = start_tab
  show_tab(start_tab)
  refresh_all()
  if app.initial_status then status(app.initial_status, app.initial_status_kind) end
  if app.warning then status(app.warning, "error") end

  -- Screenshot harness: a newer release has been found.
  if app.demo_update then
    update.latest, update.url, update.asset = app.demo_update, "https://github.com/" .. UPDATE_REPO .. "/releases", "x"
    update.checked_at = os.time()
    refresh_update_ui()
    status(("Higgs VoiceOver %s is available — update from Settings."):format(update.latest), "ok")
  end
  if app.before_show then app.before_show(itm, win) end   -- harness hook
  win:Show()
  shown = true
  shown_at = _G.bmd.gettime()
  layout_check_at = shown_at + 0.5
  if app.cfg.check_updates ~= false and not app.skip_sync
     and os.time() - (app.cfg.last_update_check or 0) > 86400 then
    check_for_updates(true)
  end
  -- If the window came up smaller than asked (small screen), lay the content
  -- out for the size it actually got rather than leaving it clipped.
  pcall(function() win:RecalcLayout() end)
  M.debug = { route = route, show_tab = show_tab, app = app, quick_place = quick_place, quick = quick }   -- harness hook
  if app.on_shown then app.on_shown(itm, win, disp) end   -- harness hook
  if app.demo_addvoice then add_voice_dialog() end
  run_loop(on_tick)
  win:Hide()
end

return M
