--- Visual tokens and Qt stylesheet builders.
--
-- Every colour, size and weight the window uses is declared here once, so the
-- interface reads as one system and a palette change is a one-file edit.
-- Widgets receive a `StyleSheet` string built by these functions; nothing in
-- ui.lua writes a hex value directly.
--
-- The target is a Resolve Inspector panel, not a floating app: Resolve's own
-- charcoal, three greys and one white doing all the hierarchy work, and one
-- accent (Boson's brand green) spent only on the primary action, the selected
-- tab, the current line and the line that needs attention. Red stays free to
-- mean "error" and nothing else.

local M = {}

M.color = {
  window       = "#28282e",
  panel        = "#2b2b31",   -- tree header, grouped settings panels, dialogs
  field        = "#1f1f23",   -- inputs, lists
  control      = "#33333a",   -- secondary button fill
  hover        = "#2f2f36",
  selected     = "#1d3322",   -- list selection: a dark tint of the brand green
  highlight    = "#2a4a30",   -- the line being played, behind text
  border       = "#3a3a40",
  border_strong = "#4a4a52",  -- focused control
  border_dark  = "#151518",   -- rules under headers

  text         = "#dcdce0",
  text_2       = "#9a9aa2",   -- labels, help, meta, unselected tabs
  text_3       = "#5c5c64",   -- disabled, "not generated"
  text_inverse = "#06200a",   -- on accent
  white        = "#ffffff",

  -- Text green: 4.8:1 on the window and 5.5:1 on fields (WCAG AA), between
  -- the brand's bright #17B726 and the deep #1D7028 used for fills.
  accent       = "#22ad2e",
  accent_hover = "#2cc23a",
  -- Large filled areas (the primary button) use the deeper brand green with
  -- white text; the bright green is too loud as a surface.
  accent_fill  = "#1d7028",
  accent_fill_hover = "#23862f",
  accent_fill_press = "#175a20",
  accent_dim   = "#1a3d20",   -- disabled primary fill
  accent_dim_text = "#82b48a",   -- 4.6:1 on accent_dim; #4f8a58 was 2.0 and vanished

  ok           = "#5cb46f",   -- on timeline (softer than the brand green)
  warn         = "#e29b3c",   -- needs attention (an edited line) — kept apart from the green family
  error        = "#e0524a",
  error_tint   = "#3a2224",   -- block behind a blocking message, as `selected` is for lists
  -- Weight is unavailable on a Fusion label — QSS font-weight, <b> and
  -- font-weight:bold in rich text all render at the body's stroke (measured
  -- three rounds running; see r11-voice-ad.md). So an error line can only be
  -- louder than the ok and warn lines it shares a slot with by being brighter.
  -- 5.3:1 on the window against the fill red's 3.8:1, which also failed AA.
  -- The fill red stays as it is for the record dot and the clipping meter.
  error_text   = "#f2776d",
}

M.font = {
  body    = 13,
  small   = 12,
  meta    = 11,
  section = 14,
  mono    = "Menlo, 'SF Mono', Consolas, monospace",
}

M.size = {
  control = 24,
  tab     = 26,
  row     = 22,
  radius  = 3,
  gap     = 6,
  rows    = 11,   -- between form rows in a settings group: one option per line
  group   = 12,
  section = 26,   -- between settings groups, clearly more than `rows`
  pad     = 12,
}

------------------------------------------------------------------ builders

local c, f, z = M.color, M.font, M.size

