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

local function sum_design_capital_initial(state, source_id)
  local total = 0
  for _, event in ipairs(get_events(state)) do
    if event.event_type == "DESIGN_COST" and event.payload then
      local payload_id = event.payload.source_id or event.payload.design_id
      if payload_id == source_id then
        total = total + (event.payload.amount or 0)
      end
    end
  end
  return total
end

local function get_source_for_item(state, item)
  if not item then
    return nil
  end

  local source_id = item.source_id
  if not source_id then
    return nil
  end

  return state.production_sources and state.production_sources[source_id] or nil
end

local function sum_process_losses(state)
  local total = 0
  for _, event in ipairs(get_events(state)) do
    if (event.event_type == "PROCESS_WRITE_OFF" or event.event_type == "FORGE_WRITE_OFF") and event.payload then
      total = total + (event.payload.amount_gold or 0)
    end
  end
  return total
end

local function unallocated_forge_session_costs(state)
  local total = 0
  local in_flight_count = 0
  for _, session in pairs(state.forge_sessions or {}) do
    if session.status == "in_flight" then
      in_flight_count = in_flight_count + 1
      local allocated = 0
      local attached = state.forge_session_items and state.forge_session_items[session.forge_session_id] or {}
      for _, amount in pairs(attached or {}) do
        allocated = allocated + (amount or 0)
      end
      local remainder = (session.coal_basis_gold or 0) - allocated
      if remainder > 0 then
        total = total + remainder
      end
    end
  end
  return total, in_flight_count
end

local function pending_forge_item_count(state)
  local count = 0
  for _, item in pairs(state.crafted_items or {}) do
    if item.pending_forge_session_id then
      count = count + 1
    end
  end
  return count
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

local function unsold_items_value(state, source_id)
  local sold_items = {}
  for _, sale in pairs(state.sales or {}) do
    sold_items[sale.item_id] = true
  end

  local total = 0
  local count = 0
  for _, item in pairs(state.crafted_items or {}) do
    if not sold_items[item.item_id] then
      if not source_id or item.source_id == source_id then
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

  local source = get_source_for_item(state, item)

  return {
    sale_id = sale.sale_id,
    item_id = sale.item_id,
    design_id = item.source_id,
    appearance_key = item.appearance_key,
    provenance = source and source.provenance or nil,
    recovery_enabled = source and source.recovery_enabled or nil,
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
  for _, source in pairs(state.production_sources) do
    if source.source_kind == "design" and source.recovery_enabled == 1 then
      total = total + (source.capital_remaining or 0)
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
  local process_losses = sum_process_losses(state)

  local design_remaining = outstanding_design_capital(state)
  local pattern_remaining = outstanding_pattern_capital(state)

  local warnings = build_base_warnings(state, opts)
  local inventory_total, inventory_warning = inventory_value(state)
  if inventory_warning then
    table.insert(warnings, inventory_warning)
  end
  local wip_total = wip_value(state)
  local forge_unallocated, forge_in_flight = unallocated_forge_session_costs(state)
  local unsold_total, unsold_count = unsold_items_value(state)
  local pending_forge_items = pending_forge_item_count(state)
  if design_remaining > 0 then
    table.insert(warnings, "WARNING: Design capital remaining > 0")
  end
  if pattern_remaining > 0 then
    table.insert(warnings, "WARNING: Pattern capital remaining > 0")
  end
  if forge_in_flight > 0 then
    table.insert(warnings, "WARNING: Forge sessions in flight")
  end
  if pending_forge_items > 0 then
    table.insert(warnings, "WARNING: Items with pending forge session allocation")
  end

  totals.process_losses = process_losses
  totals.true_profit = totals.true_profit - process_losses

  return {
    totals = totals,
    sales = sales,
    design_remaining = design_remaining,
    pattern_remaining = pattern_remaining,
    holdings = {
      inventory_value = inventory_total,
      wip_value = wip_total,
      unallocated_forge_session_costs = forge_unallocated > 0 and forge_unallocated or nil,
      unsold_items_value = (unsold_count and unsold_count > 0) and unsold_total or nil,
      process_losses = process_losses
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
  local process_losses = sum_process_losses(state)
  local design_remaining = outstanding_design_capital(state)
  local pattern_remaining = outstanding_pattern_capital(state)

  local warnings = build_base_warnings(state, opts)
  local inventory_total, inventory_warning = inventory_value(state)
  if inventory_warning then
    table.insert(warnings, inventory_warning)
  end
  local wip_total = wip_value(state)
  local forge_unallocated, forge_in_flight = unallocated_forge_session_costs(state)
  local unsold_total, unsold_count = unsold_items_value(state)
  local pending_forge_items = pending_forge_item_count(state)
  if unknown_time then
    table.insert(warnings, "WARNING: Some sales have unknown game time and were excluded")
  end
  if design_remaining > 0 then
    table.insert(warnings, "WARNING: Design capital remaining > 0")
  end
  if pattern_remaining > 0 then
    table.insert(warnings, "WARNING: Pattern capital remaining > 0")
  end
  if forge_in_flight > 0 then
    table.insert(warnings, "WARNING: Forge sessions in flight")
  end
  if pending_forge_items > 0 then
    table.insert(warnings, "WARNING: Items with pending forge session allocation")
  end

  totals.process_losses = process_losses
  totals.true_profit = totals.true_profit - process_losses

  return {
    year = year,
    totals = totals,
    sales = sales,
    holdings = {
      inventory_value = inventory_total,
      wip_value = wip_total,
      unallocated_forge_session_costs = forge_unallocated > 0 and forge_unallocated or nil,
      unsold_items_value = (unsold_count and unsold_count > 0) and unsold_total or nil,
      process_losses = process_losses
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
  local source = state.production_sources[design_id]
  if not source or source.source_kind ~= "design" then
    error("Design " .. design_id .. " not found")
  end

  local year_filter = opts.year
  local unknown_time = false
  local sales = collect_sales(state, function(sale)
    local item = state.crafted_items[sale.item_id]
    if not item or item.source_id ~= design_id then
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
    if item.source_id == design_id then
      crafted_count = crafted_count + 1
    end
  end

  local totals = sum_totals(sales)

  local pattern_remaining = nil
  if source.pattern_pool_id and state.pattern_pools[source.pattern_pool_id] then
    pattern_remaining = state.pattern_pools[source.pattern_pool_id].capital_remaining_gold
  end

  local warnings = build_base_warnings(state, opts)
  if unknown_time and year_filter then
    table.insert(warnings, "WARNING: Some sales have unknown game time and were excluded")
  end

  local unresolved = false
  for _, item in pairs(state.crafted_items) do
    if not item.source_id and item.appearance_key then
      local mapping = state.appearance_aliases[item.appearance_key]
      if mapping and mapping.source_id == design_id then
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
    design_id = source.source_id,
    name = source.name,
    design_type = source.source_type,
    provenance = source.provenance,
    recovery_enabled = source.recovery_enabled,
    pattern_pool_id = source.pattern_pool_id,
    per_item_fee_gold = source.per_item_fee_gold,
    design_capital_initial = sum_design_capital_initial(state, source.source_id),
    design_capital_remaining = source.capital_remaining or 0,
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
        if item and item.source_id == design_id and not seen[order_id] then
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
