-- Pricing policy and suggestions (advisory only)

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local pricing = _G.AchaeadexLedger.Core.Pricing or {}

local function get_inventory()
  if not _G.AchaeadexLedger or not _G.AchaeadexLedger.Core or not _G.AchaeadexLedger.Core.Inventory then
    error("AchaeadexLedger.Core.Inventory is not loaded")
  end

  return _G.AchaeadexLedger.Core.Inventory
end

local function round_up(value, step)
  if step <= 0 then
    return value
  end
  return math.ceil(value / step) * step
end

local function clamp(value, min_value, max_value)
  if value < min_value then
    return min_value
  end
  if value > max_value then
    return max_value
  end
  return value
end

function pricing.default_policy()
  return {
    round_to_gold = 50,
    tiers = {
      low = { markup_percent = 0.60, min_profit_gold = 200, max_profit_gold = 1500 },
      mid = { markup_percent = 0.90, min_profit_gold = 400, max_profit_gold = 3000 },
      high = { markup_percent = 1.20, min_profit_gold = 600, max_profit_gold = 6000 }
    }
  }
end

local function suggest_for_tier(rounded_base, policy, tier)
  local round_to = policy.round_to_gold or 50
  local raw_profit = rounded_base * tier.markup_percent
  local profit = clamp(raw_profit, tier.min_profit_gold, tier.max_profit_gold)
  local suggested = rounded_base + profit
  return round_up(suggested, round_to)
end

function pricing.suggest_prices(base_cost_gold, policy)
  assert(type(base_cost_gold) == "number", "base_cost_gold must be a number")

  policy = policy or pricing.default_policy()
  local round_to = policy.round_to_gold or 50
  local rounded_base = round_up(base_cost_gold, round_to)

  local tiers = policy.tiers or {}
  return {
    base_cost_gold = base_cost_gold,
    rounded_base_gold = rounded_base,
    suggested = {
      low = suggest_for_tier(rounded_base, policy, tiers.low),
      mid = suggest_for_tier(rounded_base, policy, tiers.mid),
      high = suggest_for_tier(rounded_base, policy, tiers.high)
    }
  }
end

local function build_selected_tiers(tier)
  if tier == "low" then
    return { low = true }
  end
  if tier == "mid" then
    return { mid = true }
  end
  if tier == "high" then
    return { high = true }
  end
  return { low = true, mid = true, high = true }
end

function pricing.resolve_source_identifier(state, source_id_or_alias)
  assert(type(state) == "table", "state must be a table")
  assert(type(source_id_or_alias) == "string", "source_id_or_alias must be a string")

  local source = state.production_sources and state.production_sources[source_id_or_alias] or nil
  if source then
    return {
      input_id = source_id_or_alias,
      source_id = source_id_or_alias,
      source = source,
      matched_alias_id = nil
    }
  end

  local alias = state.design_aliases and state.design_aliases[source_id_or_alias] or nil
  if alias and alias.source_id then
    source = state.production_sources and state.production_sources[alias.source_id] or nil
    if source then
      return {
        input_id = source_id_or_alias,
        source_id = alias.source_id,
        source = source,
        matched_alias_id = source_id_or_alias
      }
    end
  end

  return nil, "source not found for '" .. tostring(source_id_or_alias) .. "'. Try 'adex list sources' or 'adex list designs' and check aliases."
end

local function resolve_source_for_item(state, item)
  if not item or not item.source_id then
    return nil
  end
  local resolved = pricing.resolve_source_identifier(state, item.source_id)
  return resolved
end

function pricing.suggest_item(state, item_id)
  assert(type(state) == "table", "state must be a table")
  assert(type(item_id) == "string", "item_id must be a string")

  local item = state.crafted_items and state.crafted_items[item_id] or nil
  if not item then
    error("item not found")
  end

  local resolved = resolve_source_for_item(state, item)
  local source = resolved and resolved.source or nil
  local policy = source and source.pricing_policy or pricing.default_policy()
  local policy_used = source and source.pricing_policy and "source" or "default"
  local suggestion = pricing.suggest_prices(item.operational_cost_gold, policy)

  return {
    item_id = item_id,
    item = item,
    resolved_source_id = resolved and resolved.source_id or nil,
    matched_alias_id = resolved and resolved.matched_alias_id or nil,
    policy_used = policy_used,
    suggestion = suggestion
  }