--- Text roles. Labels take one of these; nothing sets a colour inline.
function M.label(role)
  if role == "section" then
    -- Headings are written in sentence case and separated by size and colour,
    -- not by capitals. Not by weight: a Fusion label cannot be bold, by
    -- stylesheet or by markup — tried and measured, both do nothing.
    -- The rule under a section heading is a separate 1 px widget (M.rule);
    -- a border on the label itself does not paint in Resolve.
    return ("QLabel { font-size: %dpx; color: %s; }")
      :format(f.section, c.text)
  elseif role == "hero" then
    -- The one heading on a screen with nothing else on it (first run): the
    -- 15 px title is only 1.15× the body there and does not lead.
    return ("QLabel { font-size: 17px; color: %s; }"):format(c.text)
  elseif role == "title" then
    return ("QLabel { font-size: 15px; font-weight: 600; color: %s; }"):format(c.text)
  elseif role == "strong" then
    -- No weight available on a label; the step up is the primary colour.
    return ("QLabel { font-size: %dpx; color: %s; }"):format(f.body, c.text)
  elseif role == "secondary" then
    -- Form labels and short explanatory paragraphs: body size, quieter colour.
    return ("QLabel { font-size: %dpx; color: %s; }"):format(f.body, c.text_2)
  elseif role == "meta" or role == "hint" then
    -- Help lines sit a real step below labels, as Resolve's Inspector hints do.
    return ("QLabel { font-size: %dpx; color: %s; }"):format(f.meta, c.text_2)
  elseif role == "mono" then
    return ("QLabel { font-family: %s; font-size: %dpx; color: %s; }"):format(f.mono, f.small, c.text_2)
  elseif role == "mono_dim" then
    -- Timecodes with nothing behind them, beside dimmed transport controls.
    return ("QLabel { font-family: %s; font-size: %dpx; color: %s; }"):format(f.mono, f.small, c.text_3)
  elseif role == "mono_strong" then
    return ("QLabel { font-family: %s; font-size: %dpx; color: %s; }"):format(f.mono, f.small, c.text)
  elseif role == "ok" then
    -- The brand green, not the timeline green: `ok` here confirms, and a
    -- confirmation must not outshout the error that shares its slot.
    return ("QLabel { font-size: %dpx; color: %s; }"):format(f.small, c.accent)
  elseif role == "note" then
    -- The quiet member of the ok/warn/error family: same size, so a line does
    -- not change type when it changes meaning.
    return ("QLabel { font-size: %dpx; color: %s; }"):format(f.small, c.text_2)
  elseif role == "error_block" then
    -- One slot holds four states, and with weight unavailable hue alone does
    -- not rank them: amber warn measures brighter than red error, and red
    -- barely clears the grey that means "carry on". So the one state that
    -- *blocks* is a block — a tinted panel with a rule down its edge, which
    -- ranks by shape and survives however the colours are perceived. The tint
    -- is deliberately almost luminance-free (1.0006:1); the rule is what does
    -- the separating, so it carries the weight the fill does not.
    return ("QLabel { font-size: %dpx; color: %s; background: %s; " ..
            "border-left: 3px solid %s; border-radius: %dpx; padding: 5px 8px; }")
      :format(f.small, c.error_text, c.error_tint, c.error, z.radius)
  elseif role == "warn" then
    -- Amber is this app's "worth a second look", never its "stop".
    return ("QLabel { font-size: %dpx; color: %s; }"):format(f.small, c.warn)
  elseif role == "error" then
    -- error_text, not the fill red: this is running text and the fill red
    -- measures 3.8:1 on the window, which fails AA.
    return ("QLabel { font-size: %dpx; color: %s; }"):format(f.small, c.error_text)
  elseif role == "disabled" then
    return ("QLabel { font-size: %dpx; color: %s; }"):format(f.body, c.text_3)
  elseif role == "link" then
    return ("QLabel { font-size: %dpx; color: %s; }"):format(f.small, c.accent)
  end
  return ("QLabel { font-size: %dpx; color: %s; }"):format(f.body, c.text)
end

