-- Busted tests for WAC inventory logic
-- Tests based on tests.instructions.md

describe("WAC Inventory", function()
  local inventory
  
  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/inventory.lua")
    inventory = _G.AchaeadexLedger.Core.Inventory
  end)
  
  describe("basic operations", function()
    it("should create empty inventory", function()
      local state = inventory.new()
      assert.is_not_nil(state)
      assert.are.equal(0, inventory.get_qty(state, "leather"))
    end)
    
    it("should add first commodity", function()
      local state = inventory.new()
      inventory.add(state, "leather", 10, 20)
      
      assert.are.equal(10, inventory.get_qty(state, "leather"))
      assert.are.equal(20, inventory.get_unit_cost(state, "leather"))
      assert.are.equal(200, inventory.get_total_cost(state, "leather"))
    end)
    
    it("should remove commodity", function()
      local state = inventory.new()
      inventory.add(state, "leather", 10, 20)
      
      local cost = inventory.remove(state, "leather", 5)
      
      assert.are.equal(100, cost) -- 5 * 20
      assert.are.equal(5, inventory.get_qty(state, "leather"))
      assert.are.equal(20, inventory.get_unit_cost(state, "leather"))
      assert.are.equal(100, inventory.get_total_cost(state, "leather"))
    end)
  end)
  
  describe("TEST 1 - WAC BLEND", function()
    it("should blend costs using weighted average", function()
      local state = inventory.new()
      
      -- OPENING leather 10 @ 20
      inventory.add(state, "leather", 10, 20)
      
      -- BUY leather 10 @ 40
      inventory.add(state, "leather", 10, 40)
      
      -- Expected WAC = 30
      local expected_wac = 30
      local actual_wac = inventory.get_unit_cost(state, "leather")
      
      assert.are.equal(20, inventory.get_qty(state, "leather"))
      assert.are.equal(expected_wac, actual_wac)
      assert.are.equal(600, inventory.get_total_cost(state, "leather"))
    end)
  end)
  
  describe("error handling", function()
    it("should error when removing non-existent commodity", function()
      local state = inventory.new()
      
      assert.has_error(function()
        inventory.remove(state, "leather", 5)
      end, "Cannot remove leather: not in inventory")
    end)
    
    it("should error when removing more than available", function()
      local state = inventory.new()
      inventory.add(state, "leather", 10, 20)
      
      assert.has_error(function()
        inventory.remove(state, "leather", 15)
      end)
    end)
    
    it("should error with invalid quantity", function()
      local state = inventory.new()
      
      assert.has_error(function()
        inventory.add(state, "leather", -5, 20)
      end)
      
      assert.has_error(function()
        inventory.add(state, "leather", 0, 20)
      end)
    end)
    
    it("should error with invalid unit cost", function()
      local state = inventory.new()
      
      assert.has_error(function()
        inventory.add(state, "leather", 10, -5)
      end)
    end)
  end)
  
  describe("multiple commodities", function()
    it("should handle multiple different commodities", function()
      local state = inventory.new()
      
      inventory.add(state, "leather", 10, 20)
      inventory.add(state, "cloth", 5, 15)
      inventory.add(state, "iron", 20, 8)
      
      assert.are.equal(10, inventory.get_qty(state, "leather"))
      assert.are.equal(5, inventory.get_qty(state, "cloth"))
      assert.are.equal(20, inventory.get_qty(state, "iron"))
      
      assert.are.equal(20, inventory.get_unit_cost(state, "leather"))
      assert.are.equal(15, inventory.get_unit_cost(state, "cloth"))
      assert.are.equal(8, inventory.get_unit_cost(state, "iron"))
    end)
    
    it("should track commodities independently", function()
      local state = inventory.new()
      
      inventory.add(state, "leather", 10, 20)
      inventory.add(state, "leather", 10, 40)
      inventory.add(state, "cloth", 10, 10)
      
      -- Leather should be blended to 30
      assert.are.equal(30, inventory.get_unit_cost(state, "leather"))
      
      -- Cloth should remain at 10
      assert.are.equal(10, inventory.get_unit_cost(state, "cloth"))
    end)
  end)
  
  describe("precision handling", function()
    it("should zero out inventory when fully consumed", function()
      local state = inventory.new()
      inventory.add(state, "leather", 10, 20)
      
      inventory.remove(state, "leather", 10)
      
      assert.are.equal(0, inventory.get_qty(state, "leather"))
      assert.are.equal(0, inventory.get_unit_cost(state, "leather"))
      assert.are.equal(0, inventory.get_total_cost(state, "leather"))
    end)
    
    it("should handle floating point precision issues", function()
      local state = inventory.new()
      inventory.add(state, "leather", 10, 20)
      
      -- Remove in small increments that might cause floating point issues
      for i = 1, 10 do
        inventory.remove(state, "leather", 1)
      end
      
      assert.are.equal(0, inventory.get_qty(state, "leather"))
      assert.are.equal(0, inventory.get_total_cost(state, "leather"))
    end)
  end)
  
  describe("get_all", function()
    it("should return all commodities with quantity > 0", function()
      local state = inventory.new()
      
      inventory.add(state, "leather", 10, 20)
      inventory.add(state, "cloth", 5, 15)
      inventory.add(state, "iron", 3, 8)
      
      local all = inventory.get_all(state)
      
      assert.is_not_nil(all.leather)
      assert.are.equal(10, all.leather.qty)
      assert.are.equal(20, all.leather.unit_cost)
      
      assert.is_not_nil(all.cloth)
      assert.are.equal(5, all.cloth.qty)
      
      assert.is_not_nil(all.iron)
      assert.are.equal(3, all.iron.qty)
    end)
    
    it("should not return commodities with qty = 0", function()
      local state = inventory.new()
      
      inventory.add(state, "leather", 10, 20)
      inventory.remove(state, "leather", 10)
      inventory.add(state, "cloth", 5, 15)
      
      local all = inventory.get_all(state)
      
      assert.is_nil(all.leather)
      assert.is_not_nil(all.cloth)
    end)
  end)
end)
