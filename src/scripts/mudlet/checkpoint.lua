-- Temporary in-memory GMCP checkpoint observer.

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Mudlet = _G.AchaeadexLedger.Mudlet or {}

local observer = _G.AchaeadexLedger.Mudlet.Checkpoint or {}

local USER_NAME = "AchaeadexLedger"
local EVENT_NAME = "AchaeadexLedger.CheckpointDiff"

local function get_core()
  return _G.AchaeadexLedger and _G.AchaeadexLedger.Core and _G.AchaeadexLedger.Core.Checkpoint
end

local function merge_into(target, source)
  if type(target) ~= "table" or type(source) ~= "table" then
    return target
  end

  for key, value in pairs(source) do
    target[key] = value
  end
  return target
end

local function build_snapshot()
  local checkpoint = get_core()
  if not checkpoint then
    return nil
  end

  return checkpoint.build_snapshot({
    currencies = observer.status_values,
    inventory_items = observer.inventory_items,
    inventory_known = observer.inventory_known,
    rift_entries = observer.rift_entries,
    rift_known = observer.rift_known
  })
end

local function emit_changes(source_event, changes)
  if type(changes) ~= "table" then
    return
  end

  for _, change in ipairs(changes) do
    local payload = {
      type = change.type,
      resource = change.resource,
      delta = change.delta,
      source_event = source_event
    }
    observer.last_diff_event = payload
    if type(raiseEvent) == "function" then
      raiseEvent(EVENT_NAME, payload)
    end
  end
end

local function refresh_snapshot(source_event)
  local checkpoint = get_core()
  if not checkpoint then
    return
  end

  local previous = observer.current_snapshot and checkpoint.copy_snapshot(observer.current_snapshot) or nil
  observer.current_snapshot = build_snapshot()
  if not previous or not observer.current_snapshot then
    return
  end

  local diff = checkpoint.diff_snapshots(previous, observer.current_snapshot)
  emit_changes(source_event, diff.changes)
end

local function request_current_state()
  local gmod_api = rawget(_G, "gmod")
  if type(gmod_api) == "table" then
    if type(gmod_api.registerUser) == "function" then
      pcall(gmod_api.registerUser, USER_NAME)
    end
    if type(gmod_api.enableModule) == "function" then
      pcall(gmod_api.enableModule, USER_NAME, "IRE.Rift")
    end
  end

  if type(sendGMCP) == "function" then
    sendGMCP("Char.Items.Inv")
    sendGMCP("IRE.Rift.Request")
  end
end

local function normalize_item_id(item)
  if type(item) ~= "table" or item.id == nil then
    return nil
  end
  return tostring(item.id)
end

local function handle_char_status()
  if not gmcp or not gmcp.Char or type(gmcp.Char.Status) ~= "table" then
    return
  end

  merge_into(observer.status_values, gmcp.Char.Status)
  refresh_snapshot("gmcp.Char.Status")
end

local function handle_items_list()
  local payload = gmcp and gmcp.Char and gmcp.Char.Items and gmcp.Char.Items.List or nil
  if type(payload) ~= "table" or payload.location ~= "inv" then
    return
  end

  observer.inventory_items = {}
  for _, item in ipairs(payload.items or {}) do
    local item_id = normalize_item_id(item)
    if item_id then
      observer.inventory_items[item_id] = item
    end
  end
  observer.inventory_known = true
  refresh_snapshot("gmcp.Char.Items.List")
end

local function handle_items_add_or_update(source_event, payload)
  if type(payload) ~= "table" or payload.location ~= "inv" or type(payload.item) ~= "table" then
    return
  end

  local item_id = normalize_item_id(payload.item)
  if not item_id then
    return
  end

  observer.inventory_items[item_id] = payload.item
  observer.inventory_known = true
  refresh_snapshot(source_event)
end

local function handle_items_remove()
  local payload = gmcp and gmcp.Char and gmcp.Char.Items and gmcp.Char.Items.Remove or nil
  if type(payload) ~= "table" or payload.location ~= "inv" or type(payload.item) ~= "table" then
    return
  end

  local item_id = normalize_item_id(payload.item)
  if not item_id then
    return
  end

  observer.inventory_items[item_id] = nil
  observer.inventory_known = true
  refresh_snapshot("gmcp.Char.Items.Remove")
end

local function normalize_rift_key(entry)
  local checkpoint = get_core()
  if not checkpoint or type(entry) ~= "table" then
    return nil
  end
  return checkpoint.normalize_name(entry.desc or entry.name)
