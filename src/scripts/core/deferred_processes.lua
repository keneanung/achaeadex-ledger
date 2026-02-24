-- Deferred process management for Achaeadex Ledger

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local deferred = _G.AchaeadexLedger.Core.DeferredProcesses or {}

local function get_inventory()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.Inventory then
    error("AchaeadexLedger.Core.Inventory is not loaded")
  end

  return _G.AchaeadexLedger.Core.Inventory
end

local function ensure_state(state)
  state.process_instances = state.process_instances or {}
end

local function add_committed_entry(instance, commodity, qty, cost)
  if qty <= 0 then
    return
  end

  local unit_cost = cost / qty
  table.insert(instance.committed_entries, {
    commodity = commodity,
    qty = qty,
    total_cost = cost,
    unit_cost = unit_cost
  })
  instance.committed_cost_total = instance.committed_cost_total + cost
end

local function committed_stats(instance)
  local totals = {}
  local total_qty = 0
  for _, entry in ipairs(instance.committed_entries or {}) do
    totals[entry.commodity] = (totals[entry.commodity] or 0) + (entry.qty or 0)
    total_qty = total_qty + (entry.qty or 0)
  end

  local commodity_count = 0
  for _ in pairs(totals) do
    commodity_count = commodity_count + 1
  end

  return total_qty, commodity_count
end

local function compute_output_basis(total_cost, committed_qty, output_qty, commodity_count)
  if output_qty <= 0 or total_cost <= 0 then
    return 0
  end

  if commodity_count == 0 or committed_qty <= 0 then
    return total_cost
  end

  if commodity_count > 1 then
    return total_cost
  end

  local ratio = output_qty / committed_qty
  if ratio > 1 then
    ratio = 1
  end

  return total_cost * ratio
end

local function allocate_from_entries(instance, commodity, qty, apply_fn)
  local remaining = qty
  local i = 1

  while remaining > 0 and i <= #instance.committed_entries do
    local entry = instance.committed_entries[i]
    if entry.commodity == commodity and entry.qty > 0 then
      local take = math.min(remaining, entry.qty)
      local unit_cost = entry.total_cost / entry.qty
      local cost = take * unit_cost

      entry.qty = entry.qty - take
      entry.total_cost = entry.total_cost - cost
      instance.committed_cost_total = instance.committed_cost_total - cost

      apply_fn(take, unit_cost, cost)
      remaining = remaining - take
    end

    if entry.qty <= 0.0001 then
      table.remove(instance.committed_entries, i)
    else
      i = i + 1
    end
  end

  if remaining > 0 then
    error("Not enough committed inputs for commodity: " .. commodity)
  end
end

function deferred.start(state, process_instance_id, process_id, inputs, gold_fee, note, started_at)
  assert(type(process_instance_id) == "string", "process_instance_id must be a string")
  assert(type(process_id) == "string", "process_id must be a string")

  ensure_state(state)

  if state.process_instances[process_instance_id] then
    error("Process instance already exists: " .. process_instance_id)
  end

  local inventory = get_inventory()
  local instance = {
    process_instance_id = process_instance_id,
    process_id = process_id,
    started_at = started_at or os.date("!%Y-%m-%dT%H:%M:%SZ"),
    completed_at = nil,
    status = "in_flight",
    note = note,
    committed_entries = {},
    committed_cost_total = 0,
    fees_total = gold_fee or 0
  }

  inputs = inputs or {}
  for commodity, qty in pairs(inputs) do
    local cost = inventory.remove(state.inventory, commodity, qty)
    add_committed_entry(instance, commodity, qty, cost)
  end

  state.process_instances[process_instance_id] = instance

  return instance
end

