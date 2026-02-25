-- List/discovery views for Achaeadex Ledger

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local listings = _G.AchaeadexLedger.Core.Listings or {}

local function get_inventory()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.Inventory then
    error("AchaeadexLedger.Core.Inventory is not loaded")
  end

  return _G.AchaeadexLedger.Core.Inventory
end

local function match_substring(value, needle)
  if not needle or needle == "" then
    return true
  end
  if not value then
    return false
  end
  return string.find(string.lower(value), string.lower(needle), 1, true) ~= nil
end

function listings.list_commodities(state, opts)
  opts = opts or {}
  local inventory = get_inventory()
  local data = inventory.get_all(state.inventory)

  local rows = {}
  for name, values in pairs(data) do
    if match_substring(name, opts.name) then
      table.insert(rows, {
        name = name,
        qty = values.qty,
        wac = values.unit_cost
      })
    end
  end

  local sort_key = opts.sort or "name"
  table.sort(rows, function(a, b)
    if sort_key == "qty" then
      if a.qty == b.qty then
        return a.name < b.name
      end
      return a.qty > b.qty
    elseif sort_key == "wac" then
      if a.wac == b.wac then
        return a.name < b.name
      end
      return a.wac > b.wac
    end
    return a.name < b.name
  end)

  return rows
end

function listings.list_patterns(state, opts)
  opts = opts or {}
  local rows = {}

  for _, pool in pairs(state.pattern_pools or {}) do
    if (not opts.type or pool.pattern_type == opts.type)
      and (not opts.status or pool.status == opts.status) then
      table.insert(rows, {
        pattern_pool_id = pool.pattern_pool_id,
        pattern_type = pool.pattern_type,
        pattern_name = pool.pattern_name,
        status = pool.status,
        remaining = pool.capital_remaining_gold,
        activated_at = pool.activated_at,
        deactivated_at = pool.deactivated_at
      })
    end
  end

  table.sort(rows, function(a, b)
    return a.pattern_pool_id < b.pattern_pool_id
  end)

  return rows
end

function listings.list_designs(state, opts)
  opts = opts or {}
  local rows = {}

  for _, source in pairs(state.production_sources or {}) do
    if source.source_kind == "design"
      and (not opts.type or source.source_type == opts.type)
      and (not opts.provenance or source.provenance == opts.provenance)
      and (opts.recovery == nil or source.recovery_enabled == opts.recovery) then
      table.insert(rows, {
        design_id = source.source_id,
        design_type = source.source_type,
        name = source.name,
        provenance = source.provenance,
        recovery_enabled = source.recovery_enabled,
        pattern_pool_id = source.pattern_pool_id,
        design_remaining = source.capital_remaining or 0
      })
    end
  end

  table.sort(rows, function(a, b)
    return a.design_id < b.design_id
  end)

  return rows
end

function listings.list_sources(state, opts)
  opts = opts or {}
  local rows = {}

  for _, source in pairs(state.production_sources or {}) do
    if (not opts.kind or source.source_kind == opts.kind)
      and (not opts.type or source.source_type == opts.type)
      and (not opts.provenance or source.provenance == opts.provenance)
      and (opts.recovery == nil or source.recovery_enabled == opts.recovery) then
      table.insert(rows, {
        source_id = source.source_id,
        source_kind = source.source_kind,
        source_type = source.source_type,
        name = source.name,
        provenance = source.provenance,
        recovery_enabled = source.recovery_enabled,
        pattern_pool_id = source.pattern_pool_id,
        capital_remaining = source.capital_remaining or 0,
        status = source.status,
        per_item_fee_gold = source.per_item_fee_gold or 0
      })
    end
  end

  table.sort(rows, function(a, b)
    return a.source_id < b.source_id
  end)

  return rows
end