end

local function handle_rift_list()
  local payload = gmcp and gmcp.IRE and gmcp.IRE.Rift and gmcp.IRE.Rift.List or nil
  if type(payload) ~= "table" then
    return
  end

  observer.rift_entries = {}
  for _, entry in ipairs(payload) do
    local key = normalize_rift_key(entry)
    if key then
      observer.rift_entries[key] = entry
    end
  end
  observer.rift_known = true
  refresh_snapshot("gmcp.IRE.Rift.List")
end

local function handle_rift_change()
  local payload = gmcp and gmcp.IRE and gmcp.IRE.Rift and gmcp.IRE.Rift.Change or nil
  if type(payload) ~= "table" then
    return
  end

  local key = normalize_rift_key(payload)
  if not key then
    return
  end

  local amount = tonumber(payload.amount)
  if amount and amount > 0 then
    observer.rift_entries[key] = payload
  else
    observer.rift_entries[key] = nil
  end
  observer.rift_known = true
  refresh_snapshot("gmcp.IRE.Rift.Change")
end

local function register_handler(name, event_name, func)
  if type(registerNamedEventHandler) ~= "function" then
    return nil
  end
  return registerNamedEventHandler(USER_NAME, name, event_name, func)
end

function observer.capture_checkpoint()
  local checkpoint = get_core()
  if not checkpoint then
    return nil
  end

  observer.current_snapshot = observer.current_snapshot or build_snapshot()
  observer.checkpoint_snapshot = checkpoint.copy_snapshot(observer.current_snapshot)
  return checkpoint.copy_snapshot(observer.checkpoint_snapshot)
end

function observer.report_since_checkpoint()
  local checkpoint = get_core()
  if not checkpoint then
    return nil, "checkpoint module is not loaded"
  end
  if not observer.checkpoint_snapshot then
    return nil, "no checkpoint captured"
  end

  observer.current_snapshot = observer.current_snapshot or build_snapshot()
  local diff = checkpoint.diff_snapshots(observer.checkpoint_snapshot, observer.current_snapshot)
  return diff, checkpoint.render_diff(diff)
end

function observer.current_state()
  observer.current_snapshot = observer.current_snapshot or build_snapshot()
  local checkpoint = get_core()
  if not checkpoint then
    return nil
  end
  return checkpoint.copy_snapshot(observer.current_snapshot)
end

function observer.start()
  if observer.started then
    return
  end

  observer.started = true
  observer.status_values = observer.status_values or {}
  observer.inventory_items = observer.inventory_items or {}
  observer.rift_entries = observer.rift_entries or {}
  observer.inventory_known = observer.inventory_known or false
  observer.rift_known = observer.rift_known or false

  if gmcp and gmcp.Char and type(gmcp.Char.Status) == "table" then
    merge_into(observer.status_values, gmcp.Char.Status)
  end
  if gmcp and gmcp.IRE and gmcp.IRE.Rift and type(gmcp.IRE.Rift.List) == "table" then
    observer.rift_known = true
    for _, entry in ipairs(gmcp.IRE.Rift.List) do
      local key = normalize_rift_key(entry)
      if key then
        observer.rift_entries[key] = entry
      end
    end
  end

  observer.handlers = {
    register_handler("checkpoint.char_status", "gmcp.Char.Status", handle_char_status),
    register_handler("checkpoint.items_list", "gmcp.Char.Items.List", handle_items_list),
    register_handler("checkpoint.items_add", "gmcp.Char.Items.Add", function()
      local payload = gmcp and gmcp.Char and gmcp.Char.Items and gmcp.Char.Items.Add or nil
      handle_items_add_or_update("gmcp.Char.Items.Add", payload)
    end),
    register_handler("checkpoint.items_update", "gmcp.Char.Items.Update", function()
      local payload = gmcp and gmcp.Char and gmcp.Char.Items and gmcp.Char.Items.Update or nil
      handle_items_add_or_update("gmcp.Char.Items.Update", payload)
    end),
    register_handler("checkpoint.items_remove", "gmcp.Char.Items.Remove", handle_items_remove),
    register_handler("checkpoint.rift_list", "gmcp.IRE.Rift.List", handle_rift_list),
    register_handler("checkpoint.rift_change", "gmcp.IRE.Rift.Change", handle_rift_change)
  }

  observer.current_snapshot = build_snapshot()
  request_current_state()
end

_G.AchaeadexLedger.Mudlet.Checkpoint = observer

return observer