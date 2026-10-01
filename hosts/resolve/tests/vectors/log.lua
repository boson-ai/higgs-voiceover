--- Vectors for the pure parts of log.lua: marking user content, home paths,
-- key=value fields, metrics, line layout, which files are kept, redaction.
--
-- The home folder is given in each case (`home`) rather than read from this
-- machine. A written line is given without its time stamp, which is the
-- clock's, not the rules'.

local L = require("higgs.log")
local P = require("higgs.platform")

local cases = {}
local function case(name, fn, input, expect)
  cases[#cases + 1] = { name = name, fn = fn, input = input, expect = expect }
end

local function upvalue(fn, name)
  for i = 1, 60 do
    local n, v = debug.getupvalue(fn, i)
    if n == nil then break end
    if n == name then return v, i end
  end
  error("no upvalue " .. name)
end

case("KEEP", "KEEP", { none = true }, L.KEEP)

------------------------------------------------------------------ q

for _, c in ipairs({
  { "user content is marked", "My Project" },
  { "marks inside content cannot close it early", "a›b" },
  { "nor open it twice", "‹x› and ‹y›" },
  { "CJK inside marks", "配音" },
  { "empty", "" },
  { "a number", 42 },
}) do case("q: " .. c[1], "q", { s = c[2] }, L.q(c[2])) end
case("q: nothing", "q", { none = true }, L.q(nil))

------------------------------------------------------------------ path_safe

local getenv = os.getenv
for _, c in ipairs({
  { "a home path is written as ~", "/Users/alex/Movies/Higgs VoiceOver/a.wav", "/Users/alex" },
  { "the home folder itself", "/Users/alex", "/Users/alex" },
  { "a path elsewhere is left alone", "/Volumes/Work/VO/a.wav", "/Users/alex" },
  { "a longer name sharing the prefix is cut too", "/Users/alexander/x.wav", "/Users/alex" },
  { "no home known", "/Users/alex/x", nil },
  { "an empty home", "/Users/alex/x", "" },
  { "a Windows home", "C:\\Users\\Alex\\Videos\\a.wav", "C:\\Users\\Alex" },
  { "nothing", nil, "/Users/alex" },
}) do
  os.getenv = function(k) if k == "HOME" then return c[3] end return getenv(k) end
  case("path_safe: " .. c[1], "path_safe", { p = c[2], home = c[3] }, L.path_safe(c[2]))
end
os.getenv = getenv

------------------------------------------------------------------ fields

for _, c in ipairs({
  { "sorted and quoted", { b = 2, a = "x y" } },
  { "fractions are trimmed", { s = 1.5 } },
  { "to three places", { r = 2 / 3, ms = 12.0004, t = 0.1 + 0.2 } },
  { "a fraction that rounds away", { tiny = 0.0004, neg = -1.25, up = 99.9996 } },
  { "an exact tie rounds up", { a = 0.0625, b = 2.0005 } },
  { "whole numbers as Lua writes them", { n = 100, z = 0, big = 1e15, bigger = 123456789012345, huge = 1e20, neg = -7 } },
  { "booleans", { t = true, f = false } },
  { "an equals sign is quoted", { s = "a=b" } },
  { "double quotes become single inside quotes", { s = 'say "hi" now' } },
  { "double quotes alone are not quoted", { s = '"x"' } },
  { "marked content is never quoted", { s = "‹a b›" } },
  { "a tab is whitespace", { s = "tab\there" } },
  { "a line break is whitespace", { s = "two\nlines" } },
  { "a no-break space is not", { s = "a\194\160b" } },
  { "empty text", { s = "" } },
  { "nothing", {} },
  { "keys sort as bytes", { B = 1, a = 2, _ = 3, ["1"] = 4 } },
}) do case("fields: " .. c[1], "fields", { t = c[2] }, L.fields(c[2])) end

------------------------------------------------------------------ messages and metrics

local write = L.write
local captured
L.write = function(level, message) captured = { level = level, message = message } end
for _, c in ipairs({
  { "info", "placed", { clips = 2 } }, { "warn", "slow", { ms = 1234.5678 } },
  { "error", "failed", nil }, { "ui", "click", { button = "Generate", where = "‹Tab one›" } },
}) do
  L[c[1]](c[2], c[3])
  case("entry: " .. c[1] .. " " .. c[2], "entry", { level = c[1], message = c[2], t = c[3] }, captured)
end

do
  local counts, sums = L.counts, L.sums
  L.counts, L.sums = {}, {}
  local steps = {
    { "speech", { ms = 100, ok = 1, voice = "nora" } },
    { "speech", { ms = 50.5, ok = 0, failed = 1 } },
    { "voice.use", { voice = "cloned" } },
    { "speech", nil },
  }
  local lines = {}
  for i, s in ipairs(steps) do
    L.metric(s[1], s[2])
    lines[i] = captured.message
  end
  local input = {}
  for i, s in ipairs(steps) do input[i] = { name = s[1], t = s[2] } end
  case("metric: counted and summed", "metric", { steps = input }, { lines = lines, counts = L.counts, sums = L.sums })
  L.counts, L.sums = counts, sums
end
L.write = write

------------------------------------------------------------------ lines

do
  local _, idx = upvalue(L.write, "current")
  local path = os.tmpname()
  local counts = L.counts
  L.counts = {}
  for _, c in ipairs({
    { "info", "hello" }, { "metric", "speech  ms=12" }, { "ui", "line one\nline two\r\n\nline three" },
    { "warn", "careful" }, { "verbose", "a level longer than six" }, { "", "no level" },
  }) do
    os.remove(path)
    debug.setupvalue(L.write, idx, path)
    L.write(c[1], c[2])
    debug.setupvalue(L.write, idx, nil)
    local f = io.open(path, "rb")
    local line = f:read("*a")
    f:close()
    -- "HH:MM:SS.mmm " is the clock's; the rest is the layout.
    case("line: " .. c[1], "line", { level = c[1], message = c[2] }, line:sub(14))
  end
  os.remove(path)
  L.counts = counts
end

------------------------------------------------------------------ which files are kept

do
  local list_logs = upvalue(L.start, "list_logs")
  local run_capture = P.run_capture
  local function keep(name, names, n)
    P.run_capture = function() return table.concat(names, "\n") end
    local sorted = list_logs()
    local drop = {}
    for i = 1, #sorted - ((n or L.KEEP) - 1) do drop[#drop + 1] = sorted[i] end
    case("logs_to_remove: " .. name, "logs_to_remove", { names = names }, drop)
  end
  local many = {}
  for i = 1, 12 do many[i] = ("higgs-vo-202609%02d-120000.log"):format(13 - i) end
  keep("twelve old logs leave nine for the new one", many)
  keep("nine old logs are all kept", { "higgs-vo-20260901-090000.log", "higgs-vo-20260902-090000.log",
    "higgs-vo-20260903-090000.log", "higgs-vo-20260904-090000.log", "higgs-vo-20260905-090000.log",
    "higgs-vo-20260906-090000.log", "higgs-vo-20260907-090000.log", "higgs-vo-20260908-090000.log",
    "higgs-vo-20260909-090000.log" })
  local mixed = { "higgs-vo.log", "notes.txt", "higgs-vo-20260101-000000.log.bak", "HIGGS-VO-20260101-000000.log",
                  "higgs-vo-x-1.log" }
  for i = 1, 10 do mixed[#mixed + 1] = ("higgs-vo-202608%02d-235959.log"):format(i) end
  keep("only this app's logs count", mixed)
  keep("no logs", {})
  P.run_capture = run_capture
end

------------------------------------------------------------------ redact

for _, c in ipairs({
  { "marked content is removed", "project=‹Secret Film› tracks=2" },
  { "every mark", "a=‹one› b=‹two words› c=3" },
  { "an unclosed mark is left", "a=‹open and b=2" },
  { "a close mark alone is left", "a=x› b" },
  { "nested marks close at the first", "‹a ‹b› c›" },
  { "a name in curly quotes is removed", "Deleted “Alex — zh” from your list." },
  { "every quoted name", "“a” and “b”" },
  { "quotes across a line", "“first\nsecond” after" },
  { "a home path loses the user name", "folder /Users/alex/Movies/x" },
  { "the user name stops at a space", "/Users/Alex Chen/Movies" },
  { "a Linux home", "/home/bob/.config/x and /home/carol" },
  { "CJK inside marks", "project=‹配音› ok" },
  { "text around a mark is untouched", "a — b ‹c› d" },
  { "several lines", "10:00:00.000 info   a  p=‹x›\n10:00:01.000 warn   /Users/al/y\n" },
  { "nothing", "" },
}) do case("redact: " .. c[1], "redact", { text = c[2] }, L.redact(c[2])) end

return {
  about = "The log: marking user content, fields, metrics, line layout, kept files, redaction.",
  source = "src/higgs/log.lua",
  cases = cases,
}
