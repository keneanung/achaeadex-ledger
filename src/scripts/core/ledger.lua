-- Core ledger module
-- Event-driven accounting system with strict WAC and waterfall recovery

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local ledger = _G.AchaeadexLedger.Core.Ledger or {}

local function get_inventory()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.Inventory then
    error("AchaeadexLedger.Core.Inventory is not loaded")
  end

  return _G.AchaeadexLedger.Core.Inventory
end

local function get_sources()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.ProductionSources then
    error("AchaeadexLedger.Core.ProductionSources is not loaded")
  end

  return _G.AchaeadexLedger.Core.ProductionSources
end

local function get_pattern_pools()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.PatternPools then
    error("AchaeadexLedger.Core.PatternPools is not loaded")
  end

  return _G.AchaeadexLedger.Core.PatternPools
end

local function get_recovery()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.Recovery then
    error("AchaeadexLedger.Core.Recovery is not loaded")
  end

  return _G.AchaeadexLedger.Core.Recovery
end

local function get_deferred()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.DeferredProcesses then
    error("AchaeadexLedger.Core.DeferredProcesses is not loaded")
  end

  return _G.AchaeadexLedger.Core.DeferredProcesses
end

local function get_json()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.Json then
    return nil
  end

  return _G.AchaeadexLedger.Core.Json
end

local function require_event_store(state)
  if not state.event_store then
    error("EventStore is required on ledger state")
  end
end

local function resolve_source_id(state, source_id)
  if state.production_sources[source_id] then
    return source_id
  end

  local alias = state.design_aliases[source_id]
  if alias and alias.source_id then
    return alias.source_id
  end

  error("Design " .. source_id .. " not found")
end

local function ensure_stub_source(state, source_id, opts)
  if not source_id then
    return nil
  end

  if state.production_sources[source_id] then
    return source_id
  end

  local alias = state.design_aliases[source_id]
  if alias and alias.source_id then
    if state.production_sources[alias.source_id] then
      return alias.source_id
    end
    source_id = alias.source_id
  end

  local sources = get_sources()
  sources.create_design(state, source_id, "unknown", nil, "unknown", 0, {
    status = "stub",
    bom = opts and opts.bom or nil
  })

  return source_id
end

local function normalize_source_payload(payload)
  local source_id = payload.source_id or payload.design_id
  local source_kind = payload.source_kind or "design"
  return source_id, source_kind
end

local function decode_breakdown(raw)
  local json = get_json()
  if not raw or raw == "" then
    return {}
  end
  if json and type(json.decode) == "function" then
    local ok, parsed = pcall(json.decode, raw)
    if ok and type(parsed) == "table" then
      return parsed
    end
  end
  return {}
end

local function encode_breakdown(breakdown)
  local json = get_json()
  if json and type(json.encode) == "function" then
    local ok, encoded = pcall(json.encode, breakdown)
    if ok and type(encoded) == "string" then
      return encoded
    end
  end
  return "{}"
end

local function item_base_cost(item)
  if item.base_operational_cost_gold ~= nil then
    return item.base_operational_cost_gold
  end
  return (item.operational_cost_gold or 0) - (item.forge_allocated_coal_gold or 0)
end

-- Create a new ledger instance
function ledger.new(event_store)
  local inventory = get_inventory()
  if not event_store then
    error("EventStore is required")
  end
  return {
    event_store = event_store,
    inventory = inventory.new(),
    production_sources = {}, -- source_id -> source data
    pattern_pools = {}, -- pattern_pool_id -> pool data
    pattern_pools_by_type = {}, -- pattern_type -> active pool id
    crafted_items = {}, -- item_id -> item data
    external_items = {}, -- item_id -> external item data
    design_aliases = {}, -- alias_id -> source_id
    appearance_aliases = {}, -- appearance_key -> source_id
    process_instances = {}, -- process_instance_id -> process data
    sales = {}, -- sale_id -> sale data
    commodity_sales = {}, -- sale_id -> commodity sale data
    orders = {}, -- order_id -> order data
    order_sales = {}, -- order_id -> { sale_id = true }
    order_commodity_sales = {}, -- order_id -> { sale_id = true }
    sale_orders = {}, -- sale_id -> order_id
    order_items = {}, -- order_id -> { item_id = true }
    item_orders = {}, -- item_id -> order_id
    order_settlements = {}, -- settlement_id -> settlement data
    process_write_offs = {}, -- list of write-off entries
    process_game_time_overrides = {}, -- process_instance_id -> { scope -> { game_time, updated_at, note } }
    forge_sessions = {}, -- forge_session_id -> session data
    forge_session_items = {}, -- forge_session_id -> { item_id -> allocated_coal_gold }
    item_transformations = {}, -- new_item_id -> transformation link
  }
end

-- Record an event in the ledger
function ledger.record_event(state, event_type, payload)
  require_event_store(state)
  assert(type(event_type) == "string", "event_type must be a string")
  assert(type(payload) == "table", "payload must be a table")

  local event = {
    event_type = event_type,
    payload = payload,
    ts = os.date("!%Y-%m-%dT%H:%M:%SZ")
  }

  if type(state.event_store.append_event_and_apply) == "function" then
    event.id = state.event_store:append_event_and_apply(event)
  else
    event.id = state.event_store:append(event)
  end

  return event
end

function ledger.record_events(state, events)
  require_event_store(state)
  assert(type(events) == "table", "events must be a table")

  if type(state.event_store.append_events_and_apply) == "function" then
    state.event_store:append_events_and_apply(events)
  else
    for _, event in ipairs(events) do
      event.id = state.event_store:append(event)
    end
  end

  return events
end

-- Simple JSON serialization (minimal implementation)
function ledger._serialize(obj)
  if type(obj) == "table" then
    local parts = {}
    local is_array = true
    for k, v in pairs(obj) do
      if type(k) ~= "number" then
        is_array = false
        break
      end
    end

    if is_array then
      for i, v in ipairs(obj) do
        table.insert(parts, ledger._serialize(v))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      for k, v in pairs(obj) do
        local key = '"' .. tostring(k) .. '"'
        local value = ledger._serialize(v)
        table.insert(parts, key .. ":" .. value)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  elseif type(obj) == "string" then
    return '"' .. obj:gsub('"', '\\"') .. '"'
  elseif type(obj) == "number" then
    return tostring(obj)
  elseif type(obj) == "boolean" then
    return obj and "true" or "false"
  elseif obj == nil then
    return "null"
  else
    return '"' .. tostring(obj) .. '"'
  end
end

