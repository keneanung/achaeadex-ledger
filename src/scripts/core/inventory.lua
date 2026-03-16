-- Inventory management with Weighted Average Cost (WAC) accounting
-- Core accounting logic independent of Mudlet

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local inventory = _G.AchaeadexLedger.Core.Inventory or {}

local MINIMUM_STANDARD_VALUE_OBSERVATIONS = 5

local function ensure_entry(state, commodity)
  local entry = state.commodities[commodity]
  if entry then
    if entry.standard_value == nil then
      entry.standard_value = nil
    end
    entry.observed_market_avg = tonumber(entry.observed_market_avg)
    entry.observed_market_count = tonumber(entry.observed_market_count) or 0
    entry.observed_market_qty_total = tonumber(entry.observed_market_qty_total) or 0
    return entry
  end

  entry = {
    qty = 0,
    total_cost = 0,
    unit_cost = 0,
    standard_value = nil,
    observed_market_avg = nil,
    observed_market_count = 0,
    observed_market_qty_total = 0
  }
  state.commodities[commodity] = entry
  return entry
end

local function maybe_adapt_standard_value(entry)
  if entry.standard_value == nil then
    return
  end

  local observed_count = tonumber(entry.observed_market_count) or 0
  local observed_avg = tonumber(entry.observed_market_avg)
  if observed_count < MINIMUM_STANDARD_VALUE_OBSERVATIONS or observed_avg == nil then
    return
  end

  entry.standard_value = (0.9 * tonumber(entry.standard_value)) + (0.1 * observed_avg)
end

-- Create a new inventory state
function inventory.new()
  return {
    commodities = {}, -- commodity_name -> {qty: number, total_cost: number, unit_cost: number}
  }
end

-- Add inventory via opening balance or purchase
-- Uses mark-to-market for opening, blends with WAC for subsequent purchases
function inventory.add(state, commodity, qty, unit_cost, opts)
  assert(type(commodity) == "string", "commodity must be a string")
  assert(type(qty) == "number" and qty > 0, "qty must be positive number")
  assert(type(unit_cost) == "number" and unit_cost >= 0, "unit_cost must be non-negative number")

  opts = opts or {}
  local existing = ensure_entry(state, commodity)

  if existing.qty <= 0 then
    existing.qty = qty
    existing.total_cost = qty * unit_cost
    existing.unit_cost = unit_cost
  else
    local new_total_cost = existing.total_cost + (qty * unit_cost)
    local new_qty = existing.qty + qty

    existing.qty = new_qty
    existing.total_cost = new_total_cost
    existing.unit_cost = new_total_cost / new_qty
  end

  if opts.seed_standard_value == true and existing.standard_value == nil then
    existing.standard_value = unit_cost
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

function inventory.set_standard_value(state, commodity, standard_value)
  assert(type(commodity) == "string", "commodity must be a string")
  assert(type(standard_value) == "number" and standard_value >= 0, "standard_value must be a non-negative number")

  local entry = ensure_entry(state, commodity)
  entry.standard_value = standard_value
  return entry.standard_value
end

function inventory.get_standard_value(state, commodity)
  local entry = state.commodities[commodity]
  if not entry then
    return nil
  end
  return entry.standard_value
end

function inventory.observe_market(state, commodity, unit_price, qty)
  assert(type(commodity) == "string", "commodity must be a string")
  assert(type(unit_price) == "number" and unit_price >= 0, "unit_price must be a non-negative number")
  assert(type(qty) == "number" and qty > 0, "qty must be a positive number")

  local entry = ensure_entry(state, commodity)
  local count = tonumber(entry.observed_market_count) or 0
  local avg = tonumber(entry.observed_market_avg)
  local qty_total = tonumber(entry.observed_market_qty_total) or 0

  if count <= 0 or avg == nil or qty_total <= 0 then
    entry.observed_market_avg = unit_price
    entry.observed_market_count = 1
    entry.observed_market_qty_total = qty
  else
    local total = (avg * qty_total) + (unit_price * qty)
    entry.observed_market_count = count + 1
    entry.observed_market_qty_total = qty_total + qty
    entry.observed_market_avg = total / entry.observed_market_qty_total
  end

  maybe_adapt_standard_value(entry)

  return {
    observed_market_avg = entry.observed_market_avg,
    observed_market_count = entry.observed_market_count,
    observed_market_qty_total = entry.observed_market_qty_total,
    standard_value = entry.standard_value
  }
end

function inventory.get_pricing_data(state, commodity)
  local entry = ensure_entry(state, commodity)
  return {
    commodity = commodity,
    standard_value = entry.standard_value,
    observed_market_avg = entry.observed_market_avg,
    observed_market_count = tonumber(entry.observed_market_count) or 0,
    observed_market_qty_total = tonumber(entry.observed_market_qty_total) or 0,
    unit_wac = entry.qty > 0 and entry.unit_cost or 0,
    qty = entry.qty or 0
  }
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
