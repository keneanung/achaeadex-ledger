-- Core reporting for Achaeadex Ledger

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local reports = _G.AchaeadexLedger.Core.Reports or {}

local function get_inventory()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.Inventory then
    error("AchaeadexLedger.Core.Inventory is not loaded")
  end

  return _G.AchaeadexLedger.Core.Inventory
end

local function get_events(state)
  if not state.event_store or type(state.event_store.read_all) ~= "function" then
    return {}
  end
  return state.event_store:read_all()
end

local function has_opening_inventory(state)
  for _, event in ipairs(get_events(state)) do
    if event.event_type == "OPENING_INVENTORY" then
      return true
    end
  end
  return false
end

local function sum_design_capital_initial(state, design_id)
  local total = 0
  for _, event in ipairs(get_events(state)) do
    if event.event_type == "DESIGN_COST" and event.payload and event.payload.design_id == design_id then
      total = total + (event.payload.amount or 0)
    end
  end
  return total
end

local function inventory_value(state)
  local ok, result = pcall(function()
    local inventory = get_inventory()
    local data = inventory.get_all(state.inventory)
    local total = 0
    for _, values in pairs(data) do
      total = total + (values.qty * values.unit_cost)
    end
    return total
  end)

  if not ok then
    return nil, "WARNING: Inventory value incomplete"
  end

  return result
end

local function wip_value(state)
  local total = 0
  local has_wip = false

  for _, instance in pairs(state.process_instances or {}) do
    if instance.status == "in_flight" then
      has_wip = true
      total = total + (instance.committed_cost_total or 0) + (instance.fees_total or 0)
    end
  end

  if not has_wip then
    return nil
  end

  return total
end

local function unsold_items_value(state, design_id)
  local sold_items = {}
  for _, sale in pairs(state.sales or {}) do
    sold_items[sale.item_id] = true
  end

  local total = 0
  local count = 0
  for _, item in pairs(state.crafted_items or {}) do
    if not sold_items[item.item_id] then
      if not design_id or item.design_id == design_id then
        total = total + (item.operational_cost_gold or 0)
        count = count + 1
      end
    end
  end

  return total, count
end

local function build_base_warnings(state, opts)
  local warnings = {}
  if has_opening_inventory(state) then
    table.insert(warnings, "WARNING: Opening inventory uses MtM")
  end
  local time_cost_per_hour = 0
  if opts and type(opts.time_cost_per_hour) == "number" then
    time_cost_per_hour = opts.time_cost_per_hour
  end
  if time_cost_per_hour == 0 then
    table.insert(warnings, "WARNING: Time cost = 0")
  end
  return warnings
end

local function sale_breakdown(state, sale)
  local item = state.crafted_items[sale.item_id]
  if not item then
    error("Crafted item " .. tostring(sale.item_id) .. " not found")
  end

  local design = item.design_id and state.designs[item.design_id] or nil

  return {
    sale_id = sale.sale_id,
    item_id = sale.item_id,
    design_id = item.design_id,
    appearance_key = item.appearance_key,
    provenance = design and design.provenance or nil,
    recovery_enabled = design and design.recovery_enabled or nil,
    sold_at = sale.sold_at,
    sale_price_gold = sale.sale_price_gold,
    operational_cost_gold = item.operational_cost_gold,
    operational_profit = sale.operational_profit or (sale.sale_price_gold - item.operational_cost_gold),
    applied_to_design_capital = sale.applied_to_design_capital or 0,
    applied_to_pattern_capital = sale.applied_to_pattern_capital or 0,
    true_profit = sale.true_profit or 0,
    game_time = sale.game_time
  }
end

local function collect_sales(state, predicate)
  local sales = {}
  for _, sale in pairs(state.sales) do
    if not predicate or predicate(sale) then
      table.insert(sales, sale_breakdown(state, sale))
    end
  end
  return sales
end

