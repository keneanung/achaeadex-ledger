-- Busted tests for core reports

describe("Reports", function()
  local ledger
  local reports
  local memory_store
  local json

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/inventory.lua")
    dofile("src/scripts/core/deferred_processes.lua")
    dofile("src/scripts/core/pattern_pools.lua")
    dofile("src/scripts/core/designs.lua")
    dofile("src/scripts/core/recovery.lua")
    dofile("src/scripts/core/json.lua")
    dofile("src/scripts/core/ledger.lua")
    dofile("src/scripts/core/reports.lua")
    dofile("src/scripts/core/storage/memory_event_store.lua")

    ledger = _G.AchaeadexLedger.Core.Ledger
    reports = _G.AchaeadexLedger.Core.Reports
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
    json = _G.AchaeadexLedger.Core.Json
  end)

  local function craft_and_sell(state, item_id, sale_id, sale_price, game_time)
    local breakdown = json.encode({ base_cost = 40, per_item_fee = 0 })
    ledger.apply_craft_item(state, item_id, "D1", 40, breakdown, nil)
    ledger.apply_sell_item(state, sale_id, item_id, sale_price, game_time)
  end

  it("overall report totals", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_pattern_activate(state, "P1", "shirt", "Pool", 150)
    ledger.apply_design_start(state, "D1", "shirt", "Test", "private", 1)
    ledger.apply_design_cost(state, "D1", 100, "submission")

    craft_and_sell(state, "I1", "S1", 100, { year = 650 })
    craft_and_sell(state, "I2", "S2", 120, { year = 650 })

    local report = reports.overall(state)

    assert.are.equal(220, report.totals.revenue)
    assert.are.equal(80, report.totals.operational_cost)
    assert.are.equal(140, report.totals.operational_profit)
    assert.are.equal(100, report.totals.applied_to_design_capital)
    assert.are.equal(40, report.totals.applied_to_pattern_capital)
    assert.are.equal(0, report.totals.true_profit)
    assert.are.equal(0, report.design_remaining)
    assert.are.equal(110, report.pattern_remaining)
  end)

  it("overall report includes inventory value", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "leather", 10, 20)
    ledger.apply_broker_buy(state, "leather", 10, 40)
    ledger.apply_broker_sell(state, "leather", 5, 35)

    local report = reports.overall(state)

    assert.are.equal(450, report.holdings.inventory_value)
  end)

  it("year report filters by game time and warns on unknown", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_pattern_activate(state, "P1", "shirt", "Pool", 150)
    ledger.apply_design_start(state, "D1", "shirt", "Test", "private", 1)

    craft_and_sell(state, "I1", "S1", 100, { year = 650 })
    craft_and_sell(state, "I2", "S2", 120, { year = 651 })
    craft_and_sell(state, "I3", "S3", 110, nil)

    local report = reports.year(state, 650)

    assert.are.equal(100, report.totals.revenue)
    assert.are.equal(40, report.totals.operational_cost)
    assert.are.equal(60, report.totals.operational_profit)

    local warned = false
    for _, warning in ipairs(report.warnings) do
      if warning:find("unknown game time", 1, true) then
        warned = true
        break
      end
    end
    assert.is_true(warned)
  end)

  it("order report totals", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_pattern_activate(state, "P1", "shirt", "Pool", 150)
    ledger.apply_design_start(state, "D1", "shirt", "Test", "private", 1)

    craft_and_sell(state, "I1", "S1", 100, { year = 650 })
    craft_and_sell(state, "I2", "S2", 120, { year = 650 })

    ledger.apply_order_create(state, "O1", "Customer", "Note")
    ledger.apply_order_add_sale(state, "O1", "S1")
    ledger.apply_order_add_sale(state, "O1", "S2")

    local report = reports.order(state, "O1")

    assert.are.equal("O1", report.order.order_id)
    assert.are.equal(220, report.totals.revenue)
    assert.are.equal(80, report.totals.operational_cost)
    assert.are.equal(140, report.totals.operational_profit)
  end)

  it("design report aggregates performance", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_pattern_activate(state, "P1", "shirt", "Pool", 150)
    ledger.apply_design_start(state, "D1", "shirt", "Test", "private", 1)
    ledger.apply_design_cost(state, "D1", 100, "submission")

    craft_and_sell(state, "I1", "S1", 100, { year = 650 })
    craft_and_sell(state, "I2", "S2", 120, { year = 650 })

    local report = reports.design(state, "D1", {})

    assert.are.equal(2, report.crafted_count)
    assert.are.equal(2, report.sold_count)
    assert.are.equal(220, report.totals.revenue)
    assert.are.equal(80, report.totals.operational_cost)
    assert.are.equal(140, report.totals.operational_profit)
    assert.are.equal(100, report.design_capital_initial)
  end)

  it("design and item reports include unsold cost basis", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_pattern_activate(state, "P1", "shirt", "Pool", 150)
    ledger.apply_design_start(state, "D1", "shirt", "Test", "private", 1)

    local breakdown = json.encode({ base_cost = 40, per_item_fee = 0 })
    ledger.apply_craft_item(state, "I1", "D1", 40, breakdown, nil)

    local report = reports.design(state, "D1", {})
    assert.are.equal(40, report.unsold_items_value)

    local item_report = ledger.report_item(state, "I1")
    assert.are.equal(40, item_report.unsold_cost_basis)
  end)
end)
