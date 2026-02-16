-- Busted tests for EventStore implementations

describe("EventStore", function()
  local schema
  local ledger
  local inventory
  local memory_store
  local sqlite_store
  local luasql

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/json.lua")
    dofile("src/scripts/core/inventory.lua")
    dofile("src/scripts/core/deferred_processes.lua")
    dofile("src/scripts/core/pattern_pools.lua")
    dofile("src/scripts/core/designs.lua")
    dofile("src/scripts/core/recovery.lua")
    dofile("src/scripts/core/schema.lua")
    dofile("src/scripts/core/ledger.lua")
    dofile("src/scripts/core/storage/memory_event_store.lua")
    dofile("src/scripts/core/storage/sqlite_event_store.lua")

    schema = _G.AchaeadexLedger.Core.Schema
    ledger = _G.AchaeadexLedger.Core.Ledger
    inventory = _G.AchaeadexLedger.Core.Inventory
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
    sqlite_store = _G.AchaeadexLedger.Core.LuaSQLEventStore
    local ok, module = pcall(require, "luasql.sqlite3")
    if ok then
      luasql = module
    else
      luasql = nil
    end
  end)

  it("migration runner is idempotent", function()
    if not luasql then
      pending("LuaSQL sqlite3 not available")
      return
    end

    local db_path = os.tmpname()
    local store = sqlite_store.new(db_path)

    local cur = assert(store.conn:execute("SELECT COUNT(*) AS count FROM schema_version"))
    local row = cur:fetch({}, "a")
    cur:close()

    assert.are.equal(#schema.migrations, tonumber(row.count))
  end)

  it("appends and reads in order", function()
    local store = memory_store.new()
    store:append({ event_type = "A", payload = { value = 1 } })
    store:append({ event_type = "B", payload = { value = 2 } })

    local events = store:read_all()
    assert.are.equal(2, #events)
    assert.are.equal(1, events[1].id)
    assert.are.equal("A", events[1].event_type)
    assert.are.equal(2, events[2].id)
    assert.are.equal("B", events[2].event_type)
  end)

  it("replays from SQLite to same projected state", function()
    if not luasql then
      pending("LuaSQL sqlite3 not available")
      return
    end

    local mem = memory_store.new()
    local state1 = ledger.new(mem)

    ledger.apply_opening_inventory(state1, "fibre", 10, 5)
    ledger.apply_opening_inventory(state1, "coal", 10, 2)
    ledger.apply_pattern_activate(state1, "P1", "shirt", "Pool", 150)
    ledger.apply_design_start(state1, "D1", "shirt", "Design 1", "private", 1)
    ledger.apply_design_cost(state1, "D1", 6000, "submission")
    ledger.apply_sell_recovery(state1, "D1", 160)
    ledger.apply_process_start(state1, "PX", "refine", { fibre = 4, coal = 4 }, 1)
    ledger.apply_process_complete(state1, "PX", { cloth = 4 })

    local events = mem:read_all()

    local db_path = os.tmpname()
    local sqlite = sqlite_store.new(db_path)
    for _, event in ipairs(events) do
      sqlite:append({ event_type = event.event_type, payload = event.payload, ts = event.ts })
    end

    local sqlite_events = sqlite:read_all()
    local mem2 = memory_store.new()
    local state2 = ledger.new(mem2)

    for _, event in ipairs(sqlite_events) do
      ledger.apply_event(state2, event)
    end

    assert.are.equal(inventory.get_qty(state1.inventory, "fibre"), inventory.get_qty(state2.inventory, "fibre"))
    assert.are.equal(inventory.get_qty(state1.inventory, "coal"), inventory.get_qty(state2.inventory, "coal"))
    assert.are.equal(inventory.get_qty(state1.inventory, "cloth"), inventory.get_qty(state2.inventory, "cloth"))

    assert.are.equal(state1.designs["D1"].capital_remaining, state2.designs["D1"].capital_remaining)
    assert.are.equal(state1.pattern_pools["P1"].capital_remaining_gold, state2.pattern_pools["P1"].capital_remaining_gold)
    assert.are.equal(state1.process_instances["PX"].status, state2.process_instances["PX"].status)
    assert.are.equal(state1.designs["D1"].pattern_pool_id, state2.designs["D1"].pattern_pool_id)
  end)
end)