local function collect_sales_by_ids(state, sale_ids)
  local sales = {}
  for sale_id, _ in pairs(sale_ids or {}) do
    local sale = state.sales[sale_id]
    if sale then
      table.insert(sales, sale_breakdown(state, sale))
    end
  end
  return sales
end

local function sum_totals(sales)
  local totals = {
    revenue = 0,
    operational_cost = 0,
    operational_profit = 0,
    applied_to_design_capital = 0,
    applied_to_pattern_capital = 0,
    true_profit = 0
  }

  for _, sale in ipairs(sales) do
    totals.revenue = totals.revenue + (sale.sale_price_gold or 0)
    totals.operational_cost = totals.operational_cost + (sale.operational_cost_gold or 0)
    totals.operational_profit = totals.operational_profit + (sale.operational_profit or 0)
    totals.applied_to_design_capital = totals.applied_to_design_capital + (sale.applied_to_design_capital or 0)
    totals.applied_to_pattern_capital = totals.applied_to_pattern_capital + (sale.applied_to_pattern_capital or 0)
    totals.true_profit = totals.true_profit + (sale.true_profit or 0)
  end

  return totals
end

local function outstanding_design_capital(state)
  local total = 0
  for _, design in pairs(state.designs) do
    if design.recovery_enabled == 1 then
      total = total + (design.capital_remaining or 0)
    end
  end
  return total
end

local function outstanding_pattern_capital(state)
  local total = 0
  for _, pool in pairs(state.pattern_pools) do
    total = total + (pool.capital_remaining_gold or 0)
  end
  return total
end

function reports.overall(state, opts)
  local sales = collect_sales(state)
  local totals = sum_totals(sales)

  local design_remaining = outstanding_design_capital(state)
  local pattern_remaining = outstanding_pattern_capital(state)

  local warnings = build_base_warnings(state, opts)
  local inventory_total, inventory_warning = inventory_value(state)
  if inventory_warning then
    table.insert(warnings, inventory_warning)
  end
  local wip_total = wip_value(state)
  local unsold_total, unsold_count = unsold_items_value(state)
  if design_remaining > 0 then
    table.insert(warnings, "WARNING: Design capital remaining > 0")
  end
  if pattern_remaining > 0 then
    table.insert(warnings, "WARNING: Pattern capital remaining > 0")
  end

  return {
    totals = totals,
    sales = sales,
    design_remaining = design_remaining,
    pattern_remaining = pattern_remaining,
    holdings = {
      inventory_value = inventory_total,
      wip_value = wip_total,
      unsold_items_value = (unsold_count and unsold_count > 0) and unsold_total or nil
    },
    warnings = warnings
  }
end

function reports.year(state, year, opts)
  local unknown_time = false
  local sales = collect_sales(state, function(sale)
    local game_time = sale.game_time
    if not game_time or not game_time.year then
      unknown_time = true
      return false
    end
    return tonumber(game_time.year) == tonumber(year)
  end)

  local totals = sum_totals(sales)
  local design_remaining = outstanding_design_capital(state)
  local pattern_remaining = outstanding_pattern_capital(state)

  local warnings = build_base_warnings(state, opts)
  local inventory_total, inventory_warning = inventory_value(state)
  if inventory_warning then
    table.insert(warnings, inventory_warning)
  end
  local wip_total = wip_value(state)
  local unsold_total, unsold_count = unsold_items_value(state)
  if unknown_time then
    table.insert(warnings, "WARNING: Some sales have unknown game time and were excluded")
  end
  if design_remaining > 0 then
    table.insert(warnings, "WARNING: Design capital remaining > 0")
  end
  if pattern_remaining > 0 then
    table.insert(warnings, "WARNING: Pattern capital remaining > 0")
  end

  return {
    year = year,
    totals = totals,
    sales = sales,
    holdings = {
      inventory_value = inventory_total,
      wip_value = wip_total,
      unsold_items_value = (unsold_count and unsold_count > 0) and unsold_total or nil
    },
    warnings = warnings
  }