function ledger.apply_event(state, event)
  assert(type(event) == "table", "event must be a table")
  local event_type = event.event_type
  local payload = event.payload or {}

  if event_type == "OPENING_INVENTORY" then
    local inventory = get_inventory()
    inventory.add(state.inventory, payload.commodity, payload.qty, payload.unit_cost)
  elseif event_type == "BROKER_BUY" then
    local inventory = get_inventory()
    inventory.add(state.inventory, payload.commodity, payload.qty, payload.unit_cost)
  elseif event_type == "BROKER_SELL" then
    local inventory = get_inventory()
    inventory.remove(state.inventory, payload.commodity, payload.qty)
    if payload.sale_id then
      state.commodity_sales[payload.sale_id] = {
        sale_id = payload.sale_id,
        commodity = payload.commodity,
        qty = payload.qty,
        unit_price = payload.unit_price,
        sold_at = payload.sold_at,
        cost = payload.cost,
        revenue = payload.revenue,
        profit = payload.profit,
        order_id = payload.order_id
      }
      if payload.order_id then
        state.order_commodity_sales[payload.order_id] = state.order_commodity_sales[payload.order_id] or {}
        state.order_commodity_sales[payload.order_id][payload.sale_id] = true
      end
    end
  elseif event_type == "PROCESS_APPLY" then
    local inventory = get_inventory()
    local inputs = payload.inputs or {}
    local outputs = payload.outputs or {}
    local gold_fee = payload.gold_fee or 0

    local total_input_cost = 0
    for commodity, qty in pairs(inputs) do
      local cost = inventory.remove(state.inventory, commodity, qty)
      total_input_cost = total_input_cost + cost
    end

    local total_cost = total_input_cost + gold_fee
    local total_output_qty = 0
    for _, qty in pairs(outputs) do
      total_output_qty = total_output_qty + qty
    end

    local output_unit_cost = 0
    if total_output_qty > 0 then
      output_unit_cost = total_cost / total_output_qty
    end

    for commodity, qty in pairs(outputs) do
      inventory.add(state.inventory, commodity, qty, output_unit_cost)
    end
  elseif event_type == "PROCESS_START" then
    local deferred = get_deferred()
    return deferred.start(state, payload.process_instance_id, payload.process_id, payload.inputs, payload.gold_fee, payload.note, payload.started_at)
  elseif event_type == "PROCESS_ADD_INPUTS" then
    local deferred = get_deferred()
    return deferred.add_inputs(state, payload.process_instance_id, payload.inputs, payload.note)
  elseif event_type == "PROCESS_ADD_FEE" then
    local deferred = get_deferred()
    return deferred.add_fee(state, payload.process_instance_id, payload.gold_fee, payload.note)
  elseif event_type == "PROCESS_COMPLETE" then
    local deferred = get_deferred()
    return deferred.complete(state, payload.process_instance_id, payload.outputs, payload.note, payload.completed_at)
  elseif event_type == "PROCESS_ABORT" then
    local deferred = get_deferred()
    return deferred.abort(state, payload.process_instance_id, payload.disposition, payload.note, payload.completed_at)
  elseif event_type == "PROCESS_WRITE_OFF" then
    state.process_write_offs = state.process_write_offs or {}
    table.insert(state.process_write_offs, {
      process_instance_id = payload.process_instance_id,
      at = event.ts,
      amount_gold = payload.amount_gold or 0,
      reason = payload.reason,
      note = payload.note,
      game_time = payload.game_time
    })
    return state
  elseif event_type == "PROCESS_SET_GAME_TIME" then
    local scope = payload.scope or "write_off"
    state.process_game_time_overrides = state.process_game_time_overrides or {}
    state.process_game_time_overrides[payload.process_instance_id] = state.process_game_time_overrides[payload.process_instance_id] or {}
    state.process_game_time_overrides[payload.process_instance_id][scope] = {
      game_time = payload.game_time,
      updated_at = event.ts,
      note = payload.note
    }
    return state
  elseif event_type == "FORGE_WRITE_OFF" then
    state.process_write_offs = state.process_write_offs or {}
    table.insert(state.process_write_offs, {
      process_instance_id = payload.forge_session_id,
      amount_gold = payload.amount_gold or 0,
      reason = payload.reason or "forge_expire_unused",
      note = payload.note
    })
    return state
  elseif event_type == "SOURCE_CREATE" then
    local sources = get_sources()
    local source_kind = payload.source_kind
    if source_kind == "skill" then
      sources.create_skill(state, payload.source_id, payload.source_type, payload.name, payload.provenance, {
        status = payload.status,
        created_at = payload.created_at,
        per_item_fee_gold = payload.per_item_fee_gold
      })
    else
      sources.create_source(state, payload.source_id, source_kind, payload.source_type, payload.name, payload.provenance, payload.recovery_enabled, {
        status = payload.status,
        created_at = payload.created_at,
        per_item_fee_gold = payload.per_item_fee_gold,
        bom = payload.bom,
        pricing_policy = payload.pricing_policy,
        capital_remaining = payload.capital_remaining_gold
      })
    end
  elseif event_type == "DESIGN_START" then
    local sources = get_sources()
    local source_id = payload.source_id or payload.design_id
    local source_type = payload.source_type or payload.design_type
    local source = sources.create_design(
      state,
      source_id,
      source_type,
      payload.name,
      payload.provenance,
      payload.recovery_enabled,
      { status = payload.status, bom = payload.bom, pricing_policy = payload.pricing_policy }
    )
    if payload.pattern_pool_id then
      source.pattern_pool_id = payload.pattern_pool_id
    end
    if payload.created_at then
      source.created_at = payload.created_at
    end
  elseif event_type == "DESIGN_COST" then
    local sources = get_sources()
    local source_id = resolve_source_id(state, payload.source_id or payload.design_id)
    sources.add_capital(state, source_id, payload.amount)
  elseif event_type == "DESIGN_SET_PER_ITEM_FEE" then
    local source_id = resolve_source_id(state, payload.source_id or payload.design_id)
    state.production_sources[source_id].per_item_fee_gold = payload.amount
  elseif event_type == "DESIGN_SET_BOM" then
    local sources = get_sources()
    local source_id = resolve_source_id(state, payload.source_id or payload.design_id)
    sources.set_bom(state, source_id, payload.bom)
  elseif event_type == "DESIGN_SET_PRICING" then
    local sources = get_sources()
    local source_id = resolve_source_id(state, payload.source_id or payload.design_id)
    sources.set_pricing_policy(state, source_id, payload.pricing_policy)
  elseif event_type == "DESIGN_UPDATE" then
    local sources = get_sources()
    local source_id = resolve_source_id(state, payload.source_id or payload.design_id)
    sources.update(state, source_id, {
      name = payload.name,
      source_type = payload.source_type or payload.design_type,
      provenance = payload.provenance,
      recovery_enabled = payload.recovery_enabled,
      status = payload.status
    })
    if payload.pattern_pool_id ~= nil then
      state.production_sources[source_id].pattern_pool_id = payload.pattern_pool_id
    end
  elseif event_type == "PATTERN_ACTIVATE" then
    local pattern_pools = get_pattern_pools()
    pattern_pools.activate(state, payload.pattern_pool_id, payload.pattern_type, payload.pattern_name, payload.capital_initial, payload.activated_at)
  elseif event_type == "PATTERN_DEACTIVATE" then
    local pattern_pools = get_pattern_pools()
    pattern_pools.deactivate(state, payload.pattern_pool_id, payload.deactivated_at)
  elseif event_type == "DESIGN_REGISTER_ALIAS" then
    local source_id = resolve_source_id(state, payload.source_id or payload.design_id)
    state.design_aliases[payload.alias_id] = {
      source_id = source_id,
      alias_kind = payload.alias_kind,
      active = payload.active
    }
  elseif event_type == "DESIGN_REGISTER_APPEARANCE" then
    local source_id = resolve_source_id(state, payload.source_id or payload.design_id)
    local existing = state.appearance_aliases[payload.appearance_key]
    if existing and existing.source_id ~= source_id then
      error("Appearance key already mapped to a different design")
    end
    state.appearance_aliases[payload.appearance_key] = {
      source_id = source_id,
      confidence = payload.confidence
    }
  elseif event_type == "ORDER_CREATE" then
    state.orders[payload.order_id] = {
      order_id = payload.order_id,
      created_at = payload.created_at,
      customer = payload.customer,
      note = payload.note,
      status = payload.status
    }
  elseif event_type == "ORDER_ADD_SALE" then
    state.order_sales[payload.order_id] = state.order_sales[payload.order_id] or {}
    state.order_sales[payload.order_id][payload.sale_id] = true
    state.sale_orders[payload.sale_id] = payload.order_id
  elseif event_type == "ORDER_ADD_ITEM" then
    state.order_items[payload.order_id] = state.order_items[payload.order_id] or {}
    state.order_items[payload.order_id][payload.item_id] = true
    state.item_orders[payload.item_id] = payload.order_id
  elseif event_type == "ORDER_SETTLE" then
    state.order_settlements[payload.settlement_id] = {
      settlement_id = payload.settlement_id,
      order_id = payload.order_id,
      amount_gold = payload.amount_gold,
      method = payload.method,
      received_at = payload.received_at
    }
  elseif event_type == "ORDER_CLOSE" then
    local order = state.orders[payload.order_id]
    if not order then
      error("Order " .. payload.order_id .. " not found")
    end
    order.status = payload.status or order.status
    order.closed_at = payload.closed_at
  elseif event_type == "ITEM_REGISTER_EXTERNAL" then
    if state.crafted_items[payload.item_id] then
      error("Item " .. tostring(payload.item_id) .. " already exists as crafted item")
    end
    local existing = state.external_items[payload.item_id]
    if existing then
      error("External item " .. tostring(payload.item_id) .. " already exists")
    end
    state.external_items[payload.item_id] = {
      item_id = payload.item_id,
      name = payload.name,
      acquired_at = payload.acquired_at,
      basis_gold = payload.basis_gold,
      basis_source = payload.basis_source,
      status = payload.status or "active",
      note = payload.note
    }
  elseif event_type == "ITEM_UPDATE_EXTERNAL" then
    local item = state.external_items[payload.item_id]
    if not item then
      error("External item " .. tostring(payload.item_id) .. " not found")
    end
    if payload.name ~= nil then
      item.name = payload.name
    end
    if payload.basis_gold ~= nil then
      item.basis_gold = payload.basis_gold
    end
    if payload.basis_source ~= nil then
      item.basis_source = payload.basis_source
    end
    if payload.status ~= nil then
      item.status = payload.status
    end
    if payload.note ~= nil then
      item.note = payload.note
    end
  elseif event_type == "CRAFT_ITEM" then
    local source_id, source_kind = normalize_source_payload(payload)
    local bom = payload.materials
    if bom and next(bom) == nil then
      bom = nil
    end
    source_id = ensure_stub_source(state, source_id, { bom = bom })
    local inventory = get_inventory()
    local materials = payload.materials or nil
    if materials then
      for commodity, qty in pairs(materials) do
        inventory.remove(state.inventory, commodity, qty)
      end
    end
    state.crafted_items[payload.item_id] = {
      item_id = payload.item_id,
      source_id = source_id,
      source_kind = source_kind,
      crafted_at = payload.crafted_at,
      operational_cost_gold = payload.operational_cost_gold,
      base_operational_cost_gold = payload.base_operational_cost_gold or payload.operational_cost_gold,
      forge_allocated_coal_gold = payload.forge_allocated_coal_gold or 0,
      cost_breakdown_json = payload.cost_breakdown_json,
      appearance_key = payload.appearance_key,
      materials = payload.materials,
      materials_source = payload.materials_source,
      materials_cost_gold = payload.materials_cost_gold,
      parent_item_id = payload.parent_item_id,
      transformed = payload.transformed == 1 and 1 or 0
    }
  elseif event_type == "CRAFT_RESOLVE_DESIGN" or event_type == "CRAFT_RESOLVE_SOURCE" then
    local item = state.crafted_items[payload.item_id]
    if not item then
      error("Crafted item " .. payload.item_id .. " not found")
    end
    local source_id = ensure_stub_source(state, payload.source_id or payload.design_id)
    item.source_id = source_id
    item.source_kind = payload.source_kind or "design"
  elseif event_type == "SELL_ITEM" then
    if payload.operational_profit ~= nil and (payload.source_id or payload.design_id) then
      local recovery = get_recovery()
      local source_id = resolve_source_id(state, payload.source_id or payload.design_id)
      return recovery.apply_to_state(state, source_id, payload.operational_profit)
    end

    local item = state.crafted_items[payload.item_id]
    local external_item = nil
    local item_basis = nil
    if item then
      if not item.source_id then
        error("Crafted item " .. payload.item_id .. " design is unresolved")
      end
      item_basis = item.operational_cost_gold
    else
      external_item = state.external_items[payload.item_id]
      if not external_item then
        error("Item " .. payload.item_id .. " not found")
      end
      item_basis = external_item.basis_gold or 0
    end

    local sale = {
      sale_id = payload.sale_id,
      item_id = payload.item_id,
      sold_at = payload.sold_at,
      sale_price_gold = payload.sale_price_gold,
      game_time = payload.game_time,
      settlement_id = payload.settlement_id
    }
    state.sales[payload.sale_id] = sale

    local operational_profit = payload.sale_price_gold - item_basis
    if item and item.source_id then
      local result = get_recovery().apply_to_state(state, item.source_id, operational_profit)
      sale.operational_profit = result.operational_profit
      sale.applied_to_design_capital = result.applied_to_design_capital
      sale.applied_to_pattern_capital = result.applied_to_pattern_capital
      sale.true_profit = result.true_profit
      return result
    end

    if external_item then
      external_item.status = "sold"
      sale.operational_profit = operational_profit
      sale.applied_to_design_capital = 0
      sale.applied_to_pattern_capital = 0
      sale.true_profit = operational_profit
      return {
        operational_profit = operational_profit,
        applied_to_design_capital = 0,
        applied_to_pattern_capital = 0,
        true_profit = operational_profit,
        design_remaining = 0,
        pattern_remaining = 0
      }
    end
  elseif event_type == "FORGE_FIRE" then
    local inventory = get_inventory()
    local coal_basis = payload.coal_basis_gold or 0
    if payload.coal_cost_explicit ~= 1 then
      inventory.remove(state.inventory, "coal", 1)
    end
    state.forge_sessions[payload.forge_session_id] = {
      forge_session_id = payload.forge_session_id,
      source_id = payload.source_id,
      started_at = payload.started_at,
      expires_at = payload.expires_at,
      status = payload.status or "in_flight",
      coal_basis_gold = coal_basis,
      allocated_total_gold = payload.allocated_total_gold or 0,
      note = payload.note
    }
    state.forge_session_items[payload.forge_session_id] = state.forge_session_items[payload.forge_session_id] or {}
  elseif event_type == "FORGE_ATTACH_ITEM" then
    local session = state.forge_sessions[payload.forge_session_id]
    if not session then
      error("Forge session " .. tostring(payload.forge_session_id) .. " not found")
    end
    local item = state.crafted_items[payload.item_id]
    if not item then
      error("Crafted item " .. tostring(payload.item_id) .. " not found")
    end
    local source = item.source_id and state.production_sources[item.source_id] or nil
    if not source or source.source_kind ~= "skill" or source.source_type ~= "forging" then
      error("Item " .. tostring(payload.item_id) .. " is not a forged skill item")
    end
    if session.source_id and item.source_id ~= session.source_id then
      error("Item source does not match forge session source")
    end
    state.forge_session_items[payload.forge_session_id] = state.forge_session_items[payload.forge_session_id] or {}
    state.forge_session_items[payload.forge_session_id][payload.item_id] = payload.allocated_coal_gold or 0
    item.pending_forge_session_id = payload.forge_session_id
  elseif event_type == "FORGE_ALLOCATE" then
    local session = state.forge_sessions[payload.forge_session_id]
    if not session then
      error("Forge session " .. tostring(payload.forge_session_id) .. " not found")
    end
    state.forge_session_items[payload.forge_session_id] = state.forge_session_items[payload.forge_session_id] or {}
    local allocations = payload.allocations or {}
    local allocated_sum = 0
    for item_id, amount in pairs(allocations) do
      local item = state.crafted_items[item_id]
      if item then
        local alloc = tonumber(amount) or 0
        allocated_sum = allocated_sum + alloc
        item.forge_allocated_coal_gold = (item.forge_allocated_coal_gold or 0) + alloc
        item.operational_cost_gold = (item.operational_cost_gold or 0) + alloc
        local breakdown = decode_breakdown(item.cost_breakdown_json)
        breakdown.base_operational_cost_gold = item_base_cost(item)
        breakdown.forge_coal_allocated_gold = item.forge_allocated_coal_gold
        breakdown.forge_session_id = payload.forge_session_id
        item.cost_breakdown_json = encode_breakdown(breakdown)
        if item.pending_forge_session_id == payload.forge_session_id then
          item.pending_forge_session_id = nil
        end
        state.forge_session_items[payload.forge_session_id][item_id] = (state.forge_session_items[payload.forge_session_id][item_id] or 0) + alloc
      end
    end
    session.allocated_total_gold = (session.allocated_total_gold or 0) + allocated_sum
  elseif event_type == "FORGE_CLOSE" or event_type == "FORGE_EXPIRE" then
    local session = state.forge_sessions[payload.forge_session_id]
    if not session then
      error("Forge session " .. tostring(payload.forge_session_id) .. " not found")
    end
    session.status = payload.status or (event_type == "FORGE_EXPIRE" and "expired" or "closed")
    session.closed_at = payload.closed_at
    if payload.note ~= nil then
      session.note = payload.note
    end
  elseif event_type == "AUGMENT_ITEM" then
    local inventory = get_inventory()
    local target_kind = payload.target_item_kind or "crafted"
    local target_item = nil
    local target_external = nil
    if target_kind == "crafted" then
      target_item = state.crafted_items[payload.target_item_id]
    elseif target_kind == "external" then
      target_external = state.external_items[payload.target_item_id]
    else
      target_item = state.crafted_items[payload.target_item_id]
      target_external = state.external_items[payload.target_item_id]
    end
    if not target_item and not target_external then
      error("Target item " .. tostring(payload.target_item_id) .. " not found")
    end
    local source_id = resolve_source_id(state, payload.source_id)
    local source = state.production_sources[source_id]
    if not source or source.source_kind ~= "skill" or source.source_type ~= "augmentation" then
      error("Augmentation source must be a skill source with type augmentation")
    end

    local materials = payload.materials or {}
    for commodity, qty in pairs(materials) do
      inventory.remove(state.inventory, commodity, qty)
    end

    if target_item then
      target_item.transformed = 1
    end
    if target_external then
      target_external.status = "transformed"
    end

    state.crafted_items[payload.new_item_id] = {
      item_id = payload.new_item_id,
      source_id = source_id,
      source_kind = "skill",
      crafted_at = payload.crafted_at,
      operational_cost_gold = payload.operational_cost_gold,
      base_operational_cost_gold = payload.operational_cost_gold,
      forge_allocated_coal_gold = 0,
      cost_breakdown_json = payload.cost_breakdown_json or "{}",
      appearance_key = payload.appearance_key,
      materials = materials,
      materials_source = payload.materials_source,
      materials_cost_gold = payload.materials_cost_gold,
      parent_item_id = payload.target_item_id,
      transformed = 0
    }

    state.item_transformations[payload.new_item_id] = {
      new_item_id = payload.new_item_id,
      old_item_id = payload.target_item_id,
      kind = payload.transform_kind or "augmentation",
      created_at = payload.crafted_at
    }
  else
    error("Unknown event type: " .. tostring(event_type))
  end

  return state
