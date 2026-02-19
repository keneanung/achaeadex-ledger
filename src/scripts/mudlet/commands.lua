-- Mudlet command handlers for Achaeadex Ledger

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Mudlet = _G.AchaeadexLedger.Mudlet or {}

local commands = _G.AchaeadexLedger.Mudlet.Commands or {}

local function get_renderer()
  return _G.AchaeadexLedger.Mudlet.Render
end

local function out(msg)
  local render = get_renderer()
  if render and render.print then
    render.print(msg)
    return
  end
  if type(echo) == "function" then
    echo(msg .. "\n")
  elseif type(print) == "function" then
    print(msg)
  end
end

local function out_plain(msg)
  out(msg)
end

local function error_out(msg)
  local render = get_renderer()
  if render and render.error then
    render.error("AchaeadexLedger: " .. msg)
    return
  end
  out("AchaeadexLedger: " .. msg)
end

local function get_state()
  local state = _G.AchaeadexLedger.Mudlet.State
  if not state then
    error("AchaeadexLedger state not initialized")
  end
  return state
end

local function tokenize(input)
  local tokens = {}
  local i = 1
  while i <= #input do
    local char = input:sub(i, i)
    if char:match("%s") then
      i = i + 1
    elseif char == "\"" or char == "'" then
      local quote = char
      local start = i + 1
      local j = start
      while j <= #input and input:sub(j, j) ~= quote do
        j = j + 1
      end
      table.insert(tokens, input:sub(start, j - 1))
      i = j + 1
    else
      local start = i
      local j = i
      while j <= #input and not input:sub(j, j):match("%s") do
        j = j + 1
      end
      table.insert(tokens, input:sub(start, j - 1))
      i = j
    end
  end
  return tokens
end

local function parse_kv_list(raw)
  local result = {}
  if not raw or raw == "" then
    return result
  end
  for pair in string.gmatch(raw, "[^,]+") do
    local key, value = pair:match("^([^=]+)=([^=]+)$")
    if key and value then
      result[key] = tonumber(value) or value
    end
  end
  return result
end

local function validate_materials(materials)
  for commodity, qty in pairs(materials or {}) do
    if type(qty) ~= "number" or qty <= 0 then
      return false, "Invalid material qty for " .. tostring(commodity)
    end
  end
  return true
end

local function parse_flags(tokens, start_index)
  local args = {}
  local flags = {}
  local i = start_index or 1
  while i <= #tokens do
    local token = tokens[i]
    if token:sub(1, 2) == "--" then
      local key = token:sub(3)
      local value = tokens[i + 1]
      if not value or value:sub(1, 2) == "--" then
        flags[key] = true
        i = i + 1
      else
        flags[key] = value
        i = i + 2
      end
    else
      table.insert(args, token)
      i = i + 1
    end
  end
  return args, flags
end

local function warn_lines(report, state, time_cost_per_hour)
  local warnings = {}

  local events = state.event_store and state.event_store:read_all() or {}
  for _, event in ipairs(events) do
    if event.event_type == "OPENING_INVENTORY" then
      table.insert(warnings, "WARNING: Opening inventory uses MtM")
      break
    end
  end

  if (time_cost_per_hour or 0) == 0 then
    table.insert(warnings, "WARNING: Time cost = 0")
  end

  if report.design_remaining and report.design_remaining > 0 then
    table.insert(warnings, "WARNING: Design capital remaining > 0")
  end
  if report.pattern_remaining and report.pattern_remaining > 0 then
    table.insert(warnings, "WARNING: Pattern capital remaining > 0")
  end

  return warnings
end

local function get_game_time()
  if not gmcp or not gmcp.IRE or not gmcp.IRE.Time or not gmcp.IRE.Time.List then
    return nil
  end

  local time = gmcp.IRE.Time.List
  local year = tonumber(time.year)
  if not year then
    return nil
  end

  local game_time = { year = year }
  local month = tonumber(time.mon) or tonumber(time.month)
  local day = tonumber(time.day)
  local hour = tonumber(time.hour)
  local minute = tonumber(time.minute) or tonumber(time.min)

  if month then
    game_time.month = month
  end
  if day then
    game_time.day = day
  end
  if hour then
    game_time.hour = hour
  end
  if minute then
    game_time.minute = minute
  end

  return game_time
end

local function resolve_design_id_for_sim(state, design_id)
  if state.designs and state.designs[design_id] then
    return design_id
  end
  local alias = state.design_aliases and state.design_aliases[design_id] or nil
  if alias and alias.design_id then
    return alias.design_id
  end
  return design_id
end

local function compute_op_cost_from_bom(state, design)
  if not design or not design.bom then
    return nil
  end

  local inventory = _G.AchaeadexLedger.Core.Inventory
  if not inventory then
    return nil
  end

  local total = 0
  for commodity, qty in pairs(design.bom) do
    local unit_cost = inventory.get_unit_cost(state.inventory, commodity)
    total = total + (unit_cost * qty)
  end

  return total + (design.per_item_fee_gold or 0)
end

local function render_totals(render, totals)
  local fmt = render.format_gold or tostring
  render.kv_block({
    { label = "Revenue", value = fmt(totals.revenue or 0) },
    { label = "Operational cost", value = fmt(totals.operational_cost or 0) },
    { label = "Operational profit", value = fmt(totals.operational_profit or 0) },
    { label = "Applied to design capital", value = fmt(totals.applied_to_design_capital or 0) },
    { label = "Applied to pattern capital", value = fmt(totals.applied_to_pattern_capital or 0) },
    { label = "True profit", value = fmt(totals.true_profit or 0) }
  })
end

local function render_holdings(render, holdings)
  if not holdings then
    return
  end
  local fmt = render.format_gold or tostring
  local rows = {}
  if holdings.inventory_value ~= nil then
    table.insert(rows, { label = "Inventory value (WAC)", value = fmt(holdings.inventory_value) })
  end
  if holdings.wip_value ~= nil then
    table.insert(rows, { label = "WIP value", value = fmt(holdings.wip_value) })
  end
  if holdings.unsold_items_value ~= nil then
    table.insert(rows, { label = "Unsold crafted items value", value = fmt(holdings.unsold_items_value) })
  end
  if #rows > 0 then
    render.kv_block(rows)
  end
end

local function render_warnings(render, warnings)
  if not warnings or #warnings == 0 then
    return
  end
  render.section("Warnings")
  for _, warning in ipairs(warnings) do
    render.warning(warning)
  end
end