--- kind: "primary" | "secondary" | "ghost" | "danger_ghost" | "destructive"
function M.button(kind)
  local base = ("QPushButton { min-height: %dpx; max-height: %dpx; border-radius: %dpx; " ..
                "padding: 0 10px; font-size: %dpx; }")
    :format(z.control, z.control, z.radius, f.body)
  local disabled = ("QPushButton:disabled { background: transparent; color: %s; border: 1px solid #2e2e34; }")
    :format(c.text_3)
  if kind == "primary" then
    return base .. (
      "QPushButton { background: %s; color: %s; border: 1px solid %s; font-weight: 600; min-width: 110px; }" ..
      "QPushButton:hover { background: %s; } QPushButton:pressed { background: %s; }" ..
      "QPushButton:disabled { background: %s; color: %s; border: 1px solid %s; }")
      :format(c.accent_fill, c.white, c.accent_fill, c.accent_fill_hover, c.accent_fill_press,
              c.accent_dim, c.accent_dim_text, c.accent_dim)
  elseif kind == "outline" then
    -- "This needs doing" without a second filled accent on the screen.
    return base .. (
      "QPushButton { background: transparent; color: %s; border: 1px solid %s; }" ..
      "QPushButton:hover { background: %s; }")
      :format(c.accent, c.accent, c.accent_dim) .. disabled
  elseif kind == "icon" then
    -- A square glyph button (transport controls): same height as everything
    -- else, no text padding. Disabled keeps its chassis and only dims the
    -- glyph, so a pair never reads as a hole beside a button.
    return base .. (
      "QPushButton { background: %s; color: %s; border: 1px solid %s; min-width: %dpx; max-width: %dpx; padding: 0; font-size: 12px; }" ..
      "QPushButton:hover { background: #3b3b43; color: %s; }" ..
      "QPushButton:disabled { background: %s; color: %s; border: 1px solid %s; }")
      :format(c.control, c.text, c.border, z.control, z.control, c.white, c.control, c.text_3, c.border)
  elseif kind == "link_flush" then
    -- A link on a line of its own under a paragraph: no inset, so its first
    -- letter sits on the paragraph's left edge.
    return base .. (
      "QPushButton { background: transparent; color: %s; border: 1px solid transparent; padding: 0; " ..
      "font-size: %dpx; text-align: left; }" ..
      "QPushButton:hover { color: %s; text-decoration: underline; }")
      :format(c.accent, f.body, c.accent_hover) .. disabled
  elseif kind == "link" then
    -- Reads as a link inside a sentence; still a button so it can be clicked.
    -- Body size, because it always sits in a row beside real buttons.
    return base .. (
      -- The border is transparent, not absent: without it Qt computes a
      -- taller content rect than the bordered button beside it and the text
      -- sits a couple of pixels high.
      "QPushButton { background: transparent; color: %s; border: 1px solid transparent; padding: 0 4px; font-size: %dpx; }" ..
      "QPushButton:hover { color: %s; text-decoration: underline; }")
      :format(c.accent, f.body, c.accent_hover) .. disabled
  elseif kind == "ghost" then
    -- Keeps its chassis when disabled, as the icon kind and the combo beside
    -- it do: the shared rule drops the border to 1.09:1 and leaves a hole.
    return base .. (
      "QPushButton { background: transparent; color: %s; border: 1px solid %s; }" ..
      "QPushButton:hover { background: %s; color: %s; }" ..
      "QPushButton:disabled { background: transparent; color: %s; border: 1px solid %s; }")
      :format(c.text_2, c.border, c.hover, c.text, c.text_3, c.border)
  elseif kind == "danger_ghost" then
    -- A ghost that says what it does: red words and a red edge while it can
    -- act, the plain ghost's dim chassis when it cannot.
    return base .. (
      "QPushButton { background: transparent; color: %s; border: 1px solid %s; }" ..
      "QPushButton:hover { background: %s; }" ..
      "QPushButton:disabled { background: transparent; color: %s; border: 1px solid %s; }")
      :format(c.error_text, c.error, c.error_tint, c.text_3, c.border)
  elseif kind == "destructive" then
    return base .. (
      "QPushButton { background: transparent; color: %s; border: 1px solid %s; }" ..
      "QPushButton:hover { color: %s; border-color: %s; }")
      :format(c.text_2, c.border, c.error, c.error) .. disabled
  end
  return base .. (
    "QPushButton { background: %s; color: %s; border: 1px solid %s; }" ..
    "QPushButton:hover { background: #3b3b43; } QPushButton:pressed { background: %s; }")
    :format(c.control, c.text, c.border, c.field) .. disabled
end

--- Slim scrollbar in the field's own colours, for text boxes and lists.
function M.scrollbar()
  return (
    "QScrollBar:vertical { background: transparent; width: 8px; margin: 2px 0; }" ..
    "QScrollBar::handle:vertical { background: %s; border-radius: 3px; min-height: 24px; }" ..
    "QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }" ..
    "QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical { background: transparent; }")
    :format(c.border_strong)
