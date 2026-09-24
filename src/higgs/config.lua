--- Settings, credentials and the on-disk layout.
--
-- Everything Higgs VO stores lives under one per-user folder so the whole
-- install can be inspected, backed up or deleted by hand. Deliberately
-- file-based rather than OS keychain: the same layout works on every platform
-- and moves between machines, which the keychain does not.

local P = require("higgs.platform")
local U = require("higgs.util")

local M = {}

--- Bump when a released schema changes so migrate() can fix older files.
M.SCHEMA = 5

--- The product's name, and the file Resolve lists it under. Users see the
-- file name as the Scripts menu entry, so it carries the full name. The
-- config folder, window IDs and code keep the short "Higgs VO" / HiggsVO:
-- renaming them would strand existing settings for nothing a user sees.
M.APP_NAME = "Higgs VoiceOver"
M.SCRIPT_FILE = "Higgs VoiceOver.lua"
M.LEGACY_SCRIPT_FILES = { "Higgs VO.lua" }   -- earlier names, removed on install/update

local DEFAULTS = {
  schema        = M.SCHEMA,
  api_key_b64   = "",
  default_voice = "nora",
  output_format = "wav",
  -- Silence appended to every clip so consecutive lines breathe (wav only).
  auto_preview  = true,        -- play the takes as soon as a generation finishes
  auto_place    = true,        -- put every clip of a finished run on the timeline (0.2.0: on)
  -- Subtitles go on the timeline with the clips, timed to Boson's word
  -- timings: "short" phrases of one line, or one "sentence" per subtitle.
  auto_subtitles = false,     -- with automatic placing (box beside Generate)
  manual_subtitles = false,   -- with the Place buttons (box in the audio preview)
  subtitle_split = "short",
  pause_enabled = true,
  pause_ms      = 400,
  -- Clip and file names: the first four words, plus any of these.
  clip_name     = { words = true, date = false, time = false, take = false },
  output_dir    = "",          -- resolved to default_output_dir() on first load
  vo_track_name = "Higgs VO",
  -- "adopt" re-times the clip to the new take; "keep" holds the original
  -- boundaries and truncates. Defaults to adopt for script-first work; SRT-timed
  -- segments override per segment.
  replace_mode  = "adopt",
  gap_seconds   = 0.35,        -- silence inserted between sequential segments
  check_updates = true,        -- look at GitHub releases once a day at launch
  last_update_check = 0,
  voices        = {},          -- cloned voice library: { {id=, name=, created=} }
  recent_files  = {},
}

------------------------------------------------------------------ disk layout

function M.dir()          return P.config_dir() end
function M.path()         return P.join(M.dir(), "config.json") end
function M.takes_dir()    return P.join(M.dir(), "takes") end
function M.refs_dir()     return P.join(M.dir(), "references") end
function M.tmp_dir()      return P.join(M.dir(), "tmp") end
function M.projects_dir() return P.join(M.dir(), "projects") end

--- Where generated audio goes by default: the user's own video folder, with
-- one subfolder per Resolve project. Takes are the user's footage, so they
-- belong beside the rest of it rather than buried in application support.
function M.default_output_dir() return P.join(P.media_dir(), M.APP_NAME) end

--- The folder a project's clips are written to: the chosen base folder plus
-- the project's own name, so two projects never mix their takes. Without a
-- project open (or with a name that sanitises to nothing) the base is used.
function M.project_output_dir(cfg, project_name)
  local base = (cfg and cfg.output_dir ~= "" and cfg.output_dir) or M.default_output_dir()
  local leaf = U.sanitize(project_name or "")
  if leaf == "" then return base end
  return P.join(base, leaf)
end

function M.lock_path()    return P.join(M.dir(), "running.lock") end
function M.raise_path()   return P.join(M.dir(), "raise.request") end
function M.raised_path()  return P.join(M.dir(), "raise.done") end

--- The Generate tab's saved draft, one per Resolve project.
function M.draft_path(project_id)
  return P.join(M.projects_dir(), U.sanitize(project_id ~= "" and project_id or "no-project"), "generate.json")
end

--- Single-instance lock. A second copy of the script would share Resolve's
-- event queue with the first and each would swallow the other's clicks, so
-- the running instance stamps the lock every couple of seconds and a new
-- launch backs off while the stamp is fresh. A stale stamp (crash, kill) is
-- simply overwritten.
M.LOCK_FRESH_SECONDS = 8

function M.lock_is_live()
  local raw = U.read_file(M.lock_path())
  local stamp = raw and tonumber(U.trim(raw))
  return stamp ~= nil and (os.time() - stamp) < M.LOCK_FRESH_SECONDS
end

function M.touch_lock()
  U.write_file(M.lock_path(), tostring(os.time()))
end

function M.release_lock()
  os.remove(M.lock_path())
end

local made_private = false
function M.ensure_dirs()
  for _, d in ipairs({ M.dir(), M.takes_dir(), M.refs_dir(), M.tmp_dir(), M.projects_dir() }) do
    if not P.exists(d) then P.mkdirs(d) end
  end
  -- Once per launch: the key lives in here (see platform make_private).
  if not made_private then
    made_private = true
    P.make_private(M.dir())
  end
