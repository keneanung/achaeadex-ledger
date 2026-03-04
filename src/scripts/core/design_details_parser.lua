-- Passive parser for Achaea design detail output (nds p <id>)

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local parser = _G.AchaeadexLedger.Core.DesignDetailsParser or {}

local function trim(value)
  value = tostring(value or "")
  value = value:gsub("^%s+", "")
  value = value:gsub("%s+$", "")
  return value
end

local function split_lines(text)
  local lines = {}
  text = tostring(text or "")
  text = text:gsub("\r\n", "\n")
  text = text:gsub("\r", "\n")
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end
  return lines
end

function parser.strip_ansi(line)
  line = tostring(line or "")
  line = line:gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
  line = line:gsub("\27%][^\7]*\7", "")
  return line
end

local function next_non_empty(lines, from_index)
  for i = from_index, #lines do
    if trim(lines[i]) ~= "" then
      return trim(lines[i]), i
    end
  end
  return nil, nil
end

local function should_end_section(line)
  local raw = trim(line)
  if raw == "" then
    return false
  end
  if raw:match("^Appearance %(short_desc%)$") then
    return true
  end
  if raw:match("^Dropped %(long_desc%)$") then
    return true
  end
  if raw:match("^Examined %(extended_desc%)$") then
    return true
  end
  if raw:match("^Months of usefulness left:") then
    return true
  end
  if raw:match("^Generic$") then
    return true
  end
  if raw:match("^In Vessel$") then
    return true
  end
  if raw:match("^First Drunk Ideal$") then
    return true
  end
  if raw:match("^First Drunk$") then
    return true
  end
  if raw:match("^Third Drunk Ideal$") then
    return true
  end
  if raw:match("^Third Drunk$") then
    return true
  end
  if raw:match("^Nose Ideal$") then
    return true
  end
  if raw:match("^Nose$") then
    return true
  end
  if raw:match("^Taste Ideal$") then
    return true
  end
  if raw:match("^Taste$") then
    return true
  end
  if raw:match("^First Eaten$") then
    return true
  end
  if raw:match("^Third Eaten$") then
    return true
  end
  if raw:match("^Smell$") then
    return true
  end
  if raw:match("^Design%d+%s+Designer:") then
    return true
  end
  return false
end

local function collect_section(lines, start_index)
  local values = {}
  local i = start_index
  while i <= #lines and trim(lines[i]) == "" do
    i = i + 1
  end

  while i <= #lines do
    local line = lines[i]
    if should_end_section(line) then
      break
    end
    table.insert(values, trim(line))
    i = i + 1
  end

  return trim(table.concat(values, "\n")), i
end

local function parse_owner(owner_raw, player_name)
  owner_raw = trim(owner_raw)
  if owner_raw == "*public" then
    return "public", 0
  end

  if owner_raw:find("%s") then
    return "organization", 0
  end

  if owner_raw == player_name then
    return "private", 1
  end

  return "foreign", 0
end

local function parse_material_pairs(segment)
  local bom = {}
  segment = trim(segment)
  if segment == "" then
    return bom
  end

  local normalized = segment:gsub("%s*,%s*", ",")
  for token in normalized:gmatch("[^,]+") do
    local part = trim(token)
    if part ~= "" then
      local commodity_first, qty_last = part:match("^(.-)%s+(%d+)$")
      if commodity_first and qty_last and not commodity_first:match("^%d+") then
        bom[trim(commodity_first):lower()] = tonumber(qty_last)
      else
        local qty_first, commodity_last = part:match("^(%d+)%s+(.+)$")
        if qty_first and commodity_last then
          bom[trim(commodity_last):lower()] = tonumber(qty_first)
        end
      end
    end
  end

  return bom
end

local function parse_sample_pairs(segment)
  local samples = {}
  segment = trim(segment)
  if segment == "" then
    return samples
  end

  for qty, commodity in segment:gmatch("(%d+)%s+([%a_%-]+)") do
    samples[trim(commodity):lower()] = tonumber(qty)
  end

  return samples
end

