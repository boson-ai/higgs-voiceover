-- Probe: (1) does a ComboBox keep its chevron when the ::drop-down rule is
-- dropped? (2) do per-cell BackgroundColors render on a Tree with
-- SelectionMode = "NoSelection", and do per-cell text colours survive?
local resolve = bmd.scriptapp("Resolve")
local fusion = resolve:Fusion()
local ui = fusion.UIManager
local disp = bmd.UIDispatcher(ui)
_G.HIGGS_VO_NO_AUTORUN = true
dofile("Higgs VoiceOver.lua")
local T = require("higgs.theme")
local combo_a = T.combo()
local combo_b = T.combo():gsub("QComboBox::drop%-down %b{}", "")
local combo_c = T.combo():gsub("QComboBox::drop%-down %b{}",
  "QComboBox::drop-down { width: 20px; border-left: 1px solid #3a3a40; background: #33333a; }")
local win = disp:AddWindow({ ID = "TreeProbe" .. os.time(), WindowTitle = "tree probe",
  Geometry = { 160, 80, 700, 320 }, Events = { Close = true } }, ui:VGroup{
  ui:HGroup{ Weight = 0,
    ui:ComboBox{ ID = "A", StyleSheet = combo_a },
    ui:ComboBox{ ID = "B", StyleSheet = combo_b },
    ui:ComboBox{ ID = "C", StyleSheet = combo_c },
    ui:ComboBox{ ID = "D" },
  },
  ui:Tree{ ID = "Tr", Weight = 1, StyleSheet = T.tree(), SelectionMode = "NoSelection", RootIsDecorated = false },
  ui:Tree{ ID = "Tr2", Weight = 1, StyleSheet = T.tree(), RootIsDecorated = false },
})
local itm = win:GetItems()
for _, id in ipairs({ "A", "B", "C", "D" }) do itm[id]:AddItem("current (" .. id .. ")"); itm[id]:AddItem("other") end
for _, id in ipairs({ "Tr", "Tr2" }) do
  local t = itm[id]; t.ColumnCount = 3
  local h = t:NewItem(); h.Text[0], h.Text[1], h.Text[2] = "#", "TEXT", "STATUS"; t:SetHeaderItem(h)
  for i = 1, 3 do
    local r = t:NewItem(); r.Text[0] = tostring(i); r.Text[1] = "row " .. i .. (i == 2 and "  (current: bg tint + accent #)" or ""); r.Text[2] = "!  Too long"
    r.TextColor[2] = T.cell.error
    if i == 2 then
      for c = 0, 2 do r.BackgroundColor[c] = { R = 0.24, G = 0.21, B = 0.16, A = 1 } end
      r.TextColor[0] = T.cell.accent
      if id == "Tr2" then r.Selected = true end
    end
    t:AddTopLevelItem(r)
  end
end
win:Show()
local t0 = os.time()
while os.time() - t0 < 6 do pcall(disp.StepLoop, disp); bmd.wait(0.05) end
win:Hide()