end

-------------------------------------------------------------------- load/save

local function apply_defaults(cfg)
  for k, v in pairs(DEFAULTS) do
    if cfg[k] == nil then
      if type(v) == "table" then
        local copy = {}
        for i, item in ipairs(v) do copy[i] = item end
        cfg[k] = copy
      else
        cfg[k] = v
      end
    end
  end
  if cfg.output_dir == "" then cfg.output_dir = M.default_output_dir() end
  return cfg
end

--- Upgrade a config written by an older release.
-- Unknown (newer) schemas are left alone: a user who downgrades keeps their
-- settings rather than having them silently rewritten.
-- Exposed for the test suite; load() is the only caller in the product.
function M.migrate(cfg)
  cfg.schema = cfg.schema or 0
  -- 2 dropped the clip pause default from 400 ms to 240; 4 put it back.
  -- A config on either default ends on 400; a value the user chose is kept.
  if cfg.schema < 4 and cfg.pause_ms == 240 then cfg.pause_ms = 400 end
  -- 3: takes moved out of application support and into the user's video
  -- folder, one subfolder per project. A config still on the old default
  -- follows; a folder the user picked is left exactly where they put it.
  if cfg.schema < 3 and (cfg.output_dir == M.takes_dir() or cfg.output_dir == "") then
    cfg.output_dir = M.default_output_dir()
  end
  -- 5 turned "Place on timeline" on by default; a config still on the old
  -- default (off) follows.
  if cfg.schema < 5 and cfg.auto_place == false then cfg.auto_place = true end
  if cfg.schema < M.SCHEMA then cfg.schema = M.SCHEMA end
  return cfg
end

--- Read config from disk, falling back to defaults.
-- A corrupt file is preserved as config.json.bad rather than overwritten, so a
-- user never silently loses a voice library to a half-written save.
function M.load()
  M.ensure_dirs()
  local raw = U.read_file(M.path())
  if not raw or raw == "" then return apply_defaults({}) end

  local parsed, err = U.json.decode(raw)
  if type(parsed) ~= "table" then
    U.write_file(M.path() .. ".bad", raw)
    return apply_defaults({}), "config was unreadable (" .. tostring(err) ..
      "); a copy was kept as config.json.bad and defaults were restored"
  end
  return apply_defaults(M.migrate(parsed))
end

--- Write config to disk via a temp file, so an interrupted save cannot
-- truncate a good config.
function M.save(cfg)
  M.ensure_dirs()
  local tmp = M.path() .. ".tmp"
  if not U.write_file(tmp, U.json.encode(cfg)) then return false end
  os.remove(M.path())
  local ok = os.rename(tmp, M.path())
  if not ok then
    -- rename can fail across some filesystems; fall back to a direct write.
    return U.write_file(M.path(), U.json.encode(cfg))
  end
  return true
end

------------------------------------------------------------------ credentials

--- The API key is base64-encoded in config.json.
-- That is obfuscation, not encryption — anyone with access to this user account
-- can read it. It matches how comparable editor plugins store keys, and the key
-- is never passed on a command line (see api.lua), so it stays out of the
-- process list. Say this plainly in the UI rather than implying it is secure.
function M.get_api_key(cfg)
  local b64 = cfg.api_key_b64 or ""
  if b64 == "" then return "" end
  local decoded = M.b64_decode(b64)
  return decoded or ""
end

function M.set_api_key(cfg, key)
  cfg.api_key_b64 = (key and key ~= "") and U.b64_encode(key) or ""
end

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function M.b64_decode(s)
  s = tostring(s):gsub("[^%w%+/=]", "")
  local out = {}
  local lookup = {}
  for i = 1, #B64_CHARS do lookup[B64_CHARS:sub(i, i)] = i - 1 end
  local i = 1
  while i + 3 <= #s do
    local c1, c2 = lookup[s:sub(i, i)], lookup[s:sub(i + 1, i + 1)]
    local ch3, ch4 = s:sub(i + 2, i + 2), s:sub(i + 3, i + 3)
    if not c1 or not c2 then return nil end
    local c3, c4 = lookup[ch3], lookup[ch4]
    local n = c1 * 262144 + c2 * 4096 + (c3 or 0) * 64 + (c4 or 0)
    out[#out + 1] = string.char(math.floor(n / 65536) % 256)
    if ch3 ~= "=" then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
    if ch4 ~= "=" then out[#out + 1] = string.char(n % 256) end
    i = i + 4
  end
  return table.concat(out)
end

--------------------------------------------------------------- voice library

function M.add_voice(cfg, id, name)
  for _, v in ipairs(cfg.voices) do
    if v.id == id then v.name = name return v end
  end
  local entry = { id = id, name = name, created = os.time() }
  cfg.voices[#cfg.voices + 1] = entry
  return entry
end

function M.remove_voice(cfg, id)
  for i, v in ipairs(cfg.voices) do
    if v.id == id then table.remove(cfg.voices, i) return true end
  end
  return false
end

function M.find_voice(cfg, id)
  for _, v in ipairs(cfg.voices) do
    if v.id == id then return v end
  end
  return nil
end

M.DEFAULTS = DEFAULTS

return M
