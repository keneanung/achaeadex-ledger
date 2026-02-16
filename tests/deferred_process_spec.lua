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
