-- Mudlet entrypoint for Achaeadex Ledger

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Mudlet = _G.AchaeadexLedger.Mudlet or {}

local function out(msg)
  if type(cecho) == "function" then
    cecho(msg .. "\n")
  elseif type(echo) == "function" then
    echo(msg .. "\n")
  elseif type(print) == "function" then
    print(msg)
  end
end

local function ensure_dir(path)
  local ok, lfs = pcall(require, "lfs")
  if not ok or not lfs then
    return false
  end
  lfs.mkdir(path)
  return true
end

local function register_time_module()
  if type(gmod) == "table" then
    if type(gmod.register) == "function" then
      gmod.register("IRE.Time")
      return
    end
    if type(gmod.enable) == "function" then
      gmod.enable("IRE.Time")
      return
    end
    if type(gmod.add) == "function" then
      gmod.add("IRE.Time")
      return
    end
  end
end

function _G.AchaeadexLedger.Mudlet.init()
  register_time_module()
  if type(sendGMCP) == "function" then
    sendGMCP("IRE.Time.Request")
  end

  local json = _G.AchaeadexLedger.Core.Json
  local ledger = _G.AchaeadexLedger.Core.Ledger

  if not json or not ledger then
    out("AchaeadexLedger: core modules not loaded")
    return
  end

  if type(getMudletHomeDir) ~= "function" then
    out("AchaeadexLedger: getMudletHomeDir is not available")
    return
  end

  local home = getMudletHomeDir()
  local base_dir = home .. "/AchaeadexLedger"
  ensure_dir(base_dir)

  local db_path = base_dir .. "/ledger.sqlite3"

  local luasql_store = _G.AchaeadexLedger.Core.LuaSQLEventStore
  if not luasql_store or type(luasql_store.new) ~= "function" then
    out("AchaeadexLedger: LuaSQL store not available")
    return
  end

  local store = luasql_store.new(db_path)
  if type(store.read_all) ~= "function" then
    out("AchaeadexLedger: LuaSQL store missing read_all")
    return
  end
  local state = ledger.new(store)
  local events = store:read_all()
  if type(events) ~= "table" then
    out("AchaeadexLedger: read_all did not return a table")
    return
  end
  for _, event in ipairs(events) do
    local ok, err = pcall(ledger.apply_event, state, event)
    if not ok then
      local msg = tostring(err)
      error("Failed to apply event " .. tostring(event.id) .. " (" .. tostring(event.event_type) .. "): " .. msg)
    end
  end

  _G.AchaeadexLedger.Mudlet.State = state
  _G.AchaeadexLedger.Mudlet.EventStore = store
  out("AchaeadexLedger: ready (luasql)")
end

local function safe_init()
  local function err_handler(err)
    if debug and type(debug.traceback) == "function" then
      return debug.traceback(err, 2)
    end
    return tostring(err)
  end

  local ok, err = xpcall(_G.AchaeadexLedger.Mudlet.init, err_handler)
  if not ok then
    out("AchaeadexLedger init failed: " .. tostring(err))
  end
end

if tempTimer then
  tempTimer(0, safe_init)
else
  safe_init()
end
