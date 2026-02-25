-- Busted tests for UX helpers (ID generation + listings)

describe("UX helpers", function()
  local id_generator
  local listings
  local ledger
  local inventory
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
    dofile("src/scripts/core/id_generator.lua")
    dofile("src/scripts/core/listings.lua")
    dofile("src/scripts/core/storage/memory_event_store.lua")

    id_generator = _G.AchaeadexLedger.Core.IdGenerator
    listings = _G.AchaeadexLedger.Core.Listings
    ledger = _G.AchaeadexLedger.Core.Ledger
    inventory = _G.AchaeadexLedger.Core.Inventory
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
    json = _G.AchaeadexLedger.Core.Json
  end)

  it("generates unique ids with expected prefix", function()
    local date_part = os.date("!%Y%m%d")
    local id1 = id_generator.generate("D")
    local id2 = id_generator.generate("D")

    assert.is_not_nil(string.match(id1, "^D%-%d%d%d%d%d%d%d%d%-%w+$"))
    assert.is_not_nil(string.match(id2, "^D%-%d%d%d%d%d%d%d%d%-%w+$"))
    assert.is_true(id1 ~= id2)
    assert.is_true(string.find(id1, date_part, 1, true) ~= nil)
  end)

  it("lists entities with filters", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "leather", 10, 20)
    ledger.apply_opening_inventory(state, "coal", 1, 20)
    ledger.apply_pattern_activate(state, "P1", "shirt", "Pool", 150)
    ledger.apply_design_start(state, "D1", "shirt", "Design", "private", 1)
    ledger.apply_source_create(state, "SK-FORGE", "skill", "forging", "Forging")
    ledger.apply_forge_fire(state, "F1", "SK-FORGE", {})

    local breakdown = json.encode({ base_cost = 40, per_item_fee = 0 })
    ledger.apply_craft_item(state, "I1", "D1", 40, breakdown, "simple shirt")
    ledger.apply_sell_item(state, "S1", "I1", 100, { year = 650 })

    ledger.apply_order_create(state, "O1", "Customer", "Note")
    ledger.apply_order_add_sale(state, "O1", "S1")

    ledger.apply_process_start(state, "X1", "refine", {})

    local commodities = listings.list_commodities(state, { name = "lea" })
    assert.are.equal(1, #commodities)
    assert.are.equal("leather", commodities[1].name)

    local designs = listings.list_designs(state, { type = "shirt", provenance = "private" })
    assert.are.equal(1, #designs)
    assert.are.equal("D1", designs[1].design_id)

    local sources = listings.list_sources(state, { kind = "skill" })
    assert.are.equal(1, #sources)
    assert.are.equal("SK-FORGE", sources[1].source_id)

    local items = listings.list_items(state, { sold = true })
    assert.are.equal(1, #items)
    assert.are.equal("I1", items[1].item_id)

    local sales = listings.list_sales(state, { year = 650 })
    assert.are.equal(1, #sales)
    assert.are.equal("S1", sales[1].sale_id)

    local orders = listings.list_orders(state)
    assert.are.equal(1, #orders)
    assert.are.equal(1, orders[1].total_sales_count)

    local processes = listings.list_processes(state, { status = "in_flight" })
    assert.are.equal(1, #processes)
    assert.are.equal("X1", processes[1].process_instance_id)

    local forge_sessions = listings.list_forge_sessions(state, { status = "in_flight" })
    assert.are.equal(1, #forge_sessions)
    assert.are.equal("F1", forge_sessions[1].forge_session_id)
    assert.are.equal("SK-FORGE", forge_sessions[1].source_id)
  end)
end)
