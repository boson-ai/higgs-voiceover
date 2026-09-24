--- Recording a voice reference: the rules, kept away from the widgets.
--
-- Capture itself is three platform calls (start, stop, is-running) over a raw
-- PCM file; what is worth testing is everything around them — when a take is
-- long enough to send, when it is too quiet or too loud to be worth sending,
-- and what to say about it. Those are pure functions here so they can be
-- checked without a microphone.
--
-- The thresholds come from Boson's own guidance (5–30 s of clean speech, hard
-- minimum 3.0 s) plus what a peak meter can honestly tell from 16-bit PCM.

local M = {}

--- Boson rejects anything under this; there is no point asking.
M.MIN_SECONDS = 3.0
--- The range Boson recommends for a reference, and the length to aim for
-- inside it: long enough to carry pace and timbre, short enough to read in
-- one breath-group without the speaker drifting.
M.GOOD_MIN = 5
M.GOOD_MAX = 30
M.IDEAL = 20

--- Below this average level the signal is too near the noise floor to clone
-- well — a microphone at the wrong end of the room, or the wrong input
-- selected. -35 dBFS RMS, the floor voice-over guides give for a usable take.
M.QUIET_RMS = 0.0178
--- At or above this a 16-bit sample is at the ceiling; a few are normal on a
-- plosive, a lot means the gain is too high and the peaks are square.
M.HOT_PEAK = 0.98
--- Clipping matters once it stops being the occasional sample.
M.HOT_RATIO = 0.005

--- Words per second of natural narration. Outside this the take is being
-- rushed or laboured, and the clone learns that pace. We can only measure it
-- because Boson requires a verbatim transcript in the first place.
M.SLOW_WPS = 1.8
M.FAST_WPS = 4.0

--- What the meter should read, 0–1, given a peak sample.
-- Peak amplitude is linear, and linear is useless to look at: normal speech
-- sits under 0.25 and would never leave the first quarter of the bar. This is
-- the usual fix — map decibels, not amplitude, over the range a voice uses.
function M.meter(peak)
  peak = tonumber(peak) or 0
  if peak <= 0 then return 0 end
  local db = 20 * math.log(peak) / math.log(10)   -- 0 dBFS at full scale
  local FLOOR = -54
  if db <= FLOOR then return 0 end
  if db >= 0 then return 1 end
  return (db - FLOOR) / -FLOOR
end

--- Words in a transcript, for the pace check. Counts runs of non-space, which
-- is close enough for a ratio and works on scripts without spaces too badly.
function M.word_count(text)
  local n = 0
  for _ in tostring(text or ""):gmatch("%S+") do n = n + 1 end
  return n
end

--- Judge a finished take. Returns
--   { ok = boolean, kind = "error" | "warn" | "ok", message = string }
-- `ok` means "we can send this"; a warning is still sendable, because the
-- user has just heard their own recording and is a better judge of it than
-- any of these numbers.
--
-- Order matters: the blocking faults come first, then the one the user can
-- least afford to ignore. Only one line is ever shown, so it has to be the
-- most useful one.
function M.judge(take, transcript)
  local seconds = tonumber(take and take.seconds) or 0
  local peak = tonumber(take and take.peak) or 0
  local rms = tonumber(take and take.rms) or 0
  local hot = tonumber(take and take.hot_ratio) or 0

  if seconds < M.MIN_SECONDS then
    return { ok = false, kind = "error",
             message = ("Only %.1f seconds — Boson needs at least %.0f. Around %d is about right.")
               :format(seconds, M.MIN_SECONDS, M.IDEAL) }
  end
  if peak <= 0.0005 then
    return { ok = false, kind = "error", silent = true,
             message = "Nothing reached the microphone." }
  end
  if rms < M.QUIET_RMS then
    return { ok = false, kind = "error",
             message = "Too quiet to clone from. Move closer to the microphone, or turn its input up, and record again." }
  end
  if hot > M.HOT_RATIO then
    -- `clipped` marks the one warning the dialog still shows: distortion is
    -- inaudible while recording and permanent once a voice is made from it.
    return { ok = true, kind = "warn", clipped = true,
             message = "Loud enough to distort in places. Turning the input down and recording again will give a cleaner voice." }
  end
  local words = M.word_count(transcript)
  if words > 0 and seconds > 0 then
    local wps = words / seconds
    if wps > M.FAST_WPS then
      return { ok = true, kind = "warn",
               message = "That was read quickly, and the voice will copy the pace. Reading it the way you would say it gives a better clone." }
    end
    if wps < M.SLOW_WPS then
      return { ok = true, kind = "warn",
               message = "That was read slowly, and the voice will copy the pace. Reading it the way you would say it gives a better clone." }
    end
  end
  if seconds < M.GOOD_MIN then
    return { ok = true, kind = "warn",
             message = ("%.1f seconds will work, but around %d gives Boson more to go on.")
               :format(seconds, M.IDEAL) }
  end
  -- Nothing wrong with it, and saying so is worth a line: the user has no
  -- meter any more and no other way to know the take is good.
  return { ok = true, kind = "ok", good = true,
           message = ("Good — %.0f seconds at a clear level."):format(seconds) }
end

--- Passages to read. Written for prosody rather than phonetic coverage: at
-- twenty seconds a clone learns timbre and pace, and a flat read of a word
-- list teaches it to be flat. Each is first person, conversational, about
-- sixty words, and carries a question and an emphatic clause so the voice has
-- somewhere to move. Three of them because identical audio returns the same
-- voice id from Boson — a second voice needs different words.
M.PASSAGES = {
  "I have been cutting video for about ten years now, and the part I still like best is the hour before anyone else is awake. No messages, no notes, nothing but the timeline. Does that sound strange? Maybe it does. But that is when the work actually happens, and honestly, nothing else in my day comes close to it.",
  "Here is the thing nobody tells you about narration: the writing matters more than the voice. You can have the warmest voice in the world and still lose people in the second sentence. So do I read the script out loud first? Every single time. And wherever I stumble, that is the line I go back and rewrite.",
  "We shot the whole thing in one afternoon, which I would not recommend to anybody. The light kept changing, the battery died twice, and somebody's phone went off right in the middle of the best take we had. Would I do it again? Probably, yes. It is still the one people write to me about, years later.",
}

--- What the level is doing right now, as a word rather than a meter.
-- Returns nil when there is nothing worth saying, which is most of the time.
function M.level_note(peak)
  peak = tonumber(peak) or 0
  if peak >= M.HOT_PEAK then return "Too loud — move back a little.", "warn" end
  if peak > 0 and peak < 0.02 then return "Very quiet — move closer to the microphone.", "warn" end
  return nil
end

--- What to say to someone who is recording right now. One rule in one place:
-- the dialog asks at every tick and never decides for itself.
function M.coach(seconds, limit)
  seconds = tonumber(seconds) or 0
  limit = tonumber(limit) or M.GOOD_MAX
  if seconds >= limit - 5 then
    return ("Recording stops at %d seconds."):format(limit)
  end
  if seconds >= M.IDEAL - 2 then
    return "That is enough — stop whenever you reach the end."
  end
  if seconds < M.MIN_SECONDS then
    return ("Keep going — %.0f seconds is the minimum, %d is ideal."):format(M.MIN_SECONDS, M.IDEAL)
  end
  return ("Around %d seconds is ideal."):format(M.IDEAL)
end

return M