end

function M.input()
  return (
    "QLineEdit, QTextEdit, QPlainTextEdit { background: %s; color: %s; border: 1px solid %s; " ..
    "border-radius: %dpx; padding: 3px 8px; font-size: %dpx; selection-background-color: %s; }" ..
    "QLineEdit { min-height: %dpx; max-height: %dpx; }" ..
    "QLineEdit:focus, QTextEdit:focus, QPlainTextEdit:focus { border-color: %s; }" ..
    "QLineEdit:disabled, QTextEdit:disabled { color: %s; }")
    :format(c.field, c.text, c.border, z.radius, f.body, c.selected,
            z.control - 6, z.control - 6, c.border_strong, c.text_3) .. M.scrollbar()
end

function M.combo()
  return (
    "QComboBox { background: %s; color: %s; border: 1px solid %s; border-radius: %dpx; " ..
    "padding: 0 8px; min-height: %dpx; max-height: %dpx; font-size: %dpx; }" ..
    "QComboBox:hover { border-color: %s; } QComboBox:disabled { color: %s; }" ..
    -- No ::drop-down rule: styling that sub-control makes Qt drop the chevron,
    -- and the base style's own arrow is the one Resolve users know.
    "QComboBox QAbstractItemView { background: %s; color: %s; selection-background-color: %s; border: 1px solid %s; }")
    :format(c.field, c.text, c.border, z.radius, z.control, z.control, f.body,
            c.border_strong, c.text_3, c.panel, c.text, c.selected, c.border)
end

function M.tree()
  return (
    "QTreeView { background: %s; color: %s; border: 1px solid %s; border-radius: %dpx; " ..
    "font-size: %dpx; outline: none; show-decoration-selected: 1; }" ..
    "QTreeView::item { height: %dpx; padding-left: 4px; border-bottom: 1px solid #232328; }" ..
    "QTreeView::item:hover { background: %s; }" ..
    -- Selection lightens the row and paints the branch strip accent; per-cell
    -- text colours are left alone so a row's state stays readable when chosen.
    "QTreeView::item:selected { background: %s; }" ..
    "QHeaderView::section { background: %s; color: %s; border: none; border-bottom: 1px solid %s; " ..
    "padding: 4px 6px; height: %dpx; font-size: %dpx; }")
    :format(c.field, c.text, c.border, z.radius, f.body,
            z.row, c.hover, c.selected,
            c.panel, c.text_2, c.border_dark, 14, f.small) .. M.scrollbar()
end

--- A list with a note along its bottom edge, drawn as one box: the list
-- drops its bottom border and corners, the note carries them, and its top
-- edge is the one line between the two — in the border colour, because a
-- darker rule there is drawn across the side borders and pokes out.
function M.tree_open_bottom()
  return M.tree() .. ("QTreeView { border-bottom: none; border-bottom-left-radius: 0px; " ..
    "border-bottom-right-radius: 0px; }")
end

function M.tree_foot()
  return ("QLabel { background: %s; color: %s; font-size: %dpx; padding: 0 10px; " ..
    "border: 1px solid %s; " ..
    "border-bottom-left-radius: %dpx; border-bottom-right-radius: %dpx; }")
    :format(c.field, c.text_2, f.body, c.border, z.radius, z.radius)
end

function M.checkbox()
  return ("QCheckBox { color: %s; font-size: %dpx; spacing: 8px; } QCheckBox::indicator { width: 14px; height: 14px; }")
    :format(c.text, f.body)
end

function M.tabs()
  return (
    "QTabBar { background: transparent; } " ..
    -- 56, not 72: the padding does most of the sizing, so the accent underline
    -- hugs the word instead of overhanging it like a swab, while the floor
    -- still keeps a short label from collapsing.
    "QTabBar::tab { background: transparent; color: %s; padding: 0 14px; min-height: %dpx; " ..
    "min-width: 56px; border: none; border-bottom: 2px solid transparent; font-size: %dpx; }" ..
    "QTabBar::tab:selected { color: %s; border-bottom: 2px solid %s; }" ..
    "QTabBar::tab:hover { color: %s; }")
    :format(c.text_2, z.tab, f.body, c.text, c.accent, c.text)