local function parse_type_line(line)
  local raw = trim(line)
  if not raw:match("^Type:%s*") then
    return nil
  end

  local design_type = raw:match("^Type:%s*(%S+)")
  if not design_type then
    return nil
  end

  local markers = {
    "Comms:",
    "Mediums:",
    "Ingredients:",
    "Samples:",
    "Crafting Fee:",
    "Sessions:",
    "Method:",
    "Aged:"
  }

  local function segment_for(key)
    local key_start = raw:find(key, 1, true)
    if not key_start then
      return nil
    end
    local segment_start = key_start + #key
    local segment_end = #raw + 1
    for _, marker in ipairs(markers) do
      if marker ~= key then
        local marker_start = raw:find(marker, segment_start, true)
        if marker_start and marker_start > segment_start then
          segment_end = math.min(segment_end, marker_start)
        end
      end
    end
    return trim(raw:sub(segment_start, segment_end - 1))
  end

  local material_segment = segment_for("Comms:") or segment_for("Mediums:") or segment_for("Ingredients:") or ""
  local samples_segment = segment_for("Samples:") or ""
  local fee = (segment_for("Crafting Fee:") or ""):match("^(%d+)$")
  local sessions = (segment_for("Sessions:") or ""):match("^(%d+)$")
  local method = segment_for("Method:")
  local aged = segment_for("Aged:")

  return {
    design_type = trim(design_type):lower(),
    bom = parse_material_pairs(material_segment),
    samples = parse_sample_pairs(samples_segment),
    per_item_fee_gold = fee and tonumber(fee) or nil,
    method = method ~= "" and method or nil,
    aged = aged ~= "" and aged or nil,
    sessions = sessions and tonumber(sessions) or nil
  }
end

local function normalize_lines(input)
  local lines = {}
  if type(input) == "string" then
    lines = split_lines(input)
  elseif type(input) == "table" then
    for _, value in ipairs(input) do
      table.insert(lines, tostring(value))
    end
  end

  local cleaned = {}
  for _, line in ipairs(lines) do
    table.insert(cleaned, trim(parser.strip_ansi(line)))
  end
  return cleaned
end

