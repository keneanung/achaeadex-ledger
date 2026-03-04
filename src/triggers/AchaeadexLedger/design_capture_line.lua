-- Mudlet UI trigger bridge for passive nds parsing

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Mudlet = _G.AchaeadexLedger.Mudlet or {}

local capture = _G.AchaeadexLedger.Mudlet.DesignCapture
if not capture or type(capture.process_line) ~= "function" then
  return
end

capture.process_line(_G.line or "")
