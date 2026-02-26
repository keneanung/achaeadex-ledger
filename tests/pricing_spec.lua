-- Busted tests for pricing suggestions and order settlement allocation

describe("Pricing", function()
  local pricing

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/pricing.lua")
    pricing = _G.AchaeadexLedger.Core.Pricing
  end)

  it("TEST 19 - price suggestion defaults and rounding", function()
    local result = pricing.suggest_prices(1210, pricing.default_policy())

    assert.are.equal(1210, result.base_cost_gold)
    assert.are.equal(1250, result.rounded_base_gold)
    assert.are.equal(2000, result.suggested.low)
    assert.are.equal(2400, result.suggested.mid)
    assert.are.equal(2750, result.suggested.high)
  end)

  it("TEST 20 - price suggestion profit cap", function()
    local result = pricing.suggest_prices(8000, pricing.default_policy())

    assert.are.equal(8000, result.rounded_base_gold)
    assert.are.equal(14000, result.suggested.high)
  end)
end)

describe("Order settlement allocation", function()
  local ledger
  local memory_store

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/json.lua")
    dofile("src/scripts/core/inventory.lua")
    dofile("src/scripts/core/deferred_processes.lua")
    dofile("src/scripts/core/pattern_pools.lua")
    dofile("src/scripts/core/production_sources.lua")
    dofile("src/scripts/core/recovery.lua")
    dofile("src/scripts/core/ledger.lua")
    dofile("src/scripts/core/storage/memory_event_store.lua")

    ledger = _G.AchaeadexLedger.Core.Ledger
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
  end)

  it("TEST 21 - lump-sum order settlement cost-weighted allocation", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_order_create(state, "O1", "Ada", "")
    ledger.apply_design_start(state, "D1", "shirt", "Design 1", "public", 0)

    ledger.apply_craft_item(state, "I1", "D1", 1000, "{}", nil)
    ledger.apply_craft_item(state, "I2", "D1", 2000, "{}", nil)
    ledger.apply_craft_item(state, "I3", "D1", 3000, "{}", nil)

    ledger.apply_order_add_item(state, "O1", "I1")
    ledger.apply_order_add_item(state, "O1", "I2")
    ledger.apply_order_add_item(state, "O1", "I3")

    ledger.apply_order_settle(state, "ST1", "O1", 9000, "cost_weighted", { "S1", "S2", "S3" })

    assert.are.equal(1500, state.sales["S1"].sale_price_gold)
    assert.are.equal(3000, state.sales["S2"].sale_price_gold)
    assert.are.equal(4500, state.sales["S3"].sale_price_gold)
  end)
end)

