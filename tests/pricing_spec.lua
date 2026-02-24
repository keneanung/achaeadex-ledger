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
    dofile("src/scripts/core/designs.lua")
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
