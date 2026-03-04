-- Passive capture for nds p <id> output blocks

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Mudlet = _G.AchaeadexLedger.Mudlet or {}

local capture = _G.AchaeadexLedger.Mudlet.DesignCapture or {}

local function get_parser()
  return _G.AchaeadexLedger and _G.AchaeadexLedger.Core and _G.AchaeadexLedger.Core.DesignDetailsParser
end

local function get_importer()
  return _G.AchaeadexLedger and _G.AchaeadexLedger.Core and _G.AchaeadexLedger.Core.DesignAutoImport
end

local function get_state()
  return _G.AchaeadexLedger and _G.AchaeadexLedger.Mudlet and _G.AchaeadexLedger.Mudlet.State
end

local function out_warning(message)
  local render = _G.AchaeadexLedger and _G.AchaeadexLedger.Mudlet and _G.AchaeadexLedger.Mudlet.Render
  if render and type(render.warning) == "function" then
    render.warning("WARNING: " .. tostring(message))
    return
  end
  if type(cecho) == "function" then
    cecho("AchaeadexLedger WARNING: " .. tostring(message) .. "\n")
  elseif type(echo) == "function" then
    echo("AchaeadexLedger WARNING: " .. tostring(message) .. "\n")
  end
end

local function out_info(message)
  local render = _G.AchaeadexLedger and _G.AchaeadexLedger.Mudlet and _G.AchaeadexLedger.Mudlet.Render
  if render and type(render.print) == "function" then
    render.print(tostring(message))
    return
  end
  if type(cecho) == "function" then
    cecho(tostring(message) .. "\n")
  elseif type(echo) == "function" then
    echo(tostring(message) .. "\n")
  end
end

local function now_seconds()
  if type(getEpoch) == "function" then
    local value = tonumber(getEpoch())
    if value then
      return value
    end
  end
  return os.time()
end

local function strip_ansi(line)
  local parser = get_parser()
  if parser and type(parser.strip_ansi) == "function" then
    return parser.strip_ansi(line)
  end
  line = tostring(line or "")
  return line:gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
end

local function trim(value)
  value = tostring(value or "")
  value = value:gsub("^%s+", "")
  value = value:gsub("%s+$", "")
  return value
end

local function start_block(line)
  capture.active = true
  capture.lines = {}
  capture.started_at = now_seconds()
  capture.line_count = 0
  if line ~= nil then
    table.insert(capture.lines, line)
    capture.line_count = 1
  end
end

local function reset_block()
  capture.active = false
  capture.lines = {}
  capture.started_at = nil
  capture.line_count = 0
end

local function finalize_block(reason)
  if not capture.active then
    return
  end

  local lines = capture.lines or {}
  reset_block()

  if #lines == 0 then
    return
  end

  local importer = get_importer()
  local state = get_state()
  if not importer or not state then
    return
  end

  local result, err = importer.parse_and_upsert(state, lines, {
    player_name = "Keneanung"
  })
  if not result then
    out_warning("design parse skipped: " .. tostring(err))
    return
  end

  if result.created then
    out_info("AchaeadexLedger: auto-imported design alias " .. tostring(result.alias_id) .. " -> " .. tostring(result.source_id))
  end

  for _, warning in ipairs(result.warnings or {}) do
    out_warning(warning)
  end

  if reason == "cutoff" then
    out_warning("design capture aborted after safety cutoff")
  end
end

function capture.process_line(raw_line)
  local cleaned = trim(strip_ansi(raw_line))
  local starts_block = cleaned:match("^Design(%d+)%s+Designer:") ~= nil

  if capture.active and type(isPrompt) == "function" and isPrompt() then
    finalize_block("prompt")
    return
  end

  if not capture.active then
    if starts_block then
      start_block(cleaned)
    end
    return
  end

  if starts_block then
    finalize_block("new-block")
    start_block(cleaned)
    return
  end

  table.insert(capture.lines, cleaned)
  capture.line_count = (capture.line_count or 0) + 1

  if capture.line_count > (capture.max_lines or 240) then
    finalize_block("cutoff")
    return
  end

  if capture.started_at and (now_seconds() - capture.started_at) > (capture.max_seconds or 15) then
    finalize_block("cutoff")
  end
end

function capture.start()
  capture.max_lines = capture.max_lines or 240
  capture.max_seconds = capture.max_seconds or 15
  capture.active = false
  capture.lines = {}
end

function capture.stop()
  reset_block()
end

_G.AchaeadexLedger.Mudlet.DesignCapture = capture

return capture
