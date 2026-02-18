-- Design management for Achaeadex Ledger

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local designs = _G.AchaeadexLedger.Core.Designs or {}

local function ensure_state(state)
  state.designs = state.designs or {}
end

local function get_pattern_pools()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.PatternPools then
    error("AchaeadexLedger.Core.PatternPools is not loaded")
  end

  return _G.AchaeadexLedger.Core.PatternPools
end

function designs.create(state, design_id, design_type, name, provenance, recovery_enabled, opts)
  assert(type(design_id) == "string", "design_id must be a string")
  assert(type(design_type) == "string", "design_type must be a string")

  if opts ~= nil and type(opts) ~= "table" then
    error("opts must be a table when provided")
  end

  ensure_state(state)

  provenance = provenance or "private"
  if recovery_enabled == nil then
    if provenance == "private" then
      recovery_enabled = 1
    else
      recovery_enabled = 0
    end
  end

  local pattern_pool_id = nil
  if recovery_enabled == 1 then
    local pattern_pools = get_pattern_pools()
    pattern_pool_id = pattern_pools.get_active_pool_id(state, design_type)
    if not pattern_pool_id then
      error("No active pattern pool for type: " .. design_type)
    end
  end

  local status = opts and opts.status or "in_progress"
  local design = {
    design_id = design_id,
    design_type = design_type,
    name = name,
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    pattern_pool_id = pattern_pool_id,
    per_item_fee_gold = 0,
    provenance = provenance,
    recovery_enabled = recovery_enabled,
    status = status,
    capital_remaining = 0,
    bom = opts and opts.bom or nil
  }

  state.designs[design_id] = design

  return design
end

function designs.set_bom(state, design_id, bom)
  ensure_state(state)

  local design = state.designs[design_id]
  if not design then
    error("Design " .. design_id .. " not found")
  end

  design.bom = bom

  return design
end

function designs.update(state, design_id, fields)
  ensure_state(state)
  assert(type(fields) == "table", "fields must be a table")

  local design = state.designs[design_id]
  if not design then
    error("Design " .. design_id .. " not found")
  end

  if fields.name ~= nil then
    design.name = fields.name
  end
  if fields.design_type then
    design.design_type = fields.design_type
  end
  if fields.provenance then
    design.provenance = fields.provenance
  end
  if fields.recovery_enabled ~= nil then
    design.recovery_enabled = fields.recovery_enabled
  end
  if fields.status then
    design.status = fields.status
  end

  if design.recovery_enabled == 1 then
    local pattern_pools = get_pattern_pools()
    local pool_id = pattern_pools.get_active_pool_id(state, design.design_type)
    if not pool_id then
      error("No active pattern pool for type: " .. design.design_type)
    end
    design.pattern_pool_id = pool_id
  else
    design.pattern_pool_id = nil
  end

  return design
end

function designs.add_capital(state, design_id, amount)
  ensure_state(state)
  assert(type(amount) == "number", "amount must be a number")

  local design = state.designs[design_id]
  if not design then
    error("Design " .. design_id .. " not found")
  end

  if design.recovery_enabled == 1 then
    design.capital_remaining = (design.capital_remaining or 0) + amount
  end

  return design.capital_remaining
end

function designs.apply_recovery(state, design_id, amount)
  ensure_state(state)
  assert(type(amount) == "number", "amount must be a number")

  local design = state.designs[design_id]
  if not design then
    error("Design " .. design_id .. " not found")
  end

  if amount <= 0 then
    return 0, design.capital_remaining
  end

  local applied = math.min(amount, design.capital_remaining or 0)
  design.capital_remaining = (design.capital_remaining or 0) - applied

  return applied, design.capital_remaining
end

_G.AchaeadexLedger.Core.Designs = designs

return designs
