-- SQLite projector for materialized domain tables

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local projector = _G.AchaeadexLedger.Core.Projector or {}

local function get_recovery()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.Recovery then
    error("AchaeadexLedger.Core.Recovery is not loaded")
  end

  return _G.AchaeadexLedger.Core.Recovery
end

local function get_json()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.Json then
    error("AchaeadexLedger.Core.Json is not loaded")
  end

  return _G.AchaeadexLedger.Core.Json
end

local function sql_value(value)
  if value == nil then
    return "NULL"
  end
  if type(value) == "number" then
    return tostring(value)
  end
  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function exec_sql(conn, sql)
  local result, err = conn:execute(sql)
  if not result then
    error("SQL execution failed: " .. tostring(err))
  end
  if type(result) == "userdata" then
    result:close()
  end
end

local function fetch_one(conn, sql)
  local cur = assert(conn:execute(sql))
  local row = cur:fetch({}, "a")
  cur:close()
  return row
end

local function payload_game_year(payload)
  if not payload or not payload.game_time or payload.game_time.year == nil then
    return nil
  end
  return tonumber(payload.game_time.year)
end

local function resolve_default_game_year(conn, event_id)
  if not event_id then
    return nil
  end
  local row = fetch_one(conn, string.format(
    "SELECT default_year FROM ledger_game_year_defaults WHERE effective_from_event_id <= %s ORDER BY effective_from_event_id DESC LIMIT 1",
    sql_value(event_id)
  ))
  if not row then
    return nil
  end
  return tonumber(row.default_year)
end

local function resolve_process_override_year(conn, process_instance_id, scope)
  if not process_instance_id then
    return nil
  end
  local json = get_json()
  local row = fetch_one(conn, string.format(
    "SELECT game_time_json FROM process_game_time_overrides WHERE process_instance_id = %s AND scope = %s",
    sql_value(process_instance_id),
    sql_value(scope)
  ))
  if row and row.game_time_json then
    local decoded = json.decode(row.game_time_json)
    if decoded and decoded.year then
      return tonumber(decoded.year)
    end
  end

  row = fetch_one(conn, string.format(
    "SELECT game_time_json FROM process_game_time_overrides WHERE process_instance_id = %s AND scope = 'all'",
    sql_value(process_instance_id)
  ))
  if row and row.game_time_json then
    local decoded = json.decode(row.game_time_json)
    if decoded and decoded.year then
      return tonumber(decoded.year)
    end
  end

  return nil
end

local function resolve_game_year(conn, event, payload, opts)
  opts = opts or {}
  local year = payload_game_year(payload)
  if year then
    return year
  end

  if opts.process_instance_id and opts.process_scope then
    local override = resolve_process_override_year(conn, opts.process_instance_id, opts.process_scope)
    if override then
      return override
    end
  end

  return resolve_default_game_year(conn, event and event.id or nil)
end

local function resolve_source_id(conn, source_id)
  local row = fetch_one(conn, "SELECT source_id FROM production_sources WHERE source_id = " .. sql_value(source_id))
  if row and row.source_id then
    return row.source_id
  end
  row = fetch_one(conn, "SELECT source_id FROM design_id_aliases WHERE alias_id = " .. sql_value(source_id))
  if row and row.source_id then
    return row.source_id
  end
  row = fetch_one(conn, "SELECT design_id FROM design_id_aliases WHERE alias_id = " .. sql_value(source_id))
  if row and row.design_id then
    return row.design_id
  end
  return source_id
end

local function normalize_currency(currency)
  local normalized = string.lower(tostring(currency or ""):gsub("^%s+", ""):gsub("%s+$", ""))
  if normalized == "" then
    error("currency must be a non-empty string")
  end
  return normalized
end

local function record_cash_movement(conn, ts, event_type, currency, amount, reason, note, source_event_id)
  local integer = tonumber(amount) or 0
  if integer == 0 then
    return
  end

  local normalized = normalize_currency(currency)
  exec_sql(conn, string.format(
    "INSERT OR IGNORE INTO cash_accounts (currency, balance) VALUES (%s, 0)",
    sql_value(normalized)
  ))
  exec_sql(conn, string.format(
    "UPDATE cash_accounts SET balance = balance + %s WHERE currency = %s",
    sql_value(integer),
    sql_value(normalized)
  ))
  exec_sql(conn, string.format(
    "INSERT INTO cash_movements (ts, event_type, currency, amount, reason, note, source_event_id) VALUES (%s, %s, %s, %s, %s, %s, %s)",
    sql_value(ts),
    sql_value(event_type),
    sql_value(normalized),
    sql_value(integer),
    sql_value(reason),
    sql_value(note),
    sql_value(source_event_id)
  ))
end

