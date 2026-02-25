-- Core reporting for Achaeadex Ledger

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local reports = _G.AchaeadexLedger.Core.Reports or {}

local function round_gold(value)
  local n = tonumber(value) or 0
  if n >= 0 then
    return math.floor(n + 0.5)
  end
  return math.ceil(n - 0.5)
end

local function merge_qty_map(target, values)
  for key, qty in pairs(values or {}) do
    target[key] = (target[key] or 0) + (qty or 0)
  end
end

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

local function resolve_process_override_game_time(state, process_instance_id, scope)
  local overrides = state.process_game_time_overrides and state.process_game_time_overrides[process_instance_id] or nil
  if not overrides then
    return nil
  end
  local scoped = overrides[scope]
  if scoped and scoped.game_time and scoped.game_time.year then
    return scoped.game_time
  end
  local fallback = overrides.all
  if fallback and fallback.game_time and fallback.game_time.year then
    return fallback.game_time
  end
  return nil
end

local function resolve_process_write_off_year(state, process_instance_id, payload)
  local payload_time = payload and payload.game_time or nil
  if payload_time and payload_time.year then
    return tonumber(payload_time.year)
  end
  local override_time = resolve_process_override_game_time(state, process_instance_id, "write_off")
  if override_time and override_time.year then
    return tonumber(override_time.year)
  end
  return nil
end

local function process_write_off_summary(state, year)
  local summary = {
    total = 0,
    year_total = 0,
    attributed_total = 0,
    unattributed_total = 0,
    unattributed_count = 0,
    unattributed_entries = {}
  }

  for _, event in ipairs(get_events(state)) do
    local payload = event.payload or {}
    if event.event_type == "PROCESS_WRITE_OFF" then
      local amount = round_gold(payload.amount_gold)
      local process_instance_id = payload.process_instance_id
      local resolved_year = resolve_process_write_off_year(state, process_instance_id, payload)

      summary.total = summary.total + amount
      if resolved_year then
        summary.attributed_total = summary.attributed_total + amount
        if year and tonumber(resolved_year) == tonumber(year) then
          summary.year_total = summary.year_total + amount
        end
      else
        summary.unattributed_total = summary.unattributed_total + amount
        summary.unattributed_count = summary.unattributed_count + 1
        table.insert(summary.unattributed_entries, {
          process_instance_id = process_instance_id,
          amount_gold = amount,
          at = event.ts
        })
      end
    elseif event.event_type == "FORGE_WRITE_OFF" then
      local amount = round_gold(payload.amount_gold)
      summary.total = summary.total + amount
      summary.unattributed_total = summary.unattributed_total + amount
    end
  end

  return summary
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

