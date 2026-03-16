describe("Standard-value process allocation", function()
  local inventory
  local ledger
  local memory_store

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

    inventory = _G.AchaeadexLedger.Core.Inventory
    ledger = _G.AchaeadexLedger.Core.Ledger
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
  end)

  local function has_write_off(events)
    for _, event in ipairs(events) do
      if event.event_type == "PROCESS_WRITE_OFF" then
        return true
      end
    end
    return false
  end

  it("allocates co-product costs by standard value instead of raw quantity", function()
    local state = ledger.new(memory_store.new())

    ledger.apply_opening_inventory(state, "carcass", 1, 2000)
    ledger.apply_commodity_set_standard_value(state, "skins", 100)
    ledger.apply_commodity_set_standard_value(state, "minerals", 10)

    ledger.apply_process(state, "butcher", { carcass = 1 }, { skins = 20, minerals = 200 }, 0)

    assert.are.equal(1000, inventory.get_total_cost(state.inventory, "skins"))
    assert.are.equal(1000, inventory.get_total_cost(state.inventory, "minerals"))
    assert.are.equal(50, inventory.get_unit_cost(state.inventory, "skins"))
    assert.are.equal(5, inventory.get_unit_cost(state.inventory, "minerals"))
  end)

  it("does not let high-quantity low-value outputs absorb most of the cost", function()
    local state = ledger.new(memory_store.new())

    ledger.apply_opening_inventory(state, "carcass", 1, 2000)
    ledger.apply_commodity_set_standard_value(state, "skins", 100)
    ledger.apply_commodity_set_standard_value(state, "minerals", 10)

    ledger.apply_process(state, "butcher", { carcass = 1 }, { skins = 20, minerals = 200 }, 0)

    assert.are.equal(inventory.get_total_cost(state.inventory, "skins"), inventory.get_total_cost(state.inventory, "minerals"))
    assert.is_true(inventory.get_total_cost(state.inventory, "minerals") <= inventory.get_total_cost(state.inventory, "skins"))
  end)

  it("fails multi-output allocation when an output commodity has no standard value", function()
    local state = ledger.new(memory_store.new())

    ledger.apply_opening_inventory(state, "carcass", 1, 2000)
    ledger.apply_commodity_set_standard_value(state, "skins", 100)

    assert.has_error(function()
      ledger.apply_process(state, "butcher", { carcass = 1 }, { skins = 20, minerals = 200 }, 0)
    end, "Process allocation requires standard_value for commodity 'minerals'")
  end)

  it("offsets material inputs with gold output but keeps time cost allocatable", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_process_time_cost_rate(state, 300)
    ledger.apply_process_time_cost_cutover(state, "2026-03-01T00:00:00Z")
    ledger.apply_opening_inventory(state, "ore", 1, 500)
    ledger.apply_commodity_set_standard_value(state, "bar", 100)

    ledger.apply_process(state, "smelt", { ore = 1 }, { gold = 400, bar = 1 }, 0, nil, {
      time_hours = 1,
      completed_at = "2026-03-13T01:00:00Z"
    })

    assert.are.equal(400, inventory.get_unit_cost(state.inventory, "bar"))
    assert.are.equal(0, inventory.get_unit_cost(state.inventory, "gold"))
    assert.is_false(has_write_off(store.events))
  end)

  it("never lets gold output drive allocatable process cost below time cost", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_process_time_cost_rate(state, 300)
    ledger.apply_process_time_cost_cutover(state, "2026-03-01T00:00:00Z")
    ledger.apply_opening_inventory(state, "ore", 1, 100)
    ledger.apply_commodity_set_standard_value(state, "bar", 100)

    ledger.apply_process(state, "smelt", { ore = 1 }, { gold = 500, bar = 1 }, 0, nil, {
      time_hours = 1,
      completed_at = "2026-03-13T01:00:00Z"
    })

    assert.are.equal(300, inventory.get_unit_cost(state.inventory, "bar"))
    assert.are.equal(0, inventory.get_unit_cost(state.inventory, "gold"))
    assert.is_false(has_write_off(store.events))
  end)

  it("capitalizes only the unrecovered offsettable cost plus time cost when revenue is lower than inputs and fees", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_process_time_cost_rate(state, 300)
    ledger.apply_process_time_cost_cutover(state, "2026-03-01T00:00:00Z")
    ledger.apply_opening_inventory(state, "ore", 1, 500)

    ledger.apply_process(state, "smelt", { ore = 1 }, { ingot = 1 }, 100, nil, {
      revenue_gold = 400,
      time_hours = 1,
      completed_at = "2026-03-13T01:00:00Z"
    })

    local process_id = next(state.process_instances)
    local instance = state.process_instances[process_id]

    assert.are.equal(500, inventory.get_unit_cost(state.inventory, "ingot"))
    assert.are.equal(600, instance.offsettable_cost_total)
    assert.are.equal(200, instance.net_offsettable_cost_total)
    assert.are.equal(500, instance.capitalized_basis_total)
    assert.are.equal(0, instance.realized_surplus_gold)
    assert.is_false(has_write_off(store.events))
  end)

  it("capitalizes only time cost when revenue exactly matches inputs and fees", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_process_time_cost_rate(state, 300)
    ledger.apply_process_time_cost_cutover(state, "2026-03-01T00:00:00Z")
    ledger.apply_opening_inventory(state, "ore", 1, 500)

    ledger.apply_process(state, "smelt", { ore = 1 }, { ingot = 1 }, 100, nil, {
      revenue_gold = 600,
      time_hours = 1,
      completed_at = "2026-03-13T01:00:00Z"
    })

    local instance = state.process_instances[next(state.process_instances)]

    assert.are.equal(300, inventory.get_unit_cost(state.inventory, "ingot"))
    assert.are.equal(300, instance.capitalized_basis_total)
    assert.are.equal(0, instance.realized_surplus_gold)
    assert.is_false(has_write_off(store.events))
  end)

  it("realizes surplus when revenue exceeds inputs and fees while keeping time cost capitalized", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_process_time_cost_rate(state, 300)
    ledger.apply_process_time_cost_cutover(state, "2026-03-01T00:00:00Z")
    ledger.apply_opening_inventory(state, "ore", 1, 500)

    ledger.apply_process(state, "smelt", { ore = 1 }, { ingot = 1 }, 100, nil, {
      revenue_gold = 900,
      time_hours = 1,
      completed_at = "2026-03-13T01:00:00Z"
    })

    local instance = state.process_instances[next(state.process_instances)]

    assert.are.equal(300, inventory.get_unit_cost(state.inventory, "ingot"))
    assert.are.equal(300, instance.capitalized_basis_total)
    assert.are.equal(300, instance.realized_surplus_gold)
    assert.is_false(has_write_off(store.events))
  end)

  it("capitalizes unrecovered input cost plus time cost when there are no direct fees", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_process_time_cost_rate(state, 300)
    ledger.apply_process_time_cost_cutover(state, "2026-03-01T00:00:00Z")
    ledger.apply_opening_inventory(state, "ore", 1, 500)

    ledger.apply_process(state, "smelt", { ore = 1 }, { ingot = 1 }, 0, nil, {
      revenue_gold = 400,
      time_hours = 1,
      completed_at = "2026-03-13T01:00:00Z"
    })

    local instance = state.process_instances[next(state.process_instances)]

    assert.are.equal(400, inventory.get_unit_cost(state.inventory, "ingot"))
    assert.are.equal(500, instance.offsettable_cost_total)
    assert.are.equal(100, instance.net_offsettable_cost_total)
    assert.are.equal(400, instance.capitalized_basis_total)
    assert.are.equal(0, instance.realized_surplus_gold)
    assert.is_false(has_write_off(store.events))
  end)

  it("allocates multi-output capitalization after revenue offset instead of the pre-offset total", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_process_time_cost_rate(state, 300)
    ledger.apply_process_time_cost_cutover(state, "2026-03-01T00:00:00Z")
    ledger.apply_opening_inventory(state, "ore", 1, 500)
    ledger.apply_commodity_set_standard_value(state, "ingot", 1)
    ledger.apply_commodity_set_standard_value(state, "slag", 1)

    ledger.apply_process(state, "smelt", { ore = 1 }, { ingot = 1, slag = 1 }, 100, nil, {
      revenue_gold = 400,
      time_hours = 1,
      completed_at = "2026-03-13T01:00:00Z"
    })

    local instance = state.process_instances[next(state.process_instances)]

    assert.are.equal(250, inventory.get_total_cost(state.inventory, "ingot"))
    assert.are.equal(250, inventory.get_total_cost(state.inventory, "slag"))
    assert.are.equal(500, instance.capitalized_basis_total)
    assert.are.equal(0, instance.realized_surplus_gold)
    assert.is_false(has_write_off(store.events))
  end)
