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

local function get_designs()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.Designs then
    error("AchaeadexLedger.Core.Designs is not loaded")
  end

  return _G.AchaeadexLedger.Core.Designs
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

local function require_event_store(state)
  if not state.event_store then
    error("EventStore is required on ledger state")
  end
end

local function resolve_design_id(state, design_id)
  if state.designs[design_id] then
    return design_id
  end

  local alias = state.design_aliases[design_id]
  if alias and alias.design_id then
    return alias.design_id
  end

  error("Design " .. design_id .. " not found")
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
    designs = {}, -- design_id -> design data
    pattern_pools = {}, -- pattern_pool_id -> pool data
    pattern_pools_by_type = {}, -- pattern_type -> active pool id
    crafted_items = {}, -- item_id -> item data
    design_aliases = {}, -- alias_id -> design_id
    appearance_aliases = {}, -- appearance_key -> design_id
    process_instances = {}, -- process_instance_id -> process data
    sales = {}, -- sale_id -> sale data
    orders = {}, -- order_id -> order data
    order_sales = {}, -- order_id -> { sale_id = true }
    sale_orders = {}, -- sale_id -> order_id
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

  event.id = state.event_store:append(event)

  return event
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
  elseif event_type == "DESIGN_START" then
    local designs = get_designs()
    local design = designs.create(state, payload.design_id, payload.design_type, payload.name, payload.provenance, payload.recovery_enabled)
    if payload.pattern_pool_id then
      design.pattern_pool_id = payload.pattern_pool_id
    end
    if payload.created_at then
      design.created_at = payload.created_at
    end
  elseif event_type == "DESIGN_COST" then
    local designs = get_designs()
    local resolved_design_id = resolve_design_id(state, payload.design_id)
    designs.add_capital(state, resolved_design_id, payload.amount)
  elseif event_type == "DESIGN_SET_PER_ITEM_FEE" then
    local resolved_design_id = resolve_design_id(state, payload.design_id)
    state.designs[resolved_design_id].per_item_fee_gold = payload.amount
  elseif event_type == "PATTERN_ACTIVATE" then
    local pattern_pools = get_pattern_pools()
    pattern_pools.activate(state, payload.pattern_pool_id, payload.pattern_type, payload.pattern_name, payload.capital_initial, payload.activated_at)
  elseif event_type == "PATTERN_DEACTIVATE" then
    local pattern_pools = get_pattern_pools()
    pattern_pools.deactivate(state, payload.pattern_pool_id, payload.deactivated_at)
  elseif event_type == "DESIGN_REGISTER_ALIAS" then
    local resolved_design_id = resolve_design_id(state, payload.design_id)
    state.design_aliases[payload.alias_id] = {
      design_id = resolved_design_id,
      alias_kind = payload.alias_kind,
      active = payload.active
    }
  elseif event_type == "DESIGN_REGISTER_APPEARANCE" then
    local resolved_design_id = resolve_design_id(state, payload.design_id)
    local existing = state.appearance_aliases[payload.appearance_key]
    if existing and existing.design_id ~= resolved_design_id then
      error("Appearance key already mapped to a different design")
    end
    state.appearance_aliases[payload.appearance_key] = {
      design_id = resolved_design_id,
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
  elseif event_type == "ORDER_CLOSE" then
    local order = state.orders[payload.order_id]
    if not order then
      error("Order " .. payload.order_id .. " not found")
    end
    order.status = payload.status or order.status
    order.closed_at = payload.closed_at
  elseif event_type == "CRAFT_ITEM" then
    state.crafted_items[payload.item_id] = {
      item_id = payload.item_id,
      design_id = payload.design_id,
      crafted_at = payload.crafted_at,
      operational_cost_gold = payload.operational_cost_gold,
      cost_breakdown_json = payload.cost_breakdown_json,
      appearance_key = payload.appearance_key
    }
  elseif event_type == "CRAFT_RESOLVE_DESIGN" then
    local item = state.crafted_items[payload.item_id]
    if not item then
      error("Crafted item " .. payload.item_id .. " not found")
    end
    item.design_id = resolve_design_id(state, payload.design_id)
  elseif event_type == "SELL_ITEM" then
    if payload.operational_profit ~= nil and payload.design_id then
      local recovery = get_recovery()
      local resolved_design_id = resolve_design_id(state, payload.design_id)
      return recovery.apply_to_state(state, resolved_design_id, payload.operational_profit)
    end

    local item = state.crafted_items[payload.item_id]
    if not item then
      error("Crafted item " .. payload.item_id .. " not found")
    end
    if not item.design_id then
      error("Crafted item " .. payload.item_id .. " design is unresolved")
    end

    local sale = {
      sale_id = payload.sale_id,
      item_id = payload.item_id,
      sold_at = payload.sold_at,
      sale_price_gold = payload.sale_price_gold,
      game_time = payload.game_time
    }
    state.sales[payload.sale_id] = sale

    local operational_profit = payload.sale_price_gold - item.operational_cost_gold
    local result = get_recovery().apply_to_state(state, item.design_id, operational_profit)
    sale.operational_profit = result.operational_profit
    sale.applied_to_design_capital = result.applied_to_design_capital
    sale.applied_to_pattern_capital = result.applied_to_pattern_capital
    sale.true_profit = result.true_profit
    return result
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
function ledger.apply_broker_sell(state, commodity, qty, unit_price)
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
    profit = profit
  })

  ledger.apply_event(state, event)

  return state, profit
