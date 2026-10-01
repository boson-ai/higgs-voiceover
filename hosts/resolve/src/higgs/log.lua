--- One plain-text log per launch, next to the config file.
--
-- Resolve shows a script's console output nowhere the user will look, so
-- when something goes wrong this file is the whole record. It has to answer
-- "what did the user do, what did the app do about it, and what did that
-- look like" — events alone are not enough: the double-click that never
-- arrived and the button that drew at the wrong edge both left logs that
-- looked perfectly healthy.
--
-- Every line: time with milliseconds, level, category, message, then
-- key=value fields. Levels: info · warn · error · ui (a user action) ·
-- metric (a measured outcome).
--
-- User content is wrapped with M.q() and home paths with M.path_safe(), so a copy
-- can be redacted mechanically (M.redact) before it ever leaves the machine.
-- The API key is never written; it travels in a curl config file.
--
-- Each launch writes logs/higgs-vo-<date>-<time>.log; the ten newest are kept.

local P = require("higgs.platform")

local M = {}

M.KEEP = 10
local current         -- path of this launch's file
local buffered = {}   -- lines written before start() chose a file
local started_at      -- wall clock at start(), for the session summary

--- Counters for the session summary and the report bundle.
-- counts[name] = number of times; sums[name.field] = running total.
M.counts, M.sums = {}, {}
M.session = nil       -- random id per launch, so a report can group lines

function M.dir()
  return P.join(P.config_dir(), "logs")
end

function M.path()
  return current or P.join(M.dir(), "higgs-vo.log")
end

