-- Mudlet config for Achaeadex Ledger

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Mudlet = _G.AchaeadexLedger.Mudlet or {}

local config = _G.AchaeadexLedger.Mudlet.Config or {}

local loaded = false
local values = {
  color = "on"
}

local function get_base_dir()
  if type(getMudletHomeDir) == "function" then
    return getMudletHomeDir() .. "/AchaeadexLedger"
  end
  return "."
end

local function get_path()
  return get_base_dir() .. "/config.json"
end

local function ensure_dir(path)
  local ok, lfs = pcall(require, "lfs")
  if not ok or not lfs then
    return false
  end
  lfs.mkdir(path)
  return true
end

local function get_json()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.Json then
    return nil
  end
  return _G.AchaeadexLedger.Core.Json
end

local function load_config()
  if loaded then
    return
  end
  loaded = true

  local json = get_json()
  if not json then
    return
  end

  ensure_dir(get_base_dir())

  local path = get_path()
  local file = io.open(path, "r")
  if not file then
    return
  end

  local content = file:read("*a")
  file:close()

  local ok, data = pcall(json.decode, content)
  if ok and type(data) == "table" then
    if data.color == "on" or data.color == "off" then
      values.color = data.color
    end
  end
end

local function save_config()
  local json = get_json()
  if not json then
    return false
  end

  ensure_dir(get_base_dir())

  local path = get_path()
  local file = io.open(path, "w")
  if not file then
    return false
  end

  file:write(json.encode(values))
  file:close()
  return true
end

function config.get(key)
  load_config()
  return values[key]
end

function config.set(key, value)
  load_config()
  values[key] = value
  return save_config()
end

function config.is_color_enabled()
  load_config()
  return values.color ~= "off"
end

_G.AchaeadexLedger.Mudlet.Config = config

return config
