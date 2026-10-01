--- Vectors for the pure parts of config.lua: defaults, migrations from each
-- older schema, loading a stored file, the stored key, the voice library.
--
-- The two folders a migration compares against are fixed here (`dirs`), so
-- nothing depends on this machine; config.lua's own are stubbed for the run.
-- Keys are fake. Byte strings travel as base64.

local C = require("higgs.config")
local U = require("higgs.util")

local cases = {}
local function case(name, fn, input, expect)
  cases[#cases + 1] = { name = name, fn = fn, input = input, expect = expect }
end

local DIRS = { takesDir = "/Users/test/Library/Application Support/Higgs VO/takes",
               defaultOutputDir = "/Users/test/Movies/Higgs VoiceOver" }

local function upvalue(fn, name)
  for i = 1, 60 do
    local n, v = debug.getupvalue(fn, i)
    if n == nil then break end
    if n == name then return v end
  end
  error("no upvalue " .. name)
end
local apply_defaults = upvalue(C.load, "apply_defaults")

local function copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = copy(v) end
  return out
end

local saved = { takes_dir = C.takes_dir, default_output_dir = C.default_output_dir, ensure_dirs = C.ensure_dirs,
                path = C.path, read_file = U.read_file, write_file = U.write_file, time = os.time }
C.takes_dir = function() return DIRS.takesDir end
C.default_output_dir = function() return DIRS.defaultOutputDir end

------------------------------------------------------------------ constants

case("SCHEMA", "SCHEMA", { none = true }, C.SCHEMA)
case("APP_NAME", "APP_NAME", { none = true }, C.APP_NAME)
case("DEFAULTS", "DEFAULTS", { none = true }, C.DEFAULTS)

------------------------------------------------------------------ migrate

local function migrate(name, cfg)
  case("migrate: " .. name, "migrate", { cfg = copy(cfg), dirs = DIRS }, C.migrate(copy(cfg)))
end

migrate("no schema is 0 and is stamped", { pause_ms = 900 })
for s = 0, 5 do
  migrate(("schema %d on every old default"):format(s),
          { schema = s, pause_ms = 240, output_dir = DIRS.takesDir, auto_place = false })
  migrate(("schema %d with the user's own choices"):format(s),
          { schema = s, pause_ms = 900, output_dir = "/Volumes/Work/VO", auto_place = true })
  migrate(("schema %d with an empty folder"):format(s), { schema = s, output_dir = "" })
end
migrate("the old 400 ms default stays 400", { schema = 1, pause_ms = 400 })
migrate("the 240 ms default of schema 2–3 follows back to 400", { schema = 3, pause_ms = 240 })
migrate("a newer schema is left untouched", { schema = 99, output_dir = DIRS.takesDir, pause_ms = 240, auto_place = false })
migrate("unknown keys are kept", { schema = 2, future_thing = "x", voices = { { id = "voice_1", name = "Me", created = 1700000000 } } })

------------------------------------------------------------------ apply_defaults

local function defaults(name, cfg)
  case("apply_defaults: " .. name, "apply_defaults", { cfg = copy(cfg), dirs = DIRS }, apply_defaults(copy(cfg)))
end
defaults("an empty config is all defaults", {})
defaults("set values are kept", { pause_ms = 900, output_format = "mp3", auto_place = false, output_dir = "/x" })
defaults("an empty folder becomes the default one", { output_dir = "" })
defaults("a clip name record is kept", { clip_name = { words = false, date = true } })
defaults("voices are kept", { voices = { { id = "voice_2", name = "Narrator", created = 1 } } })

------------------------------------------------------------------ load

C.ensure_dirs = function() end
C.path = function() return "/nowhere/config.json" end
local raw_text, bad_copy
U.read_file = function() return raw_text end
U.write_file = function(p, s) bad_copy = s return true end

local function load(name, raw)
  raw_text, bad_copy = raw, nil
  local cfg, warning = C.load()
  case("load: " .. name, "load", { raw = raw, dirs = DIRS }, { cfg = cfg, warned = warning ~= nil, kept_bad = bad_copy ~= nil })
end
load("no file is the defaults", nil)
load("an empty file is the defaults", "")
load("a broken file is kept aside", "{bad")
load("a file of null", "null")
load("a file of a number", "42")
load("an old file is migrated", '{"schema":2,"pause_ms":240,"output_dir":"' .. DIRS.takesDir .. '",'
     .. '"voices":[{"id":"voice_1","name":"A","created":1}],"auto_place":false}')
load("a current file is kept", '{"schema":5,"auto_place":false,"clip_name":{"words":false,"date":true},'
     .. '"default_voice":"voice_9","output_dir":"/Volumes/Work"}')
load("a null value takes its default", '{"schema":5,"pause_ms":null,"output_dir":"/x"}')
load("a newer file is left as it is", '{"schema":7,"pause_ms":240,"output_dir":"","new_key":true}')

U.read_file, U.write_file = saved.read_file, saved.write_file
C.ensure_dirs, C.path = saved.ensure_dirs, saved.path

------------------------------------------------------------------ the key

for _, s in ipairs({ "YmFpLXRlc3QtMDAwMA==", "YmFp", "YWI=", "YQ==", "YmFpLXRl\nc3Q=", "@@@@", "",
                     "=AAA", "Y=AA", "YQ==YmFp", "YWJj", "YW" }) do
  local d = C.b64_decode(s)
  case("b64_decode " .. s:gsub("\n", "\\n"), "b64_decode", { s = s }, d and U.b64_encode(d) or nil)
end

for _, k in ipairs({ "bai-test-0000-fake", "", "bai-ключ-fake", 'bai-quote"and\\slash' }) do
  local cfg = {}
  C.set_api_key(cfg, k)
  case("set_api_key " .. k, "set_api_key", { key = k }, cfg.api_key_b64)
  case("get_api_key " .. k, "get_api_key", { cfg = { api_key_b64 = cfg.api_key_b64 } }, C.get_api_key(cfg))
end
case("get_api_key with nothing stored", "get_api_key", { cfg = { schema = 5 } }, C.get_api_key({ schema = 5 }))
case("get_api_key from unreadable text", "get_api_key", { cfg = { api_key_b64 = "=AAA" } }, C.get_api_key({ api_key_b64 = "=AAA" }))

------------------------------------------------------------------ voices

os.time = function() return 1700000000 end
local function lib() return { voices = { { id = "voice_a", name = "Alex", created = 1 }, { id = "voice_b", name = "Bo", created = 2 } } } end
do
  local cfg = lib()
  local e = C.add_voice(cfg, "voice_c", "Cleo")
  case("add_voice adds a new one", "add_voice", { cfg = lib(), id = "voice_c", name = "Cleo", now = 1700000000 }, { entry = e, cfg = cfg })
  cfg = lib()
  e = C.add_voice(cfg, "voice_a", "Alex 2")
  case("add_voice renames one already there", "add_voice", { cfg = lib(), id = "voice_a", name = "Alex 2", now = 1700000000 }, { entry = e, cfg = cfg })
  cfg = { voices = {} }
  e = C.add_voice(cfg, "voice_x", "X")
  case("add_voice to an empty library", "add_voice", { cfg = { voices = {} }, id = "voice_x", name = "X", now = 1700000000 }, { entry = e, cfg = cfg })
  for _, id in ipairs({ "voice_b", "voice_z" }) do
    cfg = lib()
    local ok = C.remove_voice(cfg, id)
    case("remove_voice " .. id, "remove_voice", { cfg = lib(), id = id }, { removed = ok, cfg = cfg })
    case("find_voice " .. id, "find_voice", { cfg = lib(), id = id }, C.find_voice(lib(), id))
  end
end
os.time = saved.time

C.takes_dir, C.default_output_dir = saved.takes_dir, saved.default_output_dir

return {
  about = "Settings: defaults, schema migrations, loading, the stored key and the voice library.",
  source = "src/higgs/config.lua",
  cases = cases,
}