end

-- Process OPENING_INVENTORY event
function ledger.apply_opening_inventory(state, commodity, qty, unit_cost)
  local event = ledger.record_event(state, "OPENING_INVENTORY", {
    commodity = commodity,
    qty = qty,
    unit_cost = unit_cost
  })
  ledger.apply_event(state, event)
  return state
end

-- Process BROKER_BUY event
function ledger.apply_broker_buy(state, commodity, qty, unit_cost)
  local event = ledger.record_event(state, "BROKER_BUY", {
    commodity = commodity,
    qty = qty,
    unit_cost = unit_cost
  })
  ledger.apply_event(state, event)
  return state
end

-- Process BROKER_SELL event
function ledger.apply_broker_sell(state, commodity, qty, unit_price, opts)
  opts = opts or {}
  if opts.order_id and not state.orders[opts.order_id] then
    error("Order " .. tostring(opts.order_id) .. " not found")
  end
  local inventory = get_inventory()
  local cost = inventory.get_unit_cost(state.inventory, commodity) * qty
  local revenue = qty * unit_price
  local profit = revenue - cost

  local event = ledger.record_event(state, "BROKER_SELL", {
    commodity = commodity,
    qty = qty,
    unit_price = unit_price,
    cost = cost,
    revenue = revenue,
    profit = profit,
    sale_id = opts.sale_id,
    sold_at = opts.sold_at or os.date("!%Y-%m-%dT%H:%M:%SZ"),
    order_id = opts.order_id
  })

  ledger.apply_event(state, event)

  return state, profit
