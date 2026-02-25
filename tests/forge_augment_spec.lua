-- Busted tests for forge sessions and augmentation workflows

describe("Forge and augment workflows", function()
  local ledger
  local reports
  local inventory
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
    dofile("src/scripts/core/reports.lua")
    dofile("src/scripts/core/storage/memory_event_store.lua")

    ledger = _G.AchaeadexLedger.Core.Ledger
    reports = _G.AchaeadexLedger.Core.Reports
    inventory = _G.AchaeadexLedger.Core.Inventory
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
  end)

  it("forge fire -> craft -> attach -> close allocates coal deterministically", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "coal", 1, 20)
    ledger.apply_opening_inventory(state, "metal", 10, 50)
    ledger.apply_source_create(state, "SK-FORGE", "skill", "forging", "Forging")

    ledger.apply_forge_fire(state, "F1", "SK-FORGE", {})

    ledger.apply_source_craft_auto(state, "I1", "SK-FORGE", "skill", {
      source_type = "forging",
      materials = { metal = 4 }
    })
    ledger.apply_source_craft_auto(state, "I2", "SK-FORGE", "skill", {
      source_type = "forging",
      materials = { metal = 2 }
    })

    ledger.apply_forge_attach(state, "F1", "I1")
    ledger.apply_forge_attach(state, "F1", "I2")
    ledger.apply_forge_close(state, "F1", "cost_weighted")

    assert.are.equal(4, inventory.get_qty(state.inventory, "metal"))
    assert.are.equal(0, inventory.get_qty(state.inventory, "coal"))

    assert.are.equal(213, state.crafted_items["I1"].operational_cost_gold)
    assert.are.equal(107, state.crafted_items["I2"].operational_cost_gold)
    assert.are.equal(13, state.crafted_items["I1"].forge_allocated_coal_gold)
    assert.are.equal(7, state.crafted_items["I2"].forge_allocated_coal_gold)

    assert.are.equal("closed", state.forge_sessions["F1"].status)
    assert.are.equal(20, state.forge_sessions["F1"].allocated_total_gold)
  end)

  it("forge expire with no attached items creates write-off visible in overall report", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "coal", 1, 20)
    ledger.apply_source_create(state, "SK-FORGE", "skill", "forging", "Forging")

    ledger.apply_forge_fire(state, "F2", "SK-FORGE", {})
    ledger.apply_forge_expire(state, "F2", "timed out")

    local report = reports.overall(state, { time_cost_per_hour = 0 })
    assert.are.equal(20, report.totals.process_losses)
    assert.are.equal("expired", state.forge_sessions["F2"].status)
  end)

  it("augmentation creates new item basis and marks old item transformed", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "leather", 10, 20)
    ledger.apply_opening_inventory(state, "gem", 1, 100)

    ledger.apply_design_start(state, "D1", "shirt", "Base Shirt", "public", 0)
    ledger.apply_source_craft_auto(state, "I-BASE", "D1", "design", {
      materials = { leather = 2 }
    })

    ledger.apply_source_create(state, "SK-AUG", "skill", "augmentation", "Augmentation")
    ledger.apply_augment_item(state, "I-AUG", "SK-AUG", "I-BASE", {
      materials = { gem = 1 },
      fee_gold = 25
    })

    assert.are.equal(1, state.crafted_items["I-BASE"].transformed)
    assert.are.equal("I-BASE", state.crafted_items["I-AUG"].parent_item_id)
    assert.are.equal(165, state.crafted_items["I-AUG"].operational_cost_gold)
    assert.are.equal("I-BASE", state.item_transformations["I-AUG"].old_item_id)
  end)

  it("augmentation uses source BOM when explicit materials are omitted", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "leather", 10, 20)
    ledger.apply_opening_inventory(state, "gem", 2, 100)

    ledger.apply_design_start(state, "D1", "shirt", "Base Shirt", "public", 0)
    ledger.apply_source_craft_auto(state, "I-BASE2", "D1", "design", {
      materials = { leather = 2 }
    })

    ledger.apply_source_create(state, "SK-AUG", "skill", "augmentation", "Augmentation")
    ledger.apply_design_set_bom(state, "SK-AUG", { gem = 1 })

    ledger.apply_augment_item(state, "I-AUG2", "SK-AUG", "I-BASE2", {
      fee_gold = 25
    })

    assert.are.equal(1, inventory.get_qty(state.inventory, "gem"))
    assert.are.equal(165, state.crafted_items["I-AUG2"].operational_cost_gold)
    assert.are.equal("I-BASE2", state.crafted_items["I-AUG2"].parent_item_id)
  end)
end)
