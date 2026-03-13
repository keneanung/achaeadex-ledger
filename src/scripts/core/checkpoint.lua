-- Temporary in-memory checkpoint helper for GMCP-derived state.

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local checkpoint = _G.AchaeadexLedger.Core.Checkpoint or {}

local currency_order = {
  "gold",
  "bank",
  "boundcredits",
  "unboundcredits",
  "lessons",
  "mayancrowns",
  "unboundmayancrowns"
}

local currency_labels = {
  gold = "Gold",
  bank = "Bank",
  boundcredits = "Bound credits",
  unboundcredits = "Unbound credits",
  lessons = "Lessons",
  mayancrowns = "Mayan crowns",
  unboundmayancrowns = "Unbound mayan crowns"
}

local function trim(value)
  local text = tostring(value or "")
  text = select(1, string.gsub(text, "^%s+", ""))
  text = select(1, string.gsub(text, "%s+$", ""))
  return text
end

local function copy_map(source)
  if type(source) ~= "table" then
    return nil
  end

  local result = {}
  for key, value in pairs(source) do
    result[key] = value
  end
  return result
end

local function format_signed(delta)
  local value = tonumber(delta) or 0
  if value >= 0 then
    return "+" .. tostring(value)
  end
  return tostring(value)
end

local function normalize_numeric(value)
  local number = tonumber(value)
  if not number then
    return nil
  end
  return math.floor(number)
end

local function map_is_unknown(map)
  return type(map) ~= "table"
end

local function sort_changes(changes)
  table.sort(changes, function(left, right)
    if left.type ~= right.type then
      return left.type < right.type
    end
    return tostring(left.resource) < tostring(right.resource)
  end)
end

function checkpoint.normalize_name(value)
  local text = trim(value)
  if text == "" then
    return nil
  end
  text = select(1, string.gsub(text, "%s+", " "))
  return string.lower(text)
end

function checkpoint.currency_order()
  return currency_order
end

function checkpoint.currency_label(resource)
  return currency_labels[resource] or tostring(resource or "")
end

function checkpoint.copy_snapshot(snapshot)
  if type(snapshot) ~= "table" then
    return nil
  end

  return {
    currencies = copy_map(snapshot.currencies) or {},
    inventory = copy_map(snapshot.inventory),
    rift = copy_map(snapshot.rift)
  }
end

function checkpoint.normalize_currencies(status)
  local normalized = {}
  local source = type(status) == "table" and status or {}

  for _, resource in ipairs(currency_order) do
    normalized[resource] = normalize_numeric(source[resource])
  end

  return normalized
end

function checkpoint.normalize_inventory(items_by_id)
  if type(items_by_id) ~= "table" then
    return nil
  end

  local grouped = {}
  for _, item in pairs(items_by_id) do
    local key = checkpoint.normalize_name(type(item) == "table" and item.name or nil)
    if key then
      grouped[key] = (grouped[key] or 0) + 1
    end
  end
  return grouped
end

function checkpoint.normalize_rift(entries)
  if type(entries) ~= "table" then
    return nil
  end

  local grouped = {}
  for _, entry in pairs(entries) do
    if type(entry) == "table" then
      local key = checkpoint.normalize_name(entry.desc or entry.name)
      local amount = normalize_numeric(entry.amount)
      if key and amount then
        grouped[key] = amount
      end
    end
  end
  return grouped
end

function checkpoint.build_snapshot(parts)
  local source = type(parts) == "table" and parts or {}

  return {
    currencies = checkpoint.normalize_currencies(source.currencies or source.status),
    inventory = source.inventory_known and checkpoint.normalize_inventory(source.inventory_items) or nil,
    rift = source.rift_known and checkpoint.normalize_rift(source.rift_entries) or nil
  }
end

local function diff_currency_section(previous, current)
  local changes = {}
  local unknown = false

  for _, resource in ipairs(currency_order) do
    local old_value = previous and previous[resource] or nil
    local new_value = current and current[resource] or nil

    if old_value == nil or new_value == nil then
      if old_value ~= new_value then
        unknown = true
      end
    else
      local delta = new_value - old_value
      if delta ~= 0 then
        table.insert(changes, {
          type = "currency",
          resource = resource,
          delta = delta,
          label = checkpoint.currency_label(resource)
        })
      end
    end
  end

  return {
    unknown = unknown,
    changes = changes
  }
end

local function diff_named_section(section_type, previous, current)
  if map_is_unknown(previous) or map_is_unknown(current) then
    return {
      unknown = true,
      changes = {}
    }
  end

  local keys = {}
  local seen = {}
  for resource in pairs(previous) do
    seen[resource] = true
    table.insert(keys, resource)
  end
  for resource in pairs(current) do
    if not seen[resource] then
      table.insert(keys, resource)
    end
  end
  table.sort(keys)

  local changes = {}
  for _, resource in ipairs(keys) do
    local old_value = previous[resource] or 0
    local new_value = current[resource] or 0
    local delta = new_value - old_value
    if delta ~= 0 then
      table.insert(changes, {
        type = section_type,
        resource = resource,
        delta = delta,
        label = resource
      })
    end
  end

  return {
    unknown = false,
    changes = changes
  }
end

function checkpoint.diff_snapshots(previous, current)
  local old_snapshot = type(previous) == "table" and previous or {}
  local new_snapshot = type(current) == "table" and current or {}

  local sections = {
    currencies = diff_currency_section(old_snapshot.currencies or {}, new_snapshot.currencies or {}),
    inventory = diff_named_section("inventory", old_snapshot.inventory, new_snapshot.inventory),
    rift = diff_named_section("rift", old_snapshot.rift, new_snapshot.rift)
  }

  local changes = {}
  for _, section_name in ipairs({ "currencies", "inventory", "rift" }) do
    for _, change in ipairs(sections[section_name].changes) do
      table.insert(changes, change)
    end
  end
  sort_changes(changes)

  return {
    changes = changes,
    sections = sections
  }
end

function checkpoint.render_diff(diff)
  local delta = type(diff) == "table" and diff or { sections = {} }
  local sections = delta.sections or {}
  local lines = {}

  local currency_lines = {}
  for _, change in ipairs((sections.currencies and sections.currencies.changes) or {}) do
    table.insert(currency_lines, tostring(change.label) .. ": " .. format_signed(change.delta))
  end
  if #currency_lines > 0 then
    for _, line in ipairs(currency_lines) do
      table.insert(lines, line)
    end
  elseif sections.currencies and sections.currencies.unknown then
    table.insert(lines, "Currencies: unknown")
  end

  local function append_group(title, section)
    if section and #section.changes > 0 then
      table.insert(lines, title .. ":")
      for _, change in ipairs(section.changes) do
        table.insert(lines, "  " .. tostring(change.label) .. ": " .. format_signed(change.delta))
      end
      return
    end
    if section and section.unknown then
      table.insert(lines, title .. ": unknown")
    end
  end

  append_group("Inventory", sections.inventory or { changes = {} })
  append_group("Rift", sections.rift or { changes = {} })

  if #lines == 0 then
    return { "No changes since checkpoint." }
  end

  return lines
end

_G.AchaeadexLedger.Core.Checkpoint = checkpoint

return checkpoint