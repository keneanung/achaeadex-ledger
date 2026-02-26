-- Pricing policy and suggestions (advisory only)

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local pricing = _G.AchaeadexLedger.Core.Pricing or {}

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
        local source = item.source_id and state.production_sources and state.production_sources[item.source_id] or nil
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
          source_id = item.source_id or "(unresolved)",
          base_cost_gold = result.base_cost_gold,
          suggested_low = suggested_low,
          suggested_mid = suggested_mid,
          suggested_high = suggested_high,
          notes = table.concat(notes, ", ")
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
