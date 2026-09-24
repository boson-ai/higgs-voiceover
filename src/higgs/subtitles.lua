--- Subtitles from a take: split the line into subtitles and time them to the
-- words Boson says it spoke.
--
-- Pure Lua, no Resolve and no OS: the whole path from a line of text and a
-- list of word timings to an .srt file is here, so it can be tested with
-- Resolve closed.
--
-- The rules follow common subtitling practice (Netflix's Timed Text Style
-- Guide, which Resolve's own auto-captions also use as their preset):
--
--   * one line of at most 42 characters in Latin, Cyrillic, Arabic and other
--     alphabets, 16 in Chinese and Korean, 13 in Japanese, 35 in Thai —
--     measured per character, so a line mixing scripts gets a fair share;
--   * never two sentences in one subtitle, whatever the script's full stop
--     (. 。 ！ ？ । ۔ ؟ …);
--   * break after punctuation, before a conjunction or preposition, and never
--     between an article and its noun, a preposition and its object, a
--     subject pronoun and its verb, an auxiliary and its verb;
--   * a subtitle stays up at least 20 frames at 24 fps (0.83 s);
--   * consecutive subtitles are at least 2 frames apart, and a gap too short
--     to read as a pause (under half a second) is closed to those 2 frames so
--     the text does not flicker;
--   * the last subtitle before a silence stays up about half a second after
--     the voice stops.
--
-- Two ways to split, chosen in Settings:
--   "short"    — short phrases that fit one line, broken at the most natural
--                points (the default);
--   "sentence" — one subtitle per sentence, on up to two lines; a sentence
--                longer than two lines continues in the next subtitle.

local U = require("higgs.util")

local M = {}

M.MODES = { "short", "sentence" }
M.LIMIT = 42          -- width of a line, in Latin characters
M.LIMIT_CJK = 16      -- Chinese and Korean characters per line
M.LIMIT_JA = 13       -- Japanese (kana) characters per line
M.LIMIT_TH = 35       -- Thai characters per line
M.MIN_SECONDS = 20 / 24
M.MAX_SECONDS = 7
M.GAP_FRAMES = 2
M.CLOSE_SECONDS = 0.5 -- gaps shorter than this (after the lag) close to GAP_FRAMES
M.LAG_SECONDS = 0.5   -- how long a subtitle stays after the voice stops

------------------------------------------------------------------ tokens

--- Words a subtitle should not end on: they belong with what follows.
local BIND_NEXT = {}
for w in ([[a an the this that these those my your his her its our their
  some any no every each either neither another such
  to of in on at for with from by about into onto over under after before
  between through during without within upon than as
  and but or nor so yet because although though if when while whereas unless
  until since whether
  i he she we they
  am is are was were be been being
  will would shall should can could may might must do does did have has had
  not don't doesn't didn't won't can't couldn't wouldn't shouldn't isn't aren't
  wasn't weren't haven't hasn't hadn't
  i'm you're we're they're he's she's it's i've you've we've they've i'll
  you'll we'll they'll i'd you'd we'd they'd
  mr mrs ms dr very more most just
  el la los las un una unos unas mi tu su nuestro nuestra sus mis tus
  de del al en con para por sin sobre entre hacia desde hasta
  y e o u pero que porque cuando como si aunque
  no se me te le lo nos les es son era fue
  puede podría debe quiere va voy vamos ha han he hemos había está están estaba]]):gmatch("%S+") do BIND_NEXT[w] = true end

--- Words a subtitle may begin with comfortably: a break just before a
-- conjunction is the most natural after punctuation; before a preposition
-- or a determiner, a little less so ("nobody | on the team" splits a noun
-- phrase).
local BREAK_BEFORE = {}
for w in ([[and but or nor so yet because although though if when while whereas
  unless until since whether which who whom whose where that
  y o pero porque cuando aunque mientras donde que quien]]):gmatch("%S+") do BREAK_BEFORE[w] = 3 end
for w in ([[to of in on at for with from by about into over after before between
  through during without than
  de en con para por sin sobre desde hasta]]):gmatch("%S+") do BREAK_BEFORE[w] = 6 end
-- A noun phrase starts with its determiner: "believed | a small studio" is a
-- better cut than anywhere inside the phrase.
for w in ([[a an the this these those my your his her its our their some every each
  el la los las un una unos unas]]):gmatch("%S+") do BREAK_BEFORE[w] = BREAK_BEFORE[w] or 7 end

--- Abbreviations whose full stop does not end a sentence.
local ABBREV = {}
for w in ("mr mrs ms dr jr sr prof vs eg ie sra srta"):gmatch("%S+") do ABBREV[w] = true end

local OPENING = {   -- marks that belong to the word after them
  [0x22] = true, [0x28] = true, [0x5B] = true, [0x7B] = true, [0xBF] = true, [0xA1] = true,
  [0xAB] = true, [0x201E] = true, [0x201A] = true,
  [0x201C] = true, [0x2018] = true, [0x300C] = true, [0x300E] = true, [0x300A] = true,
  [0x3008] = true, [0xFF08] = true, [0x3010] = true,
}
local SENTENCE_END = {
  [0x2E] = true, [0x21] = true, [0x3F] = true,
  [0x3002] = true, [0xFF01] = true, [0xFF1F] = true, [0xFF0E] = true, [0xFF61] = true,   -- CJK
  [0x061F] = true, [0x06D4] = true,                   -- Arabic, Urdu
  [0x0964] = true, [0x0965] = true,                   -- Devanagari danda
  [0x0589] = true, [0x1362] = true,                   -- Armenian, Ethiopic
  [0x203C] = true, [0x2047] = true, [0x2048] = true, [0x2049] = true,
}
local CLAUSE_END = {
  [0x2C] = true, [0x3B] = true, [0x3A] = true, [0x2014] = true, [0x2013] = true, [0x2026] = true,
  [0x3001] = true, [0xFF0C] = true, [0xFF1B] = true, [0xFF1A] = true, [0x2D] = true,
  [0xFF64] = true, [0x060C] = true, [0x061B] = true,
}
local CLOSING = {   -- quotes and brackets that may follow a sentence's full stop
  [0x22] = true, [0x27] = true, [0x29] = true, [0x5D] = true, [0x7D] = true,
  [0x201D] = true, [0x2019] = true, [0x300D] = true, [0x300F] = true, [0x300B] = true,
  [0x3009] = true, [0xFF09] = true, [0x3011] = true, [0xBB] = true,
}

--- Punctuation in any script. util's list covers ASCII and the CJK and
-- general punctuation blocks; these are the rest a subtitle meets.
local function is_mark(cp)
  return U.is_punct(cp) or SENTENCE_END[cp] or CLAUSE_END[cp] or OPENING[cp] or CLOSING[cp]
      or cp == 0xB7 or false
end

--- How much of a line one character takes, in Latin characters. A line is
-- 42 of them; each script's own per-line limit fits the same 42.
local function char_width(cp)
  if (cp >= 0x3040 and cp <= 0x30FF) or (cp >= 0xFF66 and cp <= 0xFF9D) then
    return M.LIMIT / M.LIMIT_JA                                   -- kana
  elseif (cp >= 0x3400 and cp <= 0x4DBF) or (cp >= 0x4E00 and cp <= 0x9FFF)
      or (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0x3000 and cp <= 0x303F)
      or (cp >= 0xFF00 and cp <= 0xFF65)
      or (cp >= 0xAC00 and cp <= 0xD7AF) or (cp >= 0x1100 and cp <= 0x11FF)
      or (cp >= 0x3130 and cp <= 0x318F) then
    return M.LIMIT / M.LIMIT_CJK                                  -- Han, Hangul, full-width
  elseif cp >= 0x0E00 and cp <= 0x0E7F then
    return M.LIMIT / M.LIMIT_TH                                   -- Thai
  end
  return 1
end

local function text_width(text)
  local w = 0
  for i in U.utf8_chars(text) do w = w + char_width(U.utf8_codepoint(text, i)) end
  return w
end
M.text_width = text_width

--- What a subtitle shows for a line: the tags removed, spaces collapsed.
function M.display_text(line)
  local s = U.strip_tags(tostring(line or ""))
  s = s:gsub("%s+", " ")
  return U.trim(s)
end

--- Lower-case letters and digits only: how a typed word and a word from
-- Boson's list are compared ("We're," and "we're" and "were" all match).
local function key_of(text)
  local out = {}
  for i, ch in U.utf8_chars(text) do
    local cp = U.utf8_codepoint(text, i)
    if cp == 39 or cp == 0x2019 then
      -- an apostrophe, straight or curly, is dropped rather than kept
    elseif not is_mark(cp) and not (cp < 128 and ch:match("%s")) then
      out[#out + 1] = ch:lower()
    end
  end
  return table.concat(out)
end
M.key_of = key_of

--- Split display text into tokens: words in spaced scripts, single
-- characters in Chinese and Japanese. Punctuation rides on the token next
-- to it; `space` records whether a space came before the token.
function M.tokenize(text)
  local tokens = {}
  local cur, space_pending, prefix = nil, false, ""

  local function flush()
    if cur then
      cur.key = key_of(cur.text)
      tokens[#tokens + 1] = cur
      cur = nil
    end
  end
  local function start(ch, cjk)
    cur = { text = prefix .. ch, space = space_pending and #tokens > 0, cjk = cjk }
    prefix, space_pending = "", false
  end

  for i, ch in U.utf8_chars(text) do
    local cp = U.utf8_codepoint(text, i)
    if ch:match("^%s$") then
      flush()
      space_pending = true
    elseif U.is_ideographic(cp) then
      flush()
      start(ch, true)
    elseif is_mark(cp) and cp ~= 39 then
      -- An opening mark belongs to the word after it: at the start of a
      -- word, or after a Chinese/Japanese character ("说「好」").
      local opens = OPENING[cp] and (cur == nil or (cur.cjk and cp ~= 0x22))
      if opens then
        flush()
        prefix = prefix .. ch
      elseif cur then
        cur.text = cur.text .. ch
      elseif #tokens > 0 and prefix == "" then
        -- A mark standing alone (" — ") rides on the word before it.
        local last = tokens[#tokens]
        last.text = last.text .. (space_pending and " " or "") .. ch
        space_pending = false
      else
        prefix = prefix .. ch
      end
    else
      if cur and cur.cjk then flush() end
      if cur then cur.text = cur.text .. ch else start(ch, false) end
    end
  end
  flush()
  if prefix ~= "" then
    if #tokens > 0 then tokens[#tokens].text = tokens[#tokens].text .. prefix
    else tokens[1] = { text = prefix, key = "", space = false, cjk = false } end
  end
  for _, t in ipairs(tokens) do t.width = text_width(t.text) end
  return tokens
end

--- The last codepoint of a token that is not a closing quote or bracket.
local function final_mark(text)
  local cps = {}
  for i in U.utf8_chars(text) do cps[#cps + 1] = U.utf8_codepoint(text, i) end
  local k = #cps
  while k > 1 and CLOSING[cps[k]] do k = k - 1 end
  return cps[k], cps[k - 1]
end

--- How a token ends: "sentence", "clause" or nil.
local function ending(t)
  local last, before = final_mark(t.text)
  if not last then return nil end
  if SENTENCE_END[last] then
    if last == 0x2E and before == 0x2E then return "clause" end   -- "..." trails off
    if last == 0x2E and ABBREV[t.key] then return nil end
    return "sentence"
  end
  if CLAUSE_END[last] then return "clause" end
  return nil
end
M.ending = function(text) return ending({ text = text, key = key_of(text) }) end

------------------------------------------------------------------ timing

--- Give every token a start and end in seconds.
--
-- `words` is Boson's list ({ word, start, end }, in order) or nil. Words are
-- matched to tokens by their letters, so punctuation, capitals and tags in
-- the typed text do not matter. A word Boson reports that is not in the text
-- (or one it spells differently) is skipped; a token no word landed on is
-- placed between its neighbours. With no list, or when too little of it
-- matches, timing is spread over the speech in proportion to length, with
-- extra room at punctuation — close enough for a subtitle to follow.
--
-- Returns "words" or "estimate", for the log.
function M.align(tokens, words, speech_seconds)
  local n = #tokens
  if n == 0 then return "estimate" end
  speech_seconds = math.max(tonumber(speech_seconds) or 0, 0.1)

  -- The text as one run of letters, and which token owns each byte.
  local stream, owner, starts = {}, {}, {}
  local len = 0
  for ti, t in ipairs(tokens) do
    starts[len + 1] = true
    for b = 1, #t.key do owner[len + b] = ti end
    stream[#stream + 1] = t.key
    len = len + #t.key
  end
  stream = table.concat(stream)

  local matched = 0
  if type(words) == "table" and #words > 0 then
    local pos = 1
    for wi, w in ipairs(words) do
      local k = key_of(tostring(w.word or ""))
      local ws, we = tonumber(w.start), tonumber(w["end"])
      if k ~= "" and ws and we then
        local at
        if stream:sub(pos, pos + #k - 1) == k then
          at = pos
        else
          -- Look a little ahead for a word that starts a token; further than
          -- that and the two lists have parted ways at this word.
          local from = pos
          while true do
            local f = stream:find(k, from, true)
            if not f or f > pos + 48 then break end
            if starts[f] then at = f break end
            from = f + 1
          end
        end
        if at then
          for b = at, at + #k - 1 do
            local t = tokens[owner[b]]
            t.s = t.s and math.min(t.s, ws) or ws
            t.e = t.e and math.max(t.e, we) or we
            t.word = t.word or wi
          end
          matched = matched + 1
          pos = at + #k
        end
      end
    end
  end

  local anchored = 0
  for _, t in ipairs(tokens) do if t.s then anchored = anchored + 1 end end
  local keyed = 0
  for _, t in ipairs(tokens) do if t.key ~= "" then keyed = keyed + 1 end end

  -- Weight for spreading time: the letters, plus a breath at punctuation.
  local function weight(t)
    local e = ending(t)
    return math.max(#t.key, 1) + (e == "sentence" and 6 or e == "clause" and 3 or 1)
  end
  local function spread(from, to, a, b)
    local total = 0
    for i = from, to do total = total + weight(tokens[i]) end
    local t0 = a
    for i = from, to do
      local share = (b - a) * weight(tokens[i]) / total
      tokens[i].s, tokens[i].e = t0, t0 + share
      t0 = t0 + share
    end
  end

  if anchored == 0 or anchored < keyed * 0.5 then
    for _, t in ipairs(tokens) do t.s, t.e, t.word = nil, nil, nil end
    spread(1, n, math.min(0.05, speech_seconds / 10), speech_seconds)
    return "estimate"
  end

  -- Fill the tokens no word landed on from the anchors around them.
  local i = 1
  while i <= n do
    if tokens[i].s then
      i = i + 1
    else
      local j = i
      while j + 1 <= n and not tokens[j + 1].s do j = j + 1 end
      local prev, next = tokens[i - 1], tokens[j + 1]
      local est = 0
      for k = i, j do est = est + weight(tokens[k]) * 0.06 end
      local a = prev and prev.e or math.max(0, (next and next.s or 0) - est)
      local b = next and next.s or math.min(speech_seconds, a + est)
      if b <= a then b = a + 0.01 * (j - i + 1) end
      spread(i, j, a, b)
      i = j + 1
    end
  end
  return "words"
end

------------------------------------------------------------------ splitting

--- Cost of ending a subtitle (or a line) after token i. Low is natural.
local function break_cost(tokens, i)
  local t, nx = tokens[i], tokens[i + 1]
  if not nx then return 0 end
  local e = ending(t)
  if e == "sentence" then return 0 end
  local cost
  if e == "clause" then cost = 1
  elseif t.cjk and nx.cjk and t.word and t.word == nx.word then cost = 60   -- inside one word
  elseif BIND_NEXT[t.key] then cost = 40
  else cost = BREAK_BEFORE[nx.key] or 12 end
  -- A pause in the voice is a natural place to break, whatever the words.
  if t.e and nx.s and nx.s - t.e >= 0.25 then cost = math.min(cost, 2) end
  return cost
end

--- Width of tokens i..j as shown, spaces included.
local function width(tokens, i, j)
  local w = 0
  for k = i, j do
    w = w + tokens[k].width + ((k > i and tokens[k].space) and 1 or 0)
  end
  return w
end

local function join(tokens, i, j)
  local parts = {}
  for k = i, j do
    parts[#parts + 1] = ((k > i and tokens[k].space) and " " or "") .. tokens[k].text
  end
  return table.concat(parts)
end

--- Choose the breaks in tokens[from..to] so every piece fits `limit`,
-- minimising the cost of the breaks plus how ragged and fragmentary the
-- pieces are. `piece_cost(i, j, w)` adds a cost per piece.
local function best_breaks(tokens, from, to, limit, piece_cost)
  local best, back = { [from - 1] = 0 }, {}
  for j = from, to do
    best[j] = math.huge
    for i = j, from, -1 do
      local w = width(tokens, i, j)
      if w > limit and i < j then break end
      local c = best[i - 1] + piece_cost(i, j, w) + (i > from and break_cost(tokens, i - 1) or 0)
      if c < best[j] then best[j], back[j] = c, i end
    end
  end
  local pieces, j = {}, to
  while j >= from do
    local i = back[j]
    table.insert(pieces, 1, { i, j })
    j = i - 1
  end
  return pieces
end

--- Split aligned tokens into subtitles:
-- { { text = "…", lines = { "…" }, first = i, last = j, start = s, finish = e } }.
function M.split(tokens, mode)
  local n = #tokens
  if n == 0 then return {} end
  -- Widths are in Latin characters, so one limit serves every script (a
  -- Chinese character is 42/16 of one); the small margin absorbs rounding.
  local limit = M.LIMIT + 1e-6
  local cues = {}

  local function add(i, j, lines)
    cues[#cues + 1] = {
      first = i, last = j, lines = lines, text = table.concat(lines, "\n"),
      start = tokens[i].s or 0, finish = tokens[j].e or tokens[i].s or 0,
    }
  end

  -- A phrase of one line, broken at the most natural points.
  local function phrase_cost(i, j, w)
    local c = 2 + ((limit - math.min(w, limit)) / limit) ^ 2 * 6
    -- A scrap of a sentence on its own is hard to read.
    if w < limit * 0.35 and j < n and ending(tokens[j]) ~= "sentence" then c = c + 6 end
    for k = i, j - 1 do
      local e = ending(tokens[k])
      -- A sentence always ends its subtitle, however short both are.
      if e == "sentence" then return math.huge end
      -- One or two words of the next clause left hanging at the end
      -- ("…this project, nobody"), or of the last one at the start.
      if e then
        if j - k <= 2 and j < n and not ending(tokens[j]) then c = c + 8 end
        if k - i + 1 <= 2 and i > 1 and not ending(tokens[i - 1]) then c = c + 8 end
      end
    end
    local s, e = tokens[i].s, tokens[j].e
    if s and e and e - s > M.MAX_SECONDS then c = c + (e - s - M.MAX_SECONDS) * 3 end
    return c
  end

  if mode == "sentence" then
    -- One subtitle per sentence, on up to two lines, as even as possible
    -- with the longer line underneath unless punctuation decides. A
    -- sentence too long for two lines is cut into natural phrases first
    -- (the short-phrase rules), then the phrases are paired into two-line
    -- subtitles — so every cut is one those rules chose, never "nobody | on".
    local i = 1
    for j = 1, n do
      if j == n or ending(tokens[j]) == "sentence" then
        local total = width(tokens, i, j)
        if total <= limit then
          add(i, j, { join(tokens, i, j) })
        elseif total <= limit * 2 then
          local target = total / 2
          local lines = {}
          for _, piece in ipairs(best_breaks(tokens, i, j, limit, function(x, y, w)
            return 10 + ((w - target) / limit) ^ 2 * 6 + ((y < j and w > target) and 0.5 or 0)
          end)) do
            lines[#lines + 1] = join(tokens, piece[1], piece[2])
          end
          add(i, j, lines)
        else
          local phrases = best_breaks(tokens, i, j, limit, phrase_cost)
          -- Pair phrases: fewest subtitles, then the most natural cuts
          -- between them.
          local m = #phrases
          local best, back = { [0] = 0 }, {}
          for k = 1, m do
            best[k], back[k] = math.huge, nil
            for size = 1, math.min(2, k) do
              local a = k - size + 1
              local cut = (a > 1) and break_cost(tokens, phrases[a - 1][2]) or 0
              local c = best[a - 1] + 10 + cut
              if c < best[k] then best[k], back[k] = c, a end
            end
          end
          local groups, k = {}, m
          while k >= 1 do
            table.insert(groups, 1, { back[k], k })
            k = back[k] - 1
          end
          for _, g in ipairs(groups) do
            local lines = {}
            for q = g[1], g[2] do lines[#lines + 1] = join(tokens, phrases[q][1], phrases[q][2]) end
            add(phrases[g[1]][1], phrases[g[2]][2], lines)
          end
        end
        i = j + 1
      end
    end
    return cues
  end

  -- Short phrases: one line each.
  local pieces = best_breaks(tokens, 1, n, limit, phrase_cost)
  for _, p in ipairs(pieces) do add(p[1], p[2], { join(tokens, p[1], p[2]) }) end
  return cues
end

--- A take's subtitles, in seconds from the start of the take.
-- `take` = { text = the line as typed (tags and all), words = Boson's list
-- or nil, seconds = the clip's length, pause = trailing silence added }.
function M.for_take(take, mode)
  local tokens = M.tokenize(M.display_text(take.text))
  local speech = math.max(0.1, (tonumber(take.seconds) or 0) - (tonumber(take.pause) or 0))
  local method = M.align(tokens, take.words, speech)
  local cues = M.split(tokens, mode)
  return cues, method
end

------------------------------------------------------------------ frames

--- Snap subtitles to the timeline's frames and apply the timing rules.
-- `cues` are in seconds from a common origin, in order, each with an
-- optional `bound` (seconds) it must end by — the end of its clip. Returns
-- the same cues with `from` and `to` in frames (to is exclusive).
function M.frames(cues, fps)
  fps = tonumber(fps) or 24
  local gap = M.GAP_FRAMES
  local min_len = math.ceil(M.MIN_SECONDS * fps - 1e-6)
  local lag = math.floor(M.LAG_SECONDS * fps + 0.5)
  local close = math.floor(M.CLOSE_SECONDS * fps + 0.5)

  for _, c in ipairs(cues) do
    -- In on the first frame of the voice, out on the frame after it stops.
    c.from = math.floor(c.start * fps + 1e-6)
    c.to = math.max(c.from + 1, math.ceil(c.finish * fps - 1e-6))
    c.limit = c.bound and math.floor(c.bound * fps + 1e-6) or nil
  end
  for k, c in ipairs(cues) do
    local nx, prev = cues[k + 1], cues[k - 1]
    -- Words of neighbouring clips can sit closer than the gap allows.
    if prev and c.from < prev.to + gap then
      c.from = prev.to + gap
      c.to = math.max(c.to, c.from + 1)
    end
    local ceiling = nx and (nx.from - gap) or c.limit or math.huge
    if c.limit then ceiling = math.min(ceiling, math.max(c.limit, c.to)) end
    local out = c.to + lag
    -- Too short a gap to read as a pause: close it.
    if nx and nx.from - out < close then out = nx.from - gap end
    if out - c.from < min_len then out = c.from + min_len end
    c.to = math.max(c.from + 1, math.min(out, ceiling))
    -- Still too short to read: start a little earlier if there is room.
    if c.to - c.from < min_len then
      local floor = prev and (prev.to + gap) or 0
      c.from = math.max(floor, math.min(c.from, c.to - min_len))
    end
  end
  return cues
end

------------------------------------------------------------------ srt

local function srt_time(frames, fps)
  local ms = math.floor(frames * 1000 / fps + 0.5)
  local h = math.floor(ms / 3600000)
  local m = math.floor(ms / 60000) % 60
  local s = math.floor(ms / 1000) % 60
  return ("%02d:%02d:%02d,%03d"):format(h, m, s, ms % 1000)
end

--- SubRip text for framed cues. The first subtitle is written `lead`
-- frames in (default 0) and the rest keep their distance from it; returns
-- the text and the frame (in the cues' own frames) the first one starts on.
-- Resolve places an .srt by its first subtitle's time, so `lead` is how the
-- caller says where on the track it lands (see resolve.lua).
function M.srt(cues, fps, lead)
  fps = tonumber(fps) or 24
  local origin = cues[1] and cues[1].from or 0
  local shift = (tonumber(lead) or 0) - origin
  local out = {}
  for i, c in ipairs(cues) do
    out[#out + 1] = tostring(i)
    out[#out + 1] = srt_time(c.from + shift, fps) .. " --> " .. srt_time(c.to + shift, fps)
    out[#out + 1] = c.text
    out[#out + 1] = ""
  end
  return table.concat(out, "\n"), origin
end

------------------------------------------------------------------ preview

--- How a line would be split, timing estimated from the text alone. Used by
-- the tests, and handy when tuning the rules.
function M.preview(text, mode)
  local tokens = M.tokenize(M.display_text(text))
  M.align(tokens, nil, math.max(1, #tokens * 0.33))
  local out = {}
  for _, c in ipairs(M.split(tokens, mode)) do out[#out + 1] = c.text end
  return out
end

return M
