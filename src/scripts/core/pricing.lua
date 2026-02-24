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

_G.AchaeadexLedger.Core.Pricing = pricing

return pricing
