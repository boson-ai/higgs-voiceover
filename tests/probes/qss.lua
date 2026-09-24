--- Probe: which Qt StyleSheet properties does Resolve's UIManager honour?
-- Opens a window of styled widgets for a screenshot. Not part of the product.

local resolve = bmd.scriptapp("Resolve")
local fusion = resolve:Fusion()
local ui = fusion.UIManager
local disp = bmd.UIDispatcher(ui)

local win = disp:AddWindow({
  ID = "QssProbe", WindowTitle = "QSS probe", Geometry = { 180, 110, 880, 520 },
  Events = { Close = true },
}, ui:VGroup{
  Spacing = 10,
  ui:Label{ Text = "TITLE 18px semibold  (Label StyleSheet)", StyleSheet = "font-size: 18px; font-weight: 600; color: #f2f3f5;" },
  ui:Label{ Text = "Section label 11px uppercase letter-spaced", StyleSheet = "font-size: 11px; color: #8b93a1; letter-spacing: 1px; text-transform: uppercase;" },
  ui:Label{ Text = "Mono 13px  01:00:07:12  0:06.8", StyleSheet = "font-family: Menlo, monospace; font-size: 13px; color: #c8cdd5;" },
  ui:HGroup{
    Weight = 0, Spacing = 8,
    ui:Button{ Text = "Primary", StyleSheet = "QPushButton { background: #2f7bf5; color: white; border: none; border-radius: 6px; padding: 8px 18px; font-weight: 600; } QPushButton:hover { background: #4a8ef7; } QPushButton:pressed { background: #2367d4; }" },
    ui:Button{ Text = "Secondary", StyleSheet = "QPushButton { background: transparent; color: #e6e8eb; border: 1px solid #4a505a; border-radius: 6px; padding: 8px 18px; } QPushButton:hover { background: #33383f; }" },
    ui:Button{ Text = "Disabled", Enabled = false, StyleSheet = "QPushButton { background: #2a2e34; color: #6b7280; border: 1px solid #33383f; border-radius: 6px; padding: 8px 18px; }" },
    ui:Button{ Text = "Danger", StyleSheet = "QPushButton { background: transparent; color: #f08a86; border: 1px solid #7a3a38; border-radius: 6px; padding: 8px 18px; }" },
    ui:Label{ Weight = 1 },
  },
  ui:HGroup{
    Weight = 0, Spacing = 8,
    ui:LineEdit{ Text = "styled line edit", StyleSheet = "QLineEdit { background: #1a1d22; border: 1px solid #3a3f47; border-radius: 6px; padding: 6px 10px; color: #e6e8eb; } QLineEdit:focus { border-color: #2f7bf5; }" },
    ui:ComboBox{ StyleSheet = "QComboBox { background: #1a1d22; border: 1px solid #3a3f47; border-radius: 6px; padding: 5px 10px; color: #e6e8eb; }" },
  },
  ui:Tree{ ID = "T", Weight = 1, StyleSheet = [[
    QTreeView { background: #1a1d22; alternate-background-color: #1e2126; border: 1px solid #33383f; border-radius: 6px; color: #d6d9de; font-size: 13px; }
    QTreeView::item { height: 28px; padding-left: 6px; }
    QTreeView::item:selected { background: #24344f; color: #ffffff; }
    QHeaderView::section { background: #22262c; color: #8b93a1; border: none; border-bottom: 1px solid #33383f; padding: 6px; font-size: 11px; }
  ]] },
  ui:Label{ Text = "● On timeline   ○ Ready   ◐ Generating   ⚠ Too long", StyleSheet = "font-size: 13px; color: #9aa3b0;" },
  ui:Label{ Text = "Panel with padding + border + radius", StyleSheet = "background: #22262c; border: 1px solid #33383f; border-radius: 8px; padding: 12px; color: #c8cdd5;" },
})

local itm = win:GetItems()
itm.T.ColumnCount = 3
local h = itm.T:NewItem(); h.Text[0], h.Text[1], h.Text[2] = "#", "TEXT", "STATE"; itm.T:SetHeaderItem(h)
itm.T.ColumnWidth[0] = 40; itm.T.ColumnWidth[1] = 560
for i = 1, 4 do
  local r = itm.T:NewItem(); r.Text[0] = tostring(i); r.Text[1] = "Row " .. i .. " of styled tree"; r.Text[2] = (i == 2) and "On timeline" or "Ready"
  itm.T:AddTopLevelItem(r)
  if i == 2 then r.Selected = true end
end
itm.T.AlternatingRowColors = true

win.On.QssProbe.Close = function() disp:ExitLoop() end
win:Show()
disp:RunLoop()
win:Hide()
