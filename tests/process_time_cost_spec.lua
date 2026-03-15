describe("Process time costs", function()
  local ledger
  local inventory
  local memory_store
  local json
  local costing

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/json.lua")
    dofile("src/scripts/core/costing.lua")
    dofile("src/scripts/core/inventory.lua")
    dofile("src/scripts/core/deferred_processes.lua")
    dofile("src/scripts/core/pattern_pools.lua")
    dofile("src/scripts/core/production_sources.lua")
    dofile("src/scripts/core/recovery.lua")
    dofile("src/scripts/core/cash.lua")
    dofile("src/scripts/core/ledger.lua")
    dofile("src/scripts/core/storage/memory_event_store.lua")

    ledger = _G.AchaeadexLedger.Core.Ledger
    inventory = _G.AchaeadexLedger.Core.Inventory
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
    json = _G.AchaeadexLedger.Core.Json
    costing = _G.AchaeadexLedger.Core.Costing
  end)

  local function find_events(events, event_type)
    local matches = {}
    for _, event in ipairs(events) do
      if event.event_type == event_type then
        table.insert(matches, event)
      end
    end
    return matches
  end

  it("emits PROCESS_ADD_TIME_COST for active deferred completion", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_process_time_cost_rate(state, 25)
    ledger.apply_process_time_cost_cutover(state, "2026-03-01T00:00:00Z")
    ledger.apply_opening_inventory(state, "ore", 10, 10)
    ledger.apply_process_start(state, "PX-T1", "smelt", { ore = 5 }, 10, nil, nil, {
      started_at = "2026-03-13T00:00:00Z"
    })

    ledger.apply_process_complete(state, "PX-T1", {}, nil, nil, {
      completed_at = "2026-03-13T01:30:00Z"
    })

    local time_events = find_events(store.events, "PROCESS_ADD_TIME_COST")
    assert.are.equal(1, #time_events)
    assert.are.equal("PX-T1", time_events[1].payload.process_instance_id)
    assert.are.equal(5400, time_events[1].payload.elapsed_seconds)
    assert.are.equal(25, time_events[1].payload.rate_gold_per_hour)
    assert.are.equal(38, time_events[1].payload.amount_gold)

    local write_off = find_events(store.events, "PROCESS_WRITE_OFF")
    assert.are.equal(1, #write_off)
    assert.are.equal(98, write_off[1].payload.amount_gold)
  end)

  it("emits PROCESS_ADD_TIME_COST for active deferred abort", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_process_time_cost_rate(state, 25)
    ledger.apply_process_time_cost_cutover(state, "2026-03-01T00:00:00Z")
    ledger.apply_opening_inventory(state, "ore", 10, 3)
    ledger.apply_process_start(state, "PX-T2", "smelt", { ore = 5 }, 0, nil, nil, {
      started_at = "2026-03-13T00:00:00Z"
    })

    ledger.apply_process_abort(state, "PX-T2", nil, nil, nil, {
      completed_at = "2026-03-13T00:30:00Z"
    })

    local time_events = find_events(store.events, "PROCESS_ADD_TIME_COST")
    assert.are.equal(1, #time_events)
    assert.are.equal(13, time_events[1].payload.amount_gold)
  end)

  it("does not emit time cost for passive deferred processes", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_process_time_cost_rate(state, 25)
    ledger.apply_process_time_cost_cutover(state, "2026-03-01T00:00:00Z")
    ledger.apply_opening_inventory(state, "ore", 10, 10)
    ledger.apply_process_start(state, "PX-T3", "smelt", { ore = 5 }, 0, nil, nil, {
      started_at = "2026-03-13T00:00:00Z",
      passive = 1
    })

    ledger.apply_process_complete(state, "PX-T3", {}, nil, nil, {
      completed_at = "2026-03-13T01:00:00Z"
    })

    local time_events = find_events(store.events, "PROCESS_ADD_TIME_COST")
    assert.are.equal(0, #time_events)
  end)

  it("emits time cost for immediate processes only when time is provided", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_process_time_cost_rate(state, 10)
    ledger.apply_process_time_cost_cutover(state, "2026-03-01T00:00:00Z")
    ledger.apply_opening_inventory(state, "fibre", 10, 5)
    ledger.apply_opening_inventory(state, "coal", 10, 2)

    ledger.apply_process(state, "refine", { fibre = 4, coal = 4 }, { cloth = 4 }, 0, nil, {
      time_hours = 1,
      completed_at = "2026-03-13T02:00:00Z"
    })

    local time_events = find_events(store.events, "PROCESS_ADD_TIME_COST")
    assert.are.equal(1, #time_events)
    assert.are.equal(10, time_events[1].payload.amount_gold)
    assert.are.equal(9.5, inventory.get_unit_cost(state.inventory, "cloth"))

    ledger.apply_opening_inventory(state, "fibre", 4, 5)
    ledger.apply_opening_inventory(state, "coal", 4, 2)
    ledger.apply_process(state, "refine", { fibre = 4, coal = 4 }, { cloth2 = 4 }, 0, nil, {
      completed_at = "2026-03-13T03:00:00Z"
    })

    time_events = find_events(store.events, "PROCESS_ADD_TIME_COST")
    assert.are.equal(1, #time_events)
    assert.are.equal(7, inventory.get_unit_cost(state.inventory, "cloth2"))
  end)

  it("treats historical processes before cutover as passive by default", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_process_time_cost_rate(state, 25)
    ledger.apply_process_time_cost_cutover(state, "2026-03-13T00:00:00Z")
    ledger.apply_opening_inventory(state, "ore", 10, 10)
    ledger.apply_process_start(state, "PX-T4", "smelt", { ore = 5 }, 0, nil, nil, {
      started_at = "2026-03-12T23:00:00Z"
    })

    ledger.apply_process_complete(state, "PX-T4", {}, nil, nil, {
      completed_at = "2026-03-13T01:00:00Z"
    })

    local time_events = find_events(store.events, "PROCESS_ADD_TIME_COST")
    assert.are.equal(0, #time_events)
    assert.are.equal(1, state.process_instances["PX-T4"].passive)
  end)

  it("uses shared time-cost rounding and standardized breakdown keys", function()
    local rounded = costing.compute_time_cost(5400, 25)
    assert.are.equal(38, rounded.amount_gold)

    local process_breakdown = costing.compute_process_cost_breakdown({
      materials_cost_gold = 28,
      direct_fee_gold = 4,
      time_cost_gold = 38
    })
    assert.are.equal(28, process_breakdown.materials_cost_gold)
    assert.are.equal(4, process_breakdown.direct_fee_gold)
    assert.are.equal(38, process_breakdown.time_cost_gold)
    assert.are.equal(70, process_breakdown.total_operational_cost_gold)

    local craft_breakdown = costing.compute_craft_cost_breakdown({
      materials_cost_gold = 40,
      per_item_fee_gold = 15,
      time_cost_gold = 10
    })
    assert.are.equal(40, craft_breakdown.materials_cost_gold)
    assert.are.equal(15, craft_breakdown.per_item_fee_gold)
    assert.are.equal(10, craft_breakdown.time_cost_gold)
    assert.are.equal(65, craft_breakdown.total_operational_cost_gold)

    local state = ledger.new(memory_store.new())
    ledger.apply_opening_inventory(state, "leather", 10, 20)
    ledger.apply_design_start(state, "D-T1", "shirt", "Timed", "public", 0)
    ledger.apply_design_set_fee(state, "D-T1", 15)
    ledger.apply_design_set_bom(state, "D-T1", { leather = 2 })
    ledger.apply_craft_item_auto(state, "I-T1", "D-T1", {
      time_hours = 1,
      time_cost_gold = 10
    })

    local breakdown = json.decode(state.crafted_items["I-T1"].cost_breakdown_json)
    assert.are.equal(40, breakdown.materials_cost_gold)
    assert.are.equal(15, breakdown.per_item_fee_gold)
    assert.are.equal(10, breakdown.time_cost_gold)
    assert.are.equal(65, breakdown.total_operational_cost_gold)
  end)

  it("uses the same rounded time cost for immediate and deferred processes with matching elapsed time", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_process_time_cost_rate(state, 25)
    ledger.apply_process_time_cost_cutover(state, "2026-03-01T00:00:00Z")
    ledger.apply_opening_inventory(state, "ore", 10, 10)
    ledger.apply_opening_inventory(state, "fibre", 10, 5)
    ledger.apply_opening_inventory(state, "coal", 10, 2)

    ledger.apply_process_start(state, "PX-T5", "smelt", { ore = 1 }, 0, nil, nil, {
      started_at = "2026-03-13T00:00:00Z"
    })
    ledger.apply_process_complete(state, "PX-T5", { metal = 1 }, nil, nil, {
      completed_at = "2026-03-13T01:30:00Z"
    })

    ledger.apply_process(state, "refine", { fibre = 4, coal = 4 }, { cloth = 4 }, 0, nil, {
      time_hours = 1.5,
      completed_at = "2026-03-13T03:00:00Z"
    })

    local time_events = find_events(store.events, "PROCESS_ADD_TIME_COST")
    assert.are.equal(2, #time_events)
    assert.are.equal(38, time_events[1].payload.amount_gold)
    assert.are.equal(38, time_events[2].payload.amount_gold)
  end)

  it("supports explicit revenue alongside commodity outputs", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_process_time_cost_rate(state, 25)
    ledger.apply_process_time_cost_cutover(state, "2026-03-01T00:00:00Z")
    ledger.apply_opening_inventory(state, "ore", 5, 10)

    ledger.apply_process(state, "mint", { ore = 1 }, { gold = 2 }, 0, nil, {
      revenue_gold = 50,
      time_hours = 1,
      completed_at = "2026-03-13T03:00:00Z"
    })

    assert.are.equal(2, inventory.get_qty(state.inventory, "gold"))
    assert.are.equal(50, state.process_instances[next(state.process_instances)].revenue_gold)
  end)
end)