end

--- Thin progress bar built from a slider: groove is the track, the filled
-- sub-page is progress, and the handle is collapsed to nothing.
-- The bar keeps its slot when idle (drawn in the window colour) so nothing
-- moves when a batch starts.
function M.progress(idle, no_handle)
  -- `idle` used to paint the groove in the window colour, which made the bar
  -- vanish between takes. A track the user cannot see is not a track: it stays
  -- `border` in both states and only the fill changes.
  local track = c.border
  local fill = idle and c.border or c.accent
  -- A small round handle is what the mouse grabs to scrub. A bar that cannot
  -- be dragged gets none, or it invites a drag that does nothing.
  local handle = no_handle
    and "QSlider::handle:horizontal { width: 0; height: 0; margin: 0; background: transparent; }"
    or (("QSlider::handle:horizontal { width: 9px; height: 9px; margin: -3px 0; border-radius: 5px; background: %s; }" ..
         "QSlider::handle:horizontal:hover { background: %s; }"):format(fill, idle and c.border or c.accent_hover))
  return (
    ("QSlider::groove:horizontal { height: 4px; background: %s; border-radius: 2px; }" ..
     "QSlider::sub-page:horizontal { background: %s; border-radius: 2px; }" ..
     "QSlider::add-page:horizontal { background: %s; border-radius: 2px; }"):format(track, fill, track) ..
    handle ..
    -- The bar is Enabled = false wherever it is not draggable, so the disabled
    -- rules are the ones that actually paint: they must match, not grey out.
    ("QSlider::groove:horizontal:disabled { background: %s; }" ..
     "QSlider::sub-page:horizontal:disabled { background: %s; }" ..
     "QSlider::add-page:horizontal:disabled { background: %s; }"):format(track, fill, track))
end

--- The recording level meter: the progress bar's shape, but it turns red
-- where a take starts to distort. A meter is the one bar that has to shout,
-- because by the time the user hears the damage the take is already spent.
-- kind: "idle" (nothing to meter — an empty track) | "live" | "hot" | "full"
-- ("full" is an inert slug: a take exists, but nothing is moving.)
--
-- Hot is red, and it is the documented exception to "red means errors only".
-- The verdict after a take calls clipping a warning, which is right — the take
-- is usable and the user can hear it. The meter is a different moment: the
-- damage is happening now and can still be stopped, and every DAW meter this
-- audience has used, Fairlight included, goes red at the top.
function M.meter(kind)
  local fill = (kind == "hot" and c.error) or (kind == "live" and c.accent)
            or (kind == "full" and c.text_2) or c.border
  -- Square, not the progress bar's pill: a level meter is a rectangle in every
  -- DAW including Fairlight, and the shape is what stops a user who has met
  -- the preview player reading this as a download bar. The empty track is
  -- `border` rather than the field colour, because this is the one bar that
  -- has to be legible while it is showing nothing — and the inert "full" fill
  -- is a step lighter again, or an empty meter would read as a full one.
  local sheet = (
    "QSlider::groove:horizontal { height: 6px; background: %s; border-radius: 0; }" ..
    "QSlider::sub-page:horizontal { background: %s; border-radius: 0; }" ..
    "QSlider::add-page:horizontal { background: %s; border-radius: 0; }" ..
    -- No handle: nothing here is draggable, and a knob would invite a drag.
    "QSlider::handle:horizontal { width: 0; height: 0; margin: 0; background: transparent; }" ..
    "QSlider:disabled { background: transparent; }" ..
    "QSlider::groove:horizontal:disabled { background: %s; }" ..
    "QSlider::sub-page:horizontal:disabled { background: %s; }" ..
    "QSlider::add-page:horizontal:disabled { background: %s; }")
    :format(c.border, fill, c.border, c.border, fill, c.border)
end

--- A read-only block of text that is meant to be read aloud, not edited:
-- field-coloured like an input so it reads as content, at reading size with
-- room between the lines.
function M.passage()
  -- No line-height here: QLabel ignores it. The leading is set in the rich
  -- text the label is given, which is the only place Qt honours it.
  return ("QLabel { background: %s; color: %s; border: 1px solid %s; border-radius: %dpx; " ..
          "padding: 8px 10px; font-size: %dpx; }")
    :format(c.field, c.text, c.border, z.radius, f.body + 1)