local function ensure_stub_source(conn, source_id, bom, ts)
  if not source_id then
    return
  end

  local row = fetch_one(conn, "SELECT source_id FROM production_sources WHERE source_id = " .. sql_value(source_id))
  if row and row.source_id then
    return
  end

  local json = get_json()
  local bom_json = bom and json.encode(bom) or nil

  exec_sql(conn, string.format(
    "INSERT OR IGNORE INTO production_sources " ..
    "(source_id, source_kind, source_type, name, created_at, pattern_pool_id, per_item_fee_gold, bom_json, pricing_policy_json, provenance, recovery_enabled, status, capital_remaining_gold) " ..
    "VALUES (%s, %s, %s, %s, %s, NULL, 0, %s, NULL, %s, 0, %s, 0)",
    sql_value(source_id),
    sql_value("design"),
    sql_value("unknown"),
    sql_value(nil),
    sql_value(ts),
    sql_value(bom_json),
    sql_value("unknown"),
    sql_value("stub")
  ))
end

local function update_recovery(conn, source_id, operational_profit)
  if operational_profit == nil then
    return
  end

  local resolved_source_id = resolve_source_id(conn, source_id)
  local source_row = fetch_one(conn, "SELECT source_id, source_kind, recovery_enabled, pattern_pool_id, capital_remaining_gold FROM production_sources WHERE source_id = " .. sql_value(resolved_source_id))
  if not source_row then
    error("Design " .. tostring(resolved_source_id) .. " not found")
  end

  if source_row.source_kind ~= "design" then
    return
  end

  local design_remaining = tonumber(source_row.capital_remaining_gold) or 0
  local recovery_enabled = tonumber(source_row.recovery_enabled) or 0
  local pattern_remaining = 0
  local pattern_pool_id = source_row.pattern_pool_id
  if pattern_pool_id and pattern_pool_id ~= "" then
    local pool_row = fetch_one(conn, "SELECT capital_remaining_gold FROM pattern_pools WHERE pattern_pool_id = " .. sql_value(pattern_pool_id))
    if pool_row and pool_row.capital_remaining_gold ~= nil then
      pattern_remaining = tonumber(pool_row.capital_remaining_gold) or 0
    end
  end

  local recovery = get_recovery()
  local result = recovery.apply_waterfall(operational_profit, design_remaining, pattern_remaining, recovery_enabled)

  if recovery_enabled == 1 and operational_profit > 0 then
    if result.applied_to_design_capital > 0 then
      exec_sql(conn, string.format(
        "UPDATE production_sources SET capital_remaining_gold = %s WHERE source_id = %s",
        sql_value(result.design_remaining),
        sql_value(resolved_source_id)
      ))
    end
    if pattern_pool_id and result.applied_to_pattern_capital > 0 then
      exec_sql(conn, string.format(
        "UPDATE pattern_pools SET capital_remaining_gold = %s WHERE pattern_pool_id = %s",
        sql_value(result.pattern_remaining),
        sql_value(pattern_pool_id)
      ))
    end
  end
end

local function normalize_source_payload(payload)
  local source_id = payload.source_id or payload.design_id
  local source_kind = payload.source_kind or "design"
  local source_type = payload.source_type or payload.design_type
  return source_id, source_kind, source_type
end

