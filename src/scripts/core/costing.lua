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

  local get_unit_cost = opts.get_unit_cost or function(_)
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

local function sorted_output_rows(outputs)
  local rows = {}
  if type(outputs) ~= "table" then
    return rows
  end

  for commodity, qty in pairs(outputs) do
    local normalized_qty = tonumber(qty) or 0
    if normalized_qty > 0 then
      table.insert(rows, {
        commodity = commodity,
        qty = normalized_qty
      })
    end
  end

  table.sort(rows, function(left, right)
    return tostring(left.commodity) < tostring(right.commodity)
  end)

  return rows
end

local function legacy_process_output_basis(material_input_cost, direct_fee_gold, time_cost_gold, committed_qty, commodity_count, total_output_qty)
  local material_total = tonumber(material_input_cost) or 0
  local fee_total = (tonumber(direct_fee_gold) or 0) + (tonumber(time_cost_gold) or 0)
  local output_qty = tonumber(total_output_qty) or 0

  if output_qty <= 0 or (material_total + fee_total) <= 0 then
    return 0
  end

  if commodity_count == 0 or committed_qty <= 0 then
    return material_total + fee_total
  end

  if commodity_count > 1 then
    return material_total + fee_total
  end

  local ratio = output_qty / committed_qty
  if ratio > 1 then
    ratio = 1
  end

  return (material_total * ratio) + fee_total
end

local function revenue_adjusted_output_basis(net_offsettable_cost, time_cost_gold, committed_qty, commodity_count, total_output_qty)
  local offsettable_total = tonumber(net_offsettable_cost) or 0
  local time_total = tonumber(time_cost_gold) or 0
  local output_qty = tonumber(total_output_qty) or 0

  if output_qty <= 0 or (offsettable_total + time_total) <= 0 then
    return 0
  end

  if commodity_count == 0 or committed_qty <= 0 then
    return offsettable_total + time_total
  end

  if commodity_count > 1 then
    return offsettable_total + time_total
  end

  local ratio = output_qty / committed_qty
  if ratio > 1 then
    ratio = 1
  end

  return (offsettable_total * ratio) + time_total
end

