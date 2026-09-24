--- Higgs TTS control-tag taxonomy and the rules for composing them.
--
-- Higgs TTS 3 has no SSML. Delivery is directed with inline `<|category:value|>`
-- tokens inside the input text. This module is the single source of truth for
-- which tags exist and where they are allowed to sit, so the UI can offer
-- direction as menus while the API still receives plain tagged text.
--
-- Placement rule from Boson's docs: emotion, style, speed, pitch and
-- expressiveness apply from the start of a turn, so they lead the text. Pauses
-- and sound effects are positional and stay where the user put them.

local U = require("higgs.util")

local M = {}

--- 21 emotions, in the order Boson documents them.
M.EMOTIONS = {
  "elation", "amusement", "enthusiasm", "determination", "pride", "contentment",
  "affection", "relief", "contemplation", "confusion", "surprise", "awe",
  "longing", "arousal", "anger", "fear", "disgust", "bitterness", "sadness",
  "shame", "helplessness",
}

M.STYLES = { "singing", "shouting", "whispering" }

--- Paired with matching onomatopoeia in the text, per Boson's guidance.
M.SFX = { "cough", "laughter", "crying", "screaming", "burping", "humming",
          "sigh", "sniff", "sneeze" }

--- Prosody splits into four independent axes. Each is a leading tag except
-- pauses, which are positional.
M.SPEEDS = {
  { value = "",                  label = "Normal" },
  { value = "speed_very_slow",   label = "Very slow (~0.65×)" },
  { value = "speed_slow",        label = "Slow (~0.85×)" },
  { value = "speed_fast",        label = "Fast (~1.2×)" },
  { value = "speed_very_fast",   label = "Very fast (~1.4×)" },
}

M.PITCHES = {
  { value = "",           label = "Normal" },
  { value = "pitch_low",  label = "Low (~−3 st)" },
  { value = "pitch_high", label = "High (~+2.5 st)" },
}

M.EXPRESSIVENESS = {
  { value = "",                 label = "Normal" },
  { value = "expressive_low",   label = "Restrained" },
  { value = "expressive_high",  label = "Expressive" },
}

M.PAUSES = {
  { value = "prosody:pause",      label = "Pause (~0.4–0.7 s)" },
  { value = "prosody:long_pause", label = "Long pause (~0.7–1.5 s)" },
}

--- Categories offered by the "insert tag" control, in menu order.
function M.categories()
  return { "Emotion", "Style", "Prosody", "Sound effect" }
end