local function external_items_holdings(state)
  local total = 0
  local count = 0
  local has_mtm = false
  local has_unknown = false
  for _, item in pairs(state.external_items or {}) do
    if (item.status or "active") == "active" then
      total = total + (item.basis_gold or 0)
      count = count + 1
      if item.basis_source == "mtm" then
        has_mtm = true
      end
      if item.basis_source == "unknown" then
        has_unknown = true
      end
    end
  end
  return total, count, has_mtm, has_unknown
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
  local external = nil
  if not item then
    external = state.external_items and state.external_items[sale.item_id] or nil
    if not external then
      error("Item " .. tostring(sale.item_id) .. " not found")
    end
  end

  local source = get_source_for_item(state, item)
  local sale_price = round_gold(sale.sale_price_gold)
  local operational_cost = round_gold(item and item.operational_cost_gold or (external.basis_gold or 0))
  local operational_profit = sale_price - operational_cost
  local true_profit = round_gold(sale.true_profit or operational_profit)

  return {
    sale_id = sale.sale_id,
    item_id = sale.item_id,
    design_id = item and item.source_id or nil,
    appearance_key = item and item.appearance_key or (external and external.name or nil),
    item_kind = item and "crafted" or "external",
    provenance = source and source.provenance or nil,
    recovery_enabled = source and source.recovery_enabled or nil,
    sold_at = sale.sold_at,
    sale_price_gold = sale_price,
    operational_cost_gold = operational_cost,
    operational_profit = operational_profit,
    applied_to_design_capital = round_gold(sale.applied_to_design_capital or 0),
    applied_to_pattern_capital = round_gold(sale.applied_to_pattern_capital or 0),
    true_profit = true_profit,
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

local function collect_commodity_sales_by_ids(state, sale_ids)
  local sales = {}
  for sale_id, _ in pairs(sale_ids or {}) do
    local sale = state.commodity_sales and state.commodity_sales[sale_id] or nil
    if sale then
      table.insert(sales, {
        sale_id = sale.sale_id,
        item_id = nil,
        design_id = nil,
        appearance_key = string.format("%s x%s", tostring(sale.commodity), tostring(sale.qty)),
        item_kind = "commodity",
        commodity = sale.commodity,
        qty = sale.qty,
        unit_price = sale.unit_price,
        provenance = nil,
        recovery_enabled = 0,
        sold_at = sale.sold_at,
        sale_price_gold = sale.revenue or 0,
        operational_cost_gold = sale.cost or 0,
        operational_profit = sale.profit or ((sale.revenue or 0) - (sale.cost or 0)),
        applied_to_design_capital = 0,
        applied_to_pattern_capital = 0,
        true_profit = sale.profit or ((sale.revenue or 0) - (sale.cost or 0)),
        game_time = nil
      })
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
    totals.revenue = totals.revenue + round_gold(sale.sale_price_gold or 0)
    totals.operational_cost = totals.operational_cost + round_gold(sale.operational_cost_gold or 0)
    totals.operational_profit = totals.operational_profit + round_gold(sale.operational_profit or 0)
    totals.applied_to_design_capital = totals.applied_to_design_capital + round_gold(sale.applied_to_design_capital or 0)
    totals.applied_to_pattern_capital = totals.applied_to_pattern_capital + round_gold(sale.applied_to_pattern_capital or 0)
    totals.true_profit = totals.true_profit + round_gold(sale.true_profit or 0)
  end

  totals.operational_profit = totals.revenue - totals.operational_cost

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
  opts = opts or {}
  local sales = collect_sales(state)
  local totals = sum_totals(sales)
  local process_loss_summary = process_write_off_summary(state)
  local process_losses = round_gold(process_loss_summary.total)

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
  local external_total, external_count, ext_mtm, ext_unknown = external_items_holdings(state)
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
  if ext_mtm then
    table.insert(warnings, "WARNING: External items with basis_source=mtm")
  end
  if ext_unknown then
    table.insert(warnings, "WARNING: External items with basis_source=unknown")
  end

  totals.process_losses = process_losses
  totals.process_losses_attributed = round_gold(process_loss_summary.attributed_total)
  totals.process_losses_unattributed = round_gold(process_loss_summary.unattributed_total)
  totals.true_profit = round_gold(totals.true_profit) - process_losses

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
      external_items_holdings = (external_count and external_count > 0) and external_total or nil,
      process_losses = process_losses
    },
    warnings = warnings
  }
end

