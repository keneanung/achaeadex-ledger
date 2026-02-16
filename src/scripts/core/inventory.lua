-- Inventory management with Weighted Average Cost (WAC) accounting
-- Core accounting logic independent of Mudlet

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local inventory = _G.AchaeadexLedger.Core.Inventory or {}

-- Create a new inventory state
function inventory.new()
  return {
    commodities = {}, -- commodity_name -> {qty: number, total_cost: number, unit_cost: number}
  }
end

-- Add inventory via opening balance or purchase
-- Uses mark-to-market for opening, blends with WAC for subsequent purchases
function inventory.add(state, commodity, qty, unit_cost)
  assert(type(commodity) == "string", "commodity must be a string")
  assert(type(qty) == "number" and qty > 0, "qty must be positive number")
  assert(type(unit_cost) == "number" and unit_cost >= 0, "unit_cost must be non-negative number")
  
  if not state.commodities[commodity] then
    -- First entry for this commodity
    state.commodities[commodity] = {
      qty = qty,
      total_cost = qty * unit_cost,
      unit_cost = unit_cost
    }
  else
    -- Blend with existing using WAC
    local existing = state.commodities[commodity]
    local new_total_cost = existing.total_cost + (qty * unit_cost)
    local new_qty = existing.qty + qty
    
    existing.qty = new_qty
    existing.total_cost = new_total_cost
    existing.unit_cost = new_total_cost / new_qty
  end
  
  return state
end

-- Remove inventory (for consumption/usage)
-- Returns the total cost of the removed quantity at WAC
function inventory.remove(state, commodity, qty)
  assert(type(commodity) == "string", "commodity must be a string")
  assert(type(qty) == "number" and qty > 0, "qty must be positive number")
  
  local existing = state.commodities[commodity]
  if not existing then
    error("Cannot remove " .. commodity .. ": not in inventory")
  end
  
  if existing.qty < qty then
    error(string.format("Insufficient %s: have %.2f, need %.2f", commodity, existing.qty, qty))
  end
  
  local cost_removed = qty * existing.unit_cost
  
  existing.qty = existing.qty - qty
  existing.total_cost = existing.total_cost - cost_removed
  
  -- Handle floating point precision: if qty is very close to 0, zero it out
  if existing.qty < 0.0001 then
    existing.qty = 0
    existing.total_cost = 0
    existing.unit_cost = 0
  else
    -- Recalculate unit cost to maintain precision
    existing.unit_cost = existing.total_cost / existing.qty
  end
  
  return cost_removed
end

-- Get current quantity of a commodity
function inventory.get_qty(state, commodity)
  local existing = state.commodities[commodity]
  if not existing then
    return 0
  end
  return existing.qty
end

-- Get current WAC unit cost of a commodity
function inventory.get_unit_cost(state, commodity)
  local existing = state.commodities[commodity]
  if not existing or existing.qty == 0 then
    return 0
  end
  return existing.unit_cost
end

-- Get total cost basis of a commodity
function inventory.get_total_cost(state, commodity)
  local existing = state.commodities[commodity]
  if not existing then
    return 0
  end
  return existing.total_cost
end

-- Get all commodities in inventory
function inventory.get_all(state)
  local result = {}
  for commodity, data in pairs(state.commodities) do
    if data.qty > 0 then
      result[commodity] = {
        qty = data.qty,
        unit_cost = data.unit_cost,
        total_cost = data.total_cost
      }
    end
  end
  return result
end

_G.AchaeadexLedger.Core.Inventory = inventory

return inventory
