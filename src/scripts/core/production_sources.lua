-- Production source management for Achaeadex Ledger

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local sources = _G.AchaeadexLedger.Core.ProductionSources or {}

local function ensure_state(state)
  state.production_sources = state.production_sources or {}
end

local function get_pattern_pools()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.PatternPools then
    error("AchaeadexLedger.Core.PatternPools is not loaded")
  end

  return _G.AchaeadexLedger.Core.PatternPools
end

local function default_recovery_enabled(provenance)
  if provenance == "private" then
    return 1
  end
  return 0
end

local function resolve_pattern_pool_id(state, source_kind, source_type, recovery_enabled)
  if source_kind ~= "design" or recovery_enabled ~= 1 then
    return nil
  end

  local pattern_pools = get_pattern_pools()
  local pool_id = pattern_pools.get_active_pool_id(state, source_type)
  if not pool_id then
    error("No active pattern pool for type: " .. source_type)
  end
  return pool_id
end

function sources.create_source(state, source_id, source_kind, source_type, name, provenance, recovery_enabled, opts)
  assert(type(source_id) == "string", "source_id must be a string")
  assert(type(source_kind) == "string", "source_kind must be a string")
  assert(type(source_type) == "string", "source_type must be a string")

  if opts ~= nil and type(opts) ~= "table" then
    error("opts must be a table when provided")
  end

  ensure_state(state)

  provenance = provenance or (source_kind == "skill" and "system" or "private")
  if recovery_enabled == nil then
    if source_kind == "skill" then
      recovery_enabled = 0
    else
      recovery_enabled = default_recovery_enabled(provenance)
    end
  end

  local pattern_pool_id = resolve_pattern_pool_id(state, source_kind, source_type, recovery_enabled)
  local status = opts and opts.status or "active"

  local source = {
    source_id = source_id,
    source_kind = source_kind,
    source_type = source_type,
    name = name,
    created_at = opts and opts.created_at or os.date("!%Y-%m-%dT%H:%M:%SZ"),
    pattern_pool_id = pattern_pool_id,
    per_item_fee_gold = opts and opts.per_item_fee_gold or 0,
    provenance = provenance,
    recovery_enabled = recovery_enabled,
    status = status,
    capital_remaining = opts and opts.capital_remaining or 0,
    bom = opts and opts.bom or nil,
    pricing_policy = opts and opts.pricing_policy or nil
  }

  state.production_sources[source_id] = source

  return source
end

function sources.create_design(state, source_id, source_type, name, provenance, recovery_enabled, opts)
  local copy = opts or {}
  if copy.status == nil then
    copy.status = "in_progress"
  end
  return sources.create_source(state, source_id, "design", source_type, name, provenance, recovery_enabled, copy)
end

function sources.create_skill(state, source_id, source_type, name, provenance, opts)
  local copy = opts or {}
  if copy.status == nil then
    copy.status = "active"
  end
  return sources.create_source(state, source_id, "skill", source_type, name, provenance or "system", 0, copy)
end

function sources.get(state, source_id)
  ensure_state(state)
  return state.production_sources[source_id]
end

function sources.set_pricing_policy(state, source_id, pricing_policy)
  ensure_state(state)

  local source = state.production_sources[source_id]
  if not source then
    error("Production source " .. source_id .. " not found")
  end

  source.pricing_policy = pricing_policy

  return source
end

function sources.set_bom(state, source_id, bom)
  ensure_state(state)

  local source = state.production_sources[source_id]
  if not source then
    error("Production source " .. source_id .. " not found")
  end

  source.bom = bom

  return source
end

function sources.update(state, source_id, fields)
  ensure_state(state)
  assert(type(fields) == "table", "fields must be a table")

  local source = state.production_sources[source_id]
  if not source then
    error("Production source " .. source_id .. " not found")
  end

  if fields.name ~= nil then
    source.name = fields.name
  end
  if fields.source_type then
    source.source_type = fields.source_type
  end
  if fields.provenance then
    source.provenance = fields.provenance
  end
  if fields.recovery_enabled ~= nil then
    source.recovery_enabled = fields.recovery_enabled
  end
  if fields.status then
    source.status = fields.status
  end
  if fields.per_item_fee_gold ~= nil then
    source.per_item_fee_gold = fields.per_item_fee_gold
  end

  source.pattern_pool_id = resolve_pattern_pool_id(state, source.source_kind, source.source_type, source.recovery_enabled)

  return source
end

function sources.add_capital(state, source_id, amount)
  ensure_state(state)
  assert(type(amount) == "number", "amount must be a number")

  local source = state.production_sources[source_id]
  if not source then
    error("Production source " .. source_id .. " not found")
  end

  if source.recovery_enabled == 1 then
    source.capital_remaining = (source.capital_remaining or 0) + amount
  end

  return source.capital_remaining
end

function sources.apply_recovery(state, source_id, amount)
  ensure_state(state)
  assert(type(amount) == "number", "amount must be a number")

  local source = state.production_sources[source_id]
  if not source then
    error("Production source " .. source_id .. " not found")
  end

  if amount <= 0 then
    return 0, source.capital_remaining
  end

  local applied = math.min(amount, source.capital_remaining or 0)
  source.capital_remaining = (source.capital_remaining or 0) - applied

  return applied, source.capital_remaining
end

_G.AchaeadexLedger.Core.ProductionSources = sources

return sources