end

-- Process immediate PROCESS_APPLY event
function ledger.apply_process(state, process_id, inputs, outputs, gold_fee, game_time)
  local event = ledger.record_event(state, "PROCESS_APPLY", {
    process_id = process_id,
    inputs = inputs,
    outputs = outputs,
    gold_fee = gold_fee or 0,
    game_time = game_time
  })

  ledger.apply_event(state, event)

  return state
end

-- Process DESIGN_COST event
function ledger.apply_design_cost(state, design_id, amount, kind)
  local resolved_design_id = resolve_source_id(state, design_id)
  local event = ledger.record_event(state, "DESIGN_COST", {
    design_id = resolved_design_id,
    amount = amount,
    kind = kind
  })

  ledger.apply_event(state, event)

  return state
end

-- Process DESIGN_START event
function ledger.apply_design_start(state, design_id, design_type, name, provenance, recovery_enabled)
  provenance = provenance or "private"
  if recovery_enabled == nil then
    if provenance == "private" then
      recovery_enabled = 1
    else
      recovery_enabled = 0
    end
  end

  local pattern_pool_id = nil
  if recovery_enabled == 1 then
    local pattern_pools = get_pattern_pools()
    pattern_pool_id = pattern_pools.get_active_pool_id(state, design_type)
    if not pattern_pool_id then
      error("No active pattern pool for type: " .. design_type)
    end
  end

  local created_at = os.date("!%Y-%m-%dT%H:%M:%SZ")

  local event = ledger.record_event(state, "DESIGN_START", {
    design_id = design_id,
    design_type = design_type,
    name = name,
    provenance = provenance,
    recovery_enabled = recovery_enabled,
    pattern_pool_id = pattern_pool_id,
    created_at = created_at
  })

  ledger.apply_event(state, event)

  return state
end

-- Process DESIGN_SET_PER_ITEM_FEE event
function ledger.apply_design_set_fee(state, design_id, amount)
  local resolved_design_id = resolve_source_id(state, design_id)

  local event = ledger.record_event(state, "DESIGN_SET_PER_ITEM_FEE", {
    design_id = resolved_design_id,
    amount = amount
  })

  ledger.apply_event(state, event)

  return state
end

function ledger.apply_design_set_bom(state, design_id, bom)
  local resolved_design_id = resolve_source_id(state, design_id)
  local event = ledger.record_event(state, "DESIGN_SET_BOM", {
    design_id = resolved_design_id,
    bom = bom
  })

  ledger.apply_event(state, event)

  return state
end

function ledger.apply_design_set_pricing(state, design_id, pricing_policy)
  local resolved_design_id = resolve_source_id(state, design_id)
  local event = ledger.record_event(state, "DESIGN_SET_PRICING", {
    design_id = resolved_design_id,
    pricing_policy = pricing_policy
  })

  ledger.apply_event(state, event)

  return state
end

function ledger.apply_design_update(state, design_id, fields)
  local resolved_design_id = resolve_source_id(state, design_id)
  local source = state.production_sources[resolved_design_id]
  if not source then
    error("Design " .. resolved_design_id .. " not found")
  end

  local target_type = fields.design_type or source.source_type
  local target_recovery = fields.recovery_enabled
  if target_recovery == nil then
    target_recovery = source.recovery_enabled
  end

  local pattern_pool_id = nil
  if target_recovery == 1 then
    local pattern_pools = get_pattern_pools()
    pattern_pool_id = pattern_pools.get_active_pool_id(state, target_type)
    if not pattern_pool_id then
      error("No active pattern pool for type: " .. target_type)
    end
  end

  local event = ledger.record_event(state, "DESIGN_UPDATE", {
    design_id = resolved_design_id,
    name = fields.name,
    design_type = fields.design_type,
    provenance = fields.provenance,
    recovery_enabled = fields.recovery_enabled,
    status = fields.status,
    pattern_pool_id = pattern_pool_id
  })

  ledger.apply_event(state, event)

  return state
end

-- Process PATTERN_ACTIVATE event
function ledger.apply_pattern_activate(state, pattern_pool_id, pattern_type, pattern_name, capital_initial)
  local activated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")

  local event = ledger.record_event(state, "PATTERN_ACTIVATE", {
    pattern_pool_id = pattern_pool_id,
    pattern_type = pattern_type,
    pattern_name = pattern_name,
    capital_initial = capital_initial,
    activated_at = activated_at
  })

  ledger.apply_event(state, event)

  return state
end

function ledger.apply_pattern_deactivate(state, pattern_pool_id)
  local deactivated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")

  local event = ledger.record_event(state, "PATTERN_DEACTIVATE", {
    pattern_pool_id = pattern_pool_id,
    deactivated_at = deactivated_at
  })

  ledger.apply_event(state, event)

  return state
end

function ledger.apply_sell_recovery(state, design_id, operational_profit)
  local resolved_design_id = resolve_source_id(state, design_id)
  local event = ledger.record_event(state, "SELL_ITEM", {
    design_id = resolved_design_id,
    operational_profit = operational_profit
  })

  local result = ledger.apply_event(state, event)

  return result
end

function ledger.apply_design_alias(state, design_id, alias_id, alias_kind, active)
  local resolved_design_id = resolve_source_id(state, design_id)
  local event = ledger.record_event(state, "DESIGN_REGISTER_ALIAS", {
    design_id = resolved_design_id,
    alias_id = alias_id,
    alias_kind = alias_kind,
    active = active
  })

  ledger.apply_event(state, event)

  return state
end

