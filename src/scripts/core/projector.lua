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

local function resolve_design_id(conn, design_id)
  local row = fetch_one(conn, "SELECT design_id FROM designs WHERE design_id = " .. sql_value(design_id))
  if row and row.design_id then
    return row.design_id
  end
  row = fetch_one(conn, "SELECT design_id FROM design_id_aliases WHERE alias_id = " .. sql_value(design_id))
  if row and row.design_id then
    return row.design_id
  end
  return design_id
end

local function update_recovery(conn, design_id, operational_profit)
  if operational_profit == nil then
    return
  end

  local resolved_design_id = resolve_design_id(conn, design_id)
  local design_row = fetch_one(conn, "SELECT design_id, recovery_enabled, pattern_pool_id, capital_remaining_gold FROM designs WHERE design_id = " .. sql_value(resolved_design_id))
  if not design_row then
    error("Design " .. tostring(resolved_design_id) .. " not found")
  end

  local design_remaining = tonumber(design_row.capital_remaining_gold) or 0
  local recovery_enabled = tonumber(design_row.recovery_enabled) or 0
  local pattern_remaining = 0
  local pattern_pool_id = design_row.pattern_pool_id
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
        "UPDATE designs SET capital_remaining_gold = %s WHERE design_id = %s",
        sql_value(result.design_remaining),
        sql_value(resolved_design_id)
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

function projector.apply(conn, event)
  assert(type(event) == "table", "event must be a table")

  local event_type = event.event_type
  local payload = event.payload or {}
  local ts = event.ts or os.date("!%Y-%m-%dT%H:%M:%SZ")

  if event_type == "DESIGN_START" then
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO designs (design_id, design_type, name, created_at, pattern_pool_id, per_item_fee_gold, provenance, recovery_enabled, status, capital_remaining_gold) " ..
      "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
      sql_value(payload.design_id),
      sql_value(payload.design_type),
      sql_value(payload.name),
      sql_value(payload.created_at or ts),
      sql_value(payload.pattern_pool_id),
      sql_value(0),
      sql_value(payload.provenance),
      sql_value(payload.recovery_enabled),
      sql_value("in_progress"),
      sql_value(0)
    ))
    return
  end

  if event_type == "DESIGN_COST" then
    exec_sql(conn, string.format(
      "UPDATE designs SET capital_remaining_gold = CASE WHEN recovery_enabled = 1 THEN capital_remaining_gold + %s ELSE capital_remaining_gold END WHERE design_id = %s",
      sql_value(payload.amount or 0),
      sql_value(resolve_design_id(conn, payload.design_id))
    ))
    return
  end

  if event_type == "DESIGN_SET_PER_ITEM_FEE" then
    exec_sql(conn, string.format(
      "UPDATE designs SET per_item_fee_gold = %s WHERE design_id = %s",
      sql_value(payload.amount or 0),
      sql_value(resolve_design_id(conn, payload.design_id))
    ))
    return
  end

  if event_type == "DESIGN_REGISTER_ALIAS" then
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO design_id_aliases (alias_id, design_id, alias_kind, active, created_at) VALUES (%s, %s, %s, %s, %s)",
      sql_value(payload.alias_id),
      sql_value(resolve_design_id(conn, payload.design_id)),
      sql_value(payload.alias_kind),
      sql_value(payload.active),
      sql_value(ts)
    ))
    return
  end

  if event_type == "DESIGN_REGISTER_APPEARANCE" then
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO design_appearance_aliases (appearance_key, design_id, created_at, confidence) VALUES (%s, %s, %s, %s)",
      sql_value(payload.appearance_key),
      sql_value(resolve_design_id(conn, payload.design_id)),
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
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO crafted_items (item_id, design_id, crafted_at, operational_cost_gold, cost_breakdown_json, appearance_key) " ..
      "VALUES (%s, %s, %s, %s, %s, %s)",
      sql_value(payload.item_id),
      sql_value(payload.design_id),
      sql_value(payload.crafted_at or ts),
      sql_value(payload.operational_cost_gold or 0),
      sql_value(payload.cost_breakdown_json or "{}"),
      sql_value(payload.appearance_key)
    ))
    return
  end

  if event_type == "CRAFT_RESOLVE_DESIGN" then
    exec_sql(conn, string.format(
      "UPDATE crafted_items SET design_id = %s WHERE item_id = %s",
      sql_value(resolve_design_id(conn, payload.design_id)),
      sql_value(payload.item_id)
    ))
    return
  end

  if event_type == "SELL_ITEM" then
    if payload.sale_id then
      local game_time = payload.game_time or {}
      exec_sql(conn, string.format(
        "INSERT OR REPLACE INTO sales (sale_id, item_id, sold_at, sale_price_gold, game_time_year, game_time_month, game_time_day, game_time_hour, game_time_minute) " ..
        "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)",
        sql_value(payload.sale_id),
        sql_value(payload.item_id),
        sql_value(payload.sold_at or ts),
        sql_value(payload.sale_price_gold or 0),
        sql_value(game_time.year),
        sql_value(game_time.month),
        sql_value(game_time.day),
        sql_value(game_time.hour),
        sql_value(game_time.minute)
      ))

      local item_row = fetch_one(conn, "SELECT design_id, operational_cost_gold FROM crafted_items WHERE item_id = " .. sql_value(payload.item_id))
      if not item_row or not item_row.design_id then
        error("Crafted item " .. tostring(payload.item_id) .. " not found or unresolved")
      end
      local op_profit = (payload.sale_price_gold or 0) - (tonumber(item_row.operational_cost_gold) or 0)
      update_recovery(conn, item_row.design_id, op_profit)
      return
    end

    if payload.operational_profit ~= nil and payload.design_id then
      update_recovery(conn, payload.design_id, payload.operational_profit)
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

  if event_type == "ORDER_ADD_SALE" then
    exec_sql(conn, string.format(
      "INSERT OR REPLACE INTO order_sales (order_id, sale_id) VALUES (%s, %s)",
      sql_value(payload.order_id),
      sql_value(payload.sale_id)
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
      "INSERT OR REPLACE INTO process_instances (process_instance_id, process_id, started_at, completed_at, status, note) " ..
      "VALUES (%s, %s, %s, NULL, %s, %s)",
      sql_value(payload.process_instance_id),
      sql_value(payload.process_id),
      sql_value(payload.started_at or ts),
      sql_value("in_flight"),
      sql_value(payload.note)
    ))
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
    return
  end

  -- Inventory-only events do not map to domain tables.
  return
end

function projector.truncate_domains(conn)
  local tables = {
    "design_id_aliases",
    "design_appearance_aliases",
    "order_sales",
    "orders",
    "sales",
    "crafted_items",
    "process_instances",
    "pattern_pools",
    "designs"
  }

  for _, name in ipairs(tables) do
    exec_sql(conn, "DELETE FROM " .. name)
  end
end

_G.AchaeadexLedger.Core.Projector = projector

return projector
