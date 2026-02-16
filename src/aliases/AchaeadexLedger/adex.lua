-- Mudlet alias entrypoint for Achaeadex Ledger

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Mudlet = _G.AchaeadexLedger.Mudlet or {}

local commands = _G.AchaeadexLedger.Mudlet.Commands
if not commands then
  if cecho then
    cecho("AchaeadexLedger: commands not loaded\n")
  else
    echo("AchaeadexLedger: commands not loaded\n")
  end
  return
end

local input = matches[2] or ""
commands.handle(input)