function costing.allocate_process_outputs(opts)
  opts = opts or {}

  local material_input_cost = tonumber(opts.material_input_cost) or 0
  local direct_fee_gold = tonumber(opts.direct_fee_gold) or 0
  local time_cost_gold = tonumber(opts.time_cost_gold) or 0
  local revenue_gold = tonumber(opts.revenue_gold) or 0
  local committed_qty = tonumber(opts.committed_qty) or 0
  local commodity_count = tonumber(opts.commodity_count) or 0
  local output_rows = sorted_output_rows(opts.outputs)
  local total_output_qty = 0
  local inventory_output_count = #output_rows
  local gold_output_value = 0

  for _, row in ipairs(output_rows) do
    total_output_qty = total_output_qty + row.qty
    if inventory_output_count > 1 and row.commodity == "gold" then
      gold_output_value = gold_output_value + row.qty
    end
  end

  local material_pool = math.max(material_input_cost - gold_output_value, 0)
  local offsettable_cost = material_pool + direct_fee_gold
  local revenue_offset_applied = math.min(revenue_gold, offsettable_cost)
  local net_offsettable_cost = math.max(offsettable_cost - revenue_offset_applied, 0)
  local realized_surplus_gold = math.max(revenue_gold - offsettable_cost, 0)

  if inventory_output_count <= 1 then
    local committed_basis_for_outputs = material_input_cost + direct_fee_gold + time_cost_gold
    local capitalizable_basis = committed_basis_for_outputs
    local output_basis = 0

    if revenue_offset_applied > 0 and total_output_qty > 0 then
      capitalizable_basis = net_offsettable_cost + time_cost_gold
      output_basis = revenue_adjusted_output_basis(
        net_offsettable_cost,
        time_cost_gold,
        committed_qty,
        commodity_count,
        total_output_qty
      )
    else
      output_basis = legacy_process_output_basis(
        material_input_cost,
        direct_fee_gold,
        time_cost_gold,
        committed_qty,
        commodity_count,
        total_output_qty
      )
    end

    local output_unit_cost = 0
    if total_output_qty > 0 then
      output_unit_cost = output_basis / total_output_qty
    end

    local allocations = {}
    for _, row in ipairs(output_rows) do
      allocations[row.commodity] = {
        qty = row.qty,
        total_cost = row.qty * output_unit_cost,
        unit_cost = output_unit_cost,
        weight = row.qty
      }
    end

    return {
      mode = "legacy_single_output",
      inventory_output_count = inventory_output_count,
      total_output_qty = total_output_qty,
      gold_output_value = 0,
      material_pool = material_input_cost,
      offsettable_cost = material_input_cost + direct_fee_gold,
      revenue_offset_applied = revenue_offset_applied,
      net_offsettable_cost = revenue_offset_applied > 0 and net_offsettable_cost or (material_input_cost + direct_fee_gold),
      realized_surplus_gold = realized_surplus_gold,
      allocatable_cost = output_basis,
      committed_basis_for_outputs = revenue_offset_applied > 0 and capitalizable_basis or committed_basis_for_outputs,
      output_basis_total = output_basis,
      process_loss_gold = math.max((revenue_offset_applied > 0 and capitalizable_basis or committed_basis_for_outputs) - output_basis, 0),
      output_unit_cost = output_unit_cost,
      output_allocations = allocations
    }
  end

  local get_standard_value = opts.get_standard_value or function(_)
    return nil
  end
  local weighted_rows = {}
  local total_weight = 0

  for _, row in ipairs(output_rows) do
    if row.commodity ~= "gold" then
      local standard_value = get_standard_value(row.commodity)
      if standard_value == nil then
        error("Process allocation requires standard_value for commodity '" .. tostring(row.commodity) .. "'")
      end
      standard_value = tonumber(standard_value)
      if standard_value == nil then
        error("Process allocation requires standard_value for commodity '" .. tostring(row.commodity) .. "'")
      end
      local weight = row.qty * standard_value
      table.insert(weighted_rows, {
        commodity = row.commodity,
        qty = row.qty,
        standard_value = standard_value,
        weight = weight
      })
      total_weight = total_weight + weight
    end
  end

  if #weighted_rows == 0 then
    error("Process allocation requires at least one non-gold output commodity with standard_value")
  end
  if total_weight <= 0 then
    error("Process allocation requires positive standard_value weights for output commodities")
  end

  material_pool = math.max(material_input_cost - gold_output_value, 0)
  offsettable_cost = material_pool + direct_fee_gold
  revenue_offset_applied = math.min(revenue_gold, offsettable_cost)
  net_offsettable_cost = math.max(offsettable_cost - revenue_offset_applied, 0)
  realized_surplus_gold = math.max(revenue_gold - offsettable_cost, 0)

  local allocatable_cost = net_offsettable_cost + time_cost_gold
  local allocations = {}
  local output_basis_total = 0

  for _, row in ipairs(weighted_rows) do
    local total_cost = allocatable_cost * (row.weight / total_weight)
    local unit_cost = total_cost / row.qty
    allocations[row.commodity] = {
      qty = row.qty,
      total_cost = total_cost,
      unit_cost = unit_cost,
      weight = row.weight,
      standard_value = row.standard_value
    }
    output_basis_total = output_basis_total + total_cost
  end

  if gold_output_value > 0 then
    allocations.gold = {
      qty = gold_output_value,
      total_cost = 0,
      unit_cost = 0,
      weight = 0
    }
  end

  return {
    mode = "standard_value_multi_output",
    inventory_output_count = inventory_output_count,
    total_output_qty = total_output_qty,
    gold_output_value = gold_output_value,
    material_pool = material_pool,
    offsettable_cost = offsettable_cost,
    revenue_offset_applied = revenue_offset_applied,
    net_offsettable_cost = net_offsettable_cost,
    realized_surplus_gold = realized_surplus_gold,
    allocatable_cost = allocatable_cost,
    committed_basis_for_outputs = net_offsettable_cost + time_cost_gold,
    output_basis_total = output_basis_total,
    process_loss_gold = math.max((net_offsettable_cost + time_cost_gold) - output_basis_total, 0),
    output_unit_cost = nil,
    output_allocations = allocations
  }
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