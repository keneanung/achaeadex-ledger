-- Internal ID generator

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local id_generator = _G.AchaeadexLedger.Core.IdGenerator or {}

local counters = {}

local function to_base36(value)
  local chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  if value == 0 then
    return "0"
  end
  local result = {}
  local v = value
  while v > 0 do
    local idx = (v % 36) + 1
    table.insert(result, 1, chars:sub(idx, idx))
    v = math.floor(v / 36)
  end
  return table.concat(result)
end

local function next_suffix(prefix)
  counters[prefix] = (counters[prefix] or 0) + 1
  local token = to_base36(counters[prefix])
  return string.rep("0", math.max(0, 4 - #token)) .. token
end

function id_generator.generate(prefix, exists_fn)
  assert(type(prefix) == "string" and prefix ~= "", "prefix must be a string")

  local date_part = os.date("!%Y%m%d")
  local candidate = nil
  repeat
    local suffix = next_suffix(prefix)
    candidate = prefix .. "-" .. date_part .. "-" .. suffix
  until not exists_fn or not exists_fn(candidate)

  return candidate
end

_G.AchaeadexLedger.Core.IdGenerator = id_generator

return id_generator
