-- Probe: manual event pump (StepLoop + wait) as a substitute for Timer events,
-- which never dispatch in Resolve's UIManager.
io.stdout:setvbuf("no")
local resolve = bmd.scriptapp("Resolve")
local fusion = resolve:Fusion()
local ui = fusion.UIManager
local disp = bmd.UIDispatcher(ui)
local win = disp:AddWindow({ ID = "PumpProbe" .. os.time(), WindowTitle = "pump probe",
  Geometry = { 160, 80, 300, 100 }, Events = { Close = true } },
  ui:VGroup{ ui:Label{ ID = "L", Text = "waiting" }, ui:Button{ ID = "B", Text = "click" } })
local closed, clicks = false, 0
win.On["PumpProbe" .. os.time()].Close = function() closed = true end
win.On.B.Clicked = function() clicks = clicks + 1; print("clicked " .. clicks) end
print("StepLoop =", tostring(disp.StepLoop), "wait =", tostring(bmd.wait))
win:Show()
local n, t0 = 0, os.clock()
while not closed and n < 30 do
  disp:StepLoop()
  bmd.wait(0.1)
  n = n + 1
  win:GetItems().L.Text = "tick " .. n
end
win:Hide()
print(("exited cleanly after %d ticks, %.2fs cpu"):format(n, os.clock() - t0))