end

-- Process immediate PROCESS_APPLY event
function ledger.apply_process(state, process_id, inputs, outputs, gold_fee)
  local event = ledger.record_event(state, "PROCESS_APPLY", {
    process_id = process_id,
    inputs = inputs,
    outputs = outputs,
    gold_fee = gold_fee or 0
  })

  ledger.apply_event(state, event)

  return state
end

-- Process DESIGN_COST event
function ledger.apply_design_cost(state, design_id, amount, kind)
  local resolved_design_id = resolve_design_id(state, design_id)
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
  local designs = get_designs()
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
  local resolved_design_id = resolve_design_id(state, design_id)

  local event = ledger.record_event(state, "DESIGN_SET_PER_ITEM_FEE", {
    design_id = resolved_design_id,
    amount = amount
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
  local resolved_design_id = resolve_design_id(state, design_id)
  local event = ledger.record_event(state, "SELL_ITEM", {
    design_id = resolved_design_id,
    operational_profit = operational_profit
  })

  local result = ledger.apply_event(state, event)

  return result
end

function ledger.apply_design_alias(state, design_id, alias_id, alias_kind, active)
  local resolved_design_id = resolve_design_id(state, design_id)
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
  local resolved_design_id = resolve_design_id(state, design_id)
  local existing = state.appearance_aliases[appearance_key]
  if existing and existing.design_id ~= resolved_design_id then
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

function ledger.apply_craft_item(state, item_id, design_id, operational_cost_gold, cost_breakdown_json, appearance_key)
  local event = ledger.record_event(state, "CRAFT_ITEM", {
    item_id = item_id,
    design_id = design_id,
    operational_cost_gold = operational_cost_gold,
    cost_breakdown_json = cost_breakdown_json,
    appearance_key = appearance_key,
    crafted_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  })

  ledger.apply_event(state, event)

  return state
end

function ledger.apply_craft_resolve(state, item_id, design_id, reason)
  local resolved_design_id = resolve_design_id(state, design_id)
  local event = ledger.record_event(state, "CRAFT_RESOLVE_DESIGN", {
    item_id = item_id,
    design_id = resolved_design_id,
    reason = reason
  })

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
  if not item then
    error("Crafted item " .. item_id .. " not found")
  end

  local sale = nil
  for _, sale_record in pairs(state.sales) do
    if sale_record.item_id == item_id then
      sale = sale_record
      break
    end
  end

  local design = item.design_id and state.designs[item.design_id] or nil
  local pattern_pool = nil
  if design and design.pattern_pool_id then
    pattern_pool = state.pattern_pools[design.pattern_pool_id]
  end

  local report = {
    item_id = item_id,
    design_id = item.design_id,
    appearance_key = item.appearance_key,
    operational_cost_gold = item.operational_cost_gold,
    cost_breakdown_json = item.cost_breakdown_json,
    sale_id = sale and sale.sale_id or nil,
    sale_price_gold = sale and sale.sale_price_gold or nil,
    provenance = design and design.provenance or nil,
    design_remaining = design and design.capital_remaining or nil,
    pattern_remaining = pattern_pool and pattern_pool.capital_remaining_gold or nil
  }

  if sale and item.design_id then
    report.operational_profit = sale.operational_profit
    report.applied_to_design_capital = sale.applied_to_design_capital
    report.applied_to_pattern_capital = sale.applied_to_pattern_capital
    report.true_profit = sale.true_profit
  else
    report.unsold_cost_basis = item.operational_cost_gold
  end

  return report
end

function ledger.apply_process_start(state, process_instance_id, process_id, inputs, gold_fee, note)
  local started_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local event = ledger.record_event(state, "PROCESS_START", {
    process_instance_id = process_instance_id,
    process_id = process_id,
    inputs = inputs or {},
    gold_fee = gold_fee or 0,
    note = note,
    started_at = started_at
  })

  return ledger.apply_event(state, event)
end

function ledger.apply_process_add_inputs(state, process_instance_id, inputs, note)
  local event = ledger.record_event(state, "PROCESS_ADD_INPUTS", {
    process_instance_id = process_instance_id,
    inputs = inputs or {},
    note = note
  })

  return ledger.apply_event(state, event)
end

function ledger.apply_process_add_fee(state, process_instance_id, gold_fee, note)
  local event = ledger.record_event(state, "PROCESS_ADD_FEE", {
    process_instance_id = process_instance_id,
    gold_fee = gold_fee,
    note = note
  })

  return ledger.apply_event(state, event)
end

function ledger.apply_process_complete(state, process_instance_id, outputs, note)
  local completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local event = ledger.record_event(state, "PROCESS_COMPLETE", {
    process_instance_id = process_instance_id,
    outputs = outputs or {},
    note = note,
    completed_at = completed_at
  })

  return ledger.apply_event(state, event)
end

function ledger.apply_process_abort(state, process_instance_id, disposition, note)
  local completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local event = ledger.record_event(state, "PROCESS_ABORT", {
    process_instance_id = process_instance_id,
    disposition = disposition or {},
    note = note,
    completed_at = completed_at
  })

  return ledger.apply_event(state, event)
end

_G.AchaeadexLedger.Core.Ledger = ledger

return ledger
