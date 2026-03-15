-- Busted tests for pricing suggestions and order settlement allocation

describe("Pricing", function()
  local pricing
  local inventory

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/inventory.lua")
    dofile("src/scripts/core/pricing.lua")
    inventory = _G.AchaeadexLedger.Core.Inventory
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

  it("suggests commodity prices from current WAC for arbitrary quantity", function()
    local state = { inventory = inventory.new() }
    inventory.add(state.inventory, "leather", 10, 20)

    local result = pricing.suggest_commodity(state, "leather", { qty = 5 })

    assert.are.equal("leather", result.commodity)
    assert.are.equal(5, result.qty)
    assert.are.equal(20, result.unit_wac)
    assert.are.equal(100, result.base_cost_total)
    assert.are.equal(100, result.rounded_base_total)
    assert.are.equal(130, result.suggested_total.low)
    assert.are.equal(150, result.suggested_total.mid)
    assert.are.equal(200, result.suggested_total.high)
    assert.are.equal(26, result.suggested_unit.low)
    assert.are.equal(30, result.suggested_unit.mid)
    assert.are.equal(40, result.suggested_unit.high)
  end)

  it("scales commodity totals with qty while deriving unit suggestions from totals", function()
    local state = { inventory = inventory.new() }
    inventory.add(state.inventory, "leather", 50, 20)

    local one = pricing.suggest_commodity(state, "leather", { qty = 1, tier = "mid" })
    local ten = pricing.suggest_commodity(state, "leather", { qty = 10, tier = "mid" })

    assert.are.equal(30, one.suggested_total.mid)
    assert.are.equal(30, one.suggested_unit.mid)
    assert.are.equal(300, ten.suggested_total.mid)
    assert.are.equal(math.ceil(ten.suggested_total.mid / 10), ten.suggested_unit.mid)
  end)

  it("errors when commodity has no known WAC", function()
    local state = { inventory = inventory.new() }

    assert.has_error(function()
      pricing.suggest_commodity(state, "silk", {})
    end, "commodity 'silk' has no known WAC; initialize or acquire it first")
  end)

  it("errors when commodity qty is not positive", function()
    local state = { inventory = inventory.new() }
    inventory.add(state.inventory, "leather", 10, 20)

    assert.has_error(function()
      pricing.suggest_commodity(state, "leather", { qty = 0 })
    end, "qty must be > 0")
  end)

  it("applies commodity rounding step consistently", function()
    local state = { inventory = inventory.new() }
    inventory.add(state.inventory, "wood", 100, 7)

    local result = pricing.suggest_commodity(state, "wood", {
      qty = 3,
      extra_gold = 2
    })

    assert.are.equal(23, result.adjusted_base_total)
    assert.are.equal(30, result.rounded_base_total)
    assert.are.equal(40, result.suggested_total.low)
    assert.are.equal(50, result.suggested_total.mid)
    assert.are.equal(60, result.suggested_total.high)
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
    dofile("src/scripts/core/costing.lua")
    dofile("src/scripts/core/cash.lua")
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

    ledger.apply_order_settle(state, "ST1", "O1", 9000, "cost_weighted", { "S1", "S2", "S3" }, { year = 999 })

    assert.are.equal(1500, state.sales["S1"].sale_price_gold)
    assert.are.equal(3000, state.sales["S2"].sale_price_gold)
    assert.are.equal(4500, state.sales["S3"].sale_price_gold)
    assert.are.equal(999, state.sales["S1"].game_time.year)
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
    dofile("src/scripts/core/costing.lua")
    dofile("src/scripts/core/cash.lua")
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

  it("resolves per-item source via alias mapping when needed", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_design_start(state, "D1", "shirt", "Design 1", "public", 0)
    ledger.apply_design_alias(state, "D1", "1234", "final", 1)
    ledger.apply_craft_item(state, "I1", "D1", 1000, "{}", nil)
    ledger.apply_order_create(state, "O1", "Ada", "")
    ledger.apply_order_add_item(state, "O1", "I1")

    state.crafted_items["I1"].source_id = "1234"

    local order_suggestion = pricing.suggest_order(state, "O1", {})
    assert.are.equal(1, order_suggestion.included_count)
    assert.are.equal("D1", order_suggestion.item_rows[1].source_id)
  end)
end)

describe("Source price quote", function()
  local pricing
  local ledger
  local memory_store
  local costing
  local json

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/costing.lua")
    dofile("src/scripts/core/pricing.lua")
    dofile("src/scripts/core/json.lua")
    dofile("src/scripts/core/inventory.lua")
    dofile("src/scripts/core/deferred_processes.lua")
    dofile("src/scripts/core/pattern_pools.lua")
    dofile("src/scripts/core/production_sources.lua")
    dofile("src/scripts/core/recovery.lua")
    dofile("src/scripts/core/cash.lua")
    dofile("src/scripts/core/ledger.lua")
    dofile("src/scripts/core/storage/memory_event_store.lua")

    pricing = _G.AchaeadexLedger.Core.Pricing
    ledger = _G.AchaeadexLedger.Core.Ledger
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
    costing = _G.AchaeadexLedger.Core.Costing
    json = _G.AchaeadexLedger.Core.Json
  end)

  it("quotes by primary source id", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "leather", 10, 20)
    ledger.apply_design_start(state, "D1", "shirt", "Design 1", "public", 0)
    ledger.apply_design_set_bom(state, "D1", { leather = 2 })
    ledger.apply_design_set_fee(state, "D1", 15)

    local quote = pricing.quote_source(state, "D1", {})
    assert.are.equal("D1", quote.resolved_source_id)
    assert.is_nil(quote.matched_alias_id)
    assert.are.equal(55, quote.base_cost)
    assert.are.equal(300, quote.per_unit.low)
    assert.are.equal(500, quote.per_unit.mid)
    assert.are.equal(700, quote.per_unit.high)
  end)

  it("quotes by alias id and resolves to same internal source", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "leather", 10, 20)
    ledger.apply_design_start(state, "D1", "shirt", "Design 1", "public", 0)
    ledger.apply_design_set_bom(state, "D1", { leather = 2 })
    ledger.apply_design_set_fee(state, "D1", 15)
    ledger.apply_design_alias(state, "D1", "1234", "final", 1)

    local primary = pricing.quote_source(state, "D1", {})
    local alias = pricing.quote_source(state, "1234", {})

    assert.are.equal("D1", alias.resolved_source_id)
    assert.are.equal("1234", alias.matched_alias_id)
    assert.are.equal(primary.base_cost, alias.base_cost)
    assert.are.equal(primary.per_unit.low, alias.per_unit.low)
    assert.are.equal(primary.per_unit.mid, alias.per_unit.mid)
    assert.are.equal(primary.per_unit.high, alias.per_unit.high)
  end)

  it("materials override BOM for quote", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "leather", 10, 20)
    ledger.apply_opening_inventory(state, "cloth", 10, 5)
    ledger.apply_design_start(state, "D1", "shirt", "Design 1", "public", 0)
    ledger.apply_design_set_bom(state, "D1", { leather = 2 })

    local quote = pricing.quote_source(state, "D1", {
      materials = { cloth = 3 }
    })

    assert.are.equal("explicit", quote.materials_source)
    assert.are.equal(15, quote.components.materials_cost_gold)
  end)

  it("missing WAC yields warning without failing", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_design_start(state, "D1", "shirt", "Design 1", "public", 0)
    ledger.apply_design_set_bom(state, "D1", { silk = 2 })

    local quote = pricing.quote_source(state, "D1", {})
    assert.are.equal(1, quote.missing_wac_count)
    assert.are.equal(1, #quote.warnings)
    assert.are.equal(0, quote.components.materials_cost_gold)
  end)

  it("rounding override follows same pricing math as suggest", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "leather", 10, 20)
    ledger.apply_design_start(state, "D1", "shirt", "Design 1", "public", 0)
    ledger.apply_design_set_bom(state, "D1", { leather = 2 })
    ledger.apply_design_set_fee(state, "D1", 15)

    local quote = pricing.quote_source(state, "D1", {
      round = 100
    })
    local expected = pricing.suggest_prices(55, {
      round_to_gold = 100,
      tiers = pricing.default_policy().tiers
    })

    assert.are.equal(expected.rounded_base_gold, quote.rounded_base)
    assert.are.equal(expected.suggested.low, quote.per_unit.low)
    assert.are.equal(expected.suggested.mid, quote.per_unit.mid)
    assert.are.equal(expected.suggested.high, quote.per_unit.high)
  end)

  it("uses the same shared material and time cost basis as crafting", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "leather", 10, 20)
    ledger.apply_design_start(state, "D1", "shirt", "Design 1", "public", 0)
    ledger.apply_design_set_bom(state, "D1", { leather = 2 })
    ledger.apply_design_set_fee(state, "D1", 15)

    local quote = pricing.quote_source(state, "D1", {
      time_hours = 1.5,
      time_cost_per_hour = 25
    })

    local time_cost = costing.compute_time_cost_from_hours(1.5, 25).amount_gold
    ledger.apply_craft_item_auto(state, "I-Q1", "D1", {
      time_hours = 1.5,
      time_cost_gold = time_cost
    })

    local breakdown = json.decode(state.crafted_items["I-Q1"].cost_breakdown_json)
    assert.are.equal(40, quote.components.materials_cost_gold)
    assert.are.equal(40, breakdown.materials_cost_gold)
    assert.are.equal(38, quote.components.time_cost_gold)
    assert.are.equal(38, breakdown.time_cost_gold)
    assert.are.equal(93, quote.base_cost)
    assert.are.equal(93, breakdown.total_operational_cost_gold)
  end)

  it("suggest_item resolves item source via alias mapping", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_design_start(state, "D1", "shirt", "Design 1", "public", 0)
    ledger.apply_design_alias(state, "D1", "1234", "final", 1)
    ledger.apply_craft_item(state, "I1", "D1", 1000, "{}", nil)
    state.crafted_items["I1"].source_id = "1234"

    local suggestion = pricing.suggest_item(state, "I1")
    assert.are.equal("D1", suggestion.resolved_source_id)
  end)
end)