local help_topics = {
  inv = {
    title = "Inventory",
    purpose = "Initialize inventory with MtM opening cost.",
    commands = {
      {
        usage = "adex inv init <commodity> <qty> <unit_cost>",
        example = "adex inv init leather 10 20"
      }
    }
  },
  broker = {
    title = "Broker",
    purpose = "Broker buy inventory at price.",
    commands = {
      {
        usage = "adex broker buy <commodity> <qty> <unit_cost>",
        example = "adex broker buy leather 5 40"
      }
    }
  },
  pattern = {
    title = "Pattern",
    purpose = "Activate or deactivate pattern pools.",
    commands = {
      {
        usage = "adex pattern activate [<pool_id>] <type> <name> <capital>",
        example = "adex pattern activate shirt \"Basic Shirts\" 150"
      },
      {
        usage = "adex pattern deactivate <pool_id>",
        example = "adex pattern deactivate P-20260215-0001"
      }
    }
  },
  design = {
    title = "Design",
    purpose = "Create designs, aliases, costs, and BOM recipes.",
    commands = {
      {
        usage = "adex design start [<design_id>] <type> <name> [--provenance private|public|organization] [--recovery 0|1]",
        example = "adex design start shirt \"Midnight Tunic\" --provenance private"
      },
      {
        usage = "adex design update <design_id> [--type <type>] [--name <name>] [--provenance private|public|organization] [--recovery 0|1]",
        example = "adex design update D1 --type shirt --name \"Midnight Tunic\" --provenance private"
      },
      {
        usage = "adex design alias add <design_id> <alias_id> <pre_final|final|other> [--active 0|1]",
        example = "adex design alias add D1 9876 final --active 1"
      },
      {
        usage = "adex design bom set <design_id> --materials k=v,...",
        example = "adex design bom set D1 --materials leather=2"
      },
      {
        usage = "adex design bom show <design_id>",
        example = "adex design bom show D1"
      },
      {
        usage = "adex design appearance map <design_id> <appearance_key>",
        example = "adex design appearance map D1 \"simple black shirt\""
      },
      {
        usage = "adex design cost <design_id> <amount> <kind>",
        example = "adex design cost D1 500 submission"
      },
      {
        usage = "adex design set-fee <design_id> <amount>",
        example = "adex design set-fee D1 15"
      }
    }
  },
  order = {
    title = "Order",
    purpose = "Group sales into orders.",
    commands = {
      {
        usage = "adex order create [<order_id>] [--customer <name>] [--note <text>]",
        example = "adex order create --customer \"Ada\""
      },
      {
        usage = "adex order add <order_id> <sale_id>",
        example = "adex order add O-20260215-0001 S-20260215-0001"
      },
      {
        usage = "adex order close <order_id>",
        example = "adex order close O-20260215-0001"
      }
    }
  },
  process = {
    title = "Process",
    purpose = "Run immediate or deferred processes.",
    commands = {
      {
        usage = "adex process apply <process_id> --inputs k=v,... --outputs k=v,... [--fee <gold>] [--note <text>]",
        example = "adex process apply refine --inputs fibre=4,coal=4 --outputs cloth=4"
      },
      {
        usage = "adex process start [<process_instance_id>] <process_id> [--inputs k=v,...] [--fee <gold>] [--note <text>]",
        example = "adex process start smelt --inputs ore=5"
      },
      {
        usage = "adex process add-inputs <process_instance_id> --inputs k=v,... [--note <text>]",
        example = "adex process add-inputs X-20260215-0001 --inputs flux=2"
      },
      {
        usage = "adex process add-fee <process_instance_id> --fee <gold> [--note <text>]",
        example = "adex process add-fee X-20260215-0001 --fee 4"
      },
      {
        usage = "adex process complete <process_instance_id> --outputs k=v,... [--note <text>]",
        example = "adex process complete X-20260215-0001 --outputs metal=3"
      },
      {
        usage = "adex process abort <process_instance_id> --returned k=v,... --lost k=v,... [--outputs k=v,...] [--note <text>]",
        example = "adex process abort X-20260215-0001 --returned ore=1 --lost ore=4"
      }
    }
  },
  craft = {
    title = "Craft",
    purpose = "Record crafted items with materials, BOM, or manual cost (unknown designs create stubs).",
    commands = {
      {
        usage = "adex craft [<item_id>] [--materials k=v,...] [--appearance <appearance_key>] [--design <design_id>] [--time <hours>] [--cost <gold>]",
        example = "adex craft D1 --materials leather=2 --appearance \"simple black shirt\""
      },
      {
        usage = "adex craft resolve <item_id> <design_id>",
        example = "adex craft resolve I-20260215-0001 D1"
      }
    }
  },
  sell = {
    title = "Sell",
    purpose = "Record sale and apply recovery waterfall.",
    commands = {
      {
        usage = "adex sell [<sale_id>] <item_id> <sale_price>",
        example = "adex sell I-20260215-0001 120"
      }
    }
  },
  report = {
    title = "Report",
    purpose = "Generate reports.",
    commands = {
      {
        usage = "adex report overall",
        example = "adex report overall"
      },
      {
        usage = "adex report year <year|current>",
        example = "adex report year current"
      },
      {
        usage = "adex report order <order_id>",
        example = "adex report order O-20260215-0001"
      },
      {
        usage = "adex report design <design_id> [--items] [--orders] [--year <year>]",
        example = "adex report design D1 --items"
      },
      {
        usage = "adex report item <item_id>",
        example = "adex report item I-20260215-0001"
      }
    }
  },
  list = {
    title = "List",
    purpose = "List entities for discovery.",
    commands = {
      {
        usage = "adex list commodities [--name <substring>] [--sort name|qty|wac]",
        example = "adex list commodities --sort qty"
      },
      {
        usage = "adex list patterns [--type <pattern_type>] [--status active|closed]",
        example = "adex list patterns --status active"
      },
      {
        usage = "adex list designs [--type <design_type>] [--provenance private|public|organization] [--recovery 0|1]",
        example = "adex list designs --provenance private"
      },
      {
        usage = "adex list items [--design <design_id>] [--sold 0|1] [--unresolved 1]",
        example = "adex list items --unresolved 1"
      },
      {
        usage = "adex list sales [--year <year>] [--order <order_id>]",
        example = "adex list sales --year 650"
      },
      {
        usage = "adex list orders",
        example = "adex list orders"
      },
      {
        usage = "adex list processes [--status in_flight|completed|aborted] [--process <process_id>]",
        example = "adex list processes --status in_flight"
      }
    }
  },
  sim = {
    title = "Sim",
    purpose = "Simulator for price/units needed to recover capital (uses BOM + fee when available).",
    commands = {
      {
        usage = "adex sim price <design_id> <price> [--op-cost <gold>]",
        example = "adex sim price D1 200"
      },
      {
        usage = "adex sim units <design_id> <units> [--op-cost <gold>]",
        example = "adex sim units D1 41"
      }
    }
  },
  config = {
    title = "Config",
    purpose = "Configure output options.",
    commands = {
      {
        usage = "adex config set color on|off",
        example = "adex config set color off"
      },
      {
        usage = "adex config set time-cost <gold_per_hour>",
        example = "adex config set time-cost 25"
      },
      {
        usage = "adex config get color",
        example = "adex config get color"
      },
      {
        usage = "adex config get time-cost",
        example = "adex config get time-cost"
      }
    }
  },
  maintenance = {
    title = "Maintenance",
    purpose = "Rebuild projections or show DB stats.",
    commands = {
      {
        usage = "adex maintenance stats",
        example = "adex maintenance stats"
      },
      {
        usage = "adex maintenance rebuild",
        example = "adex maintenance rebuild"
      }
    }
  }
}

