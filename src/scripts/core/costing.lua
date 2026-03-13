-- Shared pure costing helpers for Achaeadex Ledger

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local costing = _G.AchaeadexLedger.Core.Costing or {}

local STANDARD_BREAKDOWN_KEYS = {
  "materials_cost_gold",
  "per_item_fee_gold",
  "time_cost_gold",
  "direct_fee_gold",
  "allocated_session_cost_gold",
  "carried_basis_gold"
}

local function copy_table(source)
  local target = {}
  if type(source) ~= "table" then
    return target
  end

  for key, value in pairs(source) do
    target[key] = value
  end

  return target
end

local function round_non_negative(value)
  local number = tonumber(value) or 0
  if number <= 0 then
    return 0
  end
  return math.floor(number + 0.999999999)
end

local function floor_div(a, b)
  if a >= 0 then
    return math.floor(a / b)
  end
  return math.ceil(a / b)
end

local function days_from_civil(year, month, day)
  year = tonumber(year)
  month = tonumber(month)
  day = tonumber(day)

  if not year or not month or not day then
    return nil
  end

  if month <= 2 then
    year = year - 1
  end

  local era = floor_div(year >= 0 and year or (year - 399), 400)
  local yoe = year - era * 400
  local month_prime = month + (month > 2 and -3 or 9)
  local doy = math.floor((153 * month_prime + 2) / 5) + day - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy

  return era * 146097 + doe - 719468
end

local function civil_from_days(days)
  local z = tonumber(days)
  if not z then
    return nil
  end

  z = z + 719468
  local era = floor_div(z >= 0 and z or (z - 146096), 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local year = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local day = doy - math.floor((153 * mp + 2) / 5) + 1
  local month = mp + (mp < 10 and 3 or -9)

  if month <= 2 then
    year = year + 1
  end

  return year, month, day
end

function costing.iso8601_to_epoch_seconds(timestamp)
  if type(timestamp) ~= "string" then
    return nil
  end

  local year, month, day, hour, minute, second = timestamp:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
  if not year then
    return nil
  end

  local days = days_from_civil(year, month, day)
  if not days then
    return nil
  end

  return days * 86400
    + tonumber(hour) * 3600
    + tonumber(minute) * 60
    + tonumber(second)
end

function costing.epoch_seconds_to_iso8601(epoch_seconds)
  local total = tonumber(epoch_seconds)
  if not total then
    return nil
  end

  local days = floor_div(total, 86400)
  local day_seconds = total - (days * 86400)
  if day_seconds < 0 then
    days = days - 1
    day_seconds = day_seconds + 86400
  end

  local year, month, day = civil_from_days(days)
  if not year then
    return nil
  end

  local hour = math.floor(day_seconds / 3600)
  local minute = math.floor((day_seconds % 3600) / 60)
  local second = day_seconds % 60

  return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day, hour, minute, second)
end

function costing.shift_iso8601_seconds(timestamp, delta_seconds)
  local epoch = costing.iso8601_to_epoch_seconds(timestamp)
  if not epoch then
    return nil
  end

  return costing.epoch_seconds_to_iso8601(epoch + (tonumber(delta_seconds) or 0))
end

function costing.elapsed_seconds(started_at, ended_at)
  local start_seconds = costing.iso8601_to_epoch_seconds(started_at)
  local end_seconds = costing.iso8601_to_epoch_seconds(ended_at)
  if not start_seconds or not end_seconds then
    return nil
  end
  return end_seconds - start_seconds
end

function costing.compute_materials_cost(entries)
  if type(entries) == "number" then
    return entries
  end

  local total = 0
  if type(entries) ~= "table" then
    return total
  end

  for _, entry in ipairs(entries) do
    if type(entry) == "table" then
      total = total + ((tonumber(entry.total_cost) or 0))
    end
  end

  return total
end