end

function pricing.quote_source(state, source_id_or_alias, opts)
  assert(type(state) == "table", "state must be a table")
  assert(type(source_id_or_alias) == "string", "source_id_or_alias must be a string")

  opts = opts or {}
  local qty = tonumber(opts.qty) or 1
  local tier = opts.tier or "all"
  local round_override = opts.round and tonumber(opts.round) or nil
  local time_hours = tonumber(opts.time_hours) or 0
  local extra_gold = tonumber(opts.extra_gold) or 0
  local time_cost_per_hour = tonumber(opts.time_cost_per_hour) or 0

  if qty <= 0 then
    error("qty must be > 0")
  end
  if time_hours < 0 then
    error("time must be >= 0")
  end
  if extra_gold < 0 then
    error("extra must be >= 0")
  end
  if tier ~= "low" and tier ~= "mid" and tier ~= "high" and tier ~= "all" then
    error("tier must be one of low|mid|high|all")
  end

  local resolved, err = pricing.resolve_source_identifier(state, source_id_or_alias)
  if not resolved then
    error(err)
  end

  local source = resolved.source
  local materials = opts.materials or source.bom
  if not materials then
    error("cannot quote " .. tostring(resolved.source_id) .. ": no BOM and no --materials override")
  end

  local inventory = get_inventory()
  local material_rows = {}
  local warnings = {}
  local materials_cost = 0
  local missing_wac_count = 0

  local keys = {}
  for commodity in pairs(materials) do
    table.insert(keys, commodity)
  end
  table.sort(keys)

  for _, commodity in ipairs(keys) do
    local qty_needed = tonumber(materials[commodity]) or 0
    local unit_wac = inventory.get_unit_cost(state.inventory, commodity) or 0
    local subtotal = qty_needed * unit_wac
    if unit_wac <= 0 and qty_needed > 0 then
      missing_wac_count = missing_wac_count + 1
      table.insert(warnings, "WARNING: Missing WAC for " .. tostring(commodity) .. " (use adex inv init/broker buy)")
    end
    table.insert(material_rows, {
      commodity = commodity,
      qty = qty_needed,
      unit_wac = unit_wac,
      subtotal = subtotal
    })
    materials_cost = materials_cost + subtotal
  end

  local per_item_fee = tonumber(source.per_item_fee_gold) or 0
  local time_cost = math.floor(time_hours * time_cost_per_hour)
  local base_cost = materials_cost + per_item_fee + time_cost + extra_gold
  local policy = source.pricing_policy or pricing.default_policy()
  local policy_used = source.pricing_policy and "source" or "default"

  if round_override and round_override > 0 then
    policy = {
      round_to_gold = round_override,
      tiers = policy.tiers
    }
  end

  local suggested = pricing.suggest_prices(base_cost, policy)
  local selected_tiers = build_selected_tiers(tier)
  local per_unit = {
    low = selected_tiers.low and suggested.suggested.low or nil,
    mid = selected_tiers.mid and suggested.suggested.mid or nil,
    high = selected_tiers.high and suggested.suggested.high or nil
  }

  local totals = {
    qty = qty,
    base_cost = base_cost * qty,
    low = per_unit.low and (per_unit.low * qty) or nil,
    mid = per_unit.mid and (per_unit.mid * qty) or nil,
    high = per_unit.high and (per_unit.high * qty) or nil
  }

  return {
    input_id = source_id_or_alias,
    resolved_source_id = resolved.source_id,
    matched_alias_id = resolved.matched_alias_id,
    source_name = source.name,
    source_type = source.source_type,
    source_kind = source.source_kind,
    policy_used = policy_used,
    material_rows = material_rows,
    materials_source = opts.materials and "explicit" or "design_bom",
    missing_wac_count = missing_wac_count,
    warnings = warnings,
    components = {
      materials_cost = materials_cost,
      per_item_fee = per_item_fee,
      time_cost = time_cost,
      extra = extra_gold
    },
    base_cost = suggested.base_cost_gold,
    rounded_base = suggested.rounded_base_gold,
    tier = tier,
    qty = qty,
    per_unit = per_unit,
    totals = totals,
    round_to_gold = policy.round_to_gold
  }
end

