--- Shared test vectors: what the Resolve build does, written down as data so
-- every other host can be held to the same behaviour.
--
--   fuscript -l lua tests/vectors.lua          check: the Lua still matches
--   WRITE=1 fuscript -l lua tests/vectors.lua  regenerate ../../shared/vectors
--   TOPIC=tags …                               one topic only
--
-- Each tests/vectors/<topic>.lua returns
--   { about = "...", source = "src/higgs/<module>.lua", cases = { { name, fn, input, expect }, ... } }
-- where `expect` was computed by running this build's code on `input`. Values
-- are host-neutral: strings, numbers, booleans, lists and records — never a
-- byte offset (Lua counts bytes, other hosts count characters).

_G.HIGGS_VO_NO_AUTORUN = true
dofile("Higgs VoiceOver.lua")

local TOPICS = { "text", "subtitles", "tags", "recorder", "wav", "settings", "boson", "log" }
local OUT_DIR = "../../shared/vectors/"

-- JSON with sorted keys and fixed number formatting, so a file only changes
-- when behaviour does.
local function is_list(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

local function num(v)
  if v ~= v or v == math.huge or v == -math.huge then error("vectors: non-finite number") end
  if v == math.floor(v) and math.abs(v) < 2^53 then return string.format("%d", v) end
  local s = string.format("%.12g", v)
  return s
end

local function str(s)
  s = s:gsub('[%c"\\]', function(c)
    local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
    return map[c] or string.format("\\u%04x", c:byte())
  end)
  return '"' .. s .. '"'
end

local function encode(v, indent)
  indent = indent or ""
  local t = type(v)
  if v == nil then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number" then return num(v)
  elseif t == "string" then return str(v)
  elseif t ~= "table" then error("vectors: cannot encode " .. t) end
  local inner = indent .. "  "
  if is_list(v) then
    if #v == 0 then return "[]" end
    -- Short lists of scalars stay on one line.
    local flat, scalar = {}, true
    for i = 1, #v do
      if type(v[i]) == "table" then scalar = false break end
      flat[i] = encode(v[i])
    end
    if scalar then
      local line = "[" .. table.concat(flat, ", ") .. "]"
      if #line <= 100 then return line end
    end
    local parts = {}
    for i = 1, #v do parts[i] = inner .. encode(v[i], inner) end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local parts = {}
  for i, k in ipairs(keys) do
    local val = v[k]
    if val == nil then val = v[tonumber(k)] end
    parts[i] = inner .. str(k) .. ": " .. encode(val, inner)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local write = arg and arg[1] == "write" or (os.getenv("WRITE") ~= nil)
local bad = 0
local only = os.getenv("TOPIC")
for _, topic in ipairs(TOPICS) do
  local gen = "tests/vectors/" .. topic .. ".lua"
  local ok, spec = true, nil
  if read(gen) and (not only or only == topic) then ok, spec = pcall(dofile, gen) end
  if not ok then
    bad = bad + 1
    print(("ERROR   %s: %s"):format(gen, tostring(spec)))
  elseif spec then
    local body = encode({ about = spec.about, source = spec.source, cases = spec.cases }) .. "\n"
    local path = OUT_DIR .. topic .. ".json"
    if write then
      local f = assert(io.open(path, "wb"))
      f:write(body)
      f:close()
      print(("wrote %s (%d cases)"):format(path, #spec.cases))
    elseif read(path) ~= body then
      bad = bad + 1
      print(("DIFFERS %s — run with `write` if the change is intended"):format(path))
    else
      print(("ok      %s (%d cases)"):format(path, #spec.cases))
    end
  end
end
if bad > 0 then os.exit(1) end
