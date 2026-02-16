-- Simulator for Achaeadex Ledger (strict mode)

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local simulator = _G.AchaeadexLedger.Core.Simulator or {}

local function capital_required(design_remaining, pattern_remaining, recovery_enabled)
  if recovery_enabled == 1 then
    return design_remaining + pattern_remaining
  end
  return 0
end

function simulator.units_needed(op_cost, design_remaining, pattern_remaining, price, recovery_enabled)
  assert(type(op_cost) == "number", "op_cost must be a number")
  assert(type(design_remaining) == "number", "design_remaining must be a number")
  assert(type(pattern_remaining) == "number", "pattern_remaining must be a number")
  assert(type(price) == "number", "price must be a number")

  if price <= op_cost then
    error("price must be greater than op_cost")
  end

  local capital = capital_required(design_remaining, pattern_remaining, recovery_enabled)
  local margin = price - op_cost

  if capital == 0 then
    return 0
  end

  return math.ceil(capital / margin)
end

function simulator.price_needed(op_cost, design_remaining, pattern_remaining, units, recovery_enabled)
  assert(type(op_cost) == "number", "op_cost must be a number")
  assert(type(design_remaining) == "number", "design_remaining must be a number")
  assert(type(pattern_remaining) == "number", "pattern_remaining must be a number")
  assert(type(units) == "number", "units must be a number")

  if units <= 0 then
    error("units must be greater than 0")
  end

  local capital = capital_required(design_remaining, pattern_remaining, recovery_enabled)

  return op_cost + (capital / units)
end

_G.AchaeadexLedger.Core.Simulator = simulator

return simulator
