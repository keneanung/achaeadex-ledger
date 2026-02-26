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
    dofile("src/scripts/core/production_sources.lua")
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

  it("year report filters by game time and only warns when verbose", function()
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
    assert.are.equal(0, #report.warnings)

    local verbose_report = reports.year(state, 650, { verbose = true })

    local warned = false
    for _, warning in ipairs(verbose_report.warnings) do
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
    ledger.apply_opening_inventory(state, "leather", 10, 20)

    craft_and_sell(state, "I1", "S1", 100, { year = 650 })
    craft_and_sell(state, "I2", "S2", 120, { year = 650 })

    ledger.apply_order_create(state, "O1", "Customer", "Note")
    ledger.apply_order_add_sale(state, "O1", "S1")
    ledger.apply_order_add_sale(state, "O1", "S2")
    ledger.apply_broker_sell(state, "leather", 2, 35, {
      sale_id = "CS1",
      order_id = "O1"
    })

    local report = reports.order(state, "O1")

    assert.are.equal("O1", report.order.order_id)
    assert.are.equal(290, report.totals.revenue)
    assert.are.equal(120, report.totals.operational_cost)
    assert.are.equal(170, report.totals.operational_profit)
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

  it("overall totals remain internally consistent with integer gold rounding", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_design_start(state, "D1", "shirt", "Test", "public", 0)
    ledger.apply_craft_item(state, "I-FLOAT", "D1", 40.4, "{}", nil)
    ledger.apply_sell_item(state, "S-FLOAT", "I-FLOAT", 100, { year = 998 })

    local report = reports.overall(state)
    assert.are.equal(report.totals.revenue - report.totals.operational_cost, report.totals.operational_profit)
  end)

  it("year report does not subtract global process losses from year activity", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "ore", 10, 10)
    ledger.apply_process_start(state, "P-LOSS", "smelt", { ore = 5 }, 10)
    ledger.apply_process_complete(state, "P-LOSS", {})

    ledger.apply_design_start(state, "D1", "shirt", "Test", "public", 0)
    ledger.apply_craft_item(state, "I-Y1", "D1", 40, "{}", nil)
    ledger.apply_sell_item(state, "S-Y1", "I-Y1", 100, { year = 998 })

    local report = reports.year(state, 998)
    assert.are.equal(60, report.totals.operational_profit)
    assert.are.equal(0, report.totals.process_losses)
    assert.are.equal(60, report.totals.true_profit)
    assert.are.equal(60, report.holdings.process_losses)
  end)

  it("write-off with payload game_time is attributed to that year", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "ore", 10, 10)
    ledger.apply_process_start(state, "P-Y123", "smelt", { ore = 5 }, 10, nil, { year = 123 })
    ledger.apply_process_complete(state, "P-Y123", {}, nil, { year = 123 })

    local report = reports.year(state, 123)
    assert.are.equal(60, report.totals.process_losses)
    assert.are.equal(-60, report.totals.true_profit)
    assert.are.equal(0, report.unattributed_process_write_off_count)
  end)

  it("write-off without game_time is attributed via PROCESS_SET_GAME_TIME override", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "ore", 10, 10)
    ledger.apply_process_start(state, "P-OVR", "smelt", { ore = 5 }, 10)
    ledger.apply_process_complete(state, "P-OVR", {})
    ledger.apply_process_set_game_time(state, "P-OVR", { year = 123 }, "write_off", "historic correction")

    local report = reports.year(state, 123)
    assert.are.equal(60, report.totals.process_losses)
    assert.are.equal(0, report.unattributed_process_write_off_count)
  end)

  it("write-off without game_time and no override is excluded from year totals and counted unattributed", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "ore", 10, 10)
    ledger.apply_process_start(state, "P-NOYEAR", "smelt", { ore = 5 }, 10)
    ledger.apply_process_complete(state, "P-NOYEAR", {})

    local report = reports.year(state, 123)
    assert.are.equal(0, report.totals.process_losses)
    assert.are.equal(1, report.unattributed_process_write_off_count)
    assert.is_not_nil(report.note)

    local unresolved = reports.process_write_offs_needing_year(state)
    assert.are.equal(1, #unresolved)
    assert.are.equal("P-NOYEAR", unresolved[1].process_instance_id)
  end)

  it("process report shows inputs, outputs, costs and write-off", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "ore", 10, 10)
    ledger.apply_process_start(state, "P-DETAIL", "smelt", { ore = 5 }, 10)
    ledger.apply_process_add_inputs(state, "P-DETAIL", { ore = 1 })
    ledger.apply_process_complete(state, "P-DETAIL", { metal = 3 })

    local report = reports.process(state, "P-DETAIL")
    assert.are.equal("P-DETAIL", report.process_instance_id)
    assert.are.equal("smelt", report.process_id)
    assert.are.equal("completed", report.status)
    assert.are.equal(6, report.committed_inputs.ore)
    assert.are.equal(3, report.outputs.metal)
    assert.are.equal(60, report.committed_cost_gold)
    assert.are.equal(10, report.fees_gold)
    assert.are.equal(70, report.total_committed_gold)
    assert.are.equal(30, report.write_off_total_gold)
  end)
end)
