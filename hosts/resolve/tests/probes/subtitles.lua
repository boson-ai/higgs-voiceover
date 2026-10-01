--- Probe: how Resolve takes subtitles from a script.
--
--   fuscript -l lua tests/probes/subtitles.lua
--   CRASH=1 fuscript -l lua tests/probes/subtitles.lua   -- reproduces the crash below
--
-- Needs Resolve open. Works in its own scratch project and never touches the
-- user's projects. Investigative: it prints what Resolve did.
--
-- Findings on Resolve 20.3.2 Studio (2026-09-23), which resolve.lua relies on:
--   * ImportMedia accepts an .srt: a pool item of Type "Subtitle" that starts
--     at its first subtitle (Start TC) and lasts to the end of its last.
--   * AppendToTimeline({ {mediaPoolItem=, ...} }) with a subtitle item —
--     tried with recordFrame, with and without trackIndex — CRASHES Resolve
--     (abort in the script bridge). Never use the clipInfo form.
--   * AppendToTimeline({ item }) is safe. Each subtitle becomes its own item,
--     text intact (Chinese included), on the FIRST ENABLED subtitle track, at
--     that track's last subtitle end (or the timeline start) + the file's
--     first subtitle time. Playhead and other tracks are ignored.
--   * Several subtitle tracks can be enabled; a new one may start disabled.

_G.HIGGS_VO_NO_AUTORUN = true
dofile("Higgs VoiceOver.lua")

local R = require("higgs.resolve")
local U = require("higgs.util")
local P = require("higgs.platform")

local PROJECT = "HiggsVO_SubtitleProbe"
local DIR = (os.getenv("TMPDIR") or "/tmp/") .. "higgsvo-subprobe"
P.mkdirs(DIR)

assert(R.connect(), "Resolve is not running")
print(R.product())
local pm = R.app():GetProjectManager()
local proj = pm:LoadProject(PROJECT) or pm:CreateProject(PROJECT)
assert(proj, "could not open the scratch project")
local mp = proj:GetMediaPool()
proj:SetCurrentTimeline(mp:CreateEmptyTimeline("Probe " .. os.time()))
local function T() return proj:GetCurrentTimeline() end   -- re-read: handles go stale
local t0 = T():GetStartFrame()

local n = 0
local function srt(body)
  n = n + 1
  local p = P.join(DIR, ("probe_%d_%d.srt"):format(os.time(), n))
  U.write_file(p, body)
  local item = mp:ImportMedia({ p })[1]
  print(("  imported: Type=%s Start TC=%s Duration=%s"):format(item:GetClipProperty("Type"),
    item:GetClipProperty("Start TC"), item:GetClipProperty("Duration")))
  return item
end
local function dump(label)
  print("-- " .. label)
  for i = 1, (T():GetTrackCount("subtitle") or 0) do
    print(("  ST%d %q enabled=%s"):format(i, tostring(T():GetTrackName("subtitle", i)), tostring(T():GetIsTrackEnabled("subtitle", i))))
    for _, it in ipairs(T():GetItemListInTrack("subtitle", i) or {}) do
      print(("     +%d..+%d %q"):format(it:GetStart() - t0, it:GetEnd() - t0, tostring(it:GetName())))
    end
  end
end

T():AddTrack("subtitle")
mp:AppendToTimeline({ srt("1\n00:00:10,000 --> 00:00:11,500\nFirst subtitle\n\n2\n00:00:12,000 --> 00:00:13,000\nSecond, on\ntwo lines\n\n3\n00:00:13,100 --> 00:00:14,000\n第三个字幕。\n") })
dump("plain append of a file starting at 10 s (expect +240)")
mp:AppendToTimeline({ srt("1\n00:00:02,000 --> 00:00:03,000\nTwo seconds after the last one\n") })
dump("a second file starting at 2 s (expect after the last subtitle + 48)")
T():AddTrack("subtitle", { index = 1 })
dump("a track inserted at index 1")
mp:AppendToTimeline({ srt("1\n00:00:01,000 --> 00:00:02,000\nWhere does this go?\n") })
dump("appended with the new track first (goes to the first enabled track)")

if os.getenv("CRASH") then
  print("about to append with a clipInfo table — Resolve 20.3.2 crashes here")
  mp:AppendToTimeline({ { mediaPoolItem = srt("1\n00:00:00,000 --> 00:00:01,000\nCrash\n"), startFrame = 0, endFrame = 23,
                          trackIndex = 1, recordFrame = t0 + 48 } })
end
pm:SaveProject()
print("\ndone — project " .. PROJECT .. " left open for a look")
