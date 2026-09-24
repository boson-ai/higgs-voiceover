--- Boson AI Higgs TTS client.
--
-- Lua has no HTTP, so every request shells out to the system `curl` (part of
-- macOS). Two things matter about how that is done:
--
--   * The API key is written into a curl config file and passed with -K, never
--     on the command line, so it does not appear in the process list.
--   * Requests are queued and run one at a time. Boson publishes no rate limits,
--     and sequential execution also gives the UI an honest "3 of 12" progress
--     count. Where the platform supports it, the request runs detached and is
--     polled, so the Resolve UI never blocks.
--
-- Callers never see curl. They enqueue a typed request and get a result table:
--   { ok = bool, code = string, path = string|nil, data = table|nil, error = string|nil }

local P = require("higgs.platform")
local Log = require("higgs.log")

local function clock()
  local ok, t = pcall(function() return _G.bmd.gettime() end)
  return (ok and tonumber(t)) or os.time()
end

--- Hosts and paths only: a query string could carry anything.
local function short_url(url)
  return (tostring(url or ""):gsub("%?.*$", ""))
end
local U = require("higgs.util")

local M = {}
M.__index = M

M.BASE_URL = "https://api.boson.ai/v1"
M.MODEL = "higgs-tts-3"

--- Hard limit from the API; the UI warns before a request would be rejected.
M.MAX_INPUT_CHARS = 5000

--- USD per 1,000 input characters. Generated audio is not billed separately.
M.PRICE_PER_1K_CHARS = 0.015

--- Preset voices. Descriptions are Boson's, trimmed to fit a menu.
M.PRESET_VOICES = {
  { id = "nora",    label = "Nora — calm narrative (f)" },
  { id = "eleanor", label = "Eleanor — professional, educational (f)" },
  { id = "chloe",   label = "Chloe — friendly, standard American (f)" },
  { id = "marcus",  label = "Marcus — confident, professorial (m)" },
  { id = "oliver",  label = "Oliver — thoughtful, reflective (m)" },
  { id = "jake",    label = "Jake — energetic (m)" },
  { id = "default", label = "Default" },
}

--- Reference-audio limits for voice cloning, from the API docs.
M.REF_MIN_SECONDS = 3
M.REF_MAX_SECONDS = 30
M.REF_MAX_BYTES = 10 * 1024 * 1024

function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, M)
  self.get_key = opts.get_key or function() return "" end
  self.tmp_dir = opts.tmp_dir or P.join(P.config_dir(), "tmp")
  self.queue = {}
  self.active = nil
  self.seq = 0
  return self
end

------------------------------------------------------------------ estimating

--- Cost in USD for a number of billable characters.
function M.cost_for(chars)
  return (tonumber(chars) or 0) / 1000 * M.PRICE_PER_1K_CHARS
end

function M.format_cost(usd)
  if usd < 0.01 then return string.format("$%.4f", usd) end
  return string.format("$%.2f", usd)
end

---------------------------------------------------------------- job plumbing

function M:_paths(id)
  local base = P.join(self.tmp_dir, "job_" .. id)
  return {
    cfg    = base .. ".cfg",
    body   = base .. ".body.json",
    out    = base .. ".out",
    status = base .. ".status",
    err    = base .. ".err",
    marker = base .. ".done",
  }
end

local function cleanup(paths, keep_out)
  for name, p in pairs(paths) do
    if not (keep_out and name == "out") then os.remove(p) end
  end
end