function projector.apply(conn, event)
  assert(type(event) == "table", "event must be a table")

  local event_type = event.event_type
  local payload = event.payload or {}
  local ts = event.ts or os.date("!%Y-%m-%dT%H:%M:%SZ")

  if event_type == "SOURCE_CREATE" then
    local json = get_json()
    local bom_json = payload.bom and json.encode(payload.bom) or nil
    local pricing_json = payload.pricing_policy and json.encode(payload.pricing_policy) or nil
    local metadata_json = payload.metadata and json.encode(payload.metadata) or nil
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO production_sources (source_id, source_kind, source_type, name, created_at, pattern_pool_id, per_item_fee_gold, bom_json, pricing_policy_json, metadata_json, provenance, recovery_enabled, status, capital_remaining_gold) " ..
      "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
      sql_value(payload.source_id),
      sql_value(payload.source_kind),
      sql_value(payload.source_type),
      sql_value(payload.name),
      sql_value(payload.created_at or ts),
      sql_value(payload.pattern_pool_id),
      sql_value(payload.per_item_fee_gold or 0),
      sql_value(bom_json),
      sql_value(pricing_json),
      sql_value(metadata_json),
      sql_value(payload.provenance or "system"),
      sql_value(payload.recovery_enabled or 0),
      sql_value(payload.status or "active"),
      sql_value(payload.capital_remaining_gold or 0)
    ))
    return
  end

  if event_type == "ITEM_REGISTER_EXTERNAL" then
    local resolved_game_year = resolve_game_year(conn, event, payload)
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO external_items (item_id, name, acquired_at, basis_gold, basis_source, status, note, acquired_resolved_game_year, source_event_id) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)",
      sql_value(payload.item_id),
      sql_value(payload.name),
      sql_value(payload.acquired_at or ts),
      sql_value(payload.basis_gold or 0),
      sql_value(payload.basis_source or "unknown"),
      sql_value(payload.status or "active"),
      sql_value(payload.note),
      sql_value(resolved_game_year),
      sql_value(event.id)
    ))
    return
  end

  if event_type == "ITEM_UPDATE_EXTERNAL" then
    local resolved_game_year = resolve_game_year(conn, event, payload)
    exec_sql(conn, string.format(
      "UPDATE external_items SET name = COALESCE(%s, name), basis_gold = COALESCE(%s, basis_gold), basis_source = COALESCE(%s, basis_source), status = COALESCE(%s, status), note = COALESCE(%s, note), acquired_resolved_game_year = COALESCE(%s, acquired_resolved_game_year), source_event_id = COALESCE(%s, source_event_id) WHERE item_id = %s",
      sql_value(payload.name),
      sql_value(payload.basis_gold),
      sql_value(payload.basis_source),
      sql_value(payload.status),
      sql_value(payload.note),
      sql_value(resolved_game_year),
      sql_value(event.id),
      sql_value(payload.item_id)
    ))
    return
  end

  if event_type == "CASH_INIT" then
    record_cash_movement(conn, ts, event_type, payload.currency, payload.amount, nil, payload.note, event.id)
    return
  end

  if event_type == "CASH_ADJUST" then
    record_cash_movement(conn, ts, event_type, payload.currency, payload.amount, payload.reason, payload.note, event.id)
    return
  end

  if event_type == "CURRENCY_CONVERT" then
    record_cash_movement(conn, ts, event_type, payload.from_currency, -(payload.from_amount or 0), nil, payload.note, event.id)
    record_cash_movement(conn, ts, event_type, payload.to_currency, payload.to_amount or 0, nil, payload.note, event.id)
    return
  end

  if event_type == "BROKER_BUY" then
    record_cash_movement(conn, ts, event_type, "gold", -((payload.qty or 0) * (payload.unit_cost or 0)), nil, nil, event.id)
    return
  end

  if event_type == "BROKER_SELL" then
    record_cash_movement(conn, ts, event_type, "gold", payload.revenue or 0, nil, nil, event.id)
    return
  end

  if event_type == "DESIGN_START" then
    local json = get_json()
    local source_id, source_kind, source_type = normalize_source_payload(payload)
    local bom_json = payload.bom and json.encode(payload.bom) or nil
    local pricing_json = payload.pricing_policy and json.encode(payload.pricing_policy) or nil

    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO production_sources (source_id, source_kind, source_type, name, created_at, pattern_pool_id, per_item_fee_gold, bom_json, pricing_policy_json, provenance, recovery_enabled, status, capital_remaining_gold) " ..
      "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
      sql_value(source_id),
      sql_value(source_kind),
      sql_value(source_type),
      sql_value(payload.name),
      sql_value(payload.created_at or ts),
      sql_value(payload.pattern_pool_id),
      sql_value(0),
      sql_value(bom_json),
      sql_value(pricing_json),
      sql_value(payload.provenance),
      sql_value(payload.recovery_enabled),
      sql_value(payload.status or "in_progress"),
      sql_value(0)
    ))

    if source_kind == "design" then
      exec_sql(conn, string.format(
        "INSERT OR REPLACE INTO designs (design_id, design_type, name, created_at, pattern_pool_id, per_item_fee_gold, provenance, recovery_enabled, status, capital_remaining_gold, bom_json, pricing_policy_json) " ..
        "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
        sql_value(source_id),
        sql_value(source_type),
        sql_value(payload.name),
        sql_value(payload.created_at or ts),
        sql_value(payload.pattern_pool_id),
        sql_value(0),
        sql_value(payload.provenance),
        sql_value(payload.recovery_enabled),
        sql_value(payload.status or "in_progress"),
        sql_value(0),
        sql_value(bom_json),
        sql_value(pricing_json)
      ))
    end
    return
  end

  if event_type == "DESIGN_COST" then
    local source_id = resolve_source_id(conn, payload.source_id or payload.design_id)
    exec_sql(conn, string.format(
      "UPDATE production_sources SET capital_remaining_gold = CASE WHEN recovery_enabled = 1 THEN capital_remaining_gold + %s ELSE capital_remaining_gold END WHERE source_id = %s",
      sql_value(payload.amount or 0),
      sql_value(source_id)
    ))
    exec_sql(conn, string.format(
      "UPDATE designs SET capital_remaining_gold = CASE WHEN recovery_enabled = 1 THEN capital_remaining_gold + %s ELSE capital_remaining_gold END WHERE design_id = %s",
      sql_value(payload.amount or 0),
      sql_value(source_id)
    ))
    record_cash_movement(conn, ts, event_type, "gold", -(payload.amount or 0), payload.kind, nil, event.id)
    return
  end

  if event_type == "DESIGN_SET_PER_ITEM_FEE" then
    local source_id = resolve_source_id(conn, payload.source_id or payload.design_id)
    exec_sql(conn, string.format(
      "UPDATE production_sources SET per_item_fee_gold = %s WHERE source_id = %s",
      sql_value(payload.amount or 0),
      sql_value(source_id)
    ))
    exec_sql(conn, string.format(
      "UPDATE designs SET per_item_fee_gold = %s WHERE design_id = %s",
      sql_value(payload.amount or 0),
      sql_value(source_id)
    ))
    return
  end

  if event_type == "DESIGN_SET_BOM" then
    local json = get_json()
    local bom_json = payload.bom and json.encode(payload.bom) or nil
    local source_id = resolve_source_id(conn, payload.source_id or payload.design_id)
    exec_sql(conn, string.format(
      "UPDATE production_sources SET bom_json = %s WHERE source_id = %s",
      sql_value(bom_json),
      sql_value(source_id)
    ))
    exec_sql(conn, string.format(
      "UPDATE designs SET bom_json = %s WHERE design_id = %s",
      sql_value(bom_json),
      sql_value(source_id)
    ))
    return
  end

  if event_type == "DESIGN_SET_PRICING" then
    local json = get_json()
    local policy_json = payload.pricing_policy and json.encode(payload.pricing_policy) or nil
    local source_id = resolve_source_id(conn, payload.source_id or payload.design_id)
    exec_sql(conn, string.format(
      "UPDATE production_sources SET pricing_policy_json = %s WHERE source_id = %s",
      sql_value(policy_json),
      sql_value(source_id)
    ))
    exec_sql(conn, string.format(
      "UPDATE designs SET pricing_policy_json = %s WHERE design_id = %s",
      sql_value(policy_json),
      sql_value(source_id)
    ))
    return
  end

  if event_type == "DESIGN_UPDATE" then
    local source_id, _, source_type = normalize_source_payload(payload)
    local json = get_json()
    local metadata_json = payload.metadata and json.encode(payload.metadata) or nil
    exec_sql(conn, string.format(
      "UPDATE production_sources SET source_type = COALESCE(%s, source_type), name = COALESCE(%s, name), provenance = COALESCE(%s, provenance), recovery_enabled = COALESCE(%s, recovery_enabled), status = COALESCE(%s, status), metadata_json = COALESCE(%s, metadata_json), pattern_pool_id = %s WHERE source_id = %s",
      sql_value(source_type),
      sql_value(payload.name),
      sql_value(payload.provenance),
      sql_value(payload.recovery_enabled),
      sql_value(payload.status),
      sql_value(metadata_json),
      sql_value(payload.pattern_pool_id),
      sql_value(resolve_source_id(conn, source_id))
    ))
    exec_sql(conn, string.format(
      "UPDATE designs SET design_type = COALESCE(%s, design_type), name = COALESCE(%s, name), provenance = COALESCE(%s, provenance), recovery_enabled = COALESCE(%s, recovery_enabled), status = COALESCE(%s, status), pattern_pool_id = %s WHERE design_id = %s",
      sql_value(source_type),
      sql_value(payload.name),
      sql_value(payload.provenance),
      sql_value(payload.recovery_enabled),
      sql_value(payload.status),
      sql_value(payload.pattern_pool_id),
      sql_value(resolve_source_id(conn, source_id))
    ))
    return
  end

  if event_type == "DESIGN_REGISTER_ALIAS" then
    local source_id = resolve_source_id(conn, payload.source_id or payload.design_id)
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO design_id_aliases (alias_id, design_id, source_id, alias_kind, active, created_at) VALUES (%s, %s, %s, %s, %s, %s)",
      sql_value(payload.alias_id),
      sql_value(source_id),
      sql_value(source_id),
      sql_value(payload.alias_kind),
      sql_value(payload.active),
      sql_value(ts)
    ))
    return
  end

  if event_type == "DESIGN_REGISTER_APPEARANCE" then
    local source_id = resolve_source_id(conn, payload.source_id or payload.design_id)
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO design_appearance_aliases (appearance_key, design_id, source_id, created_at, confidence) VALUES (%s, %s, %s, %s, %s)",
      sql_value(payload.appearance_key),
      sql_value(source_id),
      sql_value(source_id),
      sql_value(ts),
      sql_value(payload.confidence)
    ))
    return
  end

  if event_type == "PATTERN_ACTIVATE" then
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO pattern_pools (pattern_pool_id, pattern_type, pattern_name, activated_at, deactivated_at, capital_initial_gold, capital_remaining_gold, status) " ..
      "VALUES (%s, %s, %s, %s, NULL, %s, %s, %s)",
      sql_value(payload.pattern_pool_id),
      sql_value(payload.pattern_type),
      sql_value(payload.pattern_name),
      sql_value(payload.activated_at or ts),
      sql_value(payload.capital_initial),
      sql_value(payload.capital_initial),
      sql_value("active")
    ))
    record_cash_movement(conn, ts, event_type, "gold", -(payload.capital_initial or 0), nil, nil, event.id)
    return
  end

  if event_type == "PATTERN_DEACTIVATE" then
    exec_sql(conn, string.format(
      "UPDATE pattern_pools SET status = %s, deactivated_at = %s WHERE pattern_pool_id = %s",
      sql_value("closed"),
      sql_value(payload.deactivated_at or ts),
      sql_value(payload.pattern_pool_id)
    ))
    return
  end

  if event_type == "CRAFT_ITEM" then
    local json = get_json()
    local materials_json = payload.materials and json.encode(payload.materials) or nil
    local source_id, source_kind = normalize_source_payload(payload)
    ensure_stub_source(conn, source_id, payload.materials, ts)
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO crafted_items (item_id, design_id, source_id, source_kind, crafted_at, operational_cost_gold, base_operational_cost_gold, forge_allocated_coal_gold, parent_item_id, transformed, cost_breakdown_json, appearance_key, materials_json, materials_source) " ..
      "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
      sql_value(payload.item_id),
      sql_value(payload.design_id or source_id),
      sql_value(source_id),
      sql_value(source_kind),
      sql_value(payload.crafted_at or ts),
      sql_value(payload.operational_cost_gold or 0),
      sql_value(payload.base_operational_cost_gold or payload.operational_cost_gold or 0),
      sql_value(payload.forge_allocated_coal_gold or 0),
      sql_value(payload.parent_item_id),
      sql_value(payload.transformed or 0),
      sql_value(payload.cost_breakdown_json or "{}"),
      sql_value(payload.appearance_key),
      sql_value(materials_json),
      sql_value(payload.materials_source)
    ))
    return
  end

  if event_type == "AUGMENT_ITEM" then
    local json = get_json()
    local materials_json = payload.materials and json.encode(payload.materials) or nil
    local source_id, source_kind = normalize_source_payload(payload)

    exec_sql(conn, string.format(
      "UPDATE crafted_items SET transformed = 1 WHERE item_id = %s",
      sql_value(payload.target_item_id)
    ))
    exec_sql(conn, string.format(
      "UPDATE external_items SET status = 'transformed' WHERE item_id = %s",
      sql_value(payload.target_item_id)
    ))

    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO crafted_items (item_id, design_id, source_id, source_kind, crafted_at, operational_cost_gold, base_operational_cost_gold, forge_allocated_coal_gold, parent_item_id, transformed, cost_breakdown_json, appearance_key, materials_json, materials_source) " ..
      "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, 0, %s, %s, %s, %s)",
      sql_value(payload.new_item_id),
      sql_value(source_id),
      sql_value(source_id),
      sql_value(source_kind),
      sql_value(payload.crafted_at or ts),
      sql_value(payload.operational_cost_gold or 0),
      sql_value(payload.operational_cost_gold or 0),
      sql_value(0),
      sql_value(payload.target_item_id),
      sql_value(payload.cost_breakdown_json or "{}"),
      sql_value(payload.appearance_key),
      sql_value(materials_json),
      sql_value(payload.materials_source)
    ))

    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO item_transformations (new_item_id, old_item_id, kind, created_at) VALUES (%s, %s, %s, %s)",
      sql_value(payload.new_item_id),
      sql_value(payload.target_item_id),
      sql_value(payload.transform_kind or "augmentation"),
      sql_value(payload.crafted_at or ts)
    ))

    record_cash_movement(conn, ts, event_type, "gold", -(payload.fee_gold or 0), nil, payload.note, event.id)
    return
  end

  if event_type == "FORGE_FIRE" then
    local coal_basis = payload.coal_basis_gold or 0
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO forge_sessions (forge_session_id, source_id, started_at, expires_at, closed_at, status, coal_basis_gold, allocated_total_gold, note) VALUES (%s, %s, %s, %s, NULL, %s, %s, %s, %s)",
      sql_value(payload.forge_session_id),
      sql_value(payload.source_id),
      sql_value(payload.started_at or ts),
      sql_value(payload.expires_at),
      sql_value(payload.status or "in_flight"),
      sql_value(coal_basis),
      sql_value(payload.allocated_total_gold or 0),
      sql_value(payload.note)
    ))
    return
  end

  if event_type == "FORGE_ATTACH_ITEM" then
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO forge_session_items (forge_session_id, item_id, allocated_coal_gold) VALUES (%s, %s, %s)",
      sql_value(payload.forge_session_id),
      sql_value(payload.item_id),
      sql_value(payload.allocated_coal_gold or 0)
    ))
    return
  end

  if event_type == "FORGE_ALLOCATE" then
    local allocations = payload.allocations or {}
    local item_breakdowns = payload.item_breakdowns or {}
    local allocated_sum = 0
    for item_id, amount in pairs(allocations) do
      local alloc = tonumber(amount) or 0
      allocated_sum = allocated_sum + alloc
      exec_sql(conn, string.format(
        "UPDATE forge_session_items SET allocated_coal_gold = allocated_coal_gold + %s WHERE forge_session_id = %s AND item_id = %s",
        sql_value(alloc),
        sql_value(payload.forge_session_id),
        sql_value(item_id)
      ))
      exec_sql(conn, string.format(
        "UPDATE crafted_items SET operational_cost_gold = operational_cost_gold + %s, forge_allocated_coal_gold = forge_allocated_coal_gold + %s WHERE item_id = %s",
        sql_value(alloc),
        sql_value(alloc),
        sql_value(item_id)
      ))
      local breakdown_json = item_breakdowns[item_id]
      if breakdown_json then
        exec_sql(conn, string.format(
          "UPDATE crafted_items SET cost_breakdown_json = %s WHERE item_id = %s",
          sql_value(breakdown_json),
          sql_value(item_id)
        ))
      end
    end
    exec_sql(conn, string.format(
      "UPDATE forge_sessions SET allocated_total_gold = allocated_total_gold + %s WHERE forge_session_id = %s",
      sql_value(allocated_sum),
      sql_value(payload.forge_session_id)
    ))
    return
  end

  if event_type == "FORGE_CLOSE" or event_type == "FORGE_EXPIRE" then
    local close_status = payload.status or (event_type == "FORGE_EXPIRE" and "expired" or "closed")
    exec_sql(conn, string.format(
      "UPDATE forge_sessions SET status = %s, closed_at = %s, note = COALESCE(%s, note) WHERE forge_session_id = %s",
      sql_value(close_status),
      sql_value(payload.closed_at or ts),
      sql_value(payload.note),
      sql_value(payload.forge_session_id)
    ))
    return
  end

  if event_type == "FORGE_WRITE_OFF" then
    local resolved_game_year = resolve_game_year(conn, event, payload)
    exec_sql(conn, string.format(
      "INSERT INTO forge_write_offs (forge_session_id, amount_gold, created_at, reason, note, resolved_game_year, source_event_id) VALUES (%s, %s, %s, %s, %s, %s, %s)",
      sql_value(payload.forge_session_id),
      sql_value(payload.amount_gold or 0),
      sql_value(ts),
      sql_value(payload.reason),
      sql_value(payload.note),
      sql_value(resolved_game_year),
      sql_value(event.id)
    ))
    return
  end

  if event_type == "CRAFT_RESOLVE_DESIGN" or event_type == "CRAFT_RESOLVE_SOURCE" then
    local source_id, source_kind = normalize_source_payload(payload)
    local resolved_id = resolve_source_id(conn, source_id)
    ensure_stub_source(conn, resolved_id, nil, ts)
    exec_sql(conn, string.format(
      "UPDATE crafted_items SET design_id = %s, source_id = %s, source_kind = %s WHERE item_id = %s",
      sql_value(resolved_id),
      sql_value(resolved_id),
      sql_value(source_kind),
      sql_value(payload.item_id)
    ))
    return
  end

  if event_type == "SELL_ITEM" then
    if payload.sale_id then
      local game_time = payload.game_time or {}
      local json = get_json()
      local game_time_json = payload.game_time and json.encode(payload.game_time) or nil
      local resolved_game_year = resolve_game_year(conn, event, payload)
      exec_sql(conn, string.format(
        "INSERT OR REPLACE INTO sales (sale_id, item_id, sold_at, sale_price_gold, game_time_year, game_time_month, game_time_day, game_time_hour, game_time_minute, game_time_json, settlement_id, resolved_game_year, source_event_id) " ..
        "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
        sql_value(payload.sale_id),
        sql_value(payload.item_id),
        sql_value(payload.sold_at or ts),
        sql_value(payload.sale_price_gold or 0),
        sql_value(game_time.year),
        sql_value(game_time.month),
        sql_value(game_time.day),
        sql_value(game_time.hour),
        sql_value(game_time.minute),
        sql_value(game_time_json),
        sql_value(payload.settlement_id),
        sql_value(resolved_game_year),
        sql_value(event.id)
      ))

      record_cash_movement(conn, ts, event_type, "gold", payload.sale_price_gold or 0, nil, nil, event.id)

      local item_row = fetch_one(conn, "SELECT source_id, source_kind, operational_cost_gold FROM crafted_items WHERE item_id = " .. sql_value(payload.item_id))
      if item_row and item_row.source_id then
        local op_profit = (payload.sale_price_gold or 0) - (tonumber(item_row.operational_cost_gold) or 0)
        update_recovery(conn, item_row.source_id, op_profit)
      else
        local ext_row = fetch_one(conn, "SELECT basis_gold FROM external_items WHERE item_id = " .. sql_value(payload.item_id))
        if not ext_row then
          error("Item " .. tostring(payload.item_id) .. " not found")
        end
        exec_sql(conn, string.format(
          "UPDATE external_items SET status = 'sold' WHERE item_id = %s",
          sql_value(payload.item_id)
        ))
      end
      return
    end

    if payload.operational_profit ~= nil and (payload.source_id or payload.design_id) then
      update_recovery(conn, payload.source_id or payload.design_id, payload.operational_profit)
      return
    end
  end

  if event_type == "ORDER_CREATE" then
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO orders (order_id, created_at, customer, note, status) VALUES (%s, %s, %s, %s, %s)",
      sql_value(payload.order_id),
      sql_value(payload.created_at or ts),
      sql_value(payload.customer),
      sql_value(payload.note),
      sql_value(payload.status or "open")
    ))
    return
  end

  if event_type == "ORDER_ADD_ITEM" then
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO order_items (order_id, item_id) VALUES (%s, %s)",
      sql_value(payload.order_id),
      sql_value(payload.item_id)
    ))
    return
  end

  if event_type == "ORDER_ADD_SALE" then
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO order_sales (order_id, sale_id) VALUES (%s, %s)",
      sql_value(payload.order_id),
      sql_value(payload.sale_id)
    ))
    return
  end

  if event_type == "ORDER_SETTLE" then
    local resolved_game_year = resolve_game_year(conn, event, payload)
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO order_settlements (settlement_id, order_id, amount_gold, received_at, method, resolved_game_year, source_event_id) VALUES (%s, %s, %s, %s, %s, %s, %s)",
      sql_value(payload.settlement_id),
      sql_value(payload.order_id),
      sql_value(payload.amount_gold or 0),
      sql_value(payload.received_at or ts),
      sql_value(payload.method),
      sql_value(resolved_game_year),
      sql_value(event.id)
    ))
    return
  end

  if event_type == "ORDER_CLOSE" then
    exec_sql(conn, string.format(
      "UPDATE orders SET status = %s WHERE order_id = %s",
      sql_value(payload.status or "closed"),
      sql_value(payload.order_id)
    ))
    return
  end

  if event_type == "PROCESS_START" then
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO process_instances (process_instance_id, process_id, started_at, completed_at, status, note, passive) " ..
      "VALUES (%s, %s, %s, NULL, %s, %s, %s)",
      sql_value(payload.process_instance_id),
      sql_value(payload.process_id),
      sql_value(payload.started_at or ts),
      sql_value("in_flight"),
      sql_value(payload.note),
      sql_value(payload.passive or 0)
    ))
    record_cash_movement(conn, ts, event_type, "gold", -(payload.gold_fee or 0), nil, payload.note, event.id)
    return
  end

  if event_type == "PROCESS_APPLY" then
    local process_instance_id = payload.process_instance_id or (event.id and ("XP-" .. tostring(event.id)) or nil)
    if process_instance_id then
      exec_sql(conn, string.format(
        "INSERT OR REPLACE INTO process_instances (process_instance_id, process_id, started_at, completed_at, status, note, passive) " ..
        "VALUES (%s, %s, %s, %s, %s, %s, %s)",
        sql_value(process_instance_id),
        sql_value(payload.process_id),
        sql_value(payload.started_at or ts),
        sql_value(payload.completed_at or ts),
        sql_value("completed"),
        sql_value(payload.note),
        sql_value(payload.passive or 0)
      ))
    end
    record_cash_movement(conn, ts, event_type, "gold", -(payload.gold_fee or 0), nil, payload.note, event.id)
    record_cash_movement(conn, ts, event_type, "gold", payload.revenue_gold or 0, nil, payload.note, event.id)
    return
  end

  if event_type == "PROCESS_ADD_INPUTS" or event_type == "PROCESS_ADD_FEE" then
    if payload.note then
      exec_sql(conn, string.format(
        "UPDATE process_instances SET note = %s WHERE process_instance_id = %s",
        sql_value(payload.note),
        sql_value(payload.process_instance_id)
      ))
    end
    if event_type == "PROCESS_ADD_FEE" then
      record_cash_movement(conn, ts, event_type, "gold", -(payload.gold_fee or 0), nil, payload.note, event.id)
    end
    return
  end

  if event_type == "PROCESS_COMPLETE" then
    exec_sql(conn, string.format(
      "UPDATE process_instances SET status = %s, completed_at = %s, note = COALESCE(%s, note) WHERE process_instance_id = %s",
      sql_value("completed"),
      sql_value(payload.completed_at or ts),
      sql_value(payload.note),
      sql_value(payload.process_instance_id)
    ))
    record_cash_movement(conn, ts, event_type, "gold", payload.revenue_gold or 0, nil, payload.note, event.id)
    return
  end

  if event_type == "PROCESS_ADD_TIME_COST" then
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO process_time_costs (process_instance_id, at, amount_gold, elapsed_seconds, rate_gold_per_hour, reason, source_event_id) VALUES (%s, %s, %s, %s, %s, %s, %s)",
      sql_value(payload.process_instance_id),
      sql_value(ts),
      sql_value(payload.amount_gold or 0),
      sql_value(payload.elapsed_seconds or 0),
      sql_value(payload.rate_gold_per_hour or 0),
      sql_value(payload.reason),
      sql_value(event.id)
    ))
    return
  end

  if event_type == "PROCESS_ABORT" then
    exec_sql(conn, string.format(
      "UPDATE process_instances SET status = %s, completed_at = %s, note = COALESCE(%s, note) WHERE process_instance_id = %s",
      sql_value("aborted"),
      sql_value(payload.completed_at or ts),
      sql_value(payload.note),
      sql_value(payload.process_instance_id)
    ))
    record_cash_movement(conn, ts, event_type, "gold", payload.revenue_gold or 0, nil, payload.note, event.id)
    return
  end

  if event_type == "PROCESS_WRITE_OFF" then
    local json = get_json()
    local game_time_json = payload.game_time and json.encode(payload.game_time) or nil
    local resolved_game_year = resolve_game_year(conn, event, payload, {
      process_instance_id = payload.process_instance_id,
      process_scope = "write_off"
    })
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO process_write_offs (process_instance_id, at, amount_gold, reason, note, game_time_json, resolved_game_year, source_event_id) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
      sql_value(payload.process_instance_id),
      sql_value(ts),
      sql_value(payload.amount_gold or 0),
      sql_value(payload.reason),
      sql_value(payload.note),
      sql_value(game_time_json),
      sql_value(resolved_game_year),
      sql_value(event.id)
    ))
    return
  end

  if event_type == "PROCESS_SET_GAME_TIME" then
    local json = get_json()
    local game_time_json = payload.game_time and json.encode(payload.game_time) or nil
    if not game_time_json then
      error("PROCESS_SET_GAME_TIME requires payload.game_time")
    end
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO process_game_time_overrides (process_instance_id, scope, game_time_json, updated_at, note) VALUES (%s, %s, %s, %s, %s)",
      sql_value(payload.process_instance_id),
      sql_value(payload.scope or "write_off"),
      sql_value(game_time_json),
      sql_value(ts),
      sql_value(payload.note)
    ))

    exec_sql(conn, string.format(
      "UPDATE process_write_offs SET resolved_game_year = COALESCE(" ..
      "CAST(json_extract(game_time_json, '$.year') AS INTEGER), " ..
      "(SELECT CAST(json_extract(o.game_time_json, '$.year') AS INTEGER) FROM process_game_time_overrides o WHERE o.process_instance_id = process_write_offs.process_instance_id AND o.scope = 'write_off' LIMIT 1), " ..
      "(SELECT CAST(json_extract(o.game_time_json, '$.year') AS INTEGER) FROM process_game_time_overrides o WHERE o.process_instance_id = process_write_offs.process_instance_id AND o.scope = 'all' LIMIT 1), " ..
      "(SELECT default_year FROM ledger_game_year_defaults d WHERE d.effective_from_event_id <= process_write_offs.source_event_id ORDER BY d.effective_from_event_id DESC LIMIT 1)) " ..
      "WHERE process_instance_id = %s",
      sql_value(payload.process_instance_id)
    ))
    return
  end

  if event_type == "LEDGER_SET_DEFAULT_GAME_YEAR" then
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO ledger_game_year_defaults (effective_from_event_id, default_year, set_at, note) VALUES (%s, %s, %s, %s)",
      sql_value(payload.effective_from_event_id),
      sql_value(payload.default_year),
      sql_value(payload.set_at or ts),
      sql_value(payload.note)
    ))

    exec_sql(conn, "UPDATE sales SET resolved_game_year = COALESCE(game_time_year, (SELECT default_year FROM ledger_game_year_defaults d WHERE d.effective_from_event_id <= sales.source_event_id ORDER BY d.effective_from_event_id DESC LIMIT 1))")
    exec_sql(conn, "UPDATE external_items SET acquired_resolved_game_year = COALESCE((SELECT CAST(json_extract(e.payload_json, '$.game_time.year') AS INTEGER) FROM ledger_events e WHERE e.id = external_items.source_event_id), (SELECT default_year FROM ledger_game_year_defaults d WHERE d.effective_from_event_id <= external_items.source_event_id ORDER BY d.effective_from_event_id DESC LIMIT 1))")
    exec_sql(conn, "UPDATE order_settlements SET resolved_game_year = COALESCE((SELECT CAST(json_extract(e.payload_json, '$.game_time.year') AS INTEGER) FROM ledger_events e WHERE e.id = order_settlements.source_event_id), (SELECT default_year FROM ledger_game_year_defaults d WHERE d.effective_from_event_id <= order_settlements.source_event_id ORDER BY d.effective_from_event_id DESC LIMIT 1))")
    exec_sql(conn, "UPDATE forge_write_offs SET resolved_game_year = COALESCE((SELECT CAST(json_extract(e.payload_json, '$.game_time.year') AS INTEGER) FROM ledger_events e WHERE e.id = forge_write_offs.source_event_id), (SELECT default_year FROM ledger_game_year_defaults d WHERE d.effective_from_event_id <= forge_write_offs.source_event_id ORDER BY d.effective_from_event_id DESC LIMIT 1))")
    exec_sql(conn, "UPDATE process_write_offs SET resolved_game_year = COALESCE(CAST(json_extract(game_time_json, '$.year') AS INTEGER), (SELECT CAST(json_extract(o.game_time_json, '$.year') AS INTEGER) FROM process_game_time_overrides o WHERE o.process_instance_id = process_write_offs.process_instance_id AND o.scope = 'write_off' LIMIT 1), (SELECT CAST(json_extract(o.game_time_json, '$.year') AS INTEGER) FROM process_game_time_overrides o WHERE o.process_instance_id = process_write_offs.process_instance_id AND o.scope = 'all' LIMIT 1), (SELECT default_year FROM ledger_game_year_defaults d WHERE d.effective_from_event_id <= process_write_offs.source_event_id ORDER BY d.effective_from_event_id DESC LIMIT 1))")
    return
  end

  -- Inventory-only events do not map to domain tables.
  return
end

function projector.truncate_domains(conn)
  local tables = {
    "cash_movements",
    "cash_accounts",
    "process_time_costs",
    "forge_write_offs",
    "item_transformations",
    "forge_session_items",
    "forge_sessions",
    "process_game_time_overrides",
    "ledger_game_year_defaults",
    "process_write_offs",
    "order_items",
    "order_settlements",
    "design_id_aliases",
    "design_appearance_aliases",
    "order_sales",
    "orders",
    "sales",
    "crafted_items",
    "process_instances",
    "pattern_pools",
    "external_items",
    "production_sources",
    "designs"
  }

  for _, name in ipairs(tables) do
    exec_sql(conn, "DELETE FROM " .. name)
  end
end

_G.AchaeadexLedger.Core.Projector = projector

return projector
