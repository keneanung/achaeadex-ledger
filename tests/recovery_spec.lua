-- Busted tests for recovery waterfall and pattern pools

describe("Recovery", function()
  local sources
  local pattern_pools
  local recovery

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/pattern_pools.lua")
    dofile("src/scripts/core/production_sources.lua")
    dofile("src/scripts/core/recovery.lua")

    sources = _G.AchaeadexLedger.Core.ProductionSources
    pattern_pools = _G.AchaeadexLedger.Core.PatternPools
    recovery = _G.AchaeadexLedger.Core.Recovery
  end)

  it("applies strict waterfall (design then pattern)", function()
    local result = recovery.apply_waterfall(160, 6000, 150, 1)

    assert.are.equal(160, result.operational_profit)
    assert.are.equal(160, result.applied_to_design_capital)
    assert.are.equal(0, result.applied_to_pattern_capital)
    assert.are.equal(0, result.true_profit)
    assert.are.equal(5840, result.design_remaining)
    assert.are.equal(150, result.pattern_remaining)
  end)

  it("recovers pattern after design is cleared", function()
    local result = recovery.apply_waterfall(100, 50, 150, 1)

    assert.are.equal(50, result.applied_to_design_capital)
    assert.are.equal(50, result.applied_to_pattern_capital)
    assert.are.equal(0, result.true_profit)
    assert.are.equal(0, result.design_remaining)
    assert.are.equal(100, result.pattern_remaining)
  end)

  it("produces true profit after capitals recovered", function()
    local result = recovery.apply_waterfall(100, 0, 20, 1)

    assert.are.equal(0, result.applied_to_design_capital)
    assert.are.equal(20, result.applied_to_pattern_capital)
    assert.are.equal(80, result.true_profit)
    assert.are.equal(0, result.design_remaining)
    assert.are.equal(0, result.pattern_remaining)
  end)

  it("shares a pattern pool across designs", function()
    local state = { production_sources = {}, pattern_pools = {}, pattern_pools_by_type = {} }
    pattern_pools.activate(state, "P1", "shirt", "Pool", 150, "2026-02-14T00:00:00Z")

    local d1 = sources.create_design(state, "D1", "shirt", "Design 1", "private", 1)
    local d2 = sources.create_design(state, "D2", "shirt", "Design 2", "private", 1)

    d1.capital_remaining = 0
    d2.capital_remaining = 0

    local r1 = recovery.apply_to_state(state, "D1", 60)
    local r2 = recovery.apply_to_state(state, "D2", 100)

    assert.are.equal(60, r1.applied_to_pattern_capital)
    assert.are.equal(90, r2.applied_to_pattern_capital)
    assert.are.equal(10, r2.true_profit)
    assert.are.equal(0, state.pattern_pools["P1"].capital_remaining_gold)
  end)

  it("does not recover for public designs by default", function()
    local state = { production_sources = {}, pattern_pools = {}, pattern_pools_by_type = {} }
    local design = sources.create_design(state, "Dpub", "boots", "Public", "public", nil)
    design.capital_remaining = 5000

    local result = recovery.apply_to_state(state, "Dpub", 100)

    assert.are.equal(0, result.applied_to_design_capital)
    assert.are.equal(0, result.applied_to_pattern_capital)
    assert.are.equal(100, result.true_profit)
    assert.are.equal(5000, design.capital_remaining)
  end)
end)