--- Turn a finished curl run into a result table.
--- Turn a failure into one short sentence: what happened, then what to do.
-- Boson's own wording is only used when it names something specific we
-- cannot infer (a bad parameter, say), trimmed to one line.
local function friendly_error(code, raw)
  local low = tostring(raw or ""):lower()
  local function mentions(...)
    for _, word in ipairs({ ... }) do if low:find(word, 1, true) then return true end end
    return false
  end

  if code == "" then
    if mentions("timed out", "timeout", "operation too slow") then
      return "Boson took too long to answer. Try again."
    end
    return "Couldn't reach Boson. Check your internet connection."
  elseif code == "401" then
    return "That API key was rejected. Check it in Settings."
  elseif code == "403" then
    if mentions("credit", "quota", "billing", "balance") then
      return "Your Boson account is out of credit. Top up at boson.ai."
    end
    return "This key can't use Higgs TTS. Check your plan at boson.ai."
  elseif code == "404" then
    if mentions("voice") then
      return "That voice is no longer on your account. Pick another voice."
    end
    return "Boson couldn't find what the request asked for."
  elseif code == "413" then
    return "That line is too long for one request. Break it into shorter lines."
  elseif code == "429" then
    if mentions("credit", "quota", "billing", "balance", "insufficient") then
      return "Your Boson account is out of credit. Top up at boson.ai."
    end
    return "Too many requests at once. Wait a few seconds and try again."
  elseif code == "400" or code == "422" then
    if mentions("voice") then
      return "Boson didn't accept that voice. Pick another voice."
    end
    local detail = tostring(raw or ""):gsub("%s+", " "):sub(1, 120)
    if detail ~= "" then return "Boson rejected the request: " .. detail end
    return "Boson rejected the request."
  elseif code:sub(1, 1) == "5" then
    return "Boson's service is having trouble. Try again in a moment."
  end
  local detail = tostring(raw or ""):gsub("%s+", " "):sub(1, 120)
  return (detail ~= "" and detail) or ("Boson returned an unexpected response (" .. code .. ").")
end