function commands.help(topic)
  local render = get_renderer()
  if topic and help_topics[topic] then
    local entry = help_topics[topic]
    if render and render.section and render.table then
      render.section("Help: " .. topic)
      render.print(entry.purpose)
      for index, command in ipairs(entry.commands or {}) do
        render.section("Command " .. tostring(index))
        render.kv_block({
          { label = "Usage", value = command.usage },
          { label = "Example", value = command.example }
        })
      end
      return
    end
    out_plain("AchaeadexLedger help: " .. topic)
    out_plain("  " .. entry.purpose)
    for _, command in ipairs(entry.commands or {}) do
      out_plain("  Usage: " .. command.usage)
      out_plain("  Example: " .. command.example)
    end
    return
  end

  if render and render.section and render.kv_block and render.table then
    render.section("AchaeadexLedger Help")
    render.print("Craft accounting with strict WAC and recovery.")
    render.section("Glossary")
    render.kv_block({
      { label = "design capital", value = "gold spent to create a design, recovered via sales" },
      { label = "pattern pool", value = "shared capital from pattern activation by type" },
      { label = "operational cost", value = "material WAC + fees + time cost per item" },
      { label = "true profit", value = "profit after design and pattern capital recovery" }
    })

    render.section("Topics")
    local order = { "inv", "broker", "pattern", "design", "order", "process", "craft", "sell", "report", "list", "sim", "config", "maintenance" }
    local rows = {}
    for _, topic_name in ipairs(order) do
      local entry = help_topics[topic_name]
      if entry then
        table.insert(rows, {
          topic = topic_name,
          purpose = entry.purpose
        })
      end
    end
    render.table(rows, {
      { key = "topic", label = "Topic", nowrap = true, min = 8 },
      { key = "purpose", label = "Purpose", min = 20 }
    })
    render.print("Use: adex help <topic> for focused help.")
    return
  end

  out_plain("AchaeadexLedger: craft accounting with strict WAC and recovery.")
  out_plain("Glossary:")
  out_plain("  design capital: gold spent to create a design, recovered via sales")
  out_plain("  pattern pool: shared capital from pattern activation by type")
  out_plain("  operational cost: material WAC + fees + time cost per item")
  out_plain("  true profit: profit after design and pattern capital recovery")
  out_plain("Commands:")
  local order = { "inv", "broker", "pattern", "design", "order", "process", "craft", "sell", "report", "list", "sim", "config", "maintenance" }
  for _, topic_name in ipairs(order) do
    local entry = help_topics[topic_name]
    if entry then
      out_plain("  " .. topic_name .. ": " .. entry.purpose)
      for _, command in ipairs(entry.commands or {}) do
        out_plain("    Usage: " .. command.usage)
        out_plain("    Example: " .. command.example)
      end
    end
  end
  out_plain("Use: adex help <topic> for focused help.")
end

