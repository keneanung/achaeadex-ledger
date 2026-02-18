-- Busted tests for design BOM and explicit materials crafting

describe("Crafting BOM and materials", function()
  local ledger
  local inventory
  local json
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
    inventory = _G.AchaeadexLedger.Core.Inventory
    json = _G.AchaeadexLedger.Core.Json
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
  end)

  it("TEST 15 - design BOM used when no materials provided", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "leather", 10, 20)
    ledger.apply_design_start(state, "D1", "shirt", "Design 1", "public", 0)
    ledger.apply_design_set_bom(state, "D1", { leather = 2 })

    ledger.apply_craft_item_auto(state, "I1", "D1", {
      time_cost_gold = 0,
      time_hours = 0
    })

    assert.are.equal(8, inventory.get_qty(state.inventory, "leather"))

    local item = state.crafted_items["I1"]
    local breakdown = json.decode(item.cost_breakdown_json)
    assert.are.equal(40, breakdown.materials_cost_gold)
    assert.are.equal("design_bom", breakdown.materials_source)
    assert.are.equal(40, item.operational_cost_gold)
  end)

  it("TEST 16 - explicit materials override design BOM", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "leather", 10, 20)
    ledger.apply_opening_inventory(state, "cloth", 10, 5)
    ledger.apply_design_start(state, "D1", "shirt", "Design 1", "public", 0)
    ledger.apply_design_set_bom(state, "D1", { leather = 2 })

    ledger.apply_craft_item_auto(state, "I2", "D1", {
      materials = { cloth = 3 },
      time_cost_gold = 0,
      time_hours = 0
    })

    assert.are.equal(10, inventory.get_qty(state.inventory, "leather"))
    assert.are.equal(7, inventory.get_qty(state.inventory, "cloth"))

    local item = state.crafted_items["I2"]
    local breakdown = json.decode(item.cost_breakdown_json)
    assert.are.equal(15, breakdown.materials_cost_gold)
    assert.are.equal("explicit", breakdown.materials_source)
  end)

  it("TEST 17 - unknown design creates stub with BOM", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "cloth", 10, 5)

    ledger.apply_craft_item_auto(state, "I3", "D-UNKNOWN", {
      materials = { cloth = 2 },
      time_cost_gold = 0,
      time_hours = 0
    })

    local design = state.designs["D-UNKNOWN"]
    assert.is_not_nil(design)
    assert.are.equal(0, design.recovery_enabled)
    assert.are.equal("unknown", design.design_type)
    assert.are.same({ cloth = 2 }, design.bom)

    assert.are.equal(8, inventory.get_qty(state.inventory, "cloth"))
    assert.are.equal("D-UNKNOWN", state.crafted_items["I3"].design_id)
  end)

  it("TEST 18 - enrich stub design later", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "cloth", 10, 5)
    ledger.apply_opening_inventory(state, "leather", 10, 20)
    ledger.apply_pattern_activate(state, "P1", "shirt", "Pool", 150)

    ledger.apply_craft_item_auto(state, "I3", "D-UNKNOWN", {
      materials = { cloth = 2 },
      time_cost_gold = 0,
      time_hours = 0
    })

    ledger.apply_design_update(state, "D-UNKNOWN", {
      design_type = "shirt",
      name = "Updated",
      provenance = "private",
      recovery_enabled = 1
    })
    ledger.apply_design_set_bom(state, "D-UNKNOWN", { leather = 2 })

    ledger.apply_craft_item_auto(state, "I4", "D-UNKNOWN", {
      time_cost_gold = 0,
      time_hours = 0
    })

    assert.are.equal(8, inventory.get_qty(state.inventory, "leather"))
    assert.are.equal(8, inventory.get_qty(state.inventory, "cloth"))

    local design = state.designs["D-UNKNOWN"]
    assert.are.equal("shirt", design.design_type)
    assert.are.equal("Updated", design.name)
    assert.are.equal("private", design.provenance)
    assert.are.equal(1, design.recovery_enabled)
  end)
end)
