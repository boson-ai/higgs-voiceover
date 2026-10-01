--- Build Higgs VoiceOver: bundle src/higgs/*.lua into one installable script.
--
-- Run with Resolve's own interpreter (no toolchain to install):
--   "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript" -l lua build.lua
--
-- Each module is wrapped in package.preload so `require("higgs.x")` works inside
-- the single output file exactly as it does across the source tree. Module order
-- below is load order only for preload registration — actual dependency order is
-- resolved by require at runtime, so listing is alphabetical-ish and harmless.

local OUT = "Higgs VoiceOver.lua"
local SRC = "src/higgs/"

-- The release version lives in VERSION (one line, e.g. 0.9.0) and is
-- stamped into the bundle so the app can compare itself to GitHub releases.
local VERSION = "0.0.0"
do
  local f = io.open("VERSION", "r")
  if f then VERSION = (f:read("*l") or "0.0.0"):gsub("%s+", ""); f:close() end
end

local MODULES = {
  "util",
  "log",
  "icons",
  "theme",
  "config",
  "tags",
  "subtitles",
  "api",
  "resolve",
  "recorder",
  "record_macos",
  "ui",
  "platform_macos",
  "platform",
}

local ENTRY = "main"   -- src/higgs/main.lua runs last, un-wrapped

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

local parts = {}
local function emit(s) parts[#parts + 1] = s end

emit("--[[\n")
emit("  Higgs VoiceOver — AI voice-over for DaVinci Resolve\n")
emit("  Boson AI · Higgs TTS 3\n\n")
emit("  GENERATED FILE — do not edit.\n")
emit("  Built from src/higgs/ by build.lua. Edit the modules and rebuild.\n")
emit("]]\n\n")

local missing = {}
for _, name in ipairs(MODULES) do
  local path = SRC .. name .. ".lua"
  local body = read(path)
  if not body then
    missing[#missing + 1] = path
  else
    emit(("package.preload[%q] = function(...)\n"):format("higgs." .. name))
    emit(body)
    emit("\nend\n\n")
  end
end

if #missing > 0 then
  io.stderr:write("build: missing module(s):\n  " .. table.concat(missing, "\n  ") .. "\n")
  os.exit(1)
end

local entry_path = SRC .. ENTRY .. ".lua"
if exists(entry_path) then
  emit("-- ===== entry point (" .. entry_path .. ") =====\n")
  -- Tests load this bundle to reach the modules and must not open a window.
  -- Resolve always loads it for its side effect, so the default is to run.
  emit(("_G.HIGGS_VO_VERSION = %q\n"):format(VERSION))
emit("if not _G.HIGGS_VO_NO_AUTORUN then\n")
  emit(read(entry_path))
  emit("\nend\n")
else
  emit("-- No entry point yet (" .. entry_path .. " not found).\n")
  emit("-- Modules above are loadable via require('higgs.<name>').\n")
end

local out = io.open(OUT, "wb")
if not out then
  io.stderr:write("build: cannot write " .. OUT .. "\n")
  os.exit(1)
end
local blob = table.concat(parts)
out:write(blob)
out:close()

print(("build: wrote %s (%d modules, %.1f KB)"):format(OUT, #MODULES, #blob / 1024))