function listings.list_items(state, opts)
  opts = opts or {}
  local rows = {}
  local sales_by_item = {}
  local source_filter = opts.source or opts.design

  for _, sale in pairs(state.sales or {}) do
    sales_by_item[sale.item_id] = sale.sale_id
  end

  for _, item in pairs(state.crafted_items or {}) do
    local sold = sales_by_item[item.item_id] ~= nil
    local unresolved = item.source_id == nil

    if (not source_filter or item.source_id == source_filter)
      and (opts.sold == nil or sold == opts.sold)
      and (not opts.unresolved or unresolved) then
      table.insert(rows, {
        item_id = item.item_id,
        design_id = item.source_id,
        appearance_key = item.appearance_key,
        crafted_at = item.crafted_at,
        sold = sold
      })
    end
  end

  table.sort(rows, function(a, b)
    return a.item_id < b.item_id
  end)

  return rows
end

function listings.list_sales(state, opts)
  opts = opts or {}
  local rows = {}

  for _, sale in pairs(state.sales or {}) do
    local year = sale.game_time and sale.game_time.year or nil
    local order_id = state.sale_orders and state.sale_orders[sale.sale_id] or nil

    if (not opts.year or tonumber(year) == tonumber(opts.year))
      and (not opts.order or order_id == opts.order) then
      table.insert(rows, {
        sale_id = sale.sale_id,
        item_id = sale.item_id,
        sold_at = sale.sold_at,
        sale_price_gold = sale.sale_price_gold,
        game_year = year,
        order_id = order_id
      })
    end
  end

  table.sort(rows, function(a, b)
    return a.sale_id < b.sale_id
  end)

  return rows
end

function listings.list_orders(state, opts)
  opts = opts or {}
  local rows = {}

  for _, order in pairs(state.orders or {}) do
    local sale_ids = state.order_sales and state.order_sales[order.order_id] or {}
    local count = 0
    local revenue = 0

    for sale_id, _ in pairs(sale_ids) do
      local sale = state.sales[sale_id]
      if sale then
        count = count + 1
        revenue = revenue + (sale.sale_price_gold or 0)
      end
    end

    table.insert(rows, {
      order_id = order.order_id,
      status = order.status,
      customer = order.customer,
      created_at = order.created_at,
      total_sales_count = count,
      total_revenue = revenue
    })
  end

  table.sort(rows, function(a, b)
    return a.order_id < b.order_id
  end)

  return rows
end

function listings.list_processes(state, opts)
  opts = opts or {}
  local rows = {}

  for _, process in pairs(state.process_instances or {}) do
    if (not opts.status or process.status == opts.status)
      and (not opts.process_id or process.process_id == opts.process_id) then
      table.insert(rows, {
        process_instance_id = process.process_instance_id,
        process_id = process.process_id,
        status = process.status,
        started_at = process.started_at,
        completed_at = process.completed_at
      })
    end
  end

  table.sort(rows, function(a, b)
    return a.process_instance_id < b.process_instance_id
  end)

  return rows
end

function listings.list_forge_sessions(state, opts)
  opts = opts or {}
  local rows = {}

  for _, session in pairs(state.forge_sessions or {}) do
    if (not opts.status or session.status == opts.status)
      and (not opts.source or session.source_id == opts.source) then
      local attached_count = 0
      local attached = state.forge_session_items and state.forge_session_items[session.forge_session_id] or {}
      for _, _ in pairs(attached or {}) do
        attached_count = attached_count + 1
      end

      table.insert(rows, {
        forge_session_id = session.forge_session_id,
        source_id = session.source_id,
        status = session.status,
        started_at = session.started_at,
        expires_at = session.expires_at,
        closed_at = session.closed_at,
        coal_basis_gold = session.coal_basis_gold or 0,
        allocated_total_gold = session.allocated_total_gold or 0,
        attached_items = attached_count
      })
    end
  end

  table.sort(rows, function(a, b)
    return a.forge_session_id < b.forge_session_id
  end)

  return rows
end

_G.AchaeadexLedger.Core.Listings = listings

return listings