function commands.handle(input)
  local ledger = _G.AchaeadexLedger.Core.Ledger
  local simulator = _G.AchaeadexLedger.Core.Simulator
  local json = _G.AchaeadexLedger.Core.Json
  local id_generator = _G.AchaeadexLedger.Core.IdGenerator
  local listings = _G.AchaeadexLedger.Core.Listings
  local render = _G.AchaeadexLedger.Mudlet.Render
  local config = _G.AchaeadexLedger.Mudlet.Config

  if not ledger or not simulator or not json or not id_generator or not listings or not render or not config then
    error_out("core modules not loaded")
    return
  end

  if not input or input == "" then
    commands.help()
    return
  end

  local tokens = tokenize(input)
  local cmd = tokens[1]
  if cmd == "help" then
    commands.help(tokens[2])
    return
  end

  if cmd == "config" and tokens[2] == "set" and tokens[3] == "color" then
    local value = tokens[4]
    if value ~= "on" and value ~= "off" then
      error_out("usage: adex config set color on|off")
      return
    end
    config.set("color", value)
    out("OK")
    return
  end

  if cmd == "config" and tokens[2] == "set" and tokens[3] == "time-cost" then
    local value = tonumber(tokens[4])
    if value == nil or value < 0 then
      error_out("usage: adex config set time-cost <gold_per_hour>")
      return
    end
    config.set("time_cost_per_hour", math.floor(value))
    out("OK")
    return
  end

  if cmd == "config" and tokens[2] == "get" and tokens[3] == "color" then
    out("color: " .. tostring(config.get("color")))
    return
  end

  if cmd == "config" and tokens[2] == "get" and tokens[3] == "time-cost" then
    local value = config.get_time_cost_per_hour and config.get_time_cost_per_hour() or config.get("time_cost_per_hour") or 0
    out("time_cost_per_hour: " .. tostring(value))
    return
  end

  local state = get_state()

  if cmd == "maintenance" and tokens[2] == "stats" then
    local store = _G.AchaeadexLedger.Mudlet.EventStore
    if not store or type(store.stats) ~= "function" then
      error_out("event store does not support stats")
      return
    end
    local stats = store:stats()
    render.section("Maintenance Stats")
    render.kv_block({
      { label = "Ledger events", value = tostring(stats.event_count or 0) },
      { label = "Last event id", value = tostring(stats.last_event_id or 0) },
      { label = "DB size (bytes)", value = tostring(stats.db_size_bytes or 0) }
    })
    return
  end

  if cmd == "maintenance" and tokens[2] == "rebuild" then
    local store = _G.AchaeadexLedger.Mudlet.EventStore
    if not store or type(store.rebuild_projections) ~= "function" then
      error_out("event store does not support rebuild")
      return
    end
    local counts = store:rebuild_projections()
    local fresh_state = ledger.new(store)
    local events = store:read_all()
    for _, event in ipairs(events) do
      local ok, err = pcall(ledger.apply_event, fresh_state, event)
      if not ok then
        error_out("rebuild failed applying event " .. tostring(event.id) .. ": " .. tostring(err))
        return
      end
    end
    _G.AchaeadexLedger.Mudlet.State = fresh_state
    render.section("Maintenance Rebuild")
    render.kv_block({
      { label = "Designs", value = tostring(counts.designs or 0) },
      { label = "Pattern pools", value = tostring(counts.pattern_pools or 0) },
      { label = "Crafted items", value = tostring(counts.crafted_items or 0) },
      { label = "Sales", value = tostring(counts.sales or 0) },
      { label = "Orders", value = tostring(counts.orders or 0) },
      { label = "Order sales", value = tostring(counts.order_sales or 0) },
      { label = "Process instances", value = tostring(counts.process_instances or 0) },
      { label = "Design aliases", value = tostring(counts.design_id_aliases or 0) },
      { label = "Appearance aliases", value = tostring(counts.design_appearance_aliases or 0) }
    })
    return
  end

  if cmd == "inv" and tokens[2] == "init" then
    local commodity = tokens[3]
    local qty = tonumber(tokens[4])
    local unit_cost = tonumber(tokens[5])
    if not commodity or not qty or not unit_cost then
      error_out("usage: adex inv init <commodity> <qty> <unit_cost>")
      return
    end
    ledger.apply_opening_inventory(state, commodity, qty, unit_cost)
    out("OK")
    return
  end

  if cmd == "broker" and tokens[2] == "buy" then
    local commodity = tokens[3]
    local qty = tonumber(tokens[4])
    local unit_cost = tonumber(tokens[5])
    if not commodity or not qty or not unit_cost then
      error_out("usage: adex broker buy <commodity> <qty> <unit_cost>")
      return
    end
    ledger.apply_broker_buy(state, commodity, qty, unit_cost)
    out("OK")
    return
  end

  if cmd == "pattern" and tokens[2] == "activate" then
    local args, flags = parse_flags(tokens, 3)
    local pool_id = nil
    local pattern_type = nil
    local name = nil
    local capital = nil

    if #args == 4 then
      pool_id = args[1]
      pattern_type = args[2]
      name = args[3]
      capital = tonumber(args[4])
    elseif #args == 3 then
      pattern_type = args[1]
      name = args[2]
      capital = tonumber(args[3])
    end

    if not pattern_type or not name or not capital then
      error_out("usage: adex pattern activate [<pool_id>] <type> <name> <capital>")
      return
    end

    if not pool_id then
      pool_id = id_generator.generate("P", function(id)
        return state.pattern_pools[id] ~= nil
      end)
      out("created_id: " .. tostring(pool_id))
    end

    ledger.apply_pattern_activate(state, pool_id, pattern_type, name, capital)
    out("OK")
    return
  end

  if cmd == "pattern" and tokens[2] == "deactivate" then
    local pool_id = tokens[3]
    if not pool_id then
      error_out("usage: adex pattern deactivate <pool_id>")
      return
    end
    ledger.apply_pattern_deactivate(state, pool_id)
    out("OK")
    return
  end

  if cmd == "design" and tokens[2] == "start" then
    local args, flags = parse_flags(tokens, 3)
    local design_id = nil
    local design_type = nil
    local name = nil

    if #args == 3 then
      design_id = args[1]
      design_type = args[2]
      name = args[3]
    elseif #args == 2 then
      design_type = args[1]
      name = args[2]
    end
    local provenance = flags.provenance
    local recovery = flags.recovery and tonumber(flags.recovery) or nil

    if not design_type or not name then
      error_out("usage: adex design start [<design_id>] <type> <name> [--provenance private|public|organization] [--recovery 0|1]")
      return
    end

    if not design_id then
      design_id = id_generator.generate("D", function(id)
        return state.designs[id] ~= nil
      end)
      out("created_id: " .. tostring(design_id))
    end

    ledger.apply_design_start(state, design_id, design_type, name, provenance, recovery)
    out("OK")
    return
  end

  if cmd == "design" and tokens[2] == "update" then
    local design_id = tokens[3]
    local args, flags = parse_flags(tokens, 4)
    if not design_id then
      error_out("usage: adex design update <design_id> [--type <type>] [--name <name>] [--provenance private|public|organization] [--recovery 0|1]")
      return
    end

    local design_type = flags.type
    local name = flags.name
    local provenance = flags.provenance
    local recovery = flags.recovery and tonumber(flags.recovery) or nil
    if recovery ~= nil and recovery ~= 0 and recovery ~= 1 then
      error_out("usage: adex design update <design_id> [--type <type>] [--name <name>] [--provenance private|public|organization] [--recovery 0|1]")
      return
    end

    ledger.apply_design_update(state, design_id, {
      design_type = design_type,
      name = name,
      provenance = provenance,
      recovery_enabled = recovery
    })
    out("OK")
    return
  end

  if cmd == "design" and tokens[2] == "alias" and tokens[3] == "add" then
    local design_id = tokens[4]
    local alias_id = tokens[5]
    local alias_kind = tokens[6]
    local args, flags = parse_flags(tokens, 7)
    local active = flags.active and tonumber(flags.active) or 1

    if not design_id or not alias_id or not alias_kind then
      error_out("usage: adex design alias add <design_id> <alias_id> <pre_final|final|other> [--active 0|1]")
      return
    end

    ledger.apply_design_alias(state, design_id, alias_id, alias_kind, active)
    out("OK")
    return
  end

  if cmd == "design" and tokens[2] == "appearance" and tokens[3] == "map" then
    local design_id = tokens[4]
    local appearance_key = tokens[5]
    if not design_id or not appearance_key then
      error_out("usage: adex design appearance map <design_id> <appearance_key>")
      return
    end
    ledger.apply_design_appearance(state, design_id, appearance_key, "manual")
    out("OK")
    return
  end

  if cmd == "design" and tokens[2] == "bom" and tokens[3] == "set" then
    local design_id = tokens[4]
    local args, flags = parse_flags(tokens, 5)
    local materials = parse_kv_list(flags.materials)
    if not design_id or not flags.materials then
      error_out("usage: adex design bom set <design_id> --materials k=v,...")
      return
    end
    local ok, err = validate_materials(materials)
    if not ok then
      error_out(err)
      return
    end
    ledger.apply_design_set_bom(state, design_id, materials)
    out("OK")
    return
  end

  if cmd == "design" and tokens[2] == "bom" and tokens[3] == "show" then
    local design_id = tokens[4]
    if not design_id then
      error_out("usage: adex design bom show <design_id>")
      return
    end
    local design = state.designs[design_id]
    if not design and state.design_aliases and state.design_aliases[design_id] then
      local resolved = state.design_aliases[design_id].design_id
      design = state.designs[resolved]
      design_id = resolved
    end
    if not design then
      error_out("design not found")
      return
    end
    render.section("Design BOM")
    render.kv_block({
      { label = "Design", value = design_id }
    })
    local rows = {}
    if design.bom then
      for commodity, qty in pairs(design.bom) do
        table.insert(rows, { commodity = commodity, qty = tostring(qty) })
      end
    end
    table.sort(rows, function(a, b)
      return a.commodity < b.commodity
    end)
    if #rows > 0 then
      render.table(rows, {
        { key = "commodity", label = "Commodity", nowrap = true, min = 12 },
        { key = "qty", label = "Qty", align = "right", min = 4 }
      })
    else
      render.print("(no BOM set)")
    end
    return
  end

  if cmd == "design" and tokens[2] == "cost" then
    local design_id = tokens[3]
    local amount = tonumber(tokens[4])
    local kind = tokens[5]
    if not design_id or not amount or not kind then
      error_out("usage: adex design cost <design_id> <amount> <kind>")
      return
    end
    ledger.apply_design_cost(state, design_id, amount, kind)
    out("OK")
    return
  end

  if cmd == "design" and tokens[2] == "set-fee" then
    local design_id = tokens[3]
    local amount = tonumber(tokens[4])
    if not design_id or amount == nil then
      error_out("usage: adex design set-fee <design_id> <amount>")
      return
    end
    ledger.apply_design_set_fee(state, design_id, amount)
    out("OK")
    return
  end

  if cmd == "order" and tokens[2] == "create" then
    local args, flags = parse_flags(tokens, 3)
    local order_id = args[1]
    local customer = flags.customer
    local note = flags.note
    if not order_id then
      order_id = id_generator.generate("O", function(id)
        return state.orders[id] ~= nil
      end)
      out("created_id: " .. tostring(order_id))
    end
    ledger.apply_order_create(state, order_id, customer, note)
    out("OK")
    return
  end

  if cmd == "order" and tokens[2] == "add" then
    local order_id = tokens[3]
    local sale_id = tokens[4]
    if not order_id or not sale_id then
      error_out("usage: adex order add <order_id> <sale_id>")
      return
    end
    ledger.apply_order_add_sale(state, order_id, sale_id)
    out("OK")
    return
  end

  if cmd == "order" and tokens[2] == "close" then
    local order_id = tokens[3]
    if not order_id then
      error_out("usage: adex order close <order_id>")
      return
    end
    ledger.apply_order_close(state, order_id)
    out("OK")
    return
  end

  if cmd == "process" and tokens[2] == "apply" then
    local process_id = tokens[3]
    local args, flags = parse_flags(tokens, 4)
    local inputs = parse_kv_list(flags.inputs)
    local outputs = parse_kv_list(flags.outputs)
    local fee = flags.fee and tonumber(flags.fee) or 0
    if not process_id or not flags.inputs or not flags.outputs then
      error_out("usage: adex process apply <process_id> --inputs k=v,... --outputs k=v,... [--fee <gold>] [--note <text>]")
      return
    end
    ledger.apply_process(state, process_id, inputs, outputs, fee)
    out("OK")
    return
  end

  if cmd == "process" and tokens[2] == "start" then
    local args, flags = parse_flags(tokens, 3)
    local process_instance_id = nil
    local process_id = nil

    if #args == 2 then
      process_instance_id = args[1]
      process_id = args[2]
    elseif #args == 1 then
      process_id = args[1]
    end
    local inputs = parse_kv_list(flags.inputs)
    local fee = flags.fee and tonumber(flags.fee) or 0
    local note = flags.note
    if not process_id then
      error_out("usage: adex process start [<process_instance_id>] <process_id> [--inputs k=v,...] [--fee <gold>] [--note <text>]")
      return
    end

    if not process_instance_id then
      process_instance_id = id_generator.generate("X", function(id)
        return state.process_instances[id] ~= nil
      end)
      out("created_id: " .. tostring(process_instance_id))
    end
    ledger.apply_process_start(state, process_instance_id, process_id, inputs, fee, note)
    out("OK")
    return
  end

  if cmd == "process" and tokens[2] == "add-inputs" then
    local process_instance_id = tokens[3]
    local args, flags = parse_flags(tokens, 4)
    local inputs = parse_kv_list(flags.inputs)
    local note = flags.note
    if not process_instance_id or not flags.inputs then
      error_out("usage: adex process add-inputs <process_instance_id> --inputs k=v,... [--note <text>]")
      return
    end
    ledger.apply_process_add_inputs(state, process_instance_id, inputs, note)
    out("OK")
    return
  end

  if cmd == "process" and tokens[2] == "add-fee" then
    local process_instance_id = tokens[3]
    local args, flags = parse_flags(tokens, 4)
    local fee = flags.fee and tonumber(flags.fee) or nil
    local note = flags.note
    if not process_instance_id or fee == nil then
      error_out("usage: adex process add-fee <process_instance_id> --fee <gold> [--note <text>]")
      return
    end
    ledger.apply_process_add_fee(state, process_instance_id, fee, note)
    out("OK")
    return
  end

  if cmd == "process" and tokens[2] == "complete" then
    local process_instance_id = tokens[3]
    local args, flags = parse_flags(tokens, 4)
    local outputs = parse_kv_list(flags.outputs)
    local note = flags.note
    if not process_instance_id or not flags.outputs then
      error_out("usage: adex process complete <process_instance_id> --outputs k=v,... [--note <text>]")
      return
    end
    ledger.apply_process_complete(state, process_instance_id, outputs, note)
    out("OK")
    return
  end

  if cmd == "process" and tokens[2] == "abort" then
    local process_instance_id = tokens[3]
    local args, flags = parse_flags(tokens, 4)
    local returned = parse_kv_list(flags.returned)
    local lost = parse_kv_list(flags.lost)
    local outputs = parse_kv_list(flags.outputs)
    local note = flags.note
    if not process_instance_id or not flags.returned or not flags.lost then
      error_out("usage: adex process abort <process_instance_id> --returned k=v,... --lost k=v,... [--outputs k=v,...] [--note <text>]")
      return
    end
    ledger.apply_process_abort(state, process_instance_id, {
      returned = returned,
      lost = lost,
      outputs = outputs
    }, note)
    out("OK")
    return
  end

  if cmd == "craft" and tokens[2] == "resolve" then
    local item_id = tokens[3]
    local design_id = tokens[4]
    if not item_id or not design_id then
      error_out("usage: adex craft resolve <item_id> <design_id>")
      return
    end
    ledger.apply_craft_resolve(state, item_id, design_id, "manual")
    out("OK")
    return
  end

  if cmd == "craft" then
    local args, flags = parse_flags(tokens, 2)
    local item_id = nil
    local design_id = flags.design
    local manual_cost = flags.cost and tonumber(flags.cost) or nil
    if #args > 1 then
      error_out("usage: adex craft [<item_id>] [--materials k=v,...] [--appearance <appearance_key>] [--design <design_id>] [--time <hours>] [--cost <gold>]")
      return
    end
    if #args == 1 then
      item_id = args[1]
    end
    local appearance_key = flags.appearance
    local time_hours = 0
    if flags.time then
      time_hours = tonumber(flags.time)
      if time_hours == nil or time_hours < 0 then
        error_out("usage: adex craft [<item_id>] [--materials k=v,...] [--appearance <appearance_key>] [--design <design_id>] [--time <hours>] [--cost <gold>]")
        return
      end
    end

    local materials = nil
    if flags.materials then
      materials = parse_kv_list(flags.materials)
      local ok, err = validate_materials(materials)
      if not ok then
        error_out(err)
        return
      end
    end

    if not materials and manual_cost == nil then
      local resolved_design_id = design_id
      if design_id and state.designs[design_id] == nil and state.design_aliases and state.design_aliases[design_id] then
        resolved_design_id = state.design_aliases[design_id].design_id
      end
      local design = resolved_design_id and state.designs[resolved_design_id] or nil
      if not (design and design.bom) then
        error_out("design has no BOM; use --materials or --cost")
        return
      end
      design_id = resolved_design_id
    end

    if not item_id then
      item_id = id_generator.generate("I", function(id)
        return state.crafted_items[id] ~= nil
      end)
      out("created_id: " .. tostring(item_id))
    end

    local time_cost_per_hour = config.get_time_cost_per_hour and config.get_time_cost_per_hour() or (tonumber(config.get("time_cost_per_hour")) or 0)
    local time_cost = math.floor(time_hours * time_cost_per_hour)
    if manual_cost ~= nil and not materials then
      render.warning("WARNING: Manual craft cost used; no materials recorded.")
    end

    ledger.apply_craft_item_auto(state, item_id, design_id, {
      materials = materials,
      appearance_key = appearance_key,
      manual_cost = manual_cost,
      time_cost_gold = time_cost,
      time_hours = time_hours
    })
    out("OK")
    return
  end

  if cmd == "sell" then
    local args, flags = parse_flags(tokens, 2)
    local sale_id = nil
    local item_id = nil
    local sale_price = tonumber(args[#args])
    if #args == 3 then
      sale_id = args[1]
      item_id = args[2]
    elseif #args == 2 then
      item_id = args[1]
    end

    if not item_id or sale_price == nil then
      error_out("usage: adex sell [<sale_id>] <item_id> <sale_price>")
      return
    end
    if not sale_id then
      sale_id = id_generator.generate("S", function(id)
        return state.sales[id] ~= nil
      end)
      out("created_id: " .. tostring(sale_id))
    end
    local game_time = get_game_time()
    local result = ledger.apply_sell_item(state, sale_id, item_id, sale_price, game_time)
    if result then
      out("OK")
    end
    return
  end

  if cmd == "report" and tokens[2] == "item" then
    local item_id = tokens[3]
    if not item_id then
      error_out("usage: adex report item <item_id>")
      return
    end

    local report = ledger.report_item(state, item_id)
    local fmt = render.format_gold or tostring

    render.section("Item Report")
    render.kv_block({
      { label = "Item", value = report.item_id },
      { label = "Design", value = report.design_id or "(unresolved)" },
      { label = "Provenance", value = report.provenance or "unknown" },
      { label = "Operational cost", value = fmt(report.operational_cost_gold) }
    })

    if report.sale_price_gold then
      render.section("Sale")
      render.kv_block({
        { label = "Sale price", value = fmt(report.sale_price_gold) },
        { label = "Operational profit", value = fmt(report.operational_profit) },
        { label = "Applied to design capital", value = fmt(report.applied_to_design_capital) },
        { label = "Applied to pattern capital", value = fmt(report.applied_to_pattern_capital) },
        { label = "True profit", value = fmt(report.true_profit) }
      })
    elseif report.unsold_cost_basis ~= nil then
      render.section("Unsold")
      render.kv_block({
        { label = "Unsold item cost basis", value = fmt(report.unsold_cost_basis) }
      })
    end

    local remaining_rows = {}
    if report.design_remaining ~= nil then
      table.insert(remaining_rows, { label = "Design remaining", value = fmt(report.design_remaining) })
    end
    if report.pattern_remaining ~= nil then
      table.insert(remaining_rows, { label = "Pattern remaining", value = fmt(report.pattern_remaining) })
    end
    if #remaining_rows > 0 then
      render.section("Remaining Capital")
      render.kv_block(remaining_rows)
    end

    local time_cost_per_hour = config.get_time_cost_per_hour and config.get_time_cost_per_hour() or 0
    render_warnings(render, warn_lines(report, state, time_cost_per_hour))
    return
  end

  if cmd == "list" then
    local topic = tokens[2]
    if not topic then
      error_out("usage: adex list <commodities|patterns|designs|items|sales|orders|processes>")
      return
    end

    local args, flags = parse_flags(tokens, 3)
    if topic == "commodities" then
      local rows = listings.list_commodities(state, {
        name = flags.name,
        sort = flags.sort
      })
      render.section("Commodities")
      local display_rows = {}
      for _, row in ipairs(rows) do
        table.insert(display_rows, {
          name = row.name,
          qty = tostring(row.qty),
          wac = tostring(row.wac)
        })
      end
      render.table(display_rows, {
        { key = "name", label = "Commodity", nowrap = true, min = 12 },
        { key = "qty", label = "Qty", align = "right", min = 5 },
        { key = "wac", label = "WAC", align = "right", min = 6 }
      })
      return
    end

    if topic == "patterns" then
      local rows = listings.list_patterns(state, {
        type = flags.type,
        status = flags.status
      })
      render.section("Patterns")
      local display_rows = {}
      for _, row in ipairs(rows) do
        table.insert(display_rows, {
          pattern_pool_id = row.pattern_pool_id,
          pattern_type = row.pattern_type,
          pattern_name = row.pattern_name or "",
          status = row.status,
          remaining = render.format_gold and render.format_gold(row.remaining) or tostring(row.remaining)
        })
      end
      render.table(display_rows, {
        { key = "pattern_pool_id", label = "Pool ID", nowrap = true, min = 12 },
        { key = "pattern_type", label = "Type", nowrap = true, min = 6 },
        { key = "pattern_name", label = "Name", min = 12 },
        { key = "status", label = "Status", nowrap = true, min = 6 },
        { key = "remaining", label = "Remaining", align = "right", min = 9 }
      })
      return
    end

    if topic == "designs" then
      local recovery = flags.recovery and tonumber(flags.recovery) or nil
      local rows = listings.list_designs(state, {
        type = flags.type,
        provenance = flags.provenance,
        recovery = recovery
      })
      render.section("Designs")
      local display_rows = {}
      for _, row in ipairs(rows) do
        table.insert(display_rows, {
          design_id = row.design_id,
          design_type = row.design_type,
          name = row.name or "",
          provenance = row.provenance,
          recovery_enabled = tostring(row.recovery_enabled),
          pattern_pool_id = row.pattern_pool_id or "-",
          design_remaining = render.format_gold and render.format_gold(row.design_remaining) or tostring(row.design_remaining)
        })
      end
      render.table(display_rows, {
        { key = "design_id", label = "Design ID", nowrap = true, min = 12 },
        { key = "design_type", label = "Type", nowrap = true, min = 6 },
        { key = "name", label = "Name", min = 12 },
        { key = "provenance", label = "Prov", nowrap = true, min = 6 },
        { key = "recovery_enabled", label = "Rec", nowrap = true, min = 3 },
        { key = "pattern_pool_id", label = "Pool", nowrap = true, min = 8 },
        { key = "design_remaining", label = "Remaining", align = "right", min = 9 }
      })
      return
    end

    if topic == "items" then
      local sold = flags.sold and tonumber(flags.sold)
      local rows = listings.list_items(state, {
        design = flags.design,
        sold = sold == nil and nil or sold == 1,
        unresolved = flags.unresolved and tonumber(flags.unresolved) == 1
      })
      render.section("Items")
      local display_rows = {}
      for _, row in ipairs(rows) do
        table.insert(display_rows, {
          item_id = row.item_id,
          design_id = row.design_id or "(unresolved)",
          sold = row.sold and "yes" or "no",
          appearance_key = row.appearance_key or ""
        })
      end
      render.table(display_rows, {
        { key = "item_id", label = "Item ID", nowrap = true, min = 12 },
        { key = "design_id", label = "Design", nowrap = true, min = 10 },
        { key = "sold", label = "Sold", nowrap = true, min = 4 },
        { key = "appearance_key", label = "Appearance", min = 14 }
      })
      return
    end

    if topic == "sales" then
      local rows = listings.list_sales(state, {
        year = flags.year,
        order = flags.order
      })
      render.section("Sales")
      local display_rows = {}
      for _, row in ipairs(rows) do
        table.insert(display_rows, {
          sale_id = row.sale_id,
          item_id = row.item_id,
          price = render.format_gold and render.format_gold(row.sale_price_gold) or tostring(row.sale_price_gold),
          year = row.game_year or "?",
          order_id = row.order_id or "-"
        })
      end
      render.table(display_rows, {
        { key = "sale_id", label = "Sale ID", nowrap = true, min = 12 },
        { key = "item_id", label = "Item", nowrap = true, min = 10 },
        { key = "price", label = "Price", align = "right", min = 8 },
        { key = "year", label = "Year", nowrap = true, min = 4 },
        { key = "order_id", label = "Order", nowrap = true, min = 8 }
      })
      return
    end

    if topic == "orders" then
      local rows = listings.list_orders(state)
      render.section("Orders")
      local display_rows = {}
      for _, row in ipairs(rows) do
        table.insert(display_rows, {
          order_id = row.order_id,
          status = row.status,
          customer = row.customer or "",
          created_at = row.created_at,
          sales_count = tostring(row.total_sales_count),
          revenue = render.format_gold and render.format_gold(row.total_revenue) or tostring(row.total_revenue)
        })
      end
      render.table(display_rows, {
        { key = "order_id", label = "Order ID", nowrap = true, min = 12 },
        { key = "status", label = "Status", nowrap = true, min = 6 },
        { key = "customer", label = "Customer", min = 10 },
        { key = "created_at", label = "Created", nowrap = true, min = 10 },
        { key = "sales_count", label = "Sales", align = "right", min = 5 },
        { key = "revenue", label = "Revenue", align = "right", min = 8 }
      })
      return
    end

    if topic == "processes" then
      local rows = listings.list_processes(state, {
        status = flags.status,
        process_id = flags.process
      })
      render.section("Processes")
      local display_rows = {}
      for _, row in ipairs(rows) do
        table.insert(display_rows, {
          process_instance_id = row.process_instance_id,
          process_id = row.process_id,
          status = row.status,
          started_at = row.started_at or "",
          completed_at = row.completed_at or ""
        })
      end
      render.table(display_rows, {
        { key = "process_instance_id", label = "Instance ID", nowrap = true, min = 12 },
        { key = "process_id", label = "Process", nowrap = true, min = 8 },
        { key = "status", label = "Status", nowrap = true, min = 8 },
        { key = "started_at", label = "Started", nowrap = true, min = 10 },
        { key = "completed_at", label = "Completed", nowrap = true, min = 10 }
      })
      return
    end

    error_out("unknown list topic")
    return
  end

  if cmd == "report" and tokens[2] == "overall" then
    local reports = _G.AchaeadexLedger.Core.Reports
    if not reports then
      error_out("reports module not loaded")
      return
    end

    local report = reports.overall(state, { time_cost_per_hour = config.get_time_cost_per_hour and config.get_time_cost_per_hour() or 0 })
    local fmt = render.format_gold or tostring
    render.section("Overall Report")
    render_totals(render, report.totals)
    render.section("Holdings")
    render_holdings(render, report.holdings)
    render.section("Outstanding Capital")
    render.kv_block({
      { label = "Design capital remaining", value = fmt(report.design_remaining or 0) },
      { label = "Pattern capital remaining", value = fmt(report.pattern_remaining or 0) }
    })
    render_warnings(render, report.warnings)
    return
  end

  if cmd == "report" and tokens[2] == "year" then
    local reports = _G.AchaeadexLedger.Core.Reports
    if not reports then
      error_out("reports module not loaded")
      return
    end

    local year_token = tokens[3]
    if not year_token then
      error_out("usage: adex report year <year|current>")
      return
    end

    local year = tonumber(year_token)
    if year_token == "current" then
      local game_time = get_game_time()
      if not game_time or not game_time.year then
        error_out("current game time is not available")
        return
      end
      year = game_time.year
    end

    if not year then
      error_out("usage: adex report year <year|current>")
      return
    end

    local report = reports.year(state, year, { time_cost_per_hour = config.get_time_cost_per_hour and config.get_time_cost_per_hour() or 0 })
    render.section("Year Report: " .. tostring(year))
    render.section("Year Activity")
    render_totals(render, report.totals)
    render.section("Holdings Snapshot")
    render_holdings(render, report.holdings)
    render_warnings(render, report.warnings)
    return
  end

  if cmd == "report" and tokens[2] == "order" then
    local reports = _G.AchaeadexLedger.Core.Reports
    if not reports then
      error_out("reports module not loaded")
      return
    end

    local order_id = tokens[3]
    if not order_id then
      error_out("usage: adex report order <order_id>")
      return
    end

    local report = reports.order(state, order_id, { time_cost_per_hour = config.get_time_cost_per_hour and config.get_time_cost_per_hour() or 0 })
    local order = report.order
    local fmt = render.format_gold or tostring

    render.section("Order Report")
    render.kv_block({
      { label = "Order", value = order.order_id },
      { label = "Status", value = order.status },
      { label = "Created", value = order.created_at },
      { label = "Customer", value = order.customer or "" },
      { label = "Note", value = order.note or "" }
    })

    render.section("Line Items")
    local rows = {}
    for _, sale in ipairs(report.sales) do
      table.insert(rows, {
        sale_id = sale.sale_id,
        item_id = sale.item_id,
        design_id = sale.design_id or "(unresolved)",
        appearance = sale.appearance_key or "",
        sale_price = fmt(sale.sale_price_gold),
        operational_cost = fmt(sale.operational_cost_gold),
        operational_profit = fmt(sale.operational_profit),
        applied_design = fmt(sale.applied_to_design_capital),
        applied_pattern = fmt(sale.applied_to_pattern_capital),
        true_profit = fmt(sale.true_profit)
      })
    end
    render.table(rows, {
      { key = "sale_id", label = "Sale ID", nowrap = true, min = 12 },
      { key = "item_id", label = "Item", nowrap = true, min = 10 },
      { key = "design_id", label = "Design", nowrap = true, min = 10 },
      { key = "appearance", label = "Appearance", min = 12 },
      { key = "sale_price", label = "Price", align = "right", min = 8 },
      { key = "operational_cost", label = "Op Cost", align = "right", min = 8 },
      { key = "operational_profit", label = "Op Profit", align = "right", min = 8 },
      { key = "applied_design", label = "Design Cap", align = "right", min = 10 },
      { key = "applied_pattern", label = "Pattern Cap", align = "right", min = 11 },
      { key = "true_profit", label = "True Profit", align = "right", min = 10 }
    })

    render.section("Totals")
    render_totals(render, report.totals)
    if report.note then
      render.print(report.note)
    end
    render_warnings(render, report.warnings)
    return
  end

  if cmd == "report" and tokens[2] == "design" then
    local reports = _G.AchaeadexLedger.Core.Reports
    if not reports then
      error_out("reports module not loaded")
      return
    end

    local design_id = tokens[3]
    local args, flags = parse_flags(tokens, 4)
    if not design_id then
      error_out("usage: adex report design <design_id> [--items] [--orders] [--year <year>]")
      return
    end

    local opts = {
      include_items = flags.items and true or false,
      include_orders = flags.orders and true or false
    }

    if flags.year then
      local year = tonumber(flags.year)
      if not year and flags.year == "current" then
        local game_time = get_game_time()
        if not game_time or not game_time.year then
          error_out("current game time is not available")
          return
        end
        year = game_time.year
      end
      if not year then
        error_out("usage: adex report design <design_id> [--items] [--orders] [--year <year>]")
        return
      end
      opts.year = year
    end

    opts.time_cost_per_hour = config.get_time_cost_per_hour and config.get_time_cost_per_hour() or 0
    local report = reports.design(state, design_id, opts)
    local fmt = render.format_gold or tostring

    render.section("Design Report")
    render.kv_block({
      { label = "Design", value = report.design_id },
      { label = "Name", value = report.name or "" },
      { label = "Type", value = report.design_type },
      { label = "Provenance", value = tostring(report.provenance) .. ", recovery " .. tostring(report.recovery_enabled) },
      { label = "Pattern pool", value = report.pattern_pool_id or "" },
      { label = "Per-item fee", value = fmt(report.per_item_fee_gold or 0) },
      { label = "Design capital initial", value = fmt(report.design_capital_initial or 0) },
      { label = "Design capital remaining", value = fmt(report.design_capital_remaining or 0) },
      { label = "Pattern capital remaining", value = report.pattern_capital_remaining ~= nil and fmt(report.pattern_capital_remaining) or "" },
      { label = "Unsold crafted items value", value = report.unsold_items_value ~= nil and fmt(report.unsold_items_value) or "" }
    })

    render.section("Performance")
    render.kv_block({
      { label = "Crafted count", value = tostring(report.crafted_count or 0) },
      { label = "Sold count", value = tostring(report.sold_count or 0) }
    })
    render_totals(render, report.totals)

    if opts.include_items then
      render.section("Items")
      local rows = {}
      for _, sale in ipairs(report.sales) do
        table.insert(rows, {
          item_id = sale.item_id,
          sold_at = sale.sold_at or "",
          sale_price = fmt(sale.sale_price_gold),
          operational_cost = fmt(sale.operational_cost_gold),
          true_profit = fmt(sale.true_profit)
        })
      end
      render.table(rows, {
        { key = "item_id", label = "Item ID", nowrap = true, min = 12 },
        { key = "sold_at", label = "Sold At", nowrap = true, min = 10 },
        { key = "sale_price", label = "Price", align = "right", min = 8 },
        { key = "operational_cost", label = "Op Cost", align = "right", min = 8 },
        { key = "true_profit", label = "True Profit", align = "right", min = 9 }
      })
    end

    if opts.include_orders then
      render.section("Orders")
      local rows = {}
      for _, order_id in ipairs(report.order_ids or {}) do
        table.insert(rows, { order_id = order_id })
      end
      render.table(rows, {
        { key = "order_id", label = "Order ID", nowrap = true, min = 12 }
      })
    end

    render_warnings(render, report.warnings)
    return
  end

  if cmd == "sim" and tokens[2] == "price" then
    local design_id = tokens[3]
    local price = tonumber(tokens[4])
    local args, flags = parse_flags(tokens, 5)
    local op_cost = flags["op-cost"] and tonumber(flags["op-cost"]) or nil
    if not design_id or price == nil then
      error_out("usage: adex sim price <design_id> <price> [--op-cost <gold>]")
      return
    end
    local resolved_id = resolve_design_id_for_sim(state, design_id)
    local design = state.designs[resolved_id]
    if not op_cost then
      op_cost = compute_op_cost_from_bom(state, design)
    end
    if not op_cost then
      for _, item in pairs(state.crafted_items) do
        if item.design_id == resolved_id then
          op_cost = item.operational_cost_gold
        end
      end
    end
    if not op_cost then
      error_out("sim price requires --op-cost when no BOM or crafted items exist")
      return
    end
    local pattern_remaining = 0
    if design and design.pattern_pool_id and state.pattern_pools[design.pattern_pool_id] then
      pattern_remaining = state.pattern_pools[design.pattern_pool_id].capital_remaining_gold
    end
    local units = simulator.units_needed(op_cost, design and design.capital_remaining or 0, pattern_remaining, price, design and design.recovery_enabled or 0)
    out("Units needed: " .. tostring(units))
    return
  end

  if cmd == "sim" and tokens[2] == "units" then
    local design_id = tokens[3]
    local units = tonumber(tokens[4])
    local args, flags = parse_flags(tokens, 5)
    local op_cost = flags["op-cost"] and tonumber(flags["op-cost"]) or nil
    if not design_id or units == nil then
      error_out("usage: adex sim units <design_id> <units> [--op-cost <gold>]")
      return
    end
    local resolved_id = resolve_design_id_for_sim(state, design_id)
    local design = state.designs[resolved_id]
    if not op_cost then
      op_cost = compute_op_cost_from_bom(state, design)
    end
    if not op_cost then
      for _, item in pairs(state.crafted_items) do
        if item.design_id == resolved_id then
          op_cost = item.operational_cost_gold
        end
      end
    end
    if not op_cost then
      error_out("sim units requires --op-cost when no BOM or crafted items exist")
      return
    end
    local pattern_remaining = 0
    if design and design.pattern_pool_id and state.pattern_pools[design.pattern_pool_id] then
      pattern_remaining = state.pattern_pools[design.pattern_pool_id].capital_remaining_gold
    end
    local price = simulator.price_needed(op_cost, design and design.capital_remaining or 0, pattern_remaining, units, design and design.recovery_enabled or 0)
    out("Price needed: " .. tostring(price))
    return
  end

  error_out("Unknown command. Try: adex help")
end

_G.AchaeadexLedger.Mudlet.Commands = commands

return commands
