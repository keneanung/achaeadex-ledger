-- Busted tests for pattern pools

describe("Pattern Pools", function()
  local pattern_pools

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/pattern_pools.lua")
    pattern_pools = _G.AchaeadexLedger.Core.PatternPools
  end)

  it("enforces one active pool per type", function()
    local state = { pattern_pools = {}, pattern_pools_by_type = {} }
    pattern_pools.activate(state, "P1", "shirt", "Pool 1", 100, "2026-02-14T00:00:00Z")

    assert.has_error(function()
      pattern_pools.activate(state, "P2", "shirt", "Pool 2", 100, "2026-02-14T00:00:00Z")
    end)
  end)

  it("allows activation after deactivation", function()
    local state = { pattern_pools = {}, pattern_pools_by_type = {} }
    pattern_pools.activate(state, "P1", "shirt", "Pool 1", 100, "2026-02-14T00:00:00Z")
    pattern_pools.deactivate(state, "P1", "2026-02-14T01:00:00Z")

    local pool = pattern_pools.activate(state, "P2", "shirt", "Pool 2", 200, "2026-02-14T02:00:00Z")
    assert.are.equal("P2", pool.pattern_pool_id)
    assert.are.equal("active", pool.status)
  end)
end)