describe("Order price suggestions", function()
  local pricing
  local ledger
  local memory_store

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/pricing.lua")
    dofile("src/scripts/core/json.lua")
    dofile("src/scripts/core/inventory.lua")
    dofile("src/scripts/core/deferred_processes.lua")
    dofile("src/scripts/core/pattern_pools.lua")
    dofile("src/scripts/core/production_sources.lua")
    dofile("src/scripts/core/recovery.lua")
    dofile("src/scripts/core/ledger.lua")
    dofile("src/scripts/core/storage/memory_event_store.lua")

    pricing = _G.AchaeadexLedger.Core.Pricing
    ledger = _G.AchaeadexLedger.Core.Ledger
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
  end)

  it("matches per-item suggest outputs and lump sums for unsold order items", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_design_start(state, "D1", "shirt", "Design 1", "public", 0)
    ledger.apply_craft_item(state, "I1", "D1", 1000, "{}", nil)
    ledger.apply_craft_item(state, "I2", "D1", 2000, "{}", nil)
    ledger.apply_order_create(state, "O1", "Ada", "")
    ledger.apply_order_add_item(state, "O1", "I1")
    ledger.apply_order_add_item(state, "O1", "I2")

    local order_suggestion = pricing.suggest_order(state, "O1", {})
    local i1 = pricing.suggest_prices(1000, pricing.default_policy())
    local i2 = pricing.suggest_prices(2000, pricing.default_policy())

    assert.are.equal(2, order_suggestion.included_count)
    assert.are.equal(3000, order_suggestion.total_base_cost)
    assert.are.equal(i1.suggested.low + i2.suggested.low, order_suggestion.lump_sum_low)
    assert.are.equal(i1.suggested.mid + i2.suggested.mid, order_suggestion.lump_sum_mid)
    assert.are.equal(i1.suggested.high + i2.suggested.high, order_suggestion.lump_sum_high)
    assert.are.equal(order_suggestion.lump_sum_low - order_suggestion.total_base_cost, order_suggestion.implied_profit_low)
    assert.are.equal(order_suggestion.lump_sum_mid - order_suggestion.total_base_cost, order_suggestion.implied_profit_mid)
    assert.are.equal(order_suggestion.lump_sum_high - order_suggestion.total_base_cost, order_suggestion.implied_profit_high)
  end)

  it("excludes sold items by default and includes them when include-sold=1", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_design_start(state, "D1", "shirt", "Design 1", "public", 0)
    ledger.apply_craft_item(state, "I1", "D1", 1000, "{}", nil)
    ledger.apply_craft_item(state, "I2", "D1", 2000, "{}", nil)
    ledger.apply_order_create(state, "O1", "Ada", "")
    ledger.apply_order_add_item(state, "O1", "I1")
    ledger.apply_order_add_item(state, "O1", "I2")
    ledger.apply_sell_item(state, "S1", "I1", 1500, { year = 998 })

    local excluded = pricing.suggest_order(state, "O1", { include_sold = false })
    assert.are.equal(1, excluded.included_count)
    assert.are.equal(1, excluded.excluded_sold_count)

    local included = pricing.suggest_order(state, "O1", { include_sold = true })
    assert.are.equal(2, included.included_count)
    assert.are.equal(0, included.excluded_sold_count)

    local sold_row = nil
    for _, row in ipairs(included.item_rows) do
      if row.item_id == "I1" then
        sold_row = row
        break
      end
    end
    assert.is_not_nil(sold_row)
    assert.is_true(string.find(sold_row.notes or "", "SOLD", 1, true) ~= nil)
  end)

  it("uses mixed source policy overrides and defaults in one order", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_design_start(state, "D1", "shirt", "Design 1", "public", 0)
    ledger.apply_design_start(state, "D2", "shirt", "Design 2", "public", 0)
    ledger.apply_design_set_pricing(state, "D1", {
      round_to_gold = 100,
      tiers = {
        low = { markup_percent = 0.5, min_profit_gold = 100, max_profit_gold = 1000 },
        mid = { markup_percent = 0.8, min_profit_gold = 200, max_profit_gold = 2000 },
        high = { markup_percent = 1.0, min_profit_gold = 300, max_profit_gold = 3000 }
      }
    })

    ledger.apply_craft_item(state, "I1", "D1", 1000, "{}", nil)
    ledger.apply_craft_item(state, "I2", "D2", 1000, "{}", nil)
    ledger.apply_order_create(state, "O1", "Ada", "")
    ledger.apply_order_add_item(state, "O1", "I1")
    ledger.apply_order_add_item(state, "O1", "I2")

    local order_suggestion = pricing.suggest_order(state, "O1", {})
    local override_item = pricing.suggest_prices(1000, state.production_sources["D1"].pricing_policy)
    local default_item = pricing.suggest_prices(1000, pricing.default_policy())

    assert.are.equal(override_item.suggested.low + default_item.suggested.low, order_suggestion.lump_sum_low)
    assert.are.equal(override_item.suggested.mid + default_item.suggested.mid, order_suggestion.lump_sum_mid)
    assert.are.equal(override_item.suggested.high + default_item.suggested.high, order_suggestion.lump_sum_high)
  end)
end)