end

--- A small rounded badge for a short count, e.g. the take number in the
-- preview. Rounded corners need a real widget; HTML in a label cannot.
function M.pill()
  -- Full control height so it sits on the same baseline as the row's
  -- buttons; a radius of half that keeps it a pill.
  return ("QLabel { background: %s; color: %s; border: 1px solid %s; border-radius: %dpx; " ..
          "padding: 0 9px; min-height: %dpx; max-height: %dpx; font-family: %s; font-size: %dpx; }")
    :format(c.control, c.text_2, c.border, math.floor(z.control / 2), z.control, z.control, f.mono, f.small)
end

--- The connection badge in the window's top-right corner: a dot and a word
-- in a pill, so it reads as a status chip rather than a stray line of text.
-- The dot carries the state colour (set in the label's own HTML); the
-- chassis stays neutral so it never competes with the tab strip's accent.
--- The connection chip beside the tabs. Smaller than a control on purpose:
-- it reports, it is not something to press.
M.PILL_H = 22
function M.status_pill()
  return ("QLabel { background: %s; color: %s; border: 1px solid %s; border-radius: %dpx; " ..
          "padding: 0 8px; min-height: %dpx; max-height: %dpx; font-size: 11px; }")
    :format(c.panel, c.text_2, c.border, math.floor(M.PILL_H / 2), M.PILL_H, M.PILL_H)
end

--- The save indicator: a dot in a cell that reads as the left part of the
-- Save button beside it.
function M.save_dot(color)
  return ("QLabel { background: %s; color: %s; border: 1px solid %s; border-right: none; " ..
          "border-top-left-radius: %dpx; border-bottom-left-radius: %dpx; padding: 0 2px 0 9px; " ..
          "min-height: %dpx; max-height: %dpx; font-size: 11px; }")
    :format(c.control, color, c.border, z.radius, z.radius, z.control, z.control)
end

function M.save_button_join()
  return "QPushButton { border-top-left-radius: 0; border-bottom-left-radius: 0; border-left: none; padding-left: 4px; }"
end

--- The 1 px line under a section heading.
function M.rule()
  return ("background: %s;"):format(c.border)
end

--- A raised group area holding related controls.
function M.panel()
  return ("background: %s; border: 1px solid %s; border-radius: %dpx;")
    :format(c.panel, c.border, z.radius + 1)
end

--- The empty-state block that sits where the list would be.
function M.empty_block()
  return ("background: %s; border: 1px solid %s; border-radius: %dpx;")
    :format(c.field, c.border, z.radius)
end

--- Colour tables for per-cell tree text, in Fusion's 0–1 RGBA form.
local function rgba(hex)
  local r, g, b = hex:match("#(%x%x)(%x%x)(%x%x)")
  return { R = tonumber(r, 16) / 255, G = tonumber(g, 16) / 255, B = tonumber(b, 16) / 255, A = 1 }
end

--- One colour per tag type in the Generate tab's list. Red and green stay
-- reserved for errors and "on timeline"; amber doubles as the biggest
-- family, emotion.
M.tag_color = {
  ["Emotion"]        = "#e29b3c",
  ["Style"]          = "#6fa8dc",
  ["Speed"]          = "#5ec8c0",
  ["Pitch"]          = "#d98bc4",
  ["Expressiveness"] = "#d6c07a",
  ["Pause"]          = "#9a9aa2",
  ["Sound effect"]   = "#b48ede",
}

M.tag_cell = {}
for name, hex in pairs(M.tag_color) do M.tag_cell[name] = rgba(hex) end

M.cell = {
  text     = rgba(c.text),
  text_2   = rgba(c.text_2),
  text_3   = rgba(c.text_3),
  accent   = rgba(c.accent),
  ok       = rgba(c.ok),
  warn     = rgba(c.warn),
  error    = rgba(c.error),
  white    = rgba(c.white),
  inverse  = rgba(c.text_inverse),
}

return M
