--- Transport icons for the preview player, as 24 px PNGs (drawn at 12 px,
-- so they are sharp on Retina). Buttons take an image only from a file,
-- so they are written next to the config on first use.

local P = require("higgs.platform")
local Config = require("higgs.config")   -- owns the base64 decoder

local M = {}

M.DATA = {
  prev = "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAAWUlEQVR42mNgGAWjgCbgzp0H9UD8H0QTqV4eiPdT3QKgPD+S2v9UtQAo5w/E92GGU80CWHAgG0wVC9CDg6oWYAuOoWUBzYOILpFMt2RKt4xGUVExCkYBSQAA0I1xck1sHYIAAAAASUVORK5CYII=",
  next = "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAAVUlEQVR42mNgGAWjgCbgzp0H+4FYnki19UD8H0STYsF/mCYg5qelBSB8H4j9aWkBDGMNNmpagDXYaGEBSrANSQtoFkQ0i2SaJlOaZTTaFhWjYBSQBAA3TnFyI9tDOgAAAABJRU5ErkJggg==",
  -- Dim twins of prev/next: a PNG keeps its brightness through :disabled.
  prev_dim = "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAArklEQVR42u2SPRECMRBG30B6JBwKMkwUgAIQkPIE4ABwgIAUMLMCwMFh4IooOCTggIaKOSA/pMsrk292s28DlUou07FDa9ud1qbT2uB9f/tVxNq20dpcvO/P73cq53XWtjNgC+w/ZVRG8TVwBObfciqhcAOcgGVIXv1TR3KDUB1jTEp/06AGIu4KLGL1RE0g4h4i7vDS1BVTJOLuIm4FbICh2A5CtWUtOVVbpRLHE7E7L7kZjkGJAAAAAElFTkSuQmCC",
  next_dim = "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAAqklEQVR42u2Tyw3CMBBER4Y7JUAFq8gV0AENzIHDFkAHoZAcXQBUENNAhFxBKIEOckdA/JFvfkfvemZnZQONRimbb4ekjiLWhzC91wRI7UWsF7EIYXp81s2Pe0cAM6k9qbuSBGalfgXwJPVUywAADgBupI6k7msYFK3NZKROWpup/UxzE3TODfeY5m2CsAdwdm54pUwTYzADuMROnPMPulzxfwmy1tFo1GEBD0gwt+fEgfcAAAAASUVORK5CYII=",
  play = "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAAW0lEQVR42mNgGAUjG9y580Cf1hbUA/F9ILanpQX/oXg9EPPT0gIQfg/E+bS0AIb3UyV+8FgAw/0UBRsRFvyHJgL/IWsBzYKIZpFM02RKs4xG06JCn2EUjAJCAAADVChYHL1rLgAAAABJRU5ErkJggg==",
  pause = "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAALElEQVR42mNgGAWjgGbgzp0H9UD8HwnXEyM3asGoBaMWjFpATQtGwSggGgAAFVKW2J1TMwwAAAAASUVORK5CYII=",
  -- Redrawn so its square measures the same 7 px as the record dot at
  -- IconSize {10,10}: the two sit on one button, one press apart.
  -- Sized against the play triangle rather than against the record dot:
  -- the two that sit side by side in a transport are play and stop.
  stop = "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYBAMAAAASWSDLAAAAGFBMVEUAAADd3eD////d3eHr6+/d3eHe3uIAAAAWgxphAAAACHRSTlMA/QN+/og/AKN5JCgAAABPSURBVHjarc+xDUBQAIThD28A9BKMYAWDW0DBABTUjCDal2hI/N3l8udyfCdBC9ZnU/cTsvEScBaYEbAv6AbS2Pk3BFR5NFpuaI7XF15yA5jXDKOeIJxWAAAAAElFTkSuQmCC",
  -- The dim twin of `stop`, for the same reason `play_dim` exists: a disabled
  -- icon button that keeps its full-brightness glyph reads as live.
  stop_dim = "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYBAMAAAASWSDLAAAAGFBMVEUAAABcXGRaWmlbW2NgYGhfX18AAAAAAACF3uqJAAAACHRSTlMA+RDe/xAAALExS4kAAABLSURBVHjarc6hDYAwAADBoyVhBBSCBQizMHmDRWKQ4GogmIYFyrtzT2UNloS4EQndkXPO/SlghwkBN6SCr/8RYS4YYEXLM15ltLoXpDQO5ak6oTkAAAAASUVORK5CYII=",
  -- QSS `color` cannot touch a PNG, so a disabled icon button needs a dim
  -- asset rather than a dim rule: without one it reads as live and invites a
  -- click that does nothing.
  play_dim = "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYBAMAAAASWSDLAAAAGFBMVEVeXmZhYWNcXGQ/Pz9cXGX///8/P38AAABR9dkNAAAACHRSTlP7DqkEXQEEANKDv0oAAAB6SURBVHjaYyxnQAAmBnycX8gctntQDgsDwwLe4A8CMBmFP6u4FiAMuH8tBsm03Ut+ITj/3i47gLDnz1sHJEv/rEJ2wQOIPRCDRBEcJlctBMdVhwWuR9FgCdwelrADCTAOk/AsB5irHRZEsSH8k7AMyXMLEpA4CVgDBADtGBtq/bIIHgAAAABJRU5ErkJggg==",
  -- The one coloured icon: a record dot is red everywhere, and a white one
  -- beside "Record" would read as a bullet point.
  record = "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYBAMAAAASWSDLAAAAGFBMVEXhUkoAAADzW1j9CQngUkniUkqqVVX/////3yLtAAAACHRSTlP8AAwBVaMDAS5GxZMAAADFSURBVHjaTZCxSgNBFEXPu7sptnB3xk5FXPIFKSwsFWsx/oCfGsgfiK0wLMF0spmIQgSZsVgHcqtzON01D6A+AAjgKQXfA+ZhHsztLIPAwvUY7ncOzOPqN0AuUzX2swXIN4dD1cxTBOAdxLgAgF/f26k+JuEuCvtn1mh2UYSNzmNhZXE0bVzBZMrbo2K54GMrnou8OPMuDwDUbRb7ryk8dIh8cgtQrx2C/esSZpdXA1UDy9XZIn2P0wdqI9ZFqIH06ekG4A/YOzeS7SYthAAAAABJRU5ErkJggg==",
}

local written = {}

--- Path of the PNG for `name`, written once per launch.
-- Written every launch, not only when the file is absent: a redrawn icon in
-- this file would otherwise never reach disk, and the old one would keep
-- being drawn for as long as the user's config folder survived. That cost a
-- round of review with the change in the source and not on the screen.
function M.path(name)
  local dir = P.join(P.config_dir(), "icons")
  local file = P.join(dir, name .. ".png")
  if not written[name] then
    if not P.exists(dir) then P.mkdirs(dir) end
    require("higgs.util").write_file(file, Config.b64_decode(M.DATA[name]))
    written[name] = true
  end
  return file
end

return M
