--- Probe: how does UIManager size a window relative to Geometry / MinimumSize /
-- Margin? Opens one window per variant (env PROBE=a|b|c|d) with a bordered
-- label that reveals the laid-out width.

local resolve = bmd.scriptapp("Resolve")
local fusion = resolve:Fusion()
local ui = fusion.UIManager
local disp = bmd.UIDispatcher(ui)

local variant = os.getenv("PROBE") or "a"
local props = { ID = "SizeProbe", WindowTitle = "size probe " .. variant,
                Geometry = { 160, 80, 1000, 300 }, Events = { Close = true } }
local group = { Spacing = 6 }

if variant == "b" then group.Margin = 12 end
if variant == "c" then props.MinimumSize = { 1000, 300 } end
if variant == "d" then props.FixedSize = { 1000, 300 } end

local win = disp:AddWindow(props, ui:VGroup{
  Spacing = group.Spacing, Margin = group.Margin,
  ui:Label{ Text = "FULL-WIDTH LABEL — border shows laid-out width (variant " .. variant .. ")",
            StyleSheet = "border: 2px solid #e29b3c; padding: 6px; color: #fff;" },
  ui:HGroup{ Weight = 0,
    ui:Label{ Text = "left", StyleSheet = "border: 1px solid #5cb46f; color:#fff;" },
    ui:Label{ Weight = 1 },
    ui:Label{ Text = "right-edge marker", StyleSheet = "border: 1px solid #e0524a; color:#fff;" },
  },
  ui:Label{ Weight = 1 },
})
win.On.SizeProbe.Close = function() disp:ExitLoop() end
win:Show()
disp:RunLoop()
win:Hide()