function parser.parse(input, opts)
  opts = opts or {}
  local player_name = opts.player_name or "Keneanung"
  local lines = normalize_lines(input)

  local parsed = {
    alias_id = nil,
    designer = nil,
    owner_raw = nil,
    provenance = nil,
    recovery_enabled = 0,
    discipline = nil,
    source_type = nil,
    design_type = nil,
    bom = {},
    per_item_fee_gold = nil,
    short_desc = nil,
    metadata = {
      samples = nil,
      dropped_desc = nil,
      examined_desc = nil,
      months_usefulness = nil,
      designer = nil,
      owner_raw = nil,
      design_type = nil,
      discipline = nil,
      method = nil,
      aged = nil,
      sessions = nil,
      generic = nil,
      in_vessel = nil,
      first_drunk_ideal = nil,
      third_drunk_ideal = nil,
      nose_ideal = nil,
      taste_ideal = nil,
      first_eaten = nil,
      third_eaten = nil,
      smell = nil,
      taste = nil
    }
  }

  for i = 1, #lines do
    local line = lines[i]

    if not parsed.alias_id then
      local alias_id, designer, owner_raw = line:match("^Design(%d+)%s+Designer:%s*(.-)%s+Owner:%s*(.+)$")
      if alias_id then
        parsed.alias_id = tostring(alias_id)
        parsed.designer = trim(designer)
        parsed.owner_raw = trim(owner_raw)
        parsed.metadata.designer = parsed.designer
        parsed.metadata.owner_raw = parsed.owner_raw
        local provenance, recovery_enabled = parse_owner(parsed.owner_raw, player_name)
        parsed.provenance = provenance
        parsed.recovery_enabled = recovery_enabled
      end
    end

    local discipline = line:match("^This is an? ([%a]+) design%.$")
    if discipline then
      parsed.discipline = trim(discipline):lower()
      parsed.source_type = parsed.discipline
      parsed.metadata.discipline = parsed.discipline
    end

    local type_info = parse_type_line(line)
    if type_info then
      parsed.design_type = type_info.design_type
      parsed.metadata.design_type = type_info.design_type
      for commodity, qty in pairs(type_info.bom) do
        parsed.bom[commodity] = qty
      end
      if next(type_info.samples) then
        parsed.metadata.samples = type_info.samples
      end
      if type_info.per_item_fee_gold then
        parsed.per_item_fee_gold = type_info.per_item_fee_gold
      end
      if type_info.method then
        parsed.metadata.method = type_info.method
      end
      if type_info.aged then
        parsed.metadata.aged = type_info.aged
      end
      if type_info.sessions then
        parsed.metadata.sessions = type_info.sessions
      end
    end

    local gems_required = line:match("^This pattern requires%s+(%d+)%s+gems%.$")
    if gems_required then
      local qty = tonumber(gems_required)
      if qty and qty > 0 then
        parsed.bom.gems = qty
      end
    end

    if line:match("^This pattern requires%s+NO%s+gems%.$") then
      parsed.bom.gems = nil
    end

    if line:match("^Appearance %(short_desc%)$") then
      local short_desc = next_non_empty(lines, i + 1)
      if short_desc then
        parsed.short_desc = short_desc
      end
    end

    if line:match("^Generic$") then
      local generic_desc = collect_section(lines, i + 1)
      if generic_desc ~= "" then
        parsed.metadata.generic = generic_desc
        if not parsed.short_desc or parsed.short_desc == "" then
          parsed.short_desc = trim(generic_desc:match("([^\n]+)") or generic_desc)
        end
      end
    end

    if line:match("^In Vessel$") then
      local in_vessel = collect_section(lines, i + 1)
      if in_vessel ~= "" then
        parsed.metadata.in_vessel = in_vessel
      end
    end

    if line:match("^First Drunk Ideal$") then
      local first_drunk_ideal = collect_section(lines, i + 1)
      if first_drunk_ideal ~= "" then
        parsed.metadata.first_drunk_ideal = first_drunk_ideal
      end
    end

    if line:match("^First Drunk$") then
      local first_drunk_ideal = collect_section(lines, i + 1)
      if first_drunk_ideal ~= "" then
        parsed.metadata.first_drunk_ideal = first_drunk_ideal
      end
    end

    if line:match("^Third Drunk Ideal$") then
      local third_drunk_ideal = collect_section(lines, i + 1)
      if third_drunk_ideal ~= "" then
        parsed.metadata.third_drunk_ideal = third_drunk_ideal
      end
    end

    if line:match("^Third Drunk$") then
      local third_drunk_ideal = collect_section(lines, i + 1)
      if third_drunk_ideal ~= "" then
        parsed.metadata.third_drunk_ideal = third_drunk_ideal
      end
    end

    if line:match("^Nose Ideal$") then
      local nose_ideal = collect_section(lines, i + 1)
      if nose_ideal ~= "" then
        parsed.metadata.nose_ideal = nose_ideal
      end
    end

    if line:match("^Nose$") then
      local nose_ideal = collect_section(lines, i + 1)
      if nose_ideal ~= "" then
        parsed.metadata.nose_ideal = nose_ideal
      end
    end

    if line:match("^Taste Ideal$") then
      local taste_ideal = collect_section(lines, i + 1)
      if taste_ideal ~= "" then
        parsed.metadata.taste_ideal = taste_ideal
      end
    end

    if line:match("^First Eaten$") then
      local first_eaten = collect_section(lines, i + 1)
      if first_eaten ~= "" then
        parsed.metadata.first_eaten = first_eaten
      end
    end

    if line:match("^Third Eaten$") then
      local third_eaten = collect_section(lines, i + 1)
      if third_eaten ~= "" then
        parsed.metadata.third_eaten = third_eaten
      end
    end

    if line:match("^Smell$") then
      local smell = collect_section(lines, i + 1)
      if smell ~= "" then
        parsed.metadata.smell = smell
      end
    end

    if line:match("^Taste$") then
      local taste = collect_section(lines, i + 1)
      if taste ~= "" then
        parsed.metadata.taste = taste
      end
    end

    if line:match("^Dropped %(long_desc%)$") then
      local dropped_desc = collect_section(lines, i + 1)
      if dropped_desc ~= "" then
        parsed.metadata.dropped_desc = dropped_desc
      end
    end

    if line:match("^Examined %(extended_desc%)$") then
      local examined_desc = collect_section(lines, i + 1)
      if examined_desc ~= "" then
        parsed.metadata.examined_desc = examined_desc
      end
    end

    local months = line:match("^Months of usefulness left:%s*(.+)$")
    if months then
      parsed.metadata.months_usefulness = trim(months)
    end
  end

  if not parsed.alias_id then
    return nil, "parse failure: alias_id not found"
  end
  if not parsed.short_desc or parsed.short_desc == "" then
    return nil, "parse failure: short_desc is required"
  end

  if not parsed.source_type then
    parsed.source_type = parsed.design_type or "unknown"
  end

  if not parsed.provenance then
    local provenance, recovery_enabled = parse_owner(parsed.owner_raw or "", player_name)
    parsed.provenance = provenance
    parsed.recovery_enabled = recovery_enabled
  end

  return parsed
end

_G.AchaeadexLedger.Core.DesignDetailsParser = parser

return parser
