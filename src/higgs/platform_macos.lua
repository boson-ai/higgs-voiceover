--- macOS backend. See platform.lua for the contract.

local B = { name = "macos", sep = "/" }

local HOME = os.getenv("HOME") or "."

--- POSIX single-quoting: wrap in ', and close/escape/reopen for embedded '.
function B.quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function B.config_dir()
  return HOME .. "/Library/Application Support/HiggsVO"
end

--- Where finished audio goes by default: the user's own Movies folder, not
-- our application-support directory, so takes sit with their footage.
function B.media_dir()
  return HOME .. "/Movies"
end

function B.scripts_dir()
  return HOME .. "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility"
end

function B.mkdirs(path)
  return os.execute("mkdir -p " .. B.quote(path)) and true or false
end

--- Resolve runs scripts with a umask of 0, so everything a script creates is
-- readable and writable by every account on the Mac. The settings folder
-- holds the API key (config.json, and curl's config file for the length of
-- a request), so it is closed to everyone but the user, contents included.
function B.make_private(path)
  return os.execute("chmod -R go-rwx " .. B.quote(path) .. " 2>/dev/null") and true or false
end

function B.open_folder(path)
  return os.execute("open " .. B.quote(path)) and true or false
end

function B.run_detached(cmd)
  -- Subshell + background + detached stdio so Resolve never waits on us.
  return os.execute("(" .. cmd .. ") >/dev/null 2>&1 &") and true or false
end

function B.run_capture(cmd)
  local p = io.popen(cmd .. " 2>&1", "r")
  if not p then return nil end
  local out = p:read("*a")
  p:close()
  return out
end

--- macOS can run work in the background and be polled, so generation never
-- blocks the UI thread.
function B.supports_async() return true end

local PID_FILE = B.config_dir() .. "/.play.pid"

function B.audio_play_cmd(path)
  return "afplay " .. B.quote(path) .. " & echo $! > " .. B.quote(PID_FILE)
end

function B.audio_stop()
  local f = io.open(PID_FILE, "r")
  if not f then return false end
  local pid = (f:read("*a") or ""):match("%d+")
  f:close()
  os.remove(PID_FILE)
  if not pid then return false end
  os.execute("kill " .. pid .. " >/dev/null 2>&1")
  return true
end

local function play_pid()
  local f = io.open(PID_FILE, "r")
  if not f then return nil end
  local pid = (f:read("*a") or ""):match("%d+")
  f:close()
  return pid
end

--- afplay cannot seek, but a stopped process holds its place: SIGSTOP pauses
-- the audio where it is and SIGCONT carries on from there.
function B.audio_pause()
  local pid = play_pid()
  if not pid then return false end
  return os.execute("kill -STOP " .. pid .. " >/dev/null 2>&1") and true or false
end

function B.audio_resume()
  local pid = play_pid()
  if not pid then return false end
  return os.execute("kill -CONT " .. pid .. " >/dev/null 2>&1") and true or false
end

--- True while the afplay we started is still alive; nil when unknown.
function B.audio_is_playing()
  local pid = play_pid()
  if not pid then return false end
  return os.execute("kill -0 " .. pid .. " >/dev/null 2>&1") and true or false
end

--- afplay handles everything CoreAudio does.
function B.audio_play_formats()
  return { "wav", "mp3", "aac", "m4a", "aif", "aiff", "flac", "caf" }
end

local Rec = require("higgs.record_macos")

local REC_PID_FILE = B.config_dir() .. "/.record.pid"

local function script_path()
  return B.config_dir() .. "/record.js"
end

--- Capture needs nothing installed: osascript's JavaScript dialect reaches
-- AVAudioRecorder, which writes a plain PCM WAV. See record_macos.lua for why
-- this is not ffmpeg.
function B.can_record() return true end
function B.record_unavailable() return nil end

--- `device` is accepted and ignored: the bridge does not expose
-- AVCaptureDevice, so a take always comes from the system default input.
function B.record_start(out_path, max_seconds, count_in)
  -- Written every launch so an edited script reaches disk, as the icons do.
  local f = io.open(script_path(), "wb")
  if not f then return false end
  f:write(Rec.script_text())
  f:close()
  os.remove(out_path .. ".stop")
  os.remove(out_path .. ".status")
  local cmd = ("osascript -l JavaScript %s %s %d %s & echo $! > %s")
    :format(B.quote(script_path()), B.quote(out_path),
            tonumber(max_seconds) or 30, tostring(tonumber(count_in) or 0),
            B.quote(REC_PID_FILE))
  return os.execute("(" .. cmd .. ") >/dev/null 2>&1 &") and true or false
end

local function record_pid()
  local f = io.open(REC_PID_FILE, "r")
  if not f then return nil end
  local pid = (f:read("*a") or ""):match("%d+")
  f:close()
  return pid
end

--- Ask, do not kill: AVAudioRecorder writes the WAV's length fields in stop(),
-- and a signalled process never gets there.
function B.record_stop(out_path)
  if out_path then
    local f = io.open(out_path .. ".stop", "wb")
    if f then f:write("stop"); f:close() end
  end
  return true
end

--- The blunt version, for a dialog closing on a recording nobody wants.
function B.record_kill()
  local pid = record_pid()
  os.remove(REC_PID_FILE)
  if not pid then return false end
  os.execute("kill -INT " .. pid .. " >/dev/null 2>&1")
  return true
end

function B.record_is_running()
  local pid = record_pid()
  if not pid then return false end
  return os.execute("kill -0 " .. pid .. " >/dev/null 2>&1") and true or false
end

--- Elapsed seconds and peak level, read from the sidecar the script writes.
function B.record_status(out_path)
  local f = io.open(out_path .. ".status", "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return Rec.parse_status(text)
end

--- The name of the input a take will come from. There is no choosing it, so
-- the least the interface can do is say which one it is.
function B.default_input_name()
  local ok, out = pcall(B.run_capture, "system_profiler SPAudioDataType 2>/dev/null")
  if not ok or not out then return "" end
  -- Devices are listed as "Name:" with their properties indented under them.
  local current
  for line in tostring(out):gmatch("[^\r\n]+") do
    local name = line:match("^%s%s%s%s%s%s%s%s([^:]+):%s*$")
    if name then current = name end
    if line:match("Default Input Device:%s*Yes") and current then return current end
  end
  return ""
end

--- Where a user changes that input. Opening a settings pane is the whole of
-- what we can offer instead of a picker.
function B.open_sound_settings()
  return os.execute("open 'x-apple.systempreferences:com.apple.Sound-Settings.extension' >/dev/null 2>&1") and true or false
end

return B
