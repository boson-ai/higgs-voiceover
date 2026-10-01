--- Platform abstraction for Higgs VO.
--
-- Every OS-specific operation in the product goes through this module. No other
-- file may branch on the operating system. Porting to a new OS means writing one
-- backend table (see platform_macos.lua) and registering it below — nothing else
-- in the codebase changes.
--
-- Backend contract — a backend table must implement every function listed in
-- REQUIRED below, with these signatures:
--
--   name                                  -> string          ("macos")
--   sep                                   -> string          path separator
--   quote(s)                              -> string          shell-quote one argument
--   config_dir()                          -> string          per-user app data dir
--   media_dir()                           -> string          the user's own video folder
--   scripts_dir()                         -> string          Resolve's Utility scripts dir
--   mkdirs(path)                          -> bool            create dir + parents
--   make_private(path)                    -> bool            only the user may read it (dir + contents)
--   open_folder(path)                     -> bool            reveal in file manager
--   run_detached(cmd)                     -> bool            fire and forget, no window
--   run_capture(cmd)                      -> string|nil      run, return stdout
--   supports_async()                      -> bool            can we poll instead of block
--   audio_play_cmd(path)                  -> string          shell command to play a file
--   audio_stop()                          -> bool            stop whatever we started
--   audio_play_formats()                  -> table           extensions the player handles
--   can_record()                          -> bool            is capture possible at all?
--   record_unavailable()                  -> string|nil      why not, for the user
--   record_start(out_wav, secs, dev)      -> bool            begin capture
--   record_kill()                         -> bool            stop without finishing the file
--   record_status(out_wav)                -> table|nil       { seconds=, peak= } while running
--   default_input_name()                  -> string          the input a take will come from
--   open_sound_settings()                 -> bool            where the user changes it
--   record_stop()                         -> bool            stop the capture we started
--   record_is_running()                   -> bool            is that capture still going?
--
-- Backends never read global state and never touch the UI; they build commands
-- and answer questions about the host. That keeps them trivially testable and
-- makes an incomplete port a loud failure rather than a subtle one.

local M = {}

local REQUIRED = {
  "name", "sep", "quote", "config_dir", "media_dir", "scripts_dir", "mkdirs", "make_private", "open_folder",
  "run_detached", "run_capture", "supports_async", "audio_play_cmd", "audio_stop",
  "audio_pause", "audio_resume", "audio_is_playing",
  "audio_play_formats", "can_record", "record_unavailable", "record_start",
  "record_stop", "record_kill", "record_is_running", "record_status",
  "default_input_name", "open_sound_settings",
}

--- Which OS are we on? Detected once, at load. This release runs on macOS
-- only; another OS gets a plain message instead of a half-working window.
local home = os.getenv("HOME") or ""
local is_mac = package.config:sub(1, 1) == "/" and
  (home:sub(1, 7) == "/Users/" or os.getenv("__CFBundleIdentifier") ~= nil)

M.is_mac = is_mac

if not is_mac then
  error("Higgs VoiceOver runs on macOS. This system is not supported yet.")
end

local backend = require("higgs.platform_macos")

-- Fail at load time, not at the moment a user clicks Record on a half-ported OS.
local missing = {}
for _, fn in ipairs(REQUIRED) do
  if backend[fn] == nil then missing[#missing + 1] = fn end
end
if #missing > 0 then
  error("Higgs VoiceOver: platform backend '" .. tostring(backend.name) ..
        "' is missing: " .. table.concat(missing, ", "))
end

for _, fn in ipairs(REQUIRED) do M[fn] = backend[fn] end

--- Join path segments with the host separator, collapsing duplicates.
function M.join(...)
  local parts = { ... }
  local out = {}
  for i, p in ipairs(parts) do
    p = tostring(p)
    if i > 1 then p = p:gsub("^[/\\]+", "") end
    p = p:gsub("[/\\]+$", "")
    if p ~= "" or i == 1 then out[#out + 1] = p end
  end
  return table.concat(out, M.sep)
end

--- Last path component.
function M.basename(p)
  return (tostring(p):match("([^/\\]+)$")) or tostring(p)
end

--- Everything but the last path component.
function M.dirname(p)
  return (tostring(p):match("^(.*)[/\\][^/\\]+$")) or "."
end

--- True when the path exists and is readable.
function M.exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

--- Can this file be previewed by the host's audio player?
function M.can_play(path)
  local ext = tostring(path):match("%.([%a%d]+)$")
  if not ext then return false end
  ext = ext:lower()
  for _, e in ipairs(M.audio_play_formats()) do
    if e == ext then return true end
  end
  return false
end

return M
