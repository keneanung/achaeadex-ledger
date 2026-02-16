-- Recovery logic for Achaeadex Ledger
-- Applies strict waterfall: design -> pattern -> true profit

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local recovery = _G.AchaeadexLedger.Core.Recovery or {}

local function get_designs()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.Designs then
    error("AchaeadexLedger.Core.Designs is not loaded")
  end

  return _G.AchaeadexLedger.Core.Designs
end

local function get_pattern_pools()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.PatternPools then
    error("AchaeadexLedger.Core.PatternPools is not loaded")
  end

  return _G.AchaeadexLedger.Core.PatternPools
end

function recovery.apply_waterfall(op_profit, design_remaining, pattern_remaining, recovery_enabled)
  assert(type(op_profit) == "number", "op_profit must be a number")
  assert(type(design_remaining) == "number", "design_remaining must be a number")
  assert(type(pattern_remaining) == "number", "pattern_remaining must be a number")

  local result = {
    operational_profit = op_profit,
    applied_to_design_capital = 0,
    applied_to_pattern_capital = 0,
    true_profit = op_profit,
    design_remaining = design_remaining,
    pattern_remaining = pattern_remaining
  }

  if recovery_enabled ~= 1 then
    return result
  end

  if op_profit <= 0 then
    return result
  end

  local apply_design = math.min(op_profit, design_remaining)
  op_profit = op_profit - apply_design
  result.applied_to_design_capital = apply_design
  result.design_remaining = design_remaining - apply_design

  if op_profit > 0 then
    local apply_pattern = math.min(op_profit, pattern_remaining)
    op_profit = op_profit - apply_pattern
    result.applied_to_pattern_capital = apply_pattern
    result.pattern_remaining = pattern_remaining - apply_pattern
  end

  result.true_profit = op_profit

  return result
end

function recovery.apply_to_state(state, design_id, op_profit)
  local designs = get_designs()
  local pattern_pools = get_pattern_pools()

  if not state.designs or not state.designs[design_id] then
    error("Design " .. design_id .. " not found")
  end

  local design = state.designs[design_id]
  local pattern_remaining = 0
  if design.pattern_pool_id then
    local pool = state.pattern_pools and state.pattern_pools[design.pattern_pool_id]
    if pool then
      pattern_remaining = pool.capital_remaining_gold or 0
    end
  end

  local result = recovery.apply_waterfall(
    op_profit,
    design.capital_remaining or 0,
    pattern_remaining,
    design.recovery_enabled
  )

  if design.recovery_enabled == 1 and op_profit > 0 then
    if result.applied_to_design_capital > 0 then
      designs.apply_recovery(state, design_id, result.applied_to_design_capital)
    end

    if design.pattern_pool_id and result.applied_to_pattern_capital > 0 then
      pattern_pools.apply_recovery(state, design.pattern_pool_id, result.applied_to_pattern_capital)
    end
  end

  return result
end

_G.AchaeadexLedger.Core.Recovery = recovery

return recovery