function ledger.apply_design_appearance(state, design_id, appearance_key, confidence)
  local resolved_design_id = resolve_source_id(state, design_id)
  local existing = state.appearance_aliases[appearance_key]
  if existing and existing.source_id ~= resolved_design_id then
    error("Appearance key already mapped to a different design")
  end
  local event = ledger.record_event(state, "DESIGN_REGISTER_APPEARANCE", {
    design_id = resolved_design_id,
    appearance_key = appearance_key,
    confidence = confidence
  })

  ledger.apply_event(state, event)

  return state
end

local function ensure_design_or_stub(state, source_id, bom)
  if not source_id then
    return nil
  end

  if state.production_sources[source_id] then
    return source_id
  end

  local alias = state.design_aliases[source_id]
  if alias and alias.source_id then
    return alias.source_id
  end

  local event = ledger.record_event(state, "DESIGN_START", {
    design_id = source_id,
    design_type = "unknown",
    name = nil,
    provenance = "unknown",
    recovery_enabled = 0,
    status = "stub",
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  })

  ledger.apply_event(state, event)

  if bom then
    ledger.apply_design_set_bom(state, source_id, bom)
  end

  return source_id
end

local function ensure_source_or_stub(state, source_id, source_kind, source_type)
  if source_kind ~= "design" then
    local source = state.production_sources[source_id]
    if not source then
      error("Production source " .. tostring(source_id) .. " not found")
    end
    if source.source_kind ~= source_kind then
      error("Source kind mismatch for " .. tostring(source_id))
    end
    if source_type and source.source_type ~= source_type then
      error("Source type mismatch for " .. tostring(source_id))
    end
    return source_id
  end
  return ensure_design_or_stub(state, source_id)
end

local function compute_material_cost(state, materials)
  local inventory = get_inventory()
  local total = 0
  for commodity, qty in pairs(materials) do
    if qty <= 0 then
      error("Material quantity must be positive for " .. commodity)
    end
    local available = inventory.get_qty(state.inventory, commodity)
    if available < qty then
      error("Insufficient " .. commodity .. ": have " .. tostring(available) .. ", need " .. tostring(qty))
    end
    local unit_cost = inventory.get_unit_cost(state.inventory, commodity)
    total = total + (unit_cost * qty)
  end
  return total
end

function ledger.apply_craft_item_auto(state, item_id, design_id, opts)
  opts = opts or {}
  local materials = opts.materials
  local appearance_key = opts.appearance_key
  local manual_cost = opts.manual_cost
  local time_cost_gold = opts.time_cost_gold or 0
  local time_hours = opts.time_hours or 0

  local resolved_design_id = ensure_design_or_stub(state, design_id, materials)
  local source = resolved_design_id and state.production_sources[resolved_design_id] or nil

  local materials_source = nil
  local materials_cost = 0
  local materials_payload = nil

  if materials and next(materials) ~= nil then
    materials_source = "explicit"
    materials_payload = materials
    materials_cost = compute_material_cost(state, materials)
  elseif source and source.bom and next(source.bom) ~= nil then
    materials_source = "design_bom"
    materials_payload = source.bom
    materials_cost = compute_material_cost(state, source.bom)
  elseif manual_cost ~= nil then
    materials_source = "manual"
    materials_cost = manual_cost
  else
    error("No materials provided and no design BOM available")
  end

  local per_item_fee = source and (source.per_item_fee_gold or 0) or 0
  local operational_cost_gold = materials_cost + per_item_fee + time_cost_gold

  local breakdown = {
    materials_cost_gold = materials_cost,
    materials_source = materials_source,
    materials = materials_payload,
    per_item_fee = per_item_fee,
    time_hours = time_hours,
    time_cost_gold = time_cost_gold,
    base_operational_cost_gold = operational_cost_gold,
    forge_coal_allocated_gold = 0
  }

  local breakdown_json = encode_breakdown(breakdown)

  return ledger.apply_craft_item(
    state,
    item_id,
    resolved_design_id,
    operational_cost_gold,
    breakdown_json,
    appearance_key,
    materials_payload,
    materials_source,
    materials_cost
  )
end

function ledger.apply_craft_item(state, item_id, design_id, operational_cost_gold, cost_breakdown_json, appearance_key, materials, materials_source, materials_cost_gold)
  local event = ledger.record_event(state, "CRAFT_ITEM", {
    item_id = item_id,
    source_id = design_id,
    source_kind = "design",
    design_id = design_id,
    operational_cost_gold = operational_cost_gold,
    base_operational_cost_gold = operational_cost_gold,
    forge_allocated_coal_gold = 0,
    cost_breakdown_json = cost_breakdown_json,
    appearance_key = appearance_key,
    crafted_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    materials = materials,
    materials_source = materials_source,
    materials_cost_gold = materials_cost_gold
  })

  ledger.apply_event(state, event)

  return state
end

function ledger.apply_source_create(state, source_id, source_kind, source_type, name, opts)
  opts = opts or {}
  local event = ledger.record_event(state, "SOURCE_CREATE", {
    source_id = source_id,
    source_kind = source_kind,
    source_type = source_type,
    name = name,
    provenance = opts.provenance,
    recovery_enabled = opts.recovery_enabled,
    status = opts.status,
    per_item_fee_gold = opts.per_item_fee_gold,
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  })

  ledger.apply_event(state, event)

  return state
end

function ledger.apply_source_craft_auto(state, item_id, source_id, source_kind, opts)
  opts = opts or {}
  local resolved_source_id = ensure_source_or_stub(state, source_id, source_kind, opts.source_type)
  local source = state.production_sources[resolved_source_id]

  local materials = opts.materials
  local appearance_key = opts.appearance_key
  local manual_cost = opts.manual_cost
  local time_cost_gold = opts.time_cost_gold or 0
  local time_hours = opts.time_hours or 0
  local materials_source = nil
  local materials_cost = 0
  local materials_payload = nil

  if materials and next(materials) ~= nil then
    materials_source = "explicit"
    materials_payload = materials
    materials_cost = compute_material_cost(state, materials)
  elseif source and source.bom and next(source.bom) ~= nil then
    materials_source = "design_bom"
    materials_payload = source.bom
    materials_cost = compute_material_cost(state, source.bom)
  elseif manual_cost ~= nil then
    materials_source = "manual"
    materials_cost = manual_cost
  elseif opts.allow_estimated then
    materials_source = "estimated"
    materials_cost = 0
  else
    error("No materials provided and no source BOM available")
  end

  local per_item_fee = source and (source.per_item_fee_gold or 0) or 0
  local operational_cost_gold = materials_cost + per_item_fee + time_cost_gold
  local breakdown = {
    materials_cost_gold = materials_cost,
    materials_source = materials_source,
    materials = materials_payload,
    per_item_fee = per_item_fee,
    time_hours = time_hours,
    time_cost_gold = time_cost_gold,
    base_operational_cost_gold = operational_cost_gold,
    forge_coal_allocated_gold = 0
  }

  local event = ledger.record_event(state, "CRAFT_ITEM", {
    item_id = item_id,
    source_id = resolved_source_id,
    source_kind = source_kind,
    operational_cost_gold = operational_cost_gold,
    base_operational_cost_gold = operational_cost_gold,
    forge_allocated_coal_gold = 0,
    cost_breakdown_json = encode_breakdown(breakdown),
    appearance_key = appearance_key,
    crafted_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    materials = materials_payload,
    materials_source = materials_source,
    materials_cost_gold = materials_cost
  })

  ledger.apply_event(state, event)

  return state
end

function ledger.apply_forge_fire(state, forge_session_id, source_id, opts)
  opts = opts or {}
  local resolved_source_id = ensure_source_or_stub(state, source_id, "skill", "forging")
  local coal_basis = opts.coal_cost_gold
  local coal_cost_explicit = 0
  if coal_basis == nil then
    local inventory = get_inventory()
    local coal_qty = inventory.get_qty(state.inventory, "coal")
    if coal_qty < 1 then
      error("Insufficient coal: have " .. tostring(coal_qty) .. ", need 1")
    end
    coal_basis = inventory.get_unit_cost(state.inventory, "coal")
  else
    coal_cost_explicit = 1
  end
  local event = ledger.record_event(state, "FORGE_FIRE", {
    forge_session_id = forge_session_id,
    source_id = resolved_source_id,
    coal_basis_gold = coal_basis,
    coal_cost_explicit = coal_cost_explicit,
    expires_at = opts.expires_at,
    status = "in_flight",
    note = opts.note,
    started_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  })
  ledger.apply_event(state, event)
  return state
end

