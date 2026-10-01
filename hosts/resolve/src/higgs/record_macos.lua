--- Microphone capture on macOS, with nothing to install.
--
-- macOS ships no command-line recorder — there is `afplay` and `afconvert`
-- but no `afrecord` — so the obvious answer is ffmpeg, and the obvious answer
-- is wrong here: Homebrew's build is 53 MB across 93 packages, the FFmpeg
-- project publishes no macOS binaries of its own, and a plugin that downloads
-- and runs a third party's binary is asking every user to trust a host nobody
-- in this chain controls.
--
-- What the system does have is `osascript`, whose JavaScript dialect can reach
-- Objective-C. `AVAudioRecorder` is on the other side of that bridge, and with
-- linear-PCM settings and a `.wav` path it writes a plain RIFF/WAVE file at
-- whatever rate we ask for — the same file the rest of this product already
-- knows how to read.
--
-- The one thing the bridge does not expose is `AVCaptureDevice`, so a take
-- comes from whatever macOS has set as the default input and there is no way
-- to choose a different one from a script. That is the whole price, and the
-- UI pays it by naming the device and offering the Sound settings pane.
--
-- The script below runs detached and talks back through two small files:
-- it appends nothing to stdout (Resolve shows it nowhere), writes
-- `<out>.status` every tick, and stops cleanly when `<out>.stop` appears.
-- Cleanly matters — a killed recorder leaves the WAV's length fields unwritten.
--
-- The count-in is the recorder's, not the interface's: the device is opened
-- immediately and capture is *scheduled* against the audio clock for the end
-- of the countdown. So the take begins when the user is told to speak, and the
-- three seconds of warm-up are never in the file to be trimmed back out.

local M = {}

--- Sample format. Matches Boson's own 24 kHz so nothing resamples, and the
-- rest of the product's WAV helpers assume 16-bit mono.
M.RATE, M.BITS, M.CHANNELS = 24000, 16, 1

--- The JXA recorder. Written to disk on first use, like the icons.
-- Arguments: out.wav, max seconds.
M.SCRIPT = [==[
ObjC.import('Cocoa')
ObjC.import('AVFoundation')

function main(argv) {
  var out = argv[0]
  var maxSeconds = parseFloat(argv[1]) || 30
  var countIn = parseFloat(argv[2]) || 0
  var statusPath = out + '.status'
  var stopPath = out + '.stop'
  var fm = $.NSFileManager.defaultManager

  var settings = $.NSMutableDictionary.alloc.init
  settings.setObjectForKey($(1819304813), 'AVFormatIDKey')   // kAudioFormatLinearPCM
  settings.setObjectForKey($(SAMPLE_RATE), 'AVSampleRateKey')
  settings.setObjectForKey($(CHANNELS), 'AVNumberOfChannelsKey')
  settings.setObjectForKey($(BIT_DEPTH), 'AVLinearPCMBitDepthKey')
  settings.setObjectForKey($(false), 'AVLinearPCMIsFloatKey')
  settings.setObjectForKey($(false), 'AVLinearPCMIsBigEndianKey')

  var err = Ref()
  var rec = $.AVAudioRecorder.alloc.initWithURLSettingsError(
    $.NSURL.fileURLWithPath(out), settings, err)
  if (rec.isNil()) {
    write(statusPath, 'fail could not open the recorder')
    return
  }
  rec.meteringEnabled = true
  // Open the device now and start capturing later: the count-in is the
  // warm-up, and scheduling against the audio clock means the file begins
  // exactly when the user is told to speak rather than three seconds early.
  rec.prepareToRecord
  var startAt = rec.deviceCurrentTime + countIn
  if (!rec.recordAtTimeForDuration(startAt, maxSeconds)) {
    write(statusPath, 'fail the microphone was refused')
    return
  }

  while (true) {
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.08))
    var left = startAt - rec.deviceCurrentTime
    if (left > 0) {
      write(statusPath, 'wait ' + left.toFixed(2))
      if (fm.fileExistsAtPath(stopPath)) { rec.stop; write(statusPath, 'done'); return }
      continue
    }
    rec.updateMeters
    var elapsed = rec.currentTime
    write(statusPath, elapsed.toFixed(3) + ' ' + rec.peakPowerForChannel(0).toFixed(1))
    if (elapsed >= maxSeconds) break
    if (fm.fileExistsAtPath(stopPath)) break
    if (!rec.isRecording) break
  }
  // stop() is what writes the WAV's length fields; killing us skips it.
  rec.stop
  write(statusPath, 'done')
}

function write(path, text) {
  $(text).writeToFileAtomicallyEncodingError(
    path, true, $.NSUTF8StringEncoding, null)
}

main($.NSProcessInfo.processInfo.arguments.js.slice(4).map(function (a) {
  return ObjC.unwrap(a)
}))
]==]

--- The script with the sample format substituted in, so the format lives in
-- one place rather than in two languages.
function M.script_text()
  return (M.SCRIPT
    :gsub("SAMPLE_RATE", tostring(M.RATE))
    :gsub("BIT_DEPTH", tostring(M.BITS))
    :gsub("CHANNELS", tostring(M.CHANNELS)))
end

--- What the recorder is doing, from the status file it writes:
--   { waiting = seconds }  counting in, nothing captured yet
--   { seconds =, peak = }  recording
--   { done = true }        finished and the file is complete
--   { failed =, message }  never started
function M.parse_status(text)
  if not text then return nil end
  text = tostring(text):gsub("%s+$", "")
  if text == "done" then return { done = true } end
  local why = text:match("^fail%s+(.*)$")
  if why then return { failed = true, message = (why ~= "" and why) or "the recorder did not start" } end
  local waiting = text:match("^wait%s+([%d%.]+)$")
  if waiting then return { waiting = tonumber(waiting) or 0 } end
  local seconds, db = text:match("^([%d%.]+)%s+(-?[%d%.]+)$")
  seconds, db = tonumber(seconds), tonumber(db)
  if not seconds or not db then return nil end
  -- peakPowerForChannel is dBFS, -160 at silence; callers want 0–1.
  local peak = (db <= -160) and 0 or 10 ^ (db / 20)
  return { seconds = seconds, peak = math.min(1, peak) }
end

return M
