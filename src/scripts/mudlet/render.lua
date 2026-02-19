-- Mudlet rendering helpers for Achaeadex Ledger

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Mudlet = _G.AchaeadexLedger.Mudlet or {}

local render = _G.AchaeadexLedger.Mudlet.Render or {}

local function get_config()
  return _G.AchaeadexLedger.Mudlet.Config
end

local function get_width()
  if type(getWindowWrap) == "function" then
    local width = tonumber(getWindowWrap())
    if width and width > 0 then
      return width
    end
  end
  return 80
end

local function use_color()
  local config = get_config()
  if not config then
    return false
  end
  return config.is_color_enabled and config.is_color_enabled() or false
end

local palette = {
  header = "<cyan>",
  label = "<white>",
  value = "<white>",
  warning = "<yellow>",
  error = "<red>",
  divider = "<blue>"
}

local function can_color()
  return use_color() and type(cecho) == "function"
end

local function escape_tags(text)
  return tostring(text or "")
end

local function out_line(text, force_plain)
  local value = tostring(text or "")
  if force_plain or not can_color() then
    if type(echo) == "function" then
      echo(value .. "\n")
    elseif type(print) == "function" then
      print(value)
    end
    return
  end

  local tag = palette.value or ""
  if tag ~= "" then
    cecho(tag)
  end
  if type(echo) == "function" then
    echo(value)
    cecho("<reset>\n")
  elseif type(print) == "function" then
    print(value)
  end
end

local function out_line_colored(text, style)
  local value = tostring(text or "")
  if not can_color() then
    out_line(value, true)
    return
  end

  local tag = palette[style] or ""
  if tag ~= "" then
    cecho(tag)
  end

  if type(echo) == "function" then
    echo(value)
    cecho("<reset>\n")
  elseif type(print) == "function" then
    print(value)
  end
end

local function pad_right(text, width)
  local s = tostring(text or "")
  local len = #s
  if len >= width then
    return s
  end
  return s .. string.rep(" ", width - len)
end

local function pad_left(text, width)
  local s = tostring(text or "")
  local len = #s
  if len >= width then
    return s
  end
  return string.rep(" ", width - len) .. s
end

local function wrap(text, width)
  local str = tostring(text or "")
  if width <= 0 then
    return { str }
  end
  local lines = {}
  for line in str:gmatch("[^\n]+") do
    local current = ""
    for word in line:gmatch("%S+") do
      if current == "" then
        current = word
      elseif #current + 1 + #word <= width then
        current = current .. " " .. word
      else
        table.insert(lines, current)
        current = word
      end
    end
    table.insert(lines, current)
  end
  if #lines == 0 then
    table.insert(lines, "")
  end
  return lines
end

local function format_gold(n)
  local value = tonumber(n) or 0
  local sign = value < 0 and "-" or ""
  local str = tostring(math.abs(math.floor(value)))
  local result = str
  while true do
    result, count = result:gsub("^(%d+)(%d%d%d)", "%1,%2")
    if count == 0 then
      break
    end
  end
  return sign .. result
end

local function compute_widths(columns, width)
  local total_separators = (#columns - 1) * 3
  local widths = {}
  local fixed_total = 0
  local flex_cols = {}

  for i, col in ipairs(columns) do
    local min_width = col.min or #tostring(col.label or "")
    if col.width then
      widths[i] = col.width
      fixed_total = fixed_total + col.width
    else
      widths[i] = min_width
      fixed_total = fixed_total + min_width
      table.insert(flex_cols, i)
    end
  end

  local remaining = width - fixed_total - total_separators
  local index = 1
  while remaining > 0 and #flex_cols > 0 do
    local col_idx = flex_cols[index]
    widths[col_idx] = widths[col_idx] + 1
    remaining = remaining - 1
    index = index + 1
    if index > #flex_cols then
      index = 1
    end
  end

  return widths
end

function render.format_gold(n)
  return format_gold(n)
end

function render.section(title)
  out_line_colored(title, "header")
  out_line_colored(string.rep("-", get_width()), "divider")
end

function render.kv_block(rows)
  local max_label = 0
  for _, row in ipairs(rows) do
    local label = tostring(row.label or "")
    if #label > max_label then
      max_label = #label
    end
  end
  for _, row in ipairs(rows) do
    local label = pad_right(tostring(row.label or ""), max_label)
    local value = tostring(row.value or "")

    if can_color() and type(echo) == "function" then
      cecho(palette.label)
      echo(label .. ": ")
      cecho(palette.value)
      echo(escape_tags(value))
      cecho("<reset>\n")
    else
      out_line(label .. ": " .. escape_tags(value), true)
    end
  end
end

function render.table(rows, columns)
  local width = get_width()
  local widths = compute_widths(columns, width)

  local header_cells = {}
  for i, col in ipairs(columns) do
    local label = tostring(col.label or col.key or "")
    header_cells[i] = pad_right(label, widths[i])
  end
  out_line_colored(table.concat(header_cells, " | "), "label")
  out_line_colored(string.rep("-", width), "divider")

  for _, row in ipairs(rows) do
    local cell_lines = {}
    local max_lines = 1

    for i, col in ipairs(columns) do
      local value = row[col.key]
      local text = value == nil and "" or tostring(value)
      if not col.raw then
        text = escape_tags(text)
      end
      local lines
      if col.nowrap then
        lines = { text }
      else
        lines = wrap(text, widths[i])
      end
      cell_lines[i] = lines
      if #lines > max_lines then
        max_lines = #lines
      end
    end

    for line_idx = 1, max_lines do
      local parts = {}
      for i, col in ipairs(columns) do
        local line = cell_lines[i][line_idx] or ""
        if col.align == "right" then
          parts[i] = pad_left(line, widths[i])
        else
          parts[i] = pad_right(line, widths[i])
        end
      end
      out_line_colored(table.concat(parts, " | "), "value")
    end
  end
end

function render.warning(text)
  local value = tostring(text or "")
  out_line_colored(value, "warning"), has_angle(value)
end

function render.error(text)
  local value = tostring(text or "")
  out_line_colored(value, "error"), has_angle(value)
end

function render.print(text)
  local value = tostring(text or "")
  out_line_colored(escape_tags(value), "value")
end

function render.print_raw(text)
  out_line(tostring(text or ""))
end

function render.wrap(text, width)
  return wrap(text, width)
end

function render.pad_right(text, width)
  return pad_right(text, width)
end

function render.escape(text)
  return escape_tags(text)
end

_G.AchaeadexLedger.Mudlet.Render = render

return render
