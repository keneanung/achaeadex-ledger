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

local function normalize_text(value)
  local text = tostring(value or "")
  text = (text:gsub("^%s+", ""))
  text = (text:gsub("%s+$", ""))
  return string.lower(text)
end

local function split_keywords(query)
  local words = {}
  local value = tostring(query or "")
  value = (value:gsub("^%s+", ""))
  value = (value:gsub("%s+$", ""))
  for token in value:gmatch("%S+") do
    table.insert(words, string.lower(token))
  end
  return words
end

local function collect_aliases_for_source(state, source_id, only_active)
  local aliases = {}
  for alias_id, info in pairs(state.design_aliases or {}) do
    if info and info.source_id == source_id then
      if (not only_active) or info.active == 1 then
        table.insert(aliases, {
          alias_id = alias_id,
          alias_kind = info.alias_kind,
          active = info.active
        })
      end
    end
  end
  table.sort(aliases, function(a, b)
    return tostring(a.alias_id) < tostring(b.alias_id)
  end)
  return aliases
end

local function source_matches_keywords(source, query)
  local keywords = split_keywords(query)
  if #keywords == 0 then
    return true
  end

  local metadata = source.metadata or {}
  local haystack = table.concat({
    tostring(source.name or ""),
    tostring(metadata.generic or ""),
    tostring(metadata.designer or ""),
    tostring(metadata.owner_raw or ""),
    tostring(metadata.dropped_desc or "")
  }, " "):lower()

  for _, keyword in ipairs(keywords) do
    if not string.find(haystack, keyword, 1, true) then
      return false
    end
  end

  return true
end

local function compare_source_rows(sort_key)
  sort_key = sort_key or "newest"
  return function(a, b)
    if sort_key == "oldest" then
      if tostring(a.created_at or "") == tostring(b.created_at or "") then
        return tostring(a.source_id) < tostring(b.source_id)
      end
      return tostring(a.created_at or "") < tostring(b.created_at or "")
    elseif sort_key == "name" then
      local an = normalize_text(a.short_desc)
      local bn = normalize_text(b.short_desc)
      if an == bn then
        return tostring(a.source_id) < tostring(b.source_id)
      end
      return an < bn
    elseif sort_key == "type" then
      local at = normalize_text(a.design_type)
      local bt = normalize_text(b.design_type)
      if at == bt then
        return tostring(a.source_id) < tostring(b.source_id)
      end
      return at < bt
    end

    if tostring(a.created_at or "") == tostring(b.created_at or "") then
      return tostring(a.source_id) > tostring(b.source_id)
    end
    return tostring(a.created_at or "") > tostring(b.created_at or "")
  end
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
  local provenance_filter = opts.provenance
  if provenance_filter == "any" then
    provenance_filter = nil
  end
  local discipline_filter = opts.discipline
  if discipline_filter == "any" then
    discipline_filter = nil
  end

  local include_aliases = opts.show_aliases == 1 or opts.show_aliases == true

  for _, source in pairs(state.production_sources or {}) do
    if (not opts.kind or source.source_kind == opts.kind)
      and (not opts.type or source.source_type == opts.type)
      and (not provenance_filter or source.provenance == provenance_filter)
      and (opts.recovery == nil or source.recovery_enabled == opts.recovery)
      and (not discipline_filter or ((source.metadata and source.metadata.discipline) == discipline_filter))
      and source_matches_keywords(source, opts.q) then
      local aliases = collect_aliases_for_source(state, source.source_id, true)
      local alias_id = aliases[1] and aliases[1].alias_id or nil
      local metadata = source.metadata or {}
      table.insert(rows, {
        source_id = source.source_id,
        source_kind = source.source_kind,
        source_type = source.source_type,
        discipline = metadata.discipline,
        design_type = source.source_type,
        name = source.name,
        short_desc = source.name,
        alias_id = alias_id,
        aliases = include_aliases and aliases or nil,
        provenance = source.provenance,
        recovery_enabled = source.recovery_enabled,
        pattern_pool_id = source.pattern_pool_id,
        capital_remaining = source.capital_remaining or 0,
        status = source.status,
        per_item_fee_gold = source.per_item_fee_gold or 0,
        created_at = source.created_at,
        metadata = source.metadata
      })
    end
  end

  table.sort(rows, compare_source_rows(opts.sort))

  local total = #rows
  local offset = tonumber(opts.offset) or 0
  if offset < 0 then
    offset = 0
  end
  local limit = tonumber(opts.limit)

  if limit and limit > 0 then
    local paged = {}
    local start_index = offset + 1
    local end_index = math.min(total, offset + limit)
    for i = start_index, end_index do
      if rows[i] then
        table.insert(paged, rows[i])
      end
    end
    rows = paged
  end

  rows.total = total
  rows.offset = offset
  rows.limit = limit

  return rows