local function list_logs()
  local out = {}
  local cmd = "ls -1 " .. P.quote(M.dir()) .. " 2>/dev/null"
  local ok, listing = pcall(P.run_capture, cmd)
  if ok and listing then
    for name in tostring(listing):gmatch("[^\r\n]+") do
      if name:match("^higgs%-vo%-%d+%-%d+%.log$") then out[#out + 1] = name end
    end
  end
  table.sort(out)
  return out
end

local function clock()
  local ok, t = pcall(function() return _G.bmd.gettime() end)
  return (ok and tonumber(t)) or os.time()
end

--- bmd.gettime() has sub-second resolution but is not wall-clock time (it
-- read 21:46 at 20:03); os.time() is wall time in whole seconds. The first
-- stamp ties the two together and every later one is measured from it.
local wall_offset
local function stamp()
  local t = clock()
  if not wall_offset then wall_offset = os.time() - t end
  local w = t + wall_offset
  return os.date("%H:%M:%S", math.floor(w)) .. (".%03d"):format(math.floor((w % 1) * 1000))
end

------------------------------------------------------------------ formatting

--- User content (project, voice and file names). Marked so M.redact can
-- remove it; never pass the text a user is voicing — log its length.
local OPEN, CLOSE = "‹", "›"   -- multi-byte: never put them in a [set]

local function strip_marks(s)
  local out = s
  for _, m in ipairs({ OPEN, CLOSE }) do
    local parts, i = {}, 1
    while true do
      local a, b = out:find(m, i, true)
      if not a then parts[#parts + 1] = out:sub(i) break end
      parts[#parts + 1] = out:sub(i, a - 1)
      i = b + 1
    end
    out = table.concat(parts)
  end
  return out
end

function M.q(s)
  return OPEN .. strip_marks(tostring(s or "")) .. CLOSE
end

--- A path with the home folder written as ~, and user folders past the
-- app's own marked as content.
function M.path_safe(p)
  p = tostring(p or "")
  local home = os.getenv("HOME")
  if home and home ~= "" and p:sub(1, #home) == home then p = "~" .. p:sub(#home + 1) end
  return p
end

--- key=value pairs in a stable order. Values with spaces are quoted.
local function fields(t)
  if type(t) ~= "table" then return "" end
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do
    local v = t[k]
    if type(v) == "number" and v ~= math.floor(v) then v = ("%.3f"):format(v):gsub("0+$", ""):gsub("%.$", "") end
    v = tostring(v)
    if v:find("[%s=]") and v:sub(1, #OPEN) ~= OPEN then v = '"' .. v:gsub('"', "'") .. '"' end
    out[#out + 1] = k .. "=" .. v
  end
  return table.concat(out, " ")
end
M.fields = fields

------------------------------------------------------------------- writing

--- Start this launch's file and drop the oldest beyond KEEP.
function M.start()
  started_at = clock()
  math.randomseed(os.time() + math.floor((clock() % 1) * 1e6))
  M.session = ("%08x"):format(math.random(0, 0x7fffffff))
  pcall(function()
    if not P.exists(M.dir()) then P.mkdirs(M.dir()) end
    current = P.join(M.dir(), os.date("higgs-vo-%Y%m%d-%H%M%S.log"))
    local names = list_logs()
    for i = 1, #names - (M.KEEP - 1) do os.remove(P.join(M.dir(), names[i])) end
    local f = io.open(current, "ab")
    if f then
      f:write(("# Higgs VoiceOver log · %s · session %s\n"):format(os.date("%Y-%m-%d %H:%M:%S"), M.session))
      f:close()
    end
    for _, line in ipairs(buffered) do M.write(line[1], line[2]) end
    buffered = {}
  end)
end

--- level: "info" | "warn" | "error" | "ui" | "metric"
function M.write(level, message)
  if level == "warn" then M.counts["log.warn"] = (M.counts["log.warn"] or 0) + 1 end
  if level == "error" then M.counts["log.error"] = (M.counts["log.error"] or 0) + 1 end
  if not current then
    buffered[#buffered + 1] = { level, message }
    return
  end
  local ok = pcall(function()
    local f = io.open(current, "ab")
    if not f then return end
    f:write(stamp(), " ", ("%-6s"):format(level), " ",
            (tostring(message):gsub("[\r\n]+", " ")), "\n")
    f:close()
  end)
  if not ok then print("Higgs VoiceOver: could not write log") end
end

--- message, then optional fields: Log.info("placed", { clips = 2 })
function M.info(message, t)  M.write("info",  t and (message .. "  " .. fields(t)) or message) end
function M.warn(message, t)  M.write("warn",  t and (message .. "  " .. fields(t)) or message) end
function M.error(message, t) M.write("error", t and (message .. "  " .. fields(t)) or message) end
function M.ui(message, t)    M.write("ui",    t and (message .. "  " .. fields(t)) or message) end

--- A measured outcome. Written to the log and folded into the session
-- totals: every numeric field is summed under name.field.
function M.metric(name, t)
  t = t or {}
  M.counts[name] = (M.counts[name] or 0) + 1
  for k, v in pairs(t) do
    if type(v) == "number" then
      local key = name .. "." .. k
      M.sums[key] = (M.sums[key] or 0) + v
    end
  end
  M.write("metric", name .. "  " .. fields(t))
end

--- One line at exit: how long the session ran and what it did.
function M.summary()
  local t = { seconds = math.floor(clock() - (started_at or clock())) }
  for k, v in pairs(M.counts) do t[k] = v end
  for k, v in pairs(M.sums) do t[k] = v end
  M.write("metric", "session  " .. fields(t))
  return t
end

------------------------------------------------------------ report copy

--- A copy of a log with user content removed: ‹…› becomes ‹›, and any
-- home path that slipped through unwrapped loses its user name.
function M.redact(text)
  text = tostring(text or "")
  local parts, i = {}, 1
  while true do
    local a, b = text:find(OPEN, i, true)
    if not a then parts[#parts + 1] = text:sub(i) break end
    local c, d = text:find(CLOSE, b + 1, true)
    if not c then parts[#parts + 1] = text:sub(i) break end
    parts[#parts + 1] = text:sub(i, b) .. CLOSE
    i = d + 1
  end
  text = table.concat(parts)
  -- Messages shown to the user quote names in curly quotes.
  text = text:gsub("\226\128\156.-\226\128\157", "\226\128\156\226\128\157")
  text = text:gsub("/Users/[^/%s]+", "/Users/~"):gsub("/home/[^/%s]+", "/home/~")
  return text
end

--- This session's totals and its log, redacted: what a problem report
-- would carry. Nothing sends it.
function M.bundle()
  local f = current and io.open(current, "rb")
  local text = f and f:read("*a") or ""
  if f then f:close() end
  return {
    session = M.session,
    version = tostring(_G.HIGGS_VO_VERSION or "dev"),
    platform = P.name,
    counts = M.counts,
    sums = M.sums,
    log = M.redact(text),
  }
end

return M