end

function reports.order(state, order_id, opts)
  local order = state.orders[order_id]
  if not order then
    error("Order " .. order_id .. " not found")
  end

  local sales = collect_sales_by_ids(state, state.order_sales[order_id])
  local totals = sum_totals(sales)

  local design_remaining = outstanding_design_capital(state)
  local pattern_remaining = outstanding_pattern_capital(state)

  local warnings = build_base_warnings(state, opts)
  if design_remaining > 0 then
    table.insert(warnings, "WARNING: Design capital remaining > 0")
  end
  if pattern_remaining > 0 then
    table.insert(warnings, "WARNING: Pattern capital remaining > 0")
  end

  local missing_design = false
  for _, sale in ipairs(sales) do
    if not sale.design_id then
      missing_design = true
      break
    end
  end
  if missing_design then
    table.insert(warnings, "WARNING: Some sales have unknown design mapping")
  end

  return {
    order = order,
    sales = sales,
    totals = totals,
    note = "Holdings not shown for order scope.",
    warnings = warnings
  }
end

function reports.design(state, design_id, opts)
  opts = opts or {}
  local design = state.designs[design_id]
  if not design then
    error("Design " .. design_id .. " not found")
  end

  local year_filter = opts.year
  local unknown_time = false
  local sales = collect_sales(state, function(sale)
    local item = state.crafted_items[sale.item_id]
    if not item or item.design_id ~= design_id then
      return false
    end
    if not year_filter then
      return true
    end
    local game_time = sale.game_time
    if not game_time or not game_time.year then
      unknown_time = true
      return false
    end
    return tonumber(game_time.year) == tonumber(year_filter)
  end)

  local crafted_count = 0
  for _, item in pairs(state.crafted_items) do
    if item.design_id == design_id then
      crafted_count = crafted_count + 1
    end
  end

  local totals = sum_totals(sales)

  local pattern_remaining = nil
  if design.pattern_pool_id and state.pattern_pools[design.pattern_pool_id] then
    pattern_remaining = state.pattern_pools[design.pattern_pool_id].capital_remaining_gold
  end

  local warnings = build_base_warnings(state, opts)
  if unknown_time and year_filter then
    table.insert(warnings, "WARNING: Some sales have unknown game time and were excluded")
  end

  local unresolved = false
  for _, item in pairs(state.crafted_items) do
    if not item.design_id and item.appearance_key then
      local mapping = state.appearance_aliases[item.appearance_key]
      if mapping and mapping.design_id == design_id then
        unresolved = true
        break
      end
    end
  end
  if unresolved then
    table.insert(warnings, "WARNING: Design has unresolved crafts")
  end

  local unsold_value = unsold_items_value(state, design_id)

  local report = {
    design_id = design.design_id,
    name = design.name,
    design_type = design.design_type,
    provenance = design.provenance,
    recovery_enabled = design.recovery_enabled,
    pattern_pool_id = design.pattern_pool_id,
    per_item_fee_gold = design.per_item_fee_gold,
    design_capital_initial = sum_design_capital_initial(state, design.design_id),
    design_capital_remaining = design.capital_remaining or 0,
    pattern_capital_remaining = pattern_remaining,
    unsold_items_value = unsold_value,
    crafted_count = crafted_count,
    sold_count = #sales,
    totals = totals,
    sales = sales,
    warnings = warnings
  }

  if opts.include_orders then
    local order_ids = {}
    local seen = {}
    for sale_id, order_id in pairs(state.sale_orders) do
      local sale = state.sales[sale_id]
      if sale then
        local item = state.crafted_items[sale.item_id]
        if item and item.design_id == design_id and not seen[order_id] then
          seen[order_id] = true
          table.insert(order_ids, order_id)
        end
      end
    end
    report.order_ids = order_ids
  end

  return report
end

_G.AchaeadexLedger.Core.Reports = reports

return reports
