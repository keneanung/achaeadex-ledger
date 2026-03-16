-- Busted tests for core reports

describe("Reports", function()
  local ledger
  local reports
  local memory_store
  local json
  local inventory

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/inventory.lua")
    dofile("src/scripts/core/deferred_processes.lua")
    dofile("src/scripts/core/pattern_pools.lua")
    dofile("src/scripts/core/production_sources.lua")
    dofile("src/scripts/core/recovery.lua")
    dofile("src/scripts/core/json.lua")
    dofile("src/scripts/core/costing.lua")
    dofile("src/scripts/core/cash.lua")
    dofile("src/scripts/core/ledger.lua")
    dofile("src/scripts/core/reports.lua")
    dofile("src/scripts/core/storage/memory_event_store.lua")

    ledger = _G.AchaeadexLedger.Core.Ledger
    reports = _G.AchaeadexLedger.Core.Reports
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
    json = _G.AchaeadexLedger.Core.Json
    inventory = _G.AchaeadexLedger.Core.Inventory
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
    assert.are.equal(0, report.totals.true_profit)
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

    local verbose_report = reports.year(state, 123, { verbose = true })
    assert.is_not_nil(verbose_report.note)

    local unresolved = reports.process_write_offs_needing_year(state)
    assert.are.equal(1, #unresolved)
    assert.are.equal("P-NOYEAR", unresolved[1].process_instance_id)
  end)

  it("year report includes order settlement count for resolved year", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_design_start(state, "D1", "shirt", "Test", "public", 0)
    ledger.apply_craft_item(state, "I1", "D1", 1000, "{}", nil)
    ledger.apply_order_create(state, "O1", "Customer", "")
    ledger.apply_order_add_item(state, "O1", "I1")
    ledger.apply_order_settle(state, "ST-998", "O1", 1200, "cost_weighted", { "S-998" }, { year = 998 })

    local report_998 = reports.year(state, 998)
    assert.are.equal(1, report_998.order_settlement_count)

    local report_999 = reports.year(state, 999)
    assert.are.equal(0, report_999.order_settlement_count)
  end)

  it("event without game_time resolves year from default anchor", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_design_start(state, "D1", "shirt", "Test", "public", 0)
    ledger.apply_craft_item(state, "I-ANCHOR", "D1", 40, "{}", nil)
    ledger.apply_sell_item(state, "S-ANCHOR", "I-ANCHOR", 100, nil)
    ledger.apply_set_default_game_year(state, 123, 1, "backfill")

    local report = reports.year(state, 123)
    assert.are.equal(100, report.totals.revenue)
  end)

  it("explicit game_time overrides default anchor", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_set_default_game_year(state, 122, 1, "backfill")
    ledger.apply_opening_inventory(state, "ore", 10, 10)
    ledger.apply_process_start(state, "P-EXPL", "smelt", { ore = 5 }, 10, nil, { year = 124 })
    ledger.apply_process_complete(state, "P-EXPL", {}, nil, { year = 124 })

    assert.are.equal(60, reports.year(state, 124).totals.process_losses)
    assert.are.equal(0, reports.year(state, 122).totals.process_losses)
  end)

  it("PROCESS_SET_GAME_TIME override takes precedence over default anchor", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_set_default_game_year(state, 122, 1, "backfill")
    ledger.apply_opening_inventory(state, "ore", 10, 10)
    ledger.apply_process_start(state, "P-OVR-DEF", "smelt", { ore = 5 }, 10)
    ledger.apply_process_complete(state, "P-OVR-DEF", {})
    ledger.apply_process_set_game_time(state, "P-OVR-DEF", { year = 123 }, "write_off", "override")

    assert.are.equal(60, reports.year(state, 123).totals.process_losses)
    assert.are.equal(0, reports.year(state, 122).totals.process_losses)
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
    assert.are.equal(40, report.capitalized_basis_gold)
  end)

  it("deferred process with explicit revenue reports revenue, total cost, and net result without affecting inventory", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "curatives", 10, 15)
    ledger.apply_process_start(state, "P-HUNT", "hunting", { curatives = 2 }, 50, nil, { year = 700 })
    ledger.apply_process_add_inputs(state, "P-HUNT", { curatives = 1 })
    ledger.apply_process_complete(state, "P-HUNT", { trophies = 2 }, nil, { year = 700 }, {
      revenue_gold = 500
    })

    local process_report = reports.process(state, "P-HUNT")
    assert.are.equal(500, process_report.revenue_gold)
    assert.are.equal(45, process_report.committed_cost_gold)
    assert.are.equal(50, process_report.fees_gold)
    assert.are.equal(95, process_report.total_process_cost_gold)
    assert.are.equal(405, process_report.net_result_gold)
    assert.are.equal(0, process_report.capitalized_basis_gold)
    assert.are.equal(2, process_report.outputs.trophies)
    assert.are.equal(0, inventory.get_qty(state.inventory, "gold"))

    local year_report = reports.year(state, 700)
    assert.are.equal(500, year_report.totals.process_revenue)
    assert.are.equal(95, year_report.totals.process_total_cost)
    assert.are.equal(0, year_report.totals.process_basis_carried)
    assert.are.equal(405, year_report.totals.process_net_result)
    assert.are.equal(405, year_report.totals.process_profit_contribution)
    assert.are.equal(405, year_report.totals.true_profit)

    local overall_report = reports.overall(state)
    assert.are.equal(500, overall_report.totals.process_revenue)
    assert.are.equal(0, overall_report.totals.process_basis_carried)
    assert.are.equal(0, overall_report.totals.process_losses)
    assert.are.equal(405, overall_report.totals.process_profit_contribution)
    assert.are.equal(405, overall_report.totals.true_profit)
  end)

  it("immediate process with explicit revenue reports revenue and leaves WAC inventory unchanged", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "curatives", 10, 20)
    ledger.apply_process(state, "hunting", { curatives = 1 }, {}, 25, { year = 701 }, {
      revenue_gold = 125
    })

    local process_id = nil
    for instance_id, instance in pairs(state.process_instances or {}) do
      if instance.process_id == "hunting" then
        process_id = instance_id
        break
      end
    end

    assert.is_not_nil(process_id)
    assert.are.equal(0, inventory.get_qty(state.inventory, "gold"))
    assert.are.equal(20, inventory.get_unit_cost(state.inventory, "curatives"))

    local process_report = reports.process(state, process_id)
    assert.are.equal(125, process_report.revenue_gold)
    assert.are.equal(20, process_report.committed_cost_gold)
    assert.are.equal(45, process_report.total_process_cost_gold)
    assert.are.equal(80, process_report.net_result_gold)
    assert.are.equal(0, process_report.capitalized_basis_gold)

    local overall = reports.overall(state)
    assert.are.equal(125, overall.totals.process_revenue)
    assert.are.equal(45, overall.totals.process_total_cost)
    assert.are.equal(0, overall.totals.process_basis_carried)
    assert.are.equal(80, overall.totals.process_net_result)
    assert.are.equal(45, overall.totals.process_losses)
    assert.are.equal(80, overall.totals.process_profit_contribution)
    assert.are.equal(80, overall.totals.true_profit)
  end)

  it("revenue-emitting processes show basis carried into outputs separately from profit contribution", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "curatives", 10, 20)
    ledger.apply_process(state, "harvest", { curatives = 1 }, { trophy = 1 }, 25, { year = 704 }, {
      revenue_gold = 125
    })

    assert.are.equal(1, inventory.get_qty(state.inventory, "trophy"))
  assert.are.equal(0, inventory.get_unit_cost(state.inventory, "trophy"))

    local year_report = reports.year(state, 704)
    assert.are.equal(125, year_report.totals.process_revenue)
    assert.are.equal(45, year_report.totals.process_total_cost)
    assert.are.equal(0, year_report.totals.process_basis_carried)
    assert.are.equal(80, year_report.totals.process_net_result)
    assert.are.equal(80, year_report.totals.process_profit_contribution)
    assert.are.equal(80, year_report.totals.true_profit)
  end)

  it("true profit uses realized process net result rather than carried basis", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_design_start(state, "D-REALIZED", "shirt", "Realized Shirt", "private", 1)
    ledger.apply_design_cost(state, "D-REALIZED", 7578, "submission")
    ledger.apply_opening_inventory(state, "cloth", 1, 48193)
    ledger.apply_craft_item(state, "I-REALIZED", "D-REALIZED", 48193, json.encode({ total_operational_cost_gold = 48193 }), "realized shirt")
    ledger.apply_sell_item(state, "S-REALIZED", "I-REALIZED", 63500, { year = 999 })
    ledger.apply_process(state, "expedition", {}, { salvage = 1 }, 9185, { year = 999 }, {
      revenue_gold = 10199
    })

    local year_report = reports.year(state, 999)
    local overall_report = reports.overall(state)

    assert.are.equal(15307, year_report.totals.operational_profit)
    assert.are.equal(7578, year_report.totals.applied_to_design_capital)
    assert.are.equal(10199, year_report.totals.process_revenue)
    assert.are.equal(9185, year_report.totals.process_total_cost)
    assert.are.equal(1014, year_report.totals.process_net_result)
    assert.are.equal(0, year_report.totals.process_losses)
    assert.are.equal(0, year_report.totals.process_basis_carried)
    assert.are.equal(1014, year_report.totals.process_profit_contribution)
    assert.are.equal(8743, year_report.totals.true_profit)

    assert.are.equal(8743, overall_report.totals.true_profit)
    assert.are.equal(1014, overall_report.totals.process_profit_contribution)
    assert.are.equal(0, overall_report.totals.process_basis_carried)
  end)

  it("production process revenue is realized while committed basis remains capitalized in outputs", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_process_time_cost_rate(state, 4781)
    ledger.apply_process_time_cost_cutover(state, "2026-03-01T00:00:00Z")
    ledger.apply_opening_inventory(state, "potash", 31, 1546 / 31)
    ledger.apply_commodity_set_standard_value(state, "malachite", 1)
    ledger.apply_commodity_set_standard_value(state, "realgar", 1)
    ledger.apply_commodity_set_standard_value(state, "skins", 1)
    ledger.apply_process(state, "hunting", { potash = 31 }, { malachite = 939, realgar = 61, skins = 54 }, 0, nil, {
      revenue_gold = 2790,
      time_hours = 1,
      completed_at = "2026-03-13T03:00:00Z"
    })

    local process_id = next(state.process_instances)
    local report = reports.process(state, process_id)
    local overall = reports.overall(state)

    assert.are.equal(2790, report.revenue_gold)
    assert.are.equal(1546, report.committed_cost_gold)
    assert.are.equal(4781, report.time_cost_gold)
    assert.are.equal(6327, report.total_process_cost_gold)
    assert.are.equal(0, report.write_off_total_gold)
    assert.are.equal(4781, report.capitalized_basis_gold)
    assert.are.equal(1244, report.net_result_gold)

    assert.are.equal(2790, overall.totals.process_revenue)
    assert.are.equal(6327, overall.totals.process_total_cost)
    assert.are.equal(4781, overall.totals.process_basis_carried)
    assert.are.equal(1244, overall.totals.process_net_result)
    assert.are.equal(1244, overall.totals.process_profit_contribution)
  end)

  it("gold in process outputs is treated as a commodity when explicitly output", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "ore", 5, 10)
    ledger.apply_process(state, "mint", { ore = 1 }, { gold = 2 }, 0, { year = 702 })

    assert.are.equal(2, inventory.get_qty(state.inventory, "gold"))
    assert.are.equal(5, inventory.get_unit_cost(state.inventory, "gold"))

    local overall = reports.overall(state)
    assert.is_nil(overall.totals.process_revenue)
  end)
end)
