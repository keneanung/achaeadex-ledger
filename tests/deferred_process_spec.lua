-- Busted tests for deferred processes (Test 13 and 14)

describe("Deferred Processes", function()
  local inventory
  local deferred

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/inventory.lua")
    dofile("src/scripts/core/deferred_processes.lua")

    inventory = _G.AchaeadexLedger.Core.Inventory
    deferred = _G.AchaeadexLedger.Core.DeferredProcesses
  end)

  it("TEST 13 - deferred process start to complete", function()
    local state = { inventory = inventory.new(), process_instances = {} }

    inventory.add(state.inventory, "fibre", 10, 5)
    inventory.add(state.inventory, "coal", 10, 2)

    deferred.start(state, "P1", "refine", { fibre = 4, coal = 4 }, 1)

    assert.are.equal(6, inventory.get_qty(state.inventory, "fibre"))
    assert.are.equal(6, inventory.get_qty(state.inventory, "coal"))
    assert.are.equal(0, inventory.get_qty(state.inventory, "cloth"))

    deferred.complete(state, "P1", { cloth = 4 })

    assert.are.equal(4, inventory.get_qty(state.inventory, "cloth"))
    assert.are.equal(7.25, inventory.get_unit_cost(state.inventory, "cloth"))
  end)

  it("TEST 14 - deferred process with in-flight additions and abort", function()
    local state = { inventory = inventory.new(), process_instances = {} }

    inventory.add(state.inventory, "ore", 10, 3)
    inventory.add(state.inventory, "flux", 10, 1)

    deferred.start(state, "P2", "smelt", { ore = 5 }, 0)
    deferred.add_inputs(state, "P2", { flux = 2 })
    deferred.add_fee(state, "P2", 4)

    deferred.abort(state, "P2", {
      returned = { ore = 1 },
      lost = { ore = 4, flux = 2 },
      outputs = {}
    })

    assert.are.equal(6, inventory.get_qty(state.inventory, "ore"))
    assert.are.equal(8, inventory.get_qty(state.inventory, "flux"))
    assert.are.equal(0, inventory.get_qty(state.inventory, "ingot"))

    local instance = state.process_instances["P2"]
    assert.are.equal("aborted", instance.status)
    assert.are.equal(0, instance.committed_cost_total)
    assert.are.equal(4, instance.fees_total)
  end)
end)

describe("Deferred Process Write-Offs", function()
  local ledger
  local memory_store
  local reports
  local inventory

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/json.lua")
    dofile("src/scripts/core/inventory.lua")
    dofile("src/scripts/core/deferred_processes.lua")
    dofile("src/scripts/core/pattern_pools.lua")
    dofile("src/scripts/core/production_sources.lua")
    dofile("src/scripts/core/recovery.lua")
    dofile("src/scripts/core/ledger.lua")
    dofile("src/scripts/core/reports.lua")
    dofile("src/scripts/core/storage/memory_event_store.lua")

    ledger = _G.AchaeadexLedger.Core.Ledger
    reports = _G.AchaeadexLedger.Core.Reports
    inventory = _G.AchaeadexLedger.Core.Inventory
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
  end)

  local function find_write_off(events)
    for _, event in ipairs(events) do
      if event.event_type == "PROCESS_WRITE_OFF" then
        return event
      end
    end
    return nil
  end

  it("complete with no outputs writes off committed basis", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "ore", 10, 10)
    ledger.apply_process_start(state, "X1", "smelt", { ore = 5 }, 10)
    ledger.apply_process_complete(state, "X1", {})

    local write_off = find_write_off(store.events)
    assert.is_truthy(write_off)
    assert.are.equal("X1", write_off.payload.process_instance_id)
    assert.are.equal(60, write_off.payload.amount_gold)

    local report = reports.overall(state)
    assert.are.equal(60, report.holdings.process_losses)
    assert.are.equal(-60, report.totals.true_profit)
  end)

  it("complete with partial outputs writes off remainder", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "ore", 10, 10)
    ledger.apply_process_start(state, "X2", "smelt", { ore = 5 }, 0)
    ledger.apply_process_complete(state, "X2", { metal = 3 })

    local write_off = find_write_off(store.events)
    assert.is_truthy(write_off)
    assert.are.equal("X2", write_off.payload.process_instance_id)
    assert.are.equal(20, write_off.payload.amount_gold)

    local report = reports.overall(state)
    assert.are.equal(20, report.holdings.process_losses)
    assert.are.equal(-20, report.totals.true_profit)
  end)

  it("fee-only process assigns output basis and no write-off", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_process_start(state, "X3", "forage", {}, 700)
    ledger.apply_process_complete(state, "X3", { fibre = 528 })

    local unit_cost = inventory.get_unit_cost(state.inventory, "fibre")
    assert.is_true(unit_cost > 0)
    assert.are.equal(700 / 528, unit_cost)

    local write_off = find_write_off(store.events)
    assert.is_nil(write_off)

    local report = reports.overall(state)
    assert.are.equal(0, report.holdings.process_losses)
  end)
end)

describe("Deferred Process UX Defaults", function()
  local inventory
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

    inventory = _G.AchaeadexLedger.Core.Inventory
    ledger = _G.AchaeadexLedger.Core.Ledger
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
  end)

  it("completes without outputs", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "ore", 5, 3)
    ledger.apply_process_start(state, "P3", "smelt", { ore = 5 }, 0)

    ledger.apply_process_complete(state, "P3", nil)

    local instance = state.process_instances["P3"]
    assert.are.equal("completed", instance.status)
    assert.are.equal(0, inventory.get_qty(state.inventory, "ingot"))
  end)

  it("aborts without args defaults to lost all", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "ore", 5, 3)
    ledger.apply_process_start(state, "P4", "smelt", { ore = 5 }, 0)

    ledger.apply_process_abort(state, "P4", nil)

    local instance = state.process_instances["P4"]
    assert.are.equal("aborted", instance.status)
    assert.are.equal(0, instance.committed_cost_total)
    assert.are.equal(0, inventory.get_qty(state.inventory, "ore"))
  end)

  it("aborts with only returned computes lost", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "ore", 5, 3)
    ledger.apply_process_start(state, "P5", "smelt", { ore = 5 }, 0)

    ledger.apply_process_abort(state, "P5", { returned = { ore = 2 } })

    local instance = state.process_instances["P5"]
    assert.are.equal("aborted", instance.status)
    assert.are.equal(0, instance.committed_cost_total)
    assert.are.equal(2, inventory.get_qty(state.inventory, "ore"))
  end)
end)