end)

describe("Commodity pricing metadata", function()
  local inventory
  local ledger
  local memory_store
  local pricing

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
    dofile("src/scripts/core/pricing.lua")
    dofile("src/scripts/core/storage/memory_event_store.lua")

    inventory = _G.AchaeadexLedger.Core.Inventory
    ledger = _G.AchaeadexLedger.Core.Ledger
    pricing = _G.AchaeadexLedger.Core.Pricing
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
  end)

  it("learns quantity-weighted market prices only from broker buy and sell transactions", function()
    local state = ledger.new(memory_store.new())

    ledger.apply_opening_inventory(state, "cloth", 10, 5)
    ledger.apply_commodity_set_standard_value(state, "cloth", 5)
    ledger.apply_process(state, "weave", {}, { cloth = 2 }, 0)

    local initial = pricing.inspect_commodity(state, "cloth")
    assert.is_nil(initial.observed_market_avg)
    assert.are.equal(0, initial.observed_market_count)

    ledger.apply_broker_buy(state, "cloth", 3, 10)
    ledger.apply_broker_sell(state, "cloth", 1, 12)

    local learned = pricing.inspect_commodity(state, "cloth")
    assert.are.equal(10.5, learned.observed_market_avg)
    assert.are.equal(2, learned.observed_market_count)
    assert.are.equal(4, learned.observed_market_qty_total)
  end)

  it("adapts standard value after the observation threshold is reached", function()
    local state = ledger.new(memory_store.new())

    ledger.apply_opening_inventory(state, "skins", 1, 100)

    for _ = 1, 5 do
      ledger.apply_broker_buy(state, "skins", 1, 200)
    end

    assert.are.equal(110, inventory.get_standard_value(state.inventory, "skins"))
  end)

  it("uses market-based pricing when broker observations exceed the accounting floor", function()
    local state = ledger.new(memory_store.new())

    ledger.apply_opening_inventory(state, "leather", 10, 20)
    ledger.apply_broker_buy(state, "leather", 1, 100)

    local result = pricing.suggest_commodity(state, "leather", { qty = 1, tier = "mid" })

    assert.are.equal(100, result.observed_market_avg)
    assert.are.equal(1, result.observed_market_count)
    assert.are.equal(1, result.observed_market_qty_total)
    assert.are.equal(150, result.suggested_total.mid)
  end)

  it("replays older ledgers without requiring migration for commodity pricing fields", function()
    local original_store = memory_store.new()
    local original_state = ledger.new(original_store)

    ledger.apply_opening_inventory(original_state, "cloth", 10, 5)
    ledger.apply_broker_buy(original_state, "cloth", 2, 15)

    local replay_state = ledger.new(memory_store.new())
    for _, event in ipairs(original_store:read_all()) do
      ledger.apply_event(replay_state, event)
    end

    local pricing_data = pricing.inspect_commodity(replay_state, "cloth")
    assert.are.equal(5, pricing_data.standard_value)
    assert.are.equal(15, pricing_data.observed_market_avg)
    assert.are.equal(1, pricing_data.observed_market_count)
    assert.are.equal(2, pricing_data.observed_market_qty_total)
  end)
end)