--- Split a timestamped speech response into its audio bytes and its word
-- list ({ word, start, end } in seconds, or nil when Boson could not align
-- the line). The base64 audio is cut out by position rather than handed to
-- the JSON decoder, which reads strings a character at a time — a minute of
-- wav is several megabytes of it.
function M.unpack_timed(raw)
  raw = tostring(raw or "")
  local _, open_at = raw:find('"audio"%s*:%s*"')
  if not open_at then return nil end
  local close_at = raw:find('"', open_at + 1, true)
  if not close_at then return nil end
  local b64 = raw:sub(open_at + 1, close_at - 1):gsub("\\/", "/")
  local rest = raw:sub(1, open_at) .. raw:sub(close_at)
  local data = U.json.decode(rest)
  local words = nil
  if type(data) == "table" and type(data.timestamps) == "table" and #data.timestamps > 0 then
    words = {}
    for _, w in ipairs(data.timestamps) do
      local s, e = tonumber(w.start), tonumber(w["end"])
      if s and e and w.word then words[#words + 1] = { word = tostring(w.word), start = s, ["end"] = e } end
    end
    if #words == 0 then words = nil end
  end
  return U.b64_decode(b64), words
end

local function interpret(job)
  local paths = job.paths
  local code = (U.read_file(paths.status) or ""):gsub("%s+", "")
  local err_text = (U.read_file(paths.err) or ""):gsub("%s+$", "")
  -- curl writes 000 when no HTTP answer came back at all (no network, DNS,
  -- refused, timed out): the same case as no status.
  if code == "000" then code = "" end

  if code == "" then
    cleanup(paths)
    return { ok = false, code = "", error = friendly_error("", err_text) }
  end

  if code == "200" or code == "201" then
    if job.expect == "json" then
      local raw = U.read_file(paths.out) or ""
      local data = U.json.decode(raw)
      cleanup(paths)
      if type(data) ~= "table" then
        return { ok = false, code = code, error = "Boson sent a response Higgs VoiceOver couldn't read." }
      end
      return { ok = true, code = code, data = data }
    end
    if job.expect == "speech_json" then
      -- Timestamps turn the response into JSON with the audio inside it.
      local raw = U.read_file(paths.out) or ""
      cleanup(paths)
      local audio, words = M.unpack_timed(raw)
      if not audio or #audio == 0 then
        return { ok = false, code = code, error = "Boson returned no audio for that line." }
      end
      if not U.write_file(job.out_path, audio) then
        return { ok = false, code = code, error = "Could not write " .. tostring(job.out_path) }
      end
      return { ok = true, code = code, path = job.out_path, words = words }
    end
    -- Binary payload: move it to where the caller asked for it.
    local audio = U.read_file(paths.out)
    cleanup(paths)
    if not audio or #audio == 0 then
      return { ok = false, code = code, error = "Boson returned no audio for that line." }
    end
    if not U.write_file(job.out_path, audio) then
      return { ok = false, code = code, error = "Could not write " .. tostring(job.out_path) }
    end
    return { ok = true, code = code, path = job.out_path }
  end

  -- Error response: the body is JSON in every documented failure case.
  local body = U.read_file(paths.out) or ""
  cleanup(paths)
  local parsed = U.json.decode(body)
  local msg
  if type(parsed) == "table" then
    if type(parsed.error) == "table" then msg = parsed.error.message
    elseif type(parsed.error) == "string" then msg = parsed.error
    else msg = parsed.message end
  end
  if not msg or msg == "" then msg = U.trim(body:sub(1, 300)) end

  return { ok = false, code = code, error = friendly_error(code, msg) }
end

--- Queue a request. `on_done(result)` is always called exactly once.
function M:request(spec)
  self.seq = self.seq + 1
  local job = {
    id = self.seq,
    method = spec.method or "GET",
    url = spec.url or (M.BASE_URL .. spec.path),
    no_auth = spec.no_auth or false,
    body = spec.body,
    out_path = spec.out_path,
    expect = spec.expect or "json",
    on_done = spec.on_done or function() end,
    label = spec.label or spec.path or spec.url,
    meta = spec.meta,               -- extra fields for the log line / metric
    queued_at = clock(),
  }
  self.queue[#self.queue + 1] = job
  self:_pump()
  return job
end

--- Fetch something that is not the Boson API: JSON, or a file when
-- `out_path` is given. No key is sent.
function M:fetch(spec)
  return self:request({
    method = "GET", url = spec.url, no_auth = true,
    expect = spec.out_path and "file" or "json", out_path = spec.out_path,
    label = spec.label or spec.url, on_done = spec.on_done,
  })
end

function M:_start(job)
  local key = tostring(self.get_key() or "")
  if key == "" and not job.no_auth then
    job.on_done({ ok = false, code = "nokey", error = "Add your Boson API key in Settings first." })
    return false
  end

  if not P.exists(self.tmp_dir) then P.mkdirs(self.tmp_dir) end
  local paths = self:_paths(job.id)
  job.paths = paths
  os.remove(paths.status)
  os.remove(paths.marker)

  -- Quotes and backslashes would break the config-file syntax; a real key
  -- contains neither, so stripping them is safe and avoids an injection path.
  local safe_key = key:gsub('[\\"]', "")
  local cfg_lines = { ('user-agent = "HiggsVoiceOver/%s"'):format(tostring(_G.HIGGS_VO_VERSION or "dev")) }
  -- Public requests (the update check) never carry the Boson key.
  if not job.no_auth then cfg_lines[#cfg_lines + 1] = 'header = "Authorization: Bearer ' .. safe_key .. '"' end
  if job.body then
    cfg_lines[#cfg_lines + 1] = 'header = "Content-Type: application/json"'
    U.write_file(paths.body, U.json.encode(job.body))
  end
  U.write_file(paths.cfg, table.concat(cfg_lines, "\n") .. "\n")

  local cmd = "curl -s -S --max-time 300 -K " .. P.quote(paths.cfg)
           .. " -X " .. job.method .. " " .. P.quote(job.url)
           .. " -o " .. P.quote(paths.out)
           .. ' -w "%{http_code}"'
  -- GitHub serves release files through a redirect (302 to its download
  -- host), and a moved or renamed repository answers with one too. Public
  -- requests follow them; a Boson request never does, so the key cannot be
  -- carried to another server.
  if job.no_auth then cmd = cmd .. " -L --max-redirs 5" end
  if job.body then cmd = cmd .. " --data-binary @" .. P.quote(paths.body) end
  cmd = cmd .. " > " .. P.quote(paths.status) .. " 2> " .. P.quote(paths.err)

  job.started_at = clock()
  Log.info(("→ %s %s"):format(job.method, short_url(job.url)), { id = job.id, label = job.label })
  if P.supports_async() then
    P.run_detached(cmd .. "; echo done > " .. P.quote(paths.marker))
    self.active = job
  else
    os.execute(cmd)
    self.active = nil
    job.on_done(self:_finish(job))
    self:_pump()
  end
  return true
end

function M:_finish(job)
  local res = interpret(job)
  local t = {
    id = job.id, label = job.label,
    ms = math.floor((clock() - (job.started_at or clock())) * 1000),
    queue_ms = math.floor(((job.started_at or clock()) - (job.queued_at or clock())) * 1000),
  }
  if res.path then t.bytes = U.file_size and U.file_size(res.path) or nil end
  if job.expect == "speech_json" and res.ok then t.words = res.words and #res.words or 0 end
  for k, v in pairs(job.meta or {}) do t[k] = v end
  if not res.ok then t.error = tostring(res.error) end
  Log.write(res.ok and "info" or "warn",
    ("← %s %s %s  %s"):format(res.code ~= "" and res.code or "---", short_url(job.url), res.ok and "ok" or "failed", Log.fields(t)))
  -- One metric per request kind; the label names it (speech, create voice…).
  local m = { ok = res.ok and 1 or 0, failed = res.ok and 0 or 1, ms = t.ms, code = res.code ~= "" and res.code or "none" }
  for k, v in pairs(job.meta or {}) do m[k] = v end
  Log.metric("api." .. tostring(job.label):gsub("%s+", "_"), m)
  return res
end

function M:_pump()
  if self.active then return end
  local next_job = self.queue[1]
  -- A job backing off after "too many requests" holds the queue, so lines
  -- still come back in order.
  if next_job and next_job.not_before and clock() < next_job.not_before then return end
  local job = table.remove(self.queue, 1)
  if job then self:_start(job) end
end

--- Waits before retrying a request Boson answered "too many requests" (429,
-- not out of credit): three tries more, then the error goes to the caller.
M.RETRY_DELAYS = { 2, 5, 10 }

local function should_retry(job, res)
  if res.ok or res.code ~= "429" then return false end
  if tostring(res.error):find("credit", 1, true) then return false end
  return (job.retries or 0) < #M.RETRY_DELAYS
end

--- Advance in-flight work. Call from the UI timer; cheap when idle.
-- Returns true while work remains, so the caller can keep a progress indicator up.
function M:poll()
  local job = self.active
  if job then
    if P.exists(job.paths.marker) then
      os.remove(job.paths.marker)
      self.active = nil
      local res = self:_finish(job)
      if should_retry(job, res) then
        job.retries = (job.retries or 0) + 1
        job.not_before = clock() + M.RETRY_DELAYS[job.retries]
        Log.info("rate limited; retrying", { id = job.id, label = job.label, attempt = job.retries,
                                              wait_s = M.RETRY_DELAYS[job.retries] })
        table.insert(self.queue, 1, job)
      else
        job.on_done(res)
      end
      self:_pump()
    end
  else
    self:_pump()
  end
  return (self.active ~= nil) or (#self.queue > 0)
end

function M:pending()
  return #self.queue + (self.active and 1 or 0)
end

--- Drop queued work. A request already in flight is left to finish, because
-- curl owns it — its result is discarded.
function M:cancel_pending()
  local n = #self.queue
  self.queue = {}
  if self.active then self.active.on_done = function() end end
  return n
end

------------------------------------------------------------------- endpoints

--- A built-in voice, whose id is safe to log; cloned ids are the user's.
function M.is_preset(id)
  for _, v in ipairs(M.PRESET_VOICES) do if v.id == id then return true end end
  return false
end

--- Generate speech. `text` must already have its direction tags composed in.
function M:speech(spec)
  local text = tostring(spec.text or "")
  if U.trim(text) == "" then
    spec.on_done({ ok = false, code = "", error = "Nothing to generate — this segment is empty." })
    return nil
  end
  local chars = U.utf8_len(text)
  if chars > M.MAX_INPUT_CHARS then
    spec.on_done({ ok = false, code = "",
      error = string.format("This segment is %d characters; the limit is %d. Break it into shorter lines.",
                            chars, M.MAX_INPUT_CHARS) })
    return nil
  end
  local body = {
    model = M.MODEL,
    input = text,
    voice = spec.voice or "default",
    response_format = spec.format or "wav",
  }
  -- Word timings for subtitles. Boson then answers in JSON, and skips its
  -- text normalisation for the request (numbers and dates are read as
  -- written), so they are asked for only when subtitles are wanted.
  if spec.timestamps then body.timestamps = true end
  return self:request({
    method = "POST",
    path = "/audio/speech",
    expect = spec.timestamps and "speech_json" or "binary",
    out_path = spec.out_path,
    label = spec.label or "speech",
    meta = { chars = chars, voice = M.is_preset(spec.voice) and tostring(spec.voice) or "cloned",
             format = spec.format or "wav", timestamps = spec.timestamps and 1 or 0 },
    body = body,
    on_done = spec.on_done,
  })
end

function M:list_voices(spec)
  return self:request({
    method = "GET", path = "/audio/voices", expect = "json",
    label = "list voices", on_done = spec.on_done,
  })
end

--- Register a cloned voice from a reference recording.
-- Voice ids are deterministic per (key, audio), so re-submitting the same clip
-- returns the same id rather than creating a duplicate.
function M:create_voice(spec)
  local audio = U.read_file(spec.ref_audio_path)
  if not audio then
    spec.on_done({ ok = false, code = "", error = "Could not read the reference recording." })
    return nil
  end
  if #audio > M.REF_MAX_BYTES then
    spec.on_done({ ok = false, code = "",
      error = string.format("The reference is %.1f MB; the limit is %d MB.",
                            #audio / 1048576, M.REF_MAX_BYTES / 1048576) })
    return nil
  end
  return self:request({
    method = "POST", path = "/audio/voices", expect = "json",
    label = "create voice",
    body = {
      -- Boson's voice object has no `name`: the label is `description`, and
      -- it is what the list endpoint gives back. (Sending `name` was silently
      -- ignored, so voices came back from Refresh as bare ids.)
      description = spec.name or "Voice",
      ref_audio = U.b64_encode(audio),
      -- Boson's create-voice takes a transcript but only enforces one
      -- character, so leaving it out is a supported way to clone. A single
      -- stop is the honest stand-in for "no words given" — inventing text
      -- that does not match the audio is worse than giving none, because the
      -- model is conditioned on the pair.
      ref_text = (U.trim(spec.ref_text or "") ~= "") and spec.ref_text or ".",
    },
    on_done = spec.on_done,
  })
end

--- The name to show for a voice from the list endpoint: its description if
-- it has one; otherwise the name already given to it on this machine;
-- otherwise when it was made — never the raw `voice_<sha256>` id.
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
function M.voice_label(v, existing)
  local d = U.trim(tostring(v.description or v.name or ""))
  if d ~= "" then return d end
  if existing and existing ~= "" and not tostring(existing):match("^voice_") then return existing end
  local y, mo, day = tostring(v.created_at or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if y then return ("Cloned voice · %s %d, %s"):format(MONTHS[tonumber(mo)] or mo, tonumber(day), y) end
  return "Cloned voice"
end

--- Cheapest call that proves the key works.
function M:test(spec)
  return self:request({
    method = "GET", path = "/audio/voices", expect = "json",
    label = "test connection",
    on_done = function(res)
      if res.ok then
        local n = 0
        if type(res.data) == "table" then
          local list = res.data.data or res.data.voices or res.data
          if type(list) == "table" then n = #list end
        end
        spec.on_done({ ok = true, voices = n })
      else
        spec.on_done({ ok = false, error = res.error, code = res.code })
      end
    end,
  })
end

return M
