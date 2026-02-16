-- Busted tests for ledger module including process logic
-- Tests based on tests.instructions.md

describe("Ledger Core", function()
  local ledger
  local inventory
  local memory_store
  
  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/inventory.lua")
    dofile("src/scripts/core/deferred_processes.lua")
    dofile("src/scripts/core/pattern_pools.lua")
    dofile("src/scripts/core/designs.lua")
    dofile("src/scripts/core/recovery.lua")
    dofile("src/scripts/core/ledger.lua")
    dofile("src/scripts/core/storage/memory_event_store.lua")
    
    ledger = _G.AchaeadexLedger.Core.Ledger
    inventory = _G.AchaeadexLedger.Core.Inventory
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
  end)
  
  describe("initialization", function()
    it("should create new ledger with database", function()
      local store = memory_store.new()
      local state = ledger.new(store)
      
      assert.is_not_nil(state)
      assert.is_not_nil(state.event_store)
      assert.is_not_nil(state.inventory)
      assert.are.same({}, state.designs)
      assert.are.same({}, state.pattern_pools)
    end)
  end)
  
  describe("event recording", function()
    it("should record events to database", function()
      local store = memory_store.new()
      local state = ledger.new(store)
      
      ledger.record_event(state, "TEST_EVENT", {foo = "bar", num = 123})
      
      local events = store:read_all()
      assert.are.equal(1, #events)
      assert.are.equal("TEST_EVENT", events[1].event_type)
      assert.are.equal("bar", events[1].payload.foo)
      assert.are.equal(123, events[1].payload.num)
    end)
  end)
  
  describe("OPENING_INVENTORY", function()
    it("should add opening inventory", function()
      local store = memory_store.new()
      local state = ledger.new(store)
      
      ledger.apply_opening_inventory(state, "leather", 10, 20)
      
      assert.are.equal(10, inventory.get_qty(state.inventory, "leather"))
      assert.are.equal(20, inventory.get_unit_cost(state.inventory, "leather"))
    end)
  end)
  
  describe("BROKER_BUY", function()
    it("should add purchased inventory", function()
      local store = memory_store.new()
      local state = ledger.new(store)
      
      ledger.apply_broker_buy(state, "leather", 5, 30)
      
      assert.are.equal(5, inventory.get_qty(state.inventory, "leather"))
      assert.are.equal(30, inventory.get_unit_cost(state.inventory, "leather"))
    end)
    
    it("should blend with existing inventory", function()
      local store = memory_store.new()
      local state = ledger.new(store)
      
      ledger.apply_opening_inventory(state, "leather", 10, 20)
      ledger.apply_broker_buy(state, "leather", 10, 40)
      
      assert.are.equal(20, inventory.get_qty(state.inventory, "leather"))
      assert.are.equal(30, inventory.get_unit_cost(state.inventory, "leather"))
    end)
  end)
  
  describe("BROKER_SELL", function()
    it("should remove inventory and calculate profit", function()
      local store = memory_store.new()
      local state = ledger.new(store)
      
      ledger.apply_opening_inventory(state, "leather", 10, 20)
      local _, profit = ledger.apply_broker_sell(state, "leather", 5, 35)
      
      -- Sold 5 @ 35 = 175 revenue
      -- Cost 5 @ 20 = 100
      -- Profit = 75
      assert.are.equal(75, profit)
      assert.are.equal(5, inventory.get_qty(state.inventory, "leather"))
    end)
  end)
  
  describe("TEST 2 - GENERIC PROCESS_APPLY", function()
    it("should consume inputs and produce outputs with correct costing", function()
      local store = memory_store.new()
      local state = ledger.new(store)
      
      -- OPENING fibre 10 @ 5
      ledger.apply_opening_inventory(state, "fibre", 10, 5)
      
      -- OPENING coal 10 @ 2
      ledger.apply_opening_inventory(state, "coal", 10, 2)
      
      -- PROCESS_APPLY: inputs: fibre=4, coal=4; outputs: cloth=4; gold_fee=0
      ledger.apply_process(state, "refine", 
        {fibre = 4, coal = 4},
        {cloth = 4},
        0)
      
      -- Expected: fibre=6, coal=6, cloth=4
      assert.are.equal(6, inventory.get_qty(state.inventory, "fibre"))
      assert.are.equal(6, inventory.get_qty(state.inventory, "coal"))
      assert.are.equal(4, inventory.get_qty(state.inventory, "cloth"))
      
      -- Cloth unit cost should reflect consumed input WAC
      -- fibre cost: 4 * 5 = 20
      -- coal cost: 4 * 2 = 8
      -- total input cost = 28
      -- output unit cost = 28 / 4 = 7
      assert.are.equal(7, inventory.get_unit_cost(state.inventory, "cloth"))
    end)
    
    it("should include gold fee in output cost", function()
      local store = memory_store.new()
      local state = ledger.new(store)
      
      ledger.apply_opening_inventory(state, "ore", 10, 10)
      
      -- Process with gold fee
      ledger.apply_process(state, "smelt",
        {ore = 5},
        {ingot = 5},
        20) -- gold fee
      
      -- Total cost = (5 * 10) + 20 = 70
      -- Unit cost = 70 / 5 = 14
      assert.are.equal(5, inventory.get_qty(state.inventory, "ingot"))
      assert.are.equal(14, inventory.get_unit_cost(state.inventory, "ingot"))
    end)
    
    it("should handle multiple outputs", function()
      local store = memory_store.new()
      local state = ledger.new(store)
      
      ledger.apply_opening_inventory(state, "wood", 10, 5)
      
      -- Process producing multiple outputs
      ledger.apply_process(state, "saw",
        {wood = 4},
        {plank = 6, sawdust = 2},
        0)
      
      -- Total input cost = 4 * 5 = 20
      -- Total output qty = 6 + 2 = 8
      -- Unit cost = 20 / 8 = 2.5
      assert.are.equal(6, inventory.get_qty(state.inventory, "plank"))
      assert.are.equal(2, inventory.get_qty(state.inventory, "sawdust"))
      assert.are.equal(2.5, inventory.get_unit_cost(state.inventory, "plank"))
      assert.are.equal(2.5, inventory.get_unit_cost(state.inventory, "sawdust"))
    end)
    
    it("should handle catalyst (multiple inputs)", function()
      local store = memory_store.new()
      local state = ledger.new(store)
      
      ledger.apply_opening_inventory(state, "ore", 10, 8)
      ledger.apply_opening_inventory(state, "flux", 10, 2)
      
      -- Smelting with flux as catalyst
      ledger.apply_process(state, "smelt",
        {ore = 3, flux = 1},
        {metal = 3},
        0)
      
      -- Total input cost = (3 * 8) + (1 * 2) = 26
      -- Unit cost = 26 / 3 = 8.666...
      local expected_unit_cost = 26 / 3
      local actual_unit_cost = inventory.get_unit_cost(state.inventory, "metal")
      
      assert.are.equal(3, inventory.get_qty(state.inventory, "metal"))
      assert.is.near(expected_unit_cost, actual_unit_cost, 0.01)
    end)
  end)
  
  describe("DESIGN_START", function()
    it("should create private design with default recovery enabled", function()
      local store = memory_store.new()
      local state = ledger.new(store)

      ledger.apply_pattern_activate(state, "P1", "shirt", "Test Shirts", 150)
      
      ledger.apply_design_start(state, "D1", "shirt", "Simple Black Shirt", "private", nil)
      
      assert.is_not_nil(state.designs["D1"])
      assert.are.equal("shirt", state.designs["D1"].design_type)
      assert.are.equal("Simple Black Shirt", state.designs["D1"].name)
      assert.are.equal("private", state.designs["D1"].provenance)
      assert.are.equal(1, state.designs["D1"].recovery_enabled)
      assert.are.equal(0, state.designs["D1"].capital_remaining)
    end)
    
    it("should create public design with default recovery disabled", function()
      local store = memory_store.new()
      local state = ledger.new(store)
      
      ledger.apply_design_start(state, "D2", "boots", "Plain Boots", "public", nil)
      
      assert.is_not_nil(state.designs["D2"])
      assert.are.equal("public", state.designs["D2"].provenance)
      assert.are.equal(0, state.designs["D2"].recovery_enabled)
    end)
    
    it("should allow explicit recovery_enabled override", function()
      local store = memory_store.new()
      local state = ledger.new(store)

      ledger.apply_pattern_activate(state, "P1", "shirt", "Test Shirts", 150)
      
      -- Public design with recovery enabled (unusual but allowed)
      ledger.apply_design_start(state, "D3", "shirt", "Special Org Shirt", "organization", 1)
      
      assert.are.equal("organization", state.designs["D3"].provenance)
      assert.are.equal(1, state.designs["D3"].recovery_enabled)
    end)
  end)
  
  describe("DESIGN_COST", function()
    it("should track capital for designs with recovery enabled", function()
      local store = memory_store.new()
      local state = ledger.new(store)

      ledger.apply_pattern_activate(state, "P1", "shirt", "Test Shirts", 150)
      
      ledger.apply_design_start(state, "D1", "shirt", "Test Shirt", "private", 1)
      ledger.apply_design_cost(state, "D1", 5000, "submission")
      ledger.apply_design_cost(state, "D1", 1000, "resubmission")
      
      assert.are.equal(6000, state.designs["D1"].capital_remaining)
    end)
    
    it("should not track capital for public designs", function()
      local store = memory_store.new()
      local state = ledger.new(store)
      
      ledger.apply_design_start(state, "D2", "boots", "Public Boots", "public", 0)
      ledger.apply_design_cost(state, "D2", 5000, "submission")
      
      -- Since recovery is disabled, capital should not accumulate
      assert.are.equal(0, state.designs["D2"].capital_remaining)
    end)
  end)
  
  describe("DESIGN_SET_PER_ITEM_FEE", function()
    it("should set per-item production fee", function()
      local store = memory_store.new()
      local state = ledger.new(store)

      ledger.apply_pattern_activate(state, "P1", "jewellery", "Test Jewellery", 150)
      
      ledger.apply_design_start(state, "D1", "jewellery", "Fancy Ring", "private", 1)
      ledger.apply_design_set_fee(state, "D1", 15)
      
      assert.are.equal(15, state.designs["D1"].per_item_fee_gold)
    end)
  end)
  
  describe("PATTERN_ACTIVATE", function()
    it("should create active pattern pool", function()
      local store = memory_store.new()
      local state = ledger.new(store)
      
      ledger.apply_pattern_activate(state, "P1", "shirt", "Stylish Shirts", 150)
      
      assert.is_not_nil(state.pattern_pools["P1"])
      assert.are.equal("shirt", state.pattern_pools["P1"].pattern_type)
      assert.are.equal(150, state.pattern_pools["P1"].capital_initial_gold)
      assert.are.equal(150, state.pattern_pools["P1"].capital_remaining_gold)
      assert.are.equal("active", state.pattern_pools["P1"].status)
    end)
  end)
end)
