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

local function get_costing()
  if not _G.AchaeadexLedger or not _G.AchaeadexLedger.Core or not _G.AchaeadexLedger.Core.Costing then
    error("AchaeadexLedger.Core.Costing is not loaded")
  end

  return _G.AchaeadexLedger.Core.Costing
end

local function build_market_adjusted_suggestion(base_cost_gold, policy, observed_market_avg, qty, extra_gold)
  local observed_avg = tonumber(observed_market_avg)
  local quantity = tonumber(qty) or 1
  local extra = tonumber(extra_gold) or 0
  if observed_avg == nil then
    return nil
  end

  local market_base_total = (observed_avg * quantity) + extra
  return pricing.suggest_prices(market_base_total, policy)
end

local function round_up(value, step)
  if step <= 0 then
    return value
  end
  return math.ceil(value / step) * step
end

local function clamp(value, min_value, max_value)
  if min_value ~= nil and value < min_value then
    return min_value
  end
  if max_value ~= nil and value > max_value then
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

function pricing.default_commodity_policy()
  return {
    round_to_gold = 10,
    tiers = {
      low = { markup_percent = 0.25, min_profit_gold = 0, max_profit_gold = nil },
      mid = { markup_percent = 0.50, min_profit_gold = 0, max_profit_gold = nil },
      high = { markup_percent = 1.00, min_profit_gold = 0, max_profit_gold = nil }
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

function pricing.suggest_commodity(state, commodity, opts)
  assert(type(state) == "table", "state must be a table")
  assert(type(commodity) == "string", "commodity must be a string")

  opts = opts or {}
  local qty = tonumber(opts.qty) or 1
  local tier = opts.tier or "all"
  local round_override = opts.round and tonumber(opts.round) or nil
  local extra_gold = tonumber(opts.extra_gold) or 0

  if qty <= 0 then
    error("qty must be > 0")
  end
  if extra_gold < 0 then
    error("extra must be >= 0")
  end
  if tier ~= "low" and tier ~= "mid" and tier ~= "high" and tier ~= "all" then
    error("tier must be one of low|mid|high|all")
  end

  local inventory = get_inventory()
  local unit_wac = inventory.get_unit_cost(state.inventory, commodity)
  local qty_on_hand = inventory.get_qty(state.inventory, commodity)
  local pricing_data = inventory.get_pricing_data(state.inventory, commodity)

  if qty_on_hand <= 0 or unit_wac <= 0 then
    error("commodity '" .. tostring(commodity) .. "' has no known WAC; initialize or acquire it first")
  end

  local base_cost_total = unit_wac * qty
  local adjusted_base_total = base_cost_total + extra_gold
  local policy = pricing.default_commodity_policy()
  if round_override and round_override > 0 then
    policy = {
      round_to_gold = round_override,
      tiers = policy.tiers
    }
  end

  local suggestion = pricing.suggest_prices(adjusted_base_total, policy)
  local market_suggestion = nil
  if (pricing_data.observed_market_count or 0) > 0 and pricing_data.observed_market_avg ~= nil then
    market_suggestion = build_market_adjusted_suggestion(adjusted_base_total, policy, pricing_data.observed_market_avg, qty, extra_gold)
  end
  local selected_tiers = build_selected_tiers(tier)
  local total_suggested = {
    low = selected_tiers.low and math.max(
      suggestion.suggested.low,
      market_suggestion and market_suggestion.suggested.low or suggestion.suggested.low
    ) or nil,
    mid = selected_tiers.mid and math.max(
      suggestion.suggested.mid,
      market_suggestion and market_suggestion.suggested.mid or suggestion.suggested.mid
    ) or nil,
    high = selected_tiers.high and math.max(
      suggestion.suggested.high,
      market_suggestion and market_suggestion.suggested.high or suggestion.suggested.high
    ) or nil
  }
  local unit_suggested = {
    low = total_suggested.low and math.ceil(total_suggested.low / qty) or nil,
    mid = total_suggested.mid and math.ceil(total_suggested.mid / qty) or nil,
    high = total_suggested.high and math.ceil(total_suggested.high / qty) or nil
  }

  return {
    commodity = commodity,
    qty = qty,
    qty_on_hand = qty_on_hand,
    unit_wac = unit_wac,
    base_cost_total = base_cost_total,
    extra_gold = extra_gold,
    adjusted_base_total = adjusted_base_total,
    rounded_base_total = suggestion.rounded_base_gold,
    observed_market_avg = pricing_data.observed_market_avg,
    observed_market_count = pricing_data.observed_market_count,
    observed_market_qty_total = pricing_data.observed_market_qty_total,
    standard_value = pricing_data.standard_value,
    market_rounded_base_total = market_suggestion and market_suggestion.rounded_base_gold or nil,
    tier = tier,
    round_to_gold = policy.round_to_gold,
    suggested_total = total_suggested,
    suggested_unit = unit_suggested
  }
end

function pricing.inspect_commodity(state, commodity)
  assert(type(state) == "table", "state must be a table")
  assert(type(commodity) == "string", "commodity must be a string")

  local inventory = get_inventory()
  return inventory.get_pricing_data(state.inventory, commodity)
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
  local costing = get_costing()
  local warnings = {}
  local material_result = costing.compute_materials_breakdown(materials, {
    get_unit_cost = function(commodity)
      return inventory.get_unit_cost(state.inventory, commodity)
    end,
    validate_qty = true
  })

  for _, row in ipairs(material_result.material_lines) do
    if row.unit_wac <= 0 and row.qty > 0 then
      table.insert(warnings, "WARNING: Missing WAC for " .. tostring(row.commodity) .. " (use adex inv init/broker buy)")
    end
  end

  local per_item_fee = tonumber(source.per_item_fee_gold) or 0
  local time_cost = costing.compute_time_cost_from_hours(time_hours, time_cost_per_hour).amount_gold
  local breakdown = costing.compute_craft_cost_breakdown({
    materials_cost_gold = material_result.materials_cost_gold,
    materials = materials,
    materials_source = opts.materials and "explicit" or "design_bom",
    per_item_fee_gold = per_item_fee,
    time_hours = time_hours,
    time_cost_gold = time_cost,
    direct_fee_gold = extra_gold,
    allocated_session_cost_gold = 0,
    carried_basis_gold = 0
  })
  local base_cost = breakdown.total_operational_cost_gold
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
    material_rows = material_result.material_lines,
    materials_source = opts.materials and "explicit" or "design_bom",
    missing_wac_count = material_result.missing_wac_count,
    warnings = warnings,
    components = breakdown,
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
