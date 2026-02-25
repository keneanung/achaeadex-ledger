-- Busted tests for external items and augmentation carry-forward

describe("External items", function()
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

  it("registers external item with explicit basis", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_item_add_external(state, "E1", "a found ring", 1200, "gift", "from raid")

    local item = state.external_items["E1"]
    assert.is_not_nil(item)
    assert.are.equal("a found ring", item.name)
    assert.are.equal(1200, item.basis_gold)
    assert.are.equal("gift", item.basis_source)
    assert.are.equal("active", item.status)
  end)

  it("augmentation carries external basis forward and transforms target", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "gem", 1, 100)
    ledger.apply_source_create(state, "SK-AUG", "skill", "augmentation", "Augmentation")
    ledger.apply_item_add_external(state, "E2", "an old blade", 1000, "purchase")

    ledger.apply_augment_item(state, "I-AUG-E2", "SK-AUG", "E2", {
      materials = { gem = 1 },
      fee_gold = 25,
      time_cost_gold = 0
    })

    assert.are.equal(0, inventory.get_qty(state.inventory, "gem"))
    assert.are.equal("transformed", state.external_items["E2"].status)
    assert.are.equal(1125, state.crafted_items["I-AUG-E2"].operational_cost_gold)
    assert.are.equal("E2", state.crafted_items["I-AUG-E2"].parent_item_id)
  end)

  it("overall holdings include active external items and warn for mtm/unknown", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_item_add_external(state, "E3", "an old helm", 500, "mtm")
    ledger.apply_item_add_external(state, "E4", "mysterious charm", 300, "unknown")

    local report = reports.overall(state, { time_cost_per_hour = 0 })
    assert.are.equal(800, report.holdings.external_items_holdings)

    local has_mtm = false
    local has_unknown = false
    for _, warning in ipairs(report.warnings) do
      if warning == "WARNING: External items with basis_source=mtm" then
        has_mtm = true
      elseif warning == "WARNING: External items with basis_source=unknown" then
        has_unknown = true
      end
    end
    assert.is_true(has_mtm)
    assert.is_true(has_unknown)
  end)

  it("overall holdings exclude transformed external items", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "gem", 1, 100)
    ledger.apply_source_create(state, "SK-AUG", "skill", "augmentation", "Augmentation")
    ledger.apply_item_add_external(state, "E6", "old trinket", 300, "purchase")

    local before = reports.overall(state, { time_cost_per_hour = 0 })
    assert.are.equal(300, before.holdings.external_items_holdings)

    ledger.apply_augment_item(state, "I-AUG-E6", "SK-AUG", "E6", {
      materials = { gem = 1 },
      fee_gold = 0,
      time_cost_gold = 0
    })

    local after = reports.overall(state, { time_cost_per_hour = 0 })
    assert.is_nil(after.holdings.external_items_holdings)
  end)

  it("report item works for external items", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_item_add_external(state, "E5", "gifted pendant", 777, "gift")

    local report = ledger.report_item(state, "E5")
    assert.are.equal("external", report.source_kind)
    assert.are.equal("gifted pendant", report.external_name)
    assert.are.equal("gift", report.external_basis_source)
    assert.are.equal(777, report.unsold_cost_basis)
  end)
end)
