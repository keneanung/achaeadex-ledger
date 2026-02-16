-- Minimal JSON encode/decode for event payloads

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local json = _G.AchaeadexLedger.Core.Json or {}

local function escape_string(value)
  value = value:gsub("\\", "\\\\")
  value = value:gsub("\"", "\\\"")
  value = value:gsub("\n", "\\n")
  value = value:gsub("\r", "\\r")
  value = value:gsub("\t", "\\t")
  return value
end

function json.encode(value)
  local value_type = type(value)
  if value_type == "table" then
    local is_array = true
    local max_index = 0
    for k, _ in pairs(value) do
      if type(k) ~= "number" then
        is_array = false
        break
      end
      if k > max_index then
        max_index = k
      end
    end

    if is_array then
      local parts = {}
      for i = 1, max_index do
        table.insert(parts, json.encode(value[i]))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end

    local parts = {}
    for k, v in pairs(value) do
      local key = "\"" .. escape_string(tostring(k)) .. "\""
      local encoded = json.encode(v)
      table.insert(parts, key .. ":" .. encoded)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif value_type == "string" then
    return "\"" .. escape_string(value) .. "\""
  elseif value_type == "number" then
    return tostring(value)
  elseif value_type == "boolean" then
    return value and "true" or "false"
  elseif value == nil then
    return "null"
  end

  return "\"" .. escape_string(tostring(value)) .. "\""
end

local function decode_error(message, idx)
  error("JSON decode error at position " .. idx .. ": " .. message)
end

local function skip_whitespace(str, idx)
  while true do
    local char = str:sub(idx, idx)
    if char == "" then
      return idx
    end
    if char ~= " " and char ~= "\n" and char ~= "\r" and char ~= "\t" then
      return idx
    end
    idx = idx + 1
  end
end

local function parse_string(str, idx)
  local result = {}
  idx = idx + 1
  while true do
    local char = str:sub(idx, idx)
    if char == "" then
      decode_error("unterminated string", idx)
    end
    if char == "\"" then
      return table.concat(result), idx + 1
    end
    if char == "\\" then
      local next_char = str:sub(idx + 1, idx + 1)
      if next_char == "\"" or next_char == "\\" or next_char == "/" then
        table.insert(result, next_char)
        idx = idx + 2
      elseif next_char == "b" then
        table.insert(result, "\b")
        idx = idx + 2
      elseif next_char == "f" then
        table.insert(result, "\f")
        idx = idx + 2
      elseif next_char == "n" then
        table.insert(result, "\n")
        idx = idx + 2
      elseif next_char == "r" then
        table.insert(result, "\r")
        idx = idx + 2
      elseif next_char == "t" then
        table.insert(result, "\t")
        idx = idx + 2
      else
        decode_error("invalid escape", idx)
      end
    else
      table.insert(result, char)
      idx = idx + 1
    end
  end
end

local function parse_number(str, idx)
  local start_idx = idx
  local char = str:sub(idx, idx)
  if char == "-" then
    idx = idx + 1
  end
  while true do
    char = str:sub(idx, idx)
    if char:match("%d") then
      idx = idx + 1
    else
      break
    end
  end
  if str:sub(idx, idx) == "." then
    idx = idx + 1
    while true do
      char = str:sub(idx, idx)
      if char:match("%d") then
        idx = idx + 1
      else
        break
      end
    end
  end
  local num = tonumber(str:sub(start_idx, idx - 1))
  if num == nil then
    decode_error("invalid number", start_idx)
  end
  return num, idx
end

local function parse_value(str, idx)
  idx = skip_whitespace(str, idx)
  local char = str:sub(idx, idx)
  if char == "" then
    decode_error("unexpected end of input", idx)
  end
  if char == "{" then
    local obj = {}
    idx = skip_whitespace(str, idx + 1)
    if str:sub(idx, idx) == "}" then
      return obj, idx + 1
    end
    while true do
      idx = skip_whitespace(str, idx)
      if str:sub(idx, idx) ~= "\"" then
        decode_error("expected string key", idx)
      end
      local key
      key, idx = parse_string(str, idx)
      idx = skip_whitespace(str, idx)
      if str:sub(idx, idx) ~= ":" then
        decode_error("expected ':'", idx)
      end
      idx = idx + 1
      local value
      value, idx = parse_value(str, idx)
      obj[key] = value
      idx = skip_whitespace(str, idx)
      local next_char = str:sub(idx, idx)
      if next_char == "}" then
        return obj, idx + 1
      end
      if next_char ~= "," then
        decode_error("expected ',' or '}'", idx)
      end
      idx = idx + 1
    end
  elseif char == "[" then
    local arr = {}
    idx = skip_whitespace(str, idx + 1)
    if str:sub(idx, idx) == "]" then
      return arr, idx + 1
    end
    local i = 1
    while true do
      local value
      value, idx = parse_value(str, idx)
      arr[i] = value
      i = i + 1
      idx = skip_whitespace(str, idx)
      local next_char = str:sub(idx, idx)
      if next_char == "]" then
        return arr, idx + 1
      end
      if next_char ~= "," then
        decode_error("expected ',' or ']'", idx)
      end
      idx = idx + 1
    end
  elseif char == "\"" then
    return parse_string(str, idx)
  elseif char == "t" and str:sub(idx, idx + 3) == "true" then
    return true, idx + 4
  elseif char == "f" and str:sub(idx, idx + 4) == "false" then
    return false, idx + 5
  elseif char == "n" and str:sub(idx, idx + 3) == "null" then
    return nil, idx + 4
  else
    return parse_number(str, idx)
  end
end

function json.decode(str)
  if str == nil or str == "" then
    return nil
  end
  local value, idx = parse_value(str, 1)
  idx = skip_whitespace(str, idx)
  if idx <= #str then
    decode_error("trailing characters", idx)
  end
  return value
end

_G.AchaeadexLedger.Core.Json = json

return json
