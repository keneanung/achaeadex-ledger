-- Busted tests for simulator

describe("Simulator", function()
  local simulator

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/simulator.lua")
    simulator = _G.AchaeadexLedger.Core.Simulator
  end)

  it("computes units_needed and price_needed in strict mode", function()
    local op_cost = 50
    local design_remaining = 6000
    local pattern_remaining = 150
    local price = 200

    local units = simulator.units_needed(op_cost, design_remaining, pattern_remaining, price, 1)
    assert.are.equal(41, units)

    local price_needed = simulator.price_needed(op_cost, design_remaining, pattern_remaining, units, 1)
    assert.are.equal(200, price_needed)
  end)

  it("errors when price <= op_cost", function()
    assert.has_error(function()
      simulator.units_needed(50, 10, 0, 50, 1)
    end)
  end)

  it("errors when units <= 0", function()
    assert.has_error(function()
      simulator.price_needed(50, 10, 0, 0, 1)
    end)
  end)
end)