function M.values_for(category)
  if category == "Emotion" then
    local out = {}
    for i, e in ipairs(M.EMOTIONS) do out[i] = { value = "emotion:" .. e, label = e } end
    return out
  elseif category == "Style" then
    local out = {}
    for i, s in ipairs(M.STYLES) do out[i] = { value = "style:" .. s, label = s } end
    return out
  elseif category == "Sound effect" then
    local out = {}
    for i, s in ipairs(M.SFX) do out[i] = { value = "sfx:" .. s, label = s } end
    return out
  elseif category == "Prosody" then
    local out = {}
    for _, p in ipairs(M.PAUSES) do out[#out + 1] = p end
    for _, t in ipairs({ M.SPEEDS, M.PITCHES, M.EXPRESSIVENESS }) do
      for _, item in ipairs(t) do
        if item.value ~= "" then
          out[#out + 1] = { value = "prosody:" .. item.value, label = item.label }
        end
      end
    end
    return out
  end
  return {}
end

--- Close an unpunctuated line so the model reads it as a finished
-- sentence. Without a terminator it runs the last word to the edge of the
-- clip and skips the falling intonation and the small tail that make a
-- pause afterwards sound natural. A line already ending in punctuation, or
-- in a tag, is left exactly as it is.
--- Set by model.lua to the service's per-request ceiling: a line already
-- at the limit is left alone rather than pushed over it.
M.MAX_CHARS = 5000

--- The codepoint of the last character, stepping back over any UTF-8
-- continuation bytes.
local function last_codepoint(s)
  local i = #s
  while i > 1 and s:byte(i) >= 0x80 and s:byte(i) < 0xC0 do i = i - 1 end
  return U.utf8_codepoint(s, i)
end

function M.terminate(text)
  local s = tostring(text or "")
  if s == "" or s:sub(-2) == "|>" then return s end
  if U.utf8_len(s) >= M.MAX_CHARS then return s end
  local cp = last_codepoint(s)
  if not cp then return s end

  if cp < 0x80 then
    -- Plain ASCII: only an unfinished word needs closing.
    return string.char(cp):match("%w") and (s .. ".") or s
  end
  -- Punctuation that already ends a sentence, western or CJK.
  if (cp >= 0x2000 and cp <= 0x206F)          -- – — … ‘ ’ “ ”
     or (cp >= 0x3001 and cp <= 0x303F)       -- 、。〈〉《》
     or (cp >= 0xFF01 and cp <= 0xFF65) then  -- fullwidth ！？．
    return s
  end
  -- CJK and kana take a fullwidth stop; every other script a plain one.
  if (cp >= 0x3040 and cp <= 0x9FFF) or (cp >= 0xAC00 and cp <= 0xD7AF)
     or (cp >= 0xF900 and cp <= 0xFAFF) then
    return s .. "。"
  end
  return s .. "."
end

--- Work out the text after inserting `value` at a point, given everything
-- before and after it. `line_start` tags (speed, pitch, expressiveness)
-- only take effect at the start of a turn, so they move to the front of
-- that line and replace any tag already there on the same axis.
function M.place_tag(before, after, value, line_start)
  local token = M.token(value)
  if not line_start then return before .. token .. " " .. after end
  local nl = before:match(".*()\n")
  local head, line = "", before
  if nl then head, line = before:sub(1, nl), before:sub(nl + 1) end
  local axis = value:match("^prosody:(%a+)_")
  local rest = line .. after
  if axis then rest = rest:gsub("^%s*<|prosody:" .. axis .. "_[%w_]+|>%s*", "") end
  return head .. token .. " " .. rest
end

--- Render one tag token.
function M.token(value)
  return "<|" .. tostring(value) .. "|>"
end

--- Compose the text sent to the API from a segment's text plus its direction.
--
-- The user's text may already contain positional tags (pauses, effects) that
-- they inserted by hand; those are left exactly where they are. Direction chosen
-- in the inspector is prepended, because those tags only take effect at the
-- start of a turn.
--
-- direction = { emotion=, style=, speed=, pitch=, expressiveness= } — any field
-- may be nil or "" to mean "leave it alone".
function M.compose(text, direction)
  direction = direction or {}
  local lead = {}

  if direction.emotion and direction.emotion ~= "" then
    lead[#lead + 1] = M.token("emotion:" .. direction.emotion)
  end
  if direction.style and direction.style ~= "" then
    lead[#lead + 1] = M.token("style:" .. direction.style)
  end
  for _, key in ipairs({ "speed", "pitch", "expressiveness" }) do
    local v = direction[key]
    if v and v ~= "" then lead[#lead + 1] = M.token("prosody:" .. v) end
  end

  local body = U.trim(text or "")
  if #lead == 0 then return body end
  return table.concat(lead, " ") .. " " .. body
end

--- Billable characters for a composed segment.
-- Boson bills the full input including tags, so estimates must count the
-- composed string rather than the visible words.
function M.billable_length(text, direction)
  return #M.compose(text, direction)
end

--- Does this text already carry a leading direction tag?
-- Used to warn when hand-written tags and inspector settings would both apply.
function M.has_leading_tag(text)
  local first = U.trim(text or ""):match("^(<|[^|]+|>)")
  if not first then return false end
  local kind = first:match("^<|(%a+):")
  return kind == "emotion" or kind == "style" or kind == "prosody"
end

return M
