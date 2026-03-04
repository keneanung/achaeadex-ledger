-- Auto-import upsert logic for parsed design details

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local importer = _G.AchaeadexLedger.Core.DesignAutoImport or {}

local function get_parser()
  if not _G.AchaeadexLedger or not _G.AchaeadexLedger.Core or not _G.AchaeadexLedger.Core.DesignDetailsParser then
    error("AchaeadexLedger.Core.DesignDetailsParser is not loaded")
  end
  return _G.AchaeadexLedger.Core.DesignDetailsParser
end

local function get_ledger()
  if not _G.AchaeadexLedger or not _G.AchaeadexLedger.Core or not _G.AchaeadexLedger.Core.Ledger then
    error("AchaeadexLedger.Core.Ledger is not loaded")
  end
  return _G.AchaeadexLedger.Core.Ledger
end

local function trim(value)
  value = tostring(value or "")
  value = value:gsub("^%s+", "")
  value = value:gsub("%s+$", "")
  return value
end

local function is_empty_map(value)
  if type(value) ~= "table" then
    return true
  end
  return next(value) == nil
end

local function tables_equal(left, right)
  if left == right then
    return true
  end
  if type(left) ~= type(right) then
    return false
  end
  if type(left) ~= "table" then
    return left == right
  end

  for key, value in pairs(left) do
    if not tables_equal(value, right[key]) then
      return false
    end
  end
  for key, value in pairs(right) do
    if not tables_equal(value, left[key]) then
      return false
    end
  end

  return true
end

local function default_source_id(alias_id)
  return "D-" .. tostring(alias_id)
end

local function append_warning(result, message)
  table.insert(result.warnings, tostring(message))
end

local function auto_import_default_recovery_enabled()
  return 0
end

local function auto_import_source_type(parsed)
  return parsed.design_type or parsed.source_type or "unknown"
end

local function find_source_for_alias(state, alias_id)
  local alias = state.design_aliases and state.design_aliases[tostring(alias_id)] or nil
  if alias and alias.source_id then
    return alias.source_id, alias
  end
  return nil, nil
end

local function safe_design_update(ledger, state, source_id, fields, result)
  if not next(fields) then
    return true
  end

  local ok, err = pcall(ledger.apply_design_update, state, source_id, fields)
  if ok then
    return true
  end

  if fields.recovery_enabled == 1 then
    fields.recovery_enabled = nil
    append_warning(result, "No active pattern pool for " .. tostring(source_id) .. "; recovery remains unchanged")
    local retry_ok, retry_err = pcall(ledger.apply_design_update, state, source_id, fields)
    if retry_ok then
      return true
    end
    append_warning(result, retry_err)
    return false
  end

  append_warning(result, err)
  return false
end

function importer.upsert(state, parsed, opts)
  assert(type(state) == "table", "state must be a table")
  assert(type(parsed) == "table", "parsed must be a table")
  opts = opts or {}

  local ledger = get_ledger()
  local alias_id = tostring(parsed.alias_id)
  local result = {
    alias_id = alias_id,
    source_id = nil,
    created = false,
    updated = false,
    warnings = {}
  }

  local source_id, alias_entry = find_source_for_alias(state, alias_id)
  if not source_id then
    local deterministic_id = default_source_id(alias_id)
    if state.production_sources and state.production_sources[deterministic_id] then
      source_id = deterministic_id
    else
      source_id = deterministic_id
      local ok, err = pcall(ledger.apply_source_create, state, source_id, "design", auto_import_source_type(parsed), parsed.short_desc, {
        provenance = parsed.provenance,
        recovery_enabled = auto_import_default_recovery_enabled(),
        status = "approved",
        metadata = parsed.metadata
      })
      if not ok then
        return nil, tostring(err)
      end
      result.created = true
      result.updated = true
    end
  end

  result.source_id = source_id

  if alias_entry and alias_entry.source_id ~= source_id then
    return nil, "alias " .. tostring(alias_id) .. " already maps to " .. tostring(alias_entry.source_id)
  end

  if not alias_entry then
    local ok, err = pcall(ledger.apply_design_alias, state, source_id, alias_id, "other", 1)
    if not ok then
      return nil, tostring(err)
    end
    result.updated = true
  end

  local source = state.production_sources and state.production_sources[source_id] or nil
  if not source then
    return nil, "source " .. tostring(source_id) .. " not found after upsert"
  end

  local update_fields = {}
  if parsed.short_desc and trim(parsed.short_desc) ~= "" and trim(source.name or "") ~= trim(parsed.short_desc) then
    update_fields.name = parsed.short_desc
  end
  local parsed_source_type = auto_import_source_type(parsed)
  if parsed_source_type ~= "unknown" and source.source_type ~= parsed_source_type then
    if source.recovery_enabled == 1 and source.pattern_pool_id then
      append_warning(result,
        "source_type differs from probed design_type but pattern link is active; keeping existing source_type "
        .. tostring(source.source_type))
    else
      update_fields.design_type = parsed_source_type
    end
  end
  if parsed.provenance and parsed.provenance ~= "" and source.provenance ~= parsed.provenance then
    update_fields.provenance = parsed.provenance
  end
  if (not source.status or source.status == "stub" or source.status == "in_progress") then
    update_fields.status = "approved"
  end
  if parsed.metadata and not tables_equal(source.metadata or {}, parsed.metadata) then
    update_fields.metadata = parsed.metadata
  end

  if source.recovery_enabled == nil then
    update_fields.recovery_enabled = auto_import_default_recovery_enabled()
  end

  if next(update_fields) then
    local ok = safe_design_update(ledger, state, source_id, update_fields, result)
    if not ok then
      return nil, "failed to update design " .. tostring(source_id)
    end
    result.updated = true
    source = state.production_sources and state.production_sources[source_id] or source
  end

  local appearance_key = parsed.short_desc
  local appearance = state.appearance_aliases and state.appearance_aliases[appearance_key] or nil
  if not appearance then
    local ok, err = pcall(ledger.apply_design_appearance, state, source_id, appearance_key, "parsed")
    if not ok then
      append_warning(result, err)
    else
      result.updated = true
    end
  elseif appearance.source_id ~= source_id then
    append_warning(result, "short_desc already mapped to another source: " .. tostring(appearance.source_id))
  end

  local source_bom = source and source.bom or nil
  if type(parsed.bom) == "table" and not is_empty_map(parsed.bom) and not tables_equal(source_bom or {}, parsed.bom) then
    local ok, err = pcall(ledger.apply_design_set_bom, state, source_id, parsed.bom)
    if not ok then
      append_warning(result, err)
    else
      result.updated = true
      source = state.production_sources and state.production_sources[source_id] or source
    end
  end

  local current_fee = source and tonumber(source.per_item_fee_gold) or 0
  if parsed.per_item_fee_gold and parsed.per_item_fee_gold > 0 and parsed.per_item_fee_gold ~= current_fee then
    local ok, err = pcall(ledger.apply_design_set_fee, state, source_id, parsed.per_item_fee_gold)
    if not ok then
      append_warning(result, err)
    else
      result.updated = true
    end
  end

  return result
end

function importer.parse_and_upsert(state, lines, opts)
  assert(type(state) == "table", "state must be a table")
  opts = opts or {}

  local parser = get_parser()
  local parsed, parse_err = parser.parse(lines, {
    player_name = opts.player_name or "Keneanung"
  })
  if not parsed then
    return nil, parse_err
  end

  return importer.upsert(state, parsed, opts)
end

_G.AchaeadexLedger.Core.DesignAutoImport = importer

return importer