function costing.compute_materials_breakdown(materials, opts)
  opts = opts or {}

  local get_unit_cost = opts.get_unit_cost or function()
    return 0
  end
  local get_available_qty = opts.get_available_qty
  local validate_qty = opts.validate_qty ~= false

  local material_lines = {}
  local missing_wac_count = 0
  local total = 0

  if type(materials) ~= "table" then
    return {
      materials_cost_gold = 0,
      material_lines = material_lines,
      missing_wac_count = 0
    }
  end

  local keys = {}
  for commodity in pairs(materials) do
    table.insert(keys, commodity)
  end
  table.sort(keys)

  for _, commodity in ipairs(keys) do
    local qty = tonumber(materials[commodity]) or 0
    if validate_qty and qty <= 0 then
      error("Material quantity must be positive for " .. tostring(commodity))
    end

    if get_available_qty and qty > 0 then
      local available = tonumber(get_available_qty(commodity)) or 0
      if available < qty then
        error("Insufficient " .. tostring(commodity) .. ": have " .. tostring(available) .. ", need " .. tostring(qty))
      end
    end

    local unit_wac = tonumber(get_unit_cost(commodity)) or 0
    local subtotal = qty * unit_wac
    if qty > 0 and unit_wac <= 0 then
      missing_wac_count = missing_wac_count + 1
    end

    table.insert(material_lines, {
      commodity = commodity,
      qty = qty,
      unit_wac = unit_wac,
      subtotal = subtotal
    })

    total = total + subtotal
  end

  return {
    materials_cost_gold = total,
    material_lines = material_lines,
    missing_wac_count = missing_wac_count
  }
end

function costing.compute_time_cost(elapsed_seconds, rate_gold_per_hour)
  local seconds = tonumber(elapsed_seconds) or 0
  local rate = tonumber(rate_gold_per_hour) or 0
  if seconds <= 0 or rate <= 0 then
    return {
      elapsed_seconds = math.max(seconds, 0),
      elapsed_hours = 0,
      rate_gold_per_hour = math.max(rate, 0),
      amount_gold = 0
    }
  end

  local elapsed_hours = seconds / 3600
  local amount_gold = round_non_negative((seconds * rate) / 3600)

  return {
    elapsed_seconds = seconds,
    elapsed_hours = elapsed_hours,
    rate_gold_per_hour = rate,
    amount_gold = amount_gold
  }
end

function costing.compute_time_cost_from_hours(hours, rate_gold_per_hour)
  local time_hours = tonumber(hours) or 0
  if time_hours <= 0 then
    return costing.compute_time_cost(0, rate_gold_per_hour)
  end

  local elapsed_seconds = math.floor(time_hours * 3600)
  return costing.compute_time_cost(elapsed_seconds, rate_gold_per_hour)
end

function costing.standardize_breakdown(existing, overrides)
  local breakdown = copy_table(existing)

  if type(overrides) == "table" then
    for key, value in pairs(overrides) do
      breakdown[key] = value
    end
  end

  for _, key in ipairs(STANDARD_BREAKDOWN_KEYS) do
    breakdown[key] = tonumber(breakdown[key]) or 0
  end

  breakdown.total_operational_cost_gold = breakdown.materials_cost_gold
    + breakdown.per_item_fee_gold
    + breakdown.time_cost_gold
    + breakdown.direct_fee_gold
    + breakdown.allocated_session_cost_gold
    + breakdown.carried_basis_gold

  return breakdown
end

function costing.compute_process_cost_breakdown(opts)
  local breakdown = costing.standardize_breakdown(nil, {
    materials_cost_gold = opts and opts.materials_cost_gold,
    time_cost_gold = opts and opts.time_cost_gold,
    direct_fee_gold = opts and opts.direct_fee_gold
  })

  if opts then
    breakdown.elapsed_seconds = tonumber(opts.elapsed_seconds) or 0
    breakdown.rate_gold_per_hour = tonumber(opts.rate_gold_per_hour) or 0
    breakdown.inputs = opts.inputs
    breakdown.outputs = opts.outputs
    breakdown.passive = opts.passive and 1 or 0
  end

  return breakdown
end

function costing.compute_craft_cost_breakdown(opts)
  local breakdown = costing.standardize_breakdown(nil, {
    materials_cost_gold = opts and opts.materials_cost_gold,
    per_item_fee_gold = opts and opts.per_item_fee_gold,
    time_cost_gold = opts and opts.time_cost_gold,
    direct_fee_gold = opts and opts.direct_fee_gold,
    allocated_session_cost_gold = opts and opts.allocated_session_cost_gold,
    carried_basis_gold = opts and opts.carried_basis_gold
  })

  if opts then
    breakdown.materials_source = opts.materials_source
    breakdown.materials = opts.materials
    breakdown.time_hours = tonumber(opts.time_hours) or 0
    breakdown.transform_kind = opts.transform_kind
    breakdown.parent_item_id = opts.parent_item_id
  end

  return breakdown
end

_G.AchaeadexLedger.Core.Costing = costing

return costing