end

function listings.show_source(state, source_ref)
  local ref = tostring(source_ref or "")
  if ref == "" then
    return nil, "source reference is required"
  end

  local source_id = ref
  if not (state.production_sources and state.production_sources[source_id]) then
    local alias = state.design_aliases and state.design_aliases[ref] or nil
    if alias and alias.source_id then
      source_id = alias.source_id
    end
  end

  local source = state.production_sources and state.production_sources[source_id] or nil
  if not source then
    return nil, "source not found: " .. tostring(ref)
  end

  return {
    source_id = source.source_id,
    source_kind = source.source_kind,
    source_type = source.source_type,
    discipline = source.metadata and source.metadata.discipline or nil,
    name = source.name,
    short_desc = source.name,
    provenance = source.provenance,
    recovery_enabled = source.recovery_enabled,
    pattern_pool_id = source.pattern_pool_id,
    per_item_fee_gold = source.per_item_fee_gold or 0,
    status = source.status,
    capital_remaining = source.capital_remaining or 0,
    bom = source.bom,
    metadata = source.metadata,
    aliases = collect_aliases_for_source(state, source.source_id, false)
  }
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
    local transformed = item.transformed == 1

    if (not source_filter or item.source_id == source_filter)
      and (opts.sold == nil or sold == opts.sold)
      and (opts.transformed == nil or transformed == opts.transformed)
      and (not opts.unresolved or unresolved) then
      local status = "active"
      if sold then
        status = "sold"
      elseif transformed then
        status = "transformed"
      end
      table.insert(rows, {
        item_id = item.item_id,
        design_id = item.source_id,
        item_kind = "crafted",
        appearance_key = item.appearance_key,
        crafted_at = item.crafted_at,
        sold = sold,
        transformed = transformed,
        status = status
      })
    end
  end

  for _, item in pairs(state.external_items or {}) do
    local sold = sales_by_item[item.item_id] ~= nil or item.status == "sold"
    local unresolved = false
    local transformed = item.status == "transformed"
    if (not source_filter)
      and (opts.sold == nil or sold == opts.sold)
      and (opts.transformed == nil or transformed == opts.transformed)
      and (not opts.unresolved or unresolved) then
      table.insert(rows, {
        item_id = item.item_id,
        design_id = "(external)",
        item_kind = "external",
        appearance_key = item.name,
        crafted_at = item.acquired_at,
        sold = sold,
        transformed = transformed,
        status = item.status or (sold and "sold" or "active")
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
    local commodity_sale_ids = state.order_commodity_sales and state.order_commodity_sales[order.order_id] or {}
    local count = 0
    local revenue = 0

    for sale_id, _ in pairs(sale_ids) do
      local sale = state.sales[sale_id]
      if sale then
        count = count + 1
        revenue = revenue + (sale.sale_price_gold or 0)
      end
    end

    for sale_id, _ in pairs(commodity_sale_ids) do
      local sale = state.commodity_sales and state.commodity_sales[sale_id] or nil
      if sale then
        count = count + 1
        revenue = revenue + (sale.revenue or 0)
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