function deferred.add_inputs(state, process_instance_id, inputs, note)
  ensure_state(state)

  local instance = state.process_instances[process_instance_id]
  if not instance then
    error("Process instance not found: " .. process_instance_id)
  end
  if instance.status ~= "in_flight" then
    error("Process instance not in flight: " .. process_instance_id)
  end

  local inventory = get_inventory()
  inputs = inputs or {}
  for commodity, qty in pairs(inputs) do
    local cost = inventory.remove(state.inventory, commodity, qty)
    add_committed_entry(instance, commodity, qty, cost)
  end

  if note then
    instance.note = note
  end

  return instance
end

function deferred.add_fee(state, process_instance_id, gold_fee, note)
  ensure_state(state)
  assert(type(gold_fee) == "number", "gold_fee must be a number")

  local instance = state.process_instances[process_instance_id]
  if not instance then
    error("Process instance not found: " .. process_instance_id)
  end
  if instance.status ~= "in_flight" then
    error("Process instance not in flight: " .. process_instance_id)
  end

  instance.fees_total = instance.fees_total + gold_fee
  if note then
    instance.note = note
  end

  return instance
end

function deferred.complete(state, process_instance_id, outputs, note, completed_at)
  ensure_state(state)

  local instance = state.process_instances[process_instance_id]
  if not instance then
    error("Process instance not found: " .. process_instance_id)
  end
  if instance.status ~= "in_flight" then
    error("Process instance not in flight: " .. process_instance_id)
  end

  outputs = outputs or {}
  local total_output_qty = 0
  for _, qty in pairs(outputs) do
    total_output_qty = total_output_qty + qty
  end

  local total_cost = instance.committed_cost_total + instance.fees_total
  local committed_qty, commodity_count = committed_stats(instance)
  local output_basis = compute_output_basis(total_cost, committed_qty, total_output_qty, commodity_count)
  local output_unit_cost = 0
  if total_output_qty > 0 then
    output_unit_cost = output_basis / total_output_qty
  end

  local inventory = get_inventory()
  for commodity, qty in pairs(outputs) do
    inventory.add(state.inventory, commodity, qty, output_unit_cost)
  end

  instance.status = "completed"
  instance.completed_at = completed_at or os.date("!%Y-%m-%dT%H:%M:%SZ")
  instance.note = note or instance.note
  instance.outputs = outputs
  instance.output_unit_cost = output_unit_cost

  return instance
end

function deferred.abort(state, process_instance_id, disposition, note, completed_at)
  ensure_state(state)

  local instance = state.process_instances[process_instance_id]
  if not instance then
    error("Process instance not found: " .. process_instance_id)
  end
  if instance.status ~= "in_flight" then
    error("Process instance not in flight: " .. process_instance_id)
  end

  disposition = disposition or {}
  local returned = disposition.returned or {}
  local lost = disposition.lost or {}
  local outputs = disposition.outputs or {}

  local total_cost = instance.committed_cost_total + instance.fees_total
  local committed_qty, commodity_count = committed_stats(instance)

  local inventory = get_inventory()

  for commodity, qty in pairs(returned) do
    allocate_from_entries(instance, commodity, qty, function(take, unit_cost)
      inventory.add(state.inventory, commodity, take, unit_cost)
    end)
  end

  for commodity, qty in pairs(lost) do
    allocate_from_entries(instance, commodity, qty, function()
      -- Lost inputs remain spent; inventory already removed.
    end)
  end

  local total_output_qty = 0
  for _, qty in pairs(outputs) do
    total_output_qty = total_output_qty + qty
  end

  local output_basis = compute_output_basis(total_cost, committed_qty, total_output_qty, commodity_count)
  local output_unit_cost = 0
  if total_output_qty > 0 then
    output_unit_cost = output_basis / total_output_qty
  end

  for commodity, qty in pairs(outputs) do
    inventory.add(state.inventory, commodity, qty, output_unit_cost)
  end

  instance.status = "aborted"
  instance.completed_at = completed_at or os.date("!%Y-%m-%dT%H:%M:%SZ")
  instance.note = note or instance.note
  instance.disposition = disposition
  instance.output_unit_cost = output_unit_cost

  return instance
end

_G.AchaeadexLedger.Core.DeferredProcesses = deferred

return deferred