function ledger.apply_forge_attach(state, forge_session_id, item_id)
  local event = ledger.record_event(state, "FORGE_ATTACH_ITEM", {
    forge_session_id = forge_session_id,
    item_id = item_id,
    allocated_coal_gold = 0
  })
  ledger.apply_event(state, event)
  return state
end

function ledger.apply_forge_finalize(state, forge_session_id, status, method, note)
  local session = state.forge_sessions[forge_session_id]
  if not session then
    error("Forge session " .. tostring(forge_session_id) .. " not found")
  end
  if session.status ~= "in_flight" then
    error("Forge session " .. tostring(forge_session_id) .. " is not in_flight")
  end

  method = method or "cost_weighted"
  if method ~= "cost_weighted" then
    error("Unsupported forge allocation method: " .. tostring(method))
  end

  local item_allocs = state.forge_session_items[forge_session_id] or {}
  local attached_ids = {}
  for item_id, _ in pairs(item_allocs) do
    table.insert(attached_ids, item_id)
  end
  table.sort(attached_ids)

  local events = {
    {
      event_type = status == "expired" and "FORGE_EXPIRE" or "FORGE_CLOSE",
      payload = {
        forge_session_id = forge_session_id,
        status = status,
        method = method,
        note = note,
        closed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
      }
    }
  }

  local coal_total = session.coal_basis_gold or 0
  if #attached_ids == 0 then
    if status == "expired" and coal_total > 0 then
      table.insert(events, {
        event_type = "FORGE_WRITE_OFF",
        payload = {
          forge_session_id = forge_session_id,
          amount_gold = coal_total,
          reason = "forge_expire_unused",
          note = note
        }
      })
    end
  elseif coal_total > 0 then
    local weighted = {}
    local total_base = 0
    for _, item_id in ipairs(attached_ids) do
      local item = state.crafted_items[item_id]
      if not item then
        error("Crafted item " .. tostring(item_id) .. " not found")
      end
      local base = item_base_cost(item)
      total_base = total_base + base
      table.insert(weighted, { item_id = item_id, cost = base })
    end

    local allocations = {}
    local computed_over = {}
    local item_breakdowns = {}
    local allocated_sum = 0
    if total_base <= 0 then
      local per = math.floor(coal_total / #weighted)
      for index, row in ipairs(weighted) do
        local alloc = (index < #weighted) and per or (coal_total - allocated_sum)
        allocations[row.item_id] = alloc
        computed_over[row.item_id] = row.cost
        local item = state.crafted_items[row.item_id]
        local breakdown = decode_breakdown(item and item.cost_breakdown_json or "{}")
        breakdown.base_operational_cost_gold = row.cost
        breakdown.forge_coal_allocated_gold = (item and item.forge_allocated_coal_gold or 0) + alloc
        breakdown.forge_session_id = forge_session_id
        item_breakdowns[row.item_id] = encode_breakdown(breakdown)
        allocated_sum = allocated_sum + alloc
      end
    else
      for index, row in ipairs(weighted) do
        local alloc = 0
        if index < #weighted then
          alloc = math.floor(coal_total * row.cost / total_base)
        else
          alloc = coal_total - allocated_sum
        end
        allocations[row.item_id] = alloc
        computed_over[row.item_id] = row.cost
        local item = state.crafted_items[row.item_id]
        local breakdown = decode_breakdown(item and item.cost_breakdown_json or "{}")
        breakdown.base_operational_cost_gold = row.cost
        breakdown.forge_coal_allocated_gold = (item and item.forge_allocated_coal_gold or 0) + alloc
        breakdown.forge_session_id = forge_session_id
        item_breakdowns[row.item_id] = encode_breakdown(breakdown)
        allocated_sum = allocated_sum + alloc
      end
    end

    table.insert(events, {
      event_type = "FORGE_ALLOCATE",
      payload = {
        forge_session_id = forge_session_id,
        method = method,
        allocations = allocations,
        session_total_gold = coal_total,
        computed_over = computed_over,
        item_breakdowns = item_breakdowns
      }
    })
  end

  ledger.record_events(state, events)
  for _, event in ipairs(events) do
    ledger.apply_event(state, event)
  end

  return state
end

function ledger.apply_forge_close(state, forge_session_id, method, note)
  return ledger.apply_forge_finalize(state, forge_session_id, "closed", method, note)
end

function ledger.apply_forge_expire(state, forge_session_id, note)
  return ledger.apply_forge_finalize(state, forge_session_id, "expired", "cost_weighted", note)
end

function ledger.apply_augment_item(state, new_item_id, source_id, target_item_id, opts)
  opts = opts or {}
  local resolved_source_id = ensure_source_or_stub(state, source_id, "skill", "augmentation")
  local source = state.production_sources[resolved_source_id]
  if not source then
    error("Augmentation source " .. tostring(resolved_source_id) .. " not found")
  end
  local target_item = state.crafted_items[target_item_id]
  local target_external = state.external_items[target_item_id]
  if not target_item and not target_external then
    error("Target item " .. tostring(target_item_id) .. " not found")
  end

  local materials = opts.materials
  local materials_source = nil
  if materials and next(materials) ~= nil then
    materials_source = "explicit"
  elseif source.bom and next(source.bom) ~= nil then
    materials = source.bom
    materials_source = "design_bom"
  else
    materials = {}
    materials_source = "manual"
  end

  local materials_cost = 0
  if next(materials) ~= nil then
    materials_cost = compute_material_cost(state, materials)
  end
  local fee = opts.fee_gold or 0
  local time_cost = opts.time_cost_gold or 0
  local parent_basis = 0
  local target_item_kind = "crafted"
  if target_item then
    parent_basis = target_item.operational_cost_gold or 0
    target_item_kind = "crafted"
  else
    parent_basis = target_external.basis_gold or 0
    target_item_kind = "external"
  end
  local operational_cost = parent_basis + materials_cost + fee + time_cost

  local breakdown = {
    transform_kind = "augmentation",
    parent_item_id = target_item_id,
    parent_basis_gold = parent_basis,
    materials = materials,
    materials_cost_gold = materials_cost,
    fee_gold = fee,
    time_cost_gold = time_cost,
    base_operational_cost_gold = operational_cost,
    forge_coal_allocated_gold = 0
  }

  local event = ledger.record_event(state, "AUGMENT_ITEM", {
    new_item_id = new_item_id,
    source_id = resolved_source_id,
    source_kind = "skill",
    source_type = "augmentation",
    target_item_id = target_item_id,
    target_item_kind = target_item_kind,
    transform_kind = "augmentation",
    materials = materials,
    materials_source = materials_source,
    materials_cost_gold = materials_cost,
    fee_gold = fee,
    time_cost_gold = time_cost,
    operational_cost_gold = operational_cost,
    appearance_key = opts.appearance_key,
    note = opts.note,
    cost_breakdown_json = encode_breakdown(breakdown),
    crafted_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  })

  ledger.apply_event(state, event)
  return state
end

function ledger.apply_craft_resolve(state, item_id, design_id, reason)
  local resolved_design_id = resolve_source_id(state, design_id)
  local event = ledger.record_event(state, "CRAFT_RESOLVE_SOURCE", {
    item_id = item_id,
    source_id = resolved_design_id,
    source_kind = "design",
    design_id = resolved_design_id,
    reason = reason
  })

  ledger.apply_event(state, event)

  return state
end

function ledger.apply_item_add_external(state, item_id, name, basis_gold, basis_source, note, acquired_at)
  local event = ledger.record_event(state, "ITEM_REGISTER_EXTERNAL", {
    item_id = item_id,
    name = name,
    basis_gold = basis_gold,
    basis_source = basis_source or "unknown",
    acquired_at = acquired_at or os.date("!%Y-%m-%dT%H:%M:%SZ"),
    status = "active",
    note = note
  })

  ledger.apply_event(state, event)

  return state
end

function ledger.apply_item_update_external(state, item_id, fields)
  fields = fields or {}
  local payload = { item_id = item_id }
  payload.name = fields.name
  payload.basis_gold = fields.basis_gold
  payload.basis_source = fields.basis_source
  payload.status = fields.status
  payload.note = fields.note
  local event = ledger.record_event(state, "ITEM_UPDATE_EXTERNAL", payload)
  ledger.apply_event(state, event)
  return state
end

function ledger.apply_sell_item(state, sale_id, item_id, sale_price_gold, game_time)
  local event = ledger.record_event(state, "SELL_ITEM", {
    sale_id = sale_id,
    item_id = item_id,
    sale_price_gold = sale_price_gold,
    sold_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    game_time = game_time
  })

  return ledger.apply_event(state, event)
end

function ledger.apply_order_create(state, order_id, customer, note)
  if state.orders[order_id] then
    error("Order " .. order_id .. " already exists")
  end

  local event = ledger.record_event(state, "ORDER_CREATE", {
    order_id = order_id,
    customer = customer,
    note = note,
    status = "open",
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  })

  ledger.apply_event(state, event)

  return state
end

function ledger.apply_order_add_sale(state, order_id, sale_id)
  local order = state.orders[order_id]
  if not order then
    error("Order " .. order_id .. " not found")
  end

  if not state.sales[sale_id] then
    error("Sale " .. sale_id .. " not found")
  end

  local existing_order = state.sale_orders[sale_id]
  if existing_order then
    error("Sale " .. sale_id .. " already linked to order " .. existing_order)
  end

  local event = ledger.record_event(state, "ORDER_ADD_SALE", {
    order_id = order_id,
    sale_id = sale_id
  })

  ledger.apply_event(state, event)

  return state
end

function ledger.apply_order_add_item(state, order_id, item_id)
  local order = state.orders[order_id]
  if not order then
    error("Order " .. order_id .. " not found")
  end

  if not state.crafted_items[item_id] then
    error("Item " .. item_id .. " not found")
  end

  local existing_order = state.item_orders[item_id]
  if existing_order then
    error("Item " .. item_id .. " already linked to order " .. existing_order)
  end

  local event = ledger.record_event(state, "ORDER_ADD_ITEM", {
    order_id = order_id,
    item_id = item_id
  })

  ledger.apply_event(state, event)

  return state
end

local function allocate_cost_weighted(items, total_amount)
  local total_cost = 0
  for _, item in ipairs(items) do
    total_cost = total_cost + item.cost
  end
  if total_cost <= 0 then
    error("Total cost must be positive for settlement allocation")
  end

  local allocations = {}
  local allocated_sum = 0
  for i = 1, #items do
    local item = items[i]
    if i < #items then
      local alloc = math.floor(total_amount * item.cost / total_cost)
      table.insert(allocations, {
        item_id = item.item_id,
        amount = alloc
      })
      allocated_sum = allocated_sum + alloc
    else
      table.insert(allocations, {
        item_id = item.item_id,
        amount = total_amount - allocated_sum
      })
    end
  end

  return allocations
end

function ledger.apply_order_settle(state, settlement_id, order_id, amount_gold, method, sale_ids)
  local order = state.orders[order_id]
  if not order then
    error("Order " .. order_id .. " not found")
  end

  local items = state.order_items[order_id] or {}
  local item_ids = {}
  for item_id, _ in pairs(items) do
    table.insert(item_ids, item_id)
  end
  table.sort(item_ids)

  if #item_ids == 0 then
    error("Order has no items to settle")
  end

  method = method or "cost_weighted"
  if method ~= "cost_weighted" then
    error("Unsupported settlement method: " .. tostring(method))
  end

  local cost_items = {}
  for _, item_id in ipairs(item_ids) do
    local item = state.crafted_items[item_id]
    if not item then
      error("Item " .. item_id .. " not found")
    end
    for _, sale in pairs(state.sales) do
      if sale.item_id == item_id then
        error("Item " .. item_id .. " already sold")
      end
    end
    table.insert(cost_items, { item_id = item_id, cost = item.operational_cost_gold or 0 })
  end

  local allocations = allocate_cost_weighted(cost_items, amount_gold)
  local events = {}
  local ts = os.date("!%Y-%m-%dT%H:%M:%SZ")

  table.insert(events, {
    event_type = "ORDER_SETTLE",
    payload = {
      settlement_id = settlement_id,
      order_id = order_id,
      amount_gold = amount_gold,
      method = method,
      received_at = ts
    },
    ts = ts
  })

  for index, alloc in ipairs(allocations) do
    local sale_id = sale_ids and sale_ids[index]
    if not sale_id then
      error("Missing sale id for settlement allocation")
    end

    table.insert(events, {
      event_type = "SELL_ITEM",
      payload = {
        sale_id = sale_id,
        item_id = alloc.item_id,
        sale_price_gold = alloc.amount,
        sold_at = ts,
        game_time = nil,
        settlement_id = settlement_id
      },
      ts = ts
    })

    table.insert(events, {
      event_type = "ORDER_ADD_SALE",
      payload = {
        order_id = order_id,
        sale_id = sale_id
      },
      ts = ts
    })
  end

  ledger.record_events(state, events)
  for _, event in ipairs(events) do
    ledger.apply_event(state, event)
  end

  return state
end

function ledger.apply_order_close(state, order_id)
  local order = state.orders[order_id]
  if not order then
    error("Order " .. order_id .. " not found")
  end

  local event = ledger.record_event(state, "ORDER_CLOSE", {
    order_id = order_id,
    status = "closed",
    closed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  })

  ledger.apply_event(state, event)

  return state
end

function ledger.report_item(state, item_id)
  local item = state.crafted_items[item_id]
  local external = nil
  if not item then
    external = state.external_items[item_id]
    if not external then
      error("Item " .. item_id .. " not found")
    end
  end

  local sale = nil
  for _, sale_record in pairs(state.sales) do
    if sale_record.item_id == item_id then
      sale = sale_record
      break
    end
  end

  local source = item and item.source_id and state.production_sources[item.source_id] or nil
  local pattern_pool = nil
  if source and source.pattern_pool_id then
    pattern_pool = state.pattern_pools[source.pattern_pool_id]
  end

  local is_external = (item == nil)
  local report_design_id = nil
  local report_source_id = nil
  local report_source_kind = "external"
  local report_appearance = nil
  local report_operational_cost = external and external.basis_gold or 0
  local report_base_cost = report_operational_cost
  local report_forge_alloc = 0
  local report_pending_forge = false
  local report_pending_session = nil
  local report_transformed = (external and external.status == "transformed") or false
  local report_parent_item = nil
  local report_breakdown = "{}"

  if not is_external then
    report_design_id = item.source_id
    report_source_id = item.source_id
    report_source_kind = item.source_kind
    report_appearance = item.appearance_key
    report_operational_cost = item.operational_cost_gold
    report_base_cost = item_base_cost(item)
    report_forge_alloc = item.forge_allocated_coal_gold or 0
    report_pending_forge = item.pending_forge_session_id ~= nil
    report_pending_session = item.pending_forge_session_id
    report_transformed = item.transformed == 1
    report_parent_item = item.parent_item_id
    report_breakdown = item.cost_breakdown_json
  end

  local report = {
    item_id = item_id,
    design_id = report_design_id,
    source_id = report_source_id,
    source_kind = report_source_kind,
    appearance_key = report_appearance,
    operational_cost_gold = report_operational_cost,
    base_operational_cost_gold = report_base_cost,
    forge_allocated_coal_gold = report_forge_alloc,
    pending_forge_allocation = report_pending_forge,
    pending_forge_session_id = report_pending_session,
    transformed = report_transformed,
    parent_item_id = report_parent_item,
    cost_breakdown_json = report_breakdown,
    external_name = external and external.name or nil,
    external_basis_source = external and external.basis_source or nil,
    external_status = external and external.status or nil,
    sale_id = sale and sale.sale_id or nil,
    sale_price_gold = sale and sale.sale_price_gold or nil,
    provenance = source and source.provenance or nil,
    design_remaining = source and source.capital_remaining or nil,
    pattern_remaining = pattern_pool and pattern_pool.capital_remaining_gold or nil
  }

  if sale and item and item.source_id then
    report.operational_profit = sale.operational_profit
    report.applied_to_design_capital = sale.applied_to_design_capital
    report.applied_to_pattern_capital = sale.applied_to_pattern_capital
    report.true_profit = sale.true_profit
  elseif sale and external then
    report.operational_profit = sale.operational_profit or ((sale.sale_price_gold or 0) - (external.basis_gold or 0))
    report.applied_to_design_capital = sale.applied_to_design_capital or 0
    report.applied_to_pattern_capital = sale.applied_to_pattern_capital or 0
    report.true_profit = sale.true_profit or report.operational_profit
  else
    report.unsold_cost_basis = item and item.operational_cost_gold or external.basis_gold
  end

  return report
end

function ledger.apply_process_start(state, process_instance_id, process_id, inputs, gold_fee, note, game_time)
  local started_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local event = ledger.record_event(state, "PROCESS_START", {
    process_instance_id = process_instance_id,
    process_id = process_id,
    inputs = inputs or {},
    gold_fee = gold_fee or 0,
    note = note,
    started_at = started_at,
    game_time = game_time
  })

  return ledger.apply_event(state, event)
end

function ledger.apply_process_add_inputs(state, process_instance_id, inputs, note, game_time)
  local event = ledger.record_event(state, "PROCESS_ADD_INPUTS", {
    process_instance_id = process_instance_id,
    inputs = inputs or {},
    note = note,
    game_time = game_time
  })

  return ledger.apply_event(state, event)
end

function ledger.apply_process_add_fee(state, process_instance_id, gold_fee, note, game_time)
  local event = ledger.record_event(state, "PROCESS_ADD_FEE", {
    process_instance_id = process_instance_id,
    gold_fee = gold_fee,
    note = note,
    game_time = game_time
  })

  return ledger.apply_event(state, event)
end

function ledger.apply_process_complete(state, process_instance_id, outputs, note, game_time)
  local instance = state.process_instances and state.process_instances[process_instance_id]
  if not instance then
    error("Process instance not found: " .. process_instance_id)
  end

  outputs = outputs or {}
  local total_output_qty = 0
  for _, qty in pairs(outputs) do
    total_output_qty = total_output_qty + qty
  end

  local committed_basis = (instance.committed_cost_total or 0) + (instance.fees_total or 0)
  local committed_qty = 0
  local commodity_count = 0
  do
    local totals = {}
    for _, entry in ipairs(instance.committed_entries or {}) do
      committed_qty = committed_qty + (entry.qty or 0)
      totals[entry.commodity] = (totals[entry.commodity] or 0) + (entry.qty or 0)
    end
    for _ in pairs(totals) do
      commodity_count = commodity_count + 1
    end
  end

  local output_basis = 0
  if total_output_qty > 0 and committed_basis > 0 then
    local material_basis = instance.committed_cost_total or 0
    local fee_basis = instance.fees_total or 0
    if commodity_count == 0 or committed_qty <= 0 then
      output_basis = material_basis + fee_basis
    elseif commodity_count > 1 then
      output_basis = material_basis + fee_basis
    elseif committed_qty > 0 then
      local ratio = total_output_qty / committed_qty
      if ratio > 1 then
        ratio = 1
      end
      output_basis = (material_basis * ratio) + fee_basis
    end
  end

  local process_loss = committed_basis - output_basis

  local completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local events = {
    {
      event_type = "PROCESS_COMPLETE",
      payload = {
        process_instance_id = process_instance_id,
        outputs = outputs,
        note = note,
        completed_at = completed_at,
        game_time = game_time
      }
    }
  }

  if process_loss > 0.0001 then
    table.insert(events, {
      event_type = "PROCESS_WRITE_OFF",
      payload = {
        process_instance_id = process_instance_id,
        amount_gold = process_loss,
        game_time = game_time
      }
    })
  end

  ledger.record_events(state, events)
  for _, event in ipairs(events) do
    ledger.apply_event(state, event)
  end

  return state
end

local function sum_committed_inputs(instance)
  local totals = {}
  for _, entry in ipairs(instance.committed_entries or {}) do
    totals[entry.commodity] = (totals[entry.commodity] or 0) + (entry.qty or 0)
  end
  return totals
end

local function validate_disposition(totals, returned, lost)
  for commodity, qty in pairs(returned) do
    if type(qty) ~= "number" or qty < 0 then
      error("Returned qty must be non-negative for " .. commodity)
    end
  end
  for commodity, qty in pairs(lost) do
    if type(qty) ~= "number" or qty < 0 then
      error("Lost qty must be non-negative for " .. commodity)
    end
  end

  for commodity, qty in pairs(totals) do
    local ret = returned[commodity] or 0
    local los = lost[commodity] or 0
    if ret + los > qty + 0.0001 then
      error("Disposition exceeds committed inputs for " .. commodity)
    end
  end
end

local function complete_missing_disposition(totals, returned, lost)
  local has_returned = next(returned) ~= nil
  local has_lost = next(lost) ~= nil

  if not has_returned and not has_lost then
    for commodity, qty in pairs(totals) do
      lost[commodity] = qty
    end
    return returned, lost
  end

  if has_returned and not has_lost then
    for commodity, qty in pairs(totals) do
      local ret = returned[commodity] or 0
      if ret > qty then
        error("Returned qty exceeds committed inputs for " .. commodity)
      end
      lost[commodity] = qty - ret
    end
    return returned, lost
  end

  if has_lost and not has_returned then
    for commodity, qty in pairs(totals) do
      local los = lost[commodity] or 0
      if los > qty then
        error("Lost qty exceeds committed inputs for " .. commodity)
      end
      returned[commodity] = qty - los
    end
    return returned, lost
  end

  return returned, lost
end

function ledger.apply_process_abort(state, process_instance_id, disposition, note, game_time)
  local instance = state.process_instances and state.process_instances[process_instance_id]
  if not instance then
    error("Process instance not found: " .. process_instance_id)
  end

  disposition = disposition or {}
  local returned = disposition.returned or {}
  local lost = disposition.lost or {}
  local outputs = disposition.outputs or {}

  local totals = sum_committed_inputs(instance)
  returned, lost = complete_missing_disposition(totals, returned, lost)
  validate_disposition(totals, returned, lost)

  if next(returned) ~= nil and next(lost) ~= nil then
    for commodity, qty in pairs(totals) do
      local ret = returned[commodity] or 0
      local los = lost[commodity] or 0
      if math.abs((ret + los) - qty) > 0.0001 then
        error("Disposition does not cover all committed inputs for " .. commodity)
      end
    end
  end

  local total_output_qty = 0
  for _, qty in pairs(outputs) do
    total_output_qty = total_output_qty + qty
  end

  local committed_basis = (instance.committed_cost_total or 0) + (instance.fees_total or 0)
  local committed_qty = 0
  local commodity_count = 0
  do
    local totals = {}
    for _, entry in ipairs(instance.committed_entries or {}) do
      committed_qty = committed_qty + (entry.qty or 0)
      totals[entry.commodity] = (totals[entry.commodity] or 0) + (entry.qty or 0)
    end
    for _ in pairs(totals) do
      commodity_count = commodity_count + 1
    end
  end

  local output_basis = 0
  if total_output_qty > 0 and committed_basis > 0 then
    local material_basis = instance.committed_cost_total or 0
    local fee_basis = instance.fees_total or 0
    if commodity_count == 0 or committed_qty <= 0 then
      output_basis = material_basis + fee_basis
    elseif commodity_count > 1 then
      output_basis = material_basis + fee_basis
    elseif committed_qty > 0 then
      local ratio = total_output_qty / committed_qty
      if ratio > 1 then
        ratio = 1
      end
      output_basis = (material_basis * ratio) + fee_basis
    end
  end

  local process_loss = committed_basis - output_basis

  local completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local events = {
    {
      event_type = "PROCESS_ABORT",
      payload = {
        process_instance_id = process_instance_id,
        disposition = {
          returned = returned,
          lost = lost,
          outputs = outputs
        },
        note = note,
        completed_at = completed_at,
        game_time = game_time
      }
    }
  }

  if process_loss > 0.0001 then
    table.insert(events, {
      event_type = "PROCESS_WRITE_OFF",
      payload = {
        process_instance_id = process_instance_id,
        amount_gold = process_loss,
        game_time = game_time
      }
    })
  end

  ledger.record_events(state, events)
  for _, event in ipairs(events) do
    ledger.apply_event(state, event)
  end

  return state
end

function ledger.apply_process_set_game_time(state, process_instance_id, game_time, scope, note)
  scope = scope or "write_off"
  if scope ~= "start" and scope ~= "complete" and scope ~= "abort" and scope ~= "write_off" and scope ~= "all" then
    error("Invalid scope: " .. tostring(scope))
  end
  if not game_time or not game_time.year then
    error("game_time.year is required")
  end

  local instance = state.process_instances and state.process_instances[process_instance_id]
  if not instance then
    error("Process instance not found: " .. process_instance_id)
  end

  local event = ledger.record_event(state, "PROCESS_SET_GAME_TIME", {
    process_instance_id = process_instance_id,
    scope = scope,
    game_time = game_time,
    note = note
  })

  return ledger.apply_event(state, event)
end

_G.AchaeadexLedger.Core.Ledger = ledger

return ledger