function reports.year(state, year, opts)
  opts = opts or {}
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
  local process_loss_summary = process_write_off_summary(state, year)
  local process_losses = round_gold(process_loss_summary.total)
  local year_process_losses = round_gold(process_loss_summary.year_total)
  local design_remaining = outstanding_design_capital(state)
  local pattern_remaining = outstanding_pattern_capital(state)

  local warnings = opts.verbose and build_base_warnings(state, opts) or {}
  local inventory_total, inventory_warning = inventory_value(state)
  if inventory_warning then
    table.insert(warnings, inventory_warning)
  end
  local wip_total = wip_value(state)
  local forge_unallocated, forge_in_flight = unallocated_forge_session_costs(state)
  local unsold_total, unsold_count = unsold_items_value(state)
  local external_total, external_count, ext_mtm, ext_unknown = external_items_holdings(state)
  local pending_forge_items = pending_forge_item_count(state)
  if unknown_time and opts.verbose then
    table.insert(warnings, "WARNING: Some sales have unknown game time and were excluded")
  end
  if design_remaining > 0 and opts.verbose then
    table.insert(warnings, "WARNING: Design capital remaining > 0")
  end
  if pattern_remaining > 0 and opts.verbose then
    table.insert(warnings, "WARNING: Pattern capital remaining > 0")
  end
  if forge_in_flight > 0 and opts.verbose then
    table.insert(warnings, "WARNING: Forge sessions in flight")
  end
  if pending_forge_items > 0 and opts.verbose then
    table.insert(warnings, "WARNING: Items with pending forge session allocation")
  end
  if ext_mtm and opts.verbose then
    table.insert(warnings, "WARNING: External items with basis_source=mtm")
  end
  if ext_unknown and opts.verbose then
    table.insert(warnings, "WARNING: External items with basis_source=unknown")
  end

  totals.process_losses = year_process_losses
  totals.true_profit = round_gold(totals.true_profit) - year_process_losses

  local note = nil
  if process_loss_summary.unattributed_count > 0 then
    note = string.format(
      "Note: %d process write-offs are not attributed to a game year. Use 'adex process list --needs-year' and 'adex process set-year ...' to fix.",
      process_loss_summary.unattributed_count
    )
  end

  return {
    year = year,
    totals = totals,
    sales = sales,
    note = note,
    unattributed_process_write_off_count = process_loss_summary.unattributed_count,
    holdings = {
      inventory_value = inventory_total,
      wip_value = wip_total,
      unallocated_forge_session_costs = forge_unallocated > 0 and forge_unallocated or nil,
      unsold_items_value = (unsold_count and unsold_count > 0) and unsold_total or nil,
      external_items_holdings = (external_count and external_count > 0) and external_total or nil,
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
  local commodity_sales = collect_commodity_sales_by_ids(state, state.order_commodity_sales and state.order_commodity_sales[order_id])
  for _, sale in ipairs(commodity_sales) do
    table.insert(sales, sale)
  end

  table.sort(sales, function(a, b)
    local at = a.sold_at or ""
    local bt = b.sold_at or ""
    if at == bt then
      return tostring(a.sale_id) < tostring(b.sale_id)
    end
    return at < bt
  end)

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
    if sale.item_kind == "crafted" and not sale.design_id then
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

function reports.process(state, process_instance_id)
  local instance = state.process_instances and state.process_instances[process_instance_id] or nil
  if not instance then
    error("Process instance " .. tostring(process_instance_id) .. " not found")
  end

  local committed_inputs = {}
  local outputs = {}
  local returned_inputs = {}
  local lost_inputs = {}
  local write_off_total = 0

  for _, event in ipairs(get_events(state)) do
    local payload = event.payload or {}
    if payload.process_instance_id == process_instance_id then
      if event.event_type == "PROCESS_START" then
        merge_qty_map(committed_inputs, payload.inputs)
      elseif event.event_type == "PROCESS_ADD_INPUTS" then
        merge_qty_map(committed_inputs, payload.inputs)
      elseif event.event_type == "PROCESS_COMPLETE" then
        merge_qty_map(outputs, payload.outputs)
      elseif event.event_type == "PROCESS_ABORT" then
        local disposition = payload.disposition or {}
        merge_qty_map(returned_inputs, disposition.returned)
        merge_qty_map(lost_inputs, disposition.lost)
        merge_qty_map(outputs, disposition.outputs)
      elseif event.event_type == "PROCESS_WRITE_OFF" then
        write_off_total = write_off_total + round_gold(payload.amount_gold)
      end
    end
  end

  return {
    process_instance_id = instance.process_instance_id,
    process_id = instance.process_id,
    status = instance.status,
    started_at = instance.started_at,
    completed_at = instance.completed_at,
    note = instance.note,
    committed_inputs = committed_inputs,
    outputs = outputs,
    returned_inputs = returned_inputs,
    lost_inputs = lost_inputs,
    committed_cost_gold = round_gold(instance.committed_cost_total or 0),
    fees_gold = round_gold(instance.fees_total or 0),
    total_committed_gold = round_gold((instance.committed_cost_total or 0) + (instance.fees_total or 0)),
    output_unit_cost_gold = round_gold(instance.output_unit_cost or 0),
    write_off_total_gold = round_gold(write_off_total)
  }
end

function reports.process_write_offs_needing_year(state)
  local summary = process_write_off_summary(state)
  table.sort(summary.unattributed_entries, function(a, b)
    if a.at == b.at then
      return tostring(a.process_instance_id) < tostring(b.process_instance_id)
    end
    return tostring(a.at) < tostring(b.at)
  end)
  return summary.unattributed_entries
end

_G.AchaeadexLedger.Core.Reports = reports

return reports
