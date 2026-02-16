-- Pattern pool management for Achaeadex Ledger

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local pattern_pools = _G.AchaeadexLedger.Core.PatternPools or {}

local function ensure_state(state)
  state.pattern_pools = state.pattern_pools or {}
  state.pattern_pools_by_type = state.pattern_pools_by_type or {}
end

function pattern_pools.activate(state, pattern_pool_id, pattern_type, pattern_name, capital_initial, activated_at)
  assert(type(pattern_pool_id) == "string", "pattern_pool_id must be a string")
  assert(type(pattern_type) == "string", "pattern_type must be a string")
  assert(type(capital_initial) == "number" and capital_initial >= 0, "capital_initial must be non-negative number")

  ensure_state(state)

  local active_id = state.pattern_pools_by_type[pattern_type]
  if active_id and state.pattern_pools[active_id] and state.pattern_pools[active_id].status == "active" then
    error("Pattern pool already active for type: " .. pattern_type)
  end

  local pool = {
    pattern_pool_id = pattern_pool_id,
    pattern_type = pattern_type,
    pattern_name = pattern_name,
    activated_at = activated_at or os.date("!%Y-%m-%dT%H:%M:%SZ"),
    deactivated_at = nil,
    capital_initial_gold = capital_initial,
    capital_remaining_gold = capital_initial,
    status = "active"
  }

  state.pattern_pools[pattern_pool_id] = pool
  state.pattern_pools_by_type[pattern_type] = pattern_pool_id

  return pool
end

function pattern_pools.deactivate(state, pattern_pool_id, deactivated_at)
  ensure_state(state)

  local pool = state.pattern_pools[pattern_pool_id]
  if not pool then
    error("Pattern pool " .. pattern_pool_id .. " not found")
  end

  pool.status = "closed"
  pool.deactivated_at = deactivated_at or os.date("!%Y-%m-%dT%H:%M:%SZ")

  if state.pattern_pools_by_type[pool.pattern_type] == pattern_pool_id then
    state.pattern_pools_by_type[pool.pattern_type] = nil
  end

  return pool
end

function pattern_pools.get_active_pool_id(state, pattern_type)
  ensure_state(state)
  return state.pattern_pools_by_type[pattern_type]
end

function pattern_pools.get_active_pool(state, pattern_type)
  ensure_state(state)
  local pool_id = state.pattern_pools_by_type[pattern_type]
  if not pool_id then
    return nil
  end
  return state.pattern_pools[pool_id]
end

function pattern_pools.apply_recovery(state, pattern_pool_id, amount)
  ensure_state(state)
  assert(type(amount) == "number", "amount must be a number")

  local pool = state.pattern_pools[pattern_pool_id]
  if not pool then
    error("Pattern pool " .. pattern_pool_id .. " not found")
  end

  if amount <= 0 then
    return 0, pool.capital_remaining_gold
  end

  local applied = math.min(amount, pool.capital_remaining_gold)
  pool.capital_remaining_gold = pool.capital_remaining_gold - applied

  return applied, pool.capital_remaining_gold
end

_G.AchaeadexLedger.Core.PatternPools = pattern_pools

return pattern_pools