local function is_item_sold(state, item_id)
  for _, sale in pairs(state.sales or {}) do
    if sale.item_id == item_id then
      return true
    end
  end
  return false
end

function pricing.suggest_order(state, order_id, opts)
  assert(type(state) == "table", "state must be a table")
  assert(type(order_id) == "string", "order_id must be a string")

  opts = opts or {}
  local tier = opts.tier or "all"
  local selected_tiers = build_selected_tiers(tier)
  local include_sold = opts.include_sold == true
  local round_override = opts.round and tonumber(opts.round) or nil

  local order = state.orders and state.orders[order_id] or nil
  if not order then
    error("Order " .. order_id .. " not found")
  end

  local order_items = state.order_items and state.order_items[order_id] or nil
  if not order_items then
    return {
      order_id = order_id,
      item_rows = {},
      total_base_cost = 0,
      lump_sum_low = 0,
      lump_sum_mid = 0,
      lump_sum_high = 0,
      implied_profit_low = 0,
      implied_profit_mid = 0,
      implied_profit_high = 0,
      included_count = 0,
      excluded_sold_count = 0
    }
  end

  local item_ids = {}
  for item_id, _ in pairs(order_items) do
    table.insert(item_ids, item_id)
  end
  table.sort(item_ids)

  local item_rows = {}
  local total_base_cost = 0
  local lump_sum_low = 0
  local lump_sum_mid = 0
  local lump_sum_high = 0
  local included_count = 0
  local excluded_sold_count = 0

  for _, item_id in ipairs(item_ids) do
    local item = state.crafted_items and state.crafted_items[item_id] or nil
    if item then
      local sold = is_item_sold(state, item_id)
      if sold and not include_sold then
        excluded_sold_count = excluded_sold_count + 1
      else
        local resolved = resolve_source_for_item(state, item)
        local source = resolved and resolved.source or nil
        local policy = source and source.pricing_policy or pricing.default_policy()
        local policy_used = source and source.pricing_policy and "source" or "default"

        if round_override and round_override > 0 then
          local policy_copy = {
            round_to_gold = round_override,
            tiers = policy.tiers
          }
          policy = policy_copy
        end

        local result = pricing.suggest_prices(item.operational_cost_gold, policy)
        local suggested_low = selected_tiers.low and result.suggested.low or nil
        local suggested_mid = selected_tiers.mid and result.suggested.mid or nil
        local suggested_high = selected_tiers.high and result.suggested.high or nil
        local notes = {}
        if sold then
          table.insert(notes, "SOLD")
        end
        table.insert(notes, "policy=" .. policy_used)

        table.insert(item_rows, {
          item_id = item_id,
          source_id = resolved and resolved.source_id or item.source_id or "(unresolved)",
          base_cost_gold = result.base_cost_gold,
          suggested_low = suggested_low,
          suggested_mid = suggested_mid,
          suggested_high = suggested_high,
          notes = table.concat(notes, ", ") .. (resolved and resolved.matched_alias_id and (", alias=" .. tostring(resolved.matched_alias_id)) or "")
        })

        included_count = included_count + 1
        total_base_cost = total_base_cost + (result.base_cost_gold or 0)
        lump_sum_low = lump_sum_low + (suggested_low or 0)
        lump_sum_mid = lump_sum_mid + (suggested_mid or 0)
        lump_sum_high = lump_sum_high + (suggested_high or 0)
      end
    end
  end

  local has_settlement = false
  for _, settlement in pairs(state.order_settlements or {}) do
    if settlement.order_id == order_id then
      has_settlement = true
      break
    end
  end

  local informational_note = nil
  if has_settlement or order.status == "closed" then
    informational_note = "Order already settled/closed; suggestions are informational only."
  end

  return {
    order_id = order_id,
    item_rows = item_rows,
    total_base_cost = total_base_cost,
    lump_sum_low = lump_sum_low,
    lump_sum_mid = lump_sum_mid,
    lump_sum_high = lump_sum_high,
    implied_profit_low = lump_sum_low - total_base_cost,
    implied_profit_mid = lump_sum_mid - total_base_cost,
    implied_profit_high = lump_sum_high - total_base_cost,
    included_count = included_count,
    excluded_sold_count = excluded_sold_count,
    informational_note = informational_note
  }
end

_G.AchaeadexLedger.Core.Pricing = pricing

return pricing
