-- Busted tests for EventStore implementations

describe("EventStore", function()
  local schema
  local ledger
  local inventory
  local memory_store
  local sqlite_store
  local luasql

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/json.lua")
    dofile("src/scripts/core/inventory.lua")
    dofile("src/scripts/core/deferred_processes.lua")
    dofile("src/scripts/core/pattern_pools.lua")
    dofile("src/scripts/core/production_sources.lua")
    dofile("src/scripts/core/recovery.lua")
    dofile("src/scripts/core/projector.lua")
    dofile("src/scripts/core/reports.lua")
    dofile("src/scripts/core/schema.lua")
    dofile("src/scripts/core/costing.lua")
    dofile("src/scripts/core/cash.lua")
    dofile("src/scripts/core/ledger.lua")
    dofile("src/scripts/core/storage/memory_event_store.lua")
    dofile("src/scripts/core/storage/sqlite_event_store.lua")

    schema = _G.AchaeadexLedger.Core.Schema
    ledger = _G.AchaeadexLedger.Core.Ledger
    inventory = _G.AchaeadexLedger.Core.Inventory
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
    sqlite_store = _G.AchaeadexLedger.Core.LuaSQLEventStore
    local ok, module = pcall(require, "luasql.sqlite3")
    if ok then
      luasql = module
    else
      luasql = nil
    end
  end)

  it("migration runner is idempotent", function()
    if not luasql then
      pending("LuaSQL sqlite3 not available")
      return
    end

    local db_path = os.tmpname()
    local store = sqlite_store.new(db_path)

    local cur = assert(store.conn:execute("SELECT COUNT(*) AS count FROM schema_version"))
    local row = cur:fetch({}, "a")
    cur:close()

    assert.are.equal(#schema.migrations, tonumber(row.count))
  end)

  it("appends and reads in order", function()
    local store = memory_store.new()
    store:append({ event_type = "A", payload = { value = 1 } })
    store:append({ event_type = "B", payload = { value = 2 } })

    local events = store:read_all()
    assert.are.equal(2, #events)
    assert.are.equal(1, events[1].id)
    assert.are.equal("A", events[1].event_type)
    assert.are.equal(2, events[2].id)
    assert.are.equal("B", events[2].event_type)
  end)

  it("replays from SQLite to same projected state", function()
    if not luasql then
      pending("LuaSQL sqlite3 not available")
      return
    end

    local mem = memory_store.new()
    local state1 = ledger.new(mem)

    ledger.apply_opening_inventory(state1, "fibre", 10, 5)
    ledger.apply_opening_inventory(state1, "coal", 10, 2)
    ledger.apply_pattern_activate(state1, "P1", "shirt", "Pool", 150)
    ledger.apply_design_start(state1, "D1", "shirt", "Design 1", "private", 1)
    ledger.apply_design_cost(state1, "D1", 6000, "submission")
    ledger.apply_sell_recovery(state1, "D1", 160)
    ledger.apply_process_start(state1, "PX", "refine", { fibre = 4, coal = 4 }, 1)
    ledger.apply_process_complete(state1, "PX", { cloth = 4 })

    local events = mem:read_all()

    local db_path = os.tmpname()
    local sqlite = sqlite_store.new(db_path)
    for _, event in ipairs(events) do
      sqlite:append({ event_type = event.event_type, payload = event.payload, ts = event.ts })
    end

    local sqlite_events = sqlite:read_all()
    local mem2 = memory_store.new()
    local state2 = ledger.new(mem2)

    for _, event in ipairs(sqlite_events) do
      ledger.apply_event(state2, event)
    end

    assert.are.equal(inventory.get_qty(state1.inventory, "fibre"), inventory.get_qty(state2.inventory, "fibre"))
    assert.are.equal(inventory.get_qty(state1.inventory, "coal"), inventory.get_qty(state2.inventory, "coal"))
    assert.are.equal(inventory.get_qty(state1.inventory, "cloth"), inventory.get_qty(state2.inventory, "cloth"))

    assert.are.equal(state1.production_sources["D1"].capital_remaining, state2.production_sources["D1"].capital_remaining)
    assert.are.equal(state1.pattern_pools["P1"].capital_remaining_gold, state2.pattern_pools["P1"].capital_remaining_gold)
    assert.are.equal(state1.process_instances["PX"].status, state2.process_instances["PX"].status)
    assert.are.equal(state1.production_sources["D1"].pattern_pool_id, state2.production_sources["D1"].pattern_pool_id)
  end)

  it("rebuilds projections deterministically", function()
    if not luasql then
      pending("LuaSQL sqlite3 not available")
      return
    end

    local db_path = os.tmpname()
    local reports = _G.AchaeadexLedger.Core.Reports
    local store = sqlite_store.new(db_path)
    local state = ledger.new(store)

    ledger.apply_pattern_activate(state, "P1", "shirt", "Pool", 150)
    ledger.apply_design_start(state, "D1", "shirt", "Design 1", "private", 1)
    ledger.apply_design_cost(state, "D1", 6000, "submission")
    ledger.apply_design_set_fee(state, "D1", 10)
    ledger.apply_design_alias(state, "D1", "1234", "pre_final", 1)
    ledger.apply_craft_item(state, "I1", "D1", 50, "{}", "simple shirt")
    ledger.apply_sell_item(state, "S1", "I1", 200, { year = 650 })
    ledger.apply_opening_inventory(state, "fibre", 10, 5)
    ledger.apply_process_start(state, "PX", "refine", { fibre = 4 }, 1)
    ledger.apply_process_complete(state, "PX", { cloth = 4 })

    local report_before = reports.overall(state)
    local before = store:domain_counts()
    store:rebuild_projections()
    local after = store:domain_counts()

    assert.are.same(before, after)

    local events = store:read_all()
    local fresh = ledger.new(store)
    for _, event in ipairs(events) do
      ledger.apply_event(fresh, event)
    end
    local report_after = reports.overall(fresh)

    assert.are.same(report_before.totals, report_after.totals)

    local cur = assert(store.conn:execute("SELECT capital_remaining_gold FROM designs WHERE design_id = 'D1'"))
    local row = cur:fetch({}, "a")
    cur:close()
    assert.is_not_nil(row)

    local cur2 = assert(store.conn:execute("SELECT status FROM process_instances WHERE process_instance_id = 'PX'"))
    local row2 = cur2:fetch({}, "a")
    cur2:close()
    assert.are.equal("completed", row2.status)
  end)

  it("rebuild applies legacy craft resolve events", function()
    if not luasql then
      pending("LuaSQL sqlite3 not available")
      return
    end

    local db_path = os.tmpname()
    local store = sqlite_store.new(db_path)

    store:append({
      event_type = "CRAFT_ITEM",
      payload = {
        item_id = "I-LEGACY",
        design_id = "D1",
        operational_cost_gold = 10,
        cost_breakdown_json = "{}",
        crafted_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
      }
    })

    store:append({
      event_type = "CRAFT_RESOLVE_DESIGN",
      payload = {
        item_id = "I-LEGACY",
        design_id = "D1",
        reason = "manual_map"
      }
    })

    store:rebuild_projections()

    local cur = assert(store.conn:execute("SELECT source_id, source_kind FROM crafted_items WHERE item_id = 'I-LEGACY'"))
    local row = cur:fetch({}, "a")
    cur:close()

    assert.are.equal("D1", row.source_id)
    assert.are.equal("design", row.source_kind)
  end)

  it("rebuild preserves external item transformation from augmentation", function()
    if not luasql then
      pending("LuaSQL sqlite3 not available")
      return
    end

    local db_path = os.tmpname()
    local store = sqlite_store.new(db_path)
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "gem", 1, 100)
    ledger.apply_source_create(state, "SK-AUG", "skill", "augmentation", "Augmentation")
    ledger.apply_item_add_external(state, "E-R1", "old amulet", 1000, "purchase")
    ledger.apply_augment_item(state, "I-R1", "SK-AUG", "E-R1", {
      materials = { gem = 1 },
      fee_gold = 25
    })

    store:rebuild_projections()

    local cur1 = assert(store.conn:execute("SELECT status FROM external_items WHERE item_id = 'E-R1'"))
    local row1 = cur1:fetch({}, "a")
    cur1:close()
    assert.are.equal("transformed", row1.status)

    local cur2 = assert(store.conn:execute("SELECT operational_cost_gold, parent_item_id FROM crafted_items WHERE item_id = 'I-R1'"))
    local row2 = cur2:fetch({}, "a")
    cur2:close()
    assert.are.equal(1125, tonumber(row2.operational_cost_gold))
    assert.are.equal("E-R1", row2.parent_item_id)
  end)

  it("rebuild applies PROCESS_SET_GAME_TIME override for historical write-offs", function()
    if not luasql then
      pending("LuaSQL sqlite3 not available")
      return
    end

    local db_path = os.tmpname()
    local store = sqlite_store.new(db_path)
    local state = ledger.new(store)
    local reports = _G.AchaeadexLedger.Core.Reports

    ledger.apply_opening_inventory(state, "ore", 10, 10)
    ledger.apply_process_start(state, "P-RB-YEAR", "smelt", { ore = 5 }, 10)
    ledger.apply_process_complete(state, "P-RB-YEAR", {})
    ledger.apply_process_set_game_time(state, "P-RB-YEAR", { year = 123 }, "write_off", "rebuild correction")

    store:rebuild_projections()

    local events = store:read_all()
    local fresh = ledger.new(store)
    for _, event in ipairs(events) do
      ledger.apply_event(fresh, event)
    end

    local report = reports.year(fresh, 123)
    assert.are.equal(60, report.totals.process_losses)
    assert.are.equal(0, report.unattributed_process_write_off_count)

    local cur = assert(store.conn:execute("SELECT game_time_json FROM process_game_time_overrides WHERE process_instance_id = 'P-RB-YEAR' AND scope = 'write_off'"))
    local row = cur:fetch({}, "a")
    cur:close()
    assert.is_not_nil(row)
  end)

  it("updates projected write-off year immediately after PROCESS_SET_GAME_TIME", function()
    if not luasql then
      pending("LuaSQL sqlite3 not available")
      return
    end

    local db_path = os.tmpname()
    local store = sqlite_store.new(db_path)
    local state = ledger.new(store)

    ledger.apply_opening_inventory(state, "ore", 10, 10)
    ledger.apply_process_start(state, "P-IMM-YEAR", "smelt", { ore = 5 }, 10)
    ledger.apply_process_complete(state, "P-IMM-YEAR", {})

    local cur_before = assert(store.conn:execute("SELECT resolved_game_year FROM process_write_offs WHERE process_instance_id = 'P-IMM-YEAR'"))
    local row_before = cur_before:fetch({}, "a")
    cur_before:close()
    assert.is_not_nil(row_before)
    assert.is_nil(row_before.resolved_game_year)

    ledger.apply_process_set_game_time(state, "P-IMM-YEAR", { year = 123 }, "write_off", "inline correction")

    local cur_after = assert(store.conn:execute("SELECT resolved_game_year FROM process_write_offs WHERE process_instance_id = 'P-IMM-YEAR'"))
    local row_after = cur_after:fetch({}, "a")
    cur_after:close()
    assert.is_not_nil(row_after)
    assert.are.equal(123, tonumber(row_after.resolved_game_year))
  end)

  it("projects sales game_time_json consistently", function()
    if not luasql then
      pending("LuaSQL sqlite3 not available")
      return
    end

    local db_path = os.tmpname()
    local store = sqlite_store.new(db_path)
    local state = ledger.new(store)

    ledger.apply_design_start(state, "D-GT", "shirt", "GameTime", "public", 0)
    ledger.apply_craft_item(state, "I-GT", "D-GT", 40, "{}", nil)
    ledger.apply_sell_item(state, "S-GT", "I-GT", 100, { year = 998, month = 1, day = 2, hour = 3, minute = 4 })

    local cur = assert(store.conn:execute("SELECT game_time_json, game_time_year FROM sales WHERE sale_id = 'S-GT'"))
    local row = cur:fetch({}, "a")
    cur:close()

    assert.is_not_nil(row)
    assert.is_not_nil(row.game_time_json)
    assert.are.equal(998, tonumber(row.game_time_year))
  end)

  it("rebuild deterministically recomputes resolved_game_year from default anchor", function()
    if not luasql then
      pending("LuaSQL sqlite3 not available")
      return
    end

    local db_path = os.tmpname()
    local store = sqlite_store.new(db_path)
    local state = ledger.new(store)

    ledger.apply_design_start(state, "D-YR", "shirt", "Yearful", "public", 0)
    ledger.apply_craft_item(state, "I-YR", "D-YR", 40, "{}", nil)
    ledger.apply_sell_item(state, "S-YR", "I-YR", 100, nil)
    ledger.apply_set_default_game_year(state, 998, 1, "coarse backfill")

    store:rebuild_projections()

    local cur = assert(store.conn:execute("SELECT resolved_game_year FROM sales WHERE sale_id = 'S-YR'"))
    local row = cur:fetch({}, "a")
    cur:close()

    assert.is_not_nil(row)
    assert.are.equal(998, tonumber(row.resolved_game_year))
  end)

  it("rebuild preserves deferred process passive state and time-cost rows", function()
    if not luasql then
      pending("LuaSQL sqlite3 not available")
      return
    end

    local db_path = os.tmpname()
    local store = sqlite_store.new(db_path)
    local state = ledger.new(store)

    ledger.apply_process_time_cost_rate(state, 25)
    ledger.apply_process_time_cost_cutover(state, "2026-03-01T00:00:00Z")
    ledger.apply_opening_inventory(state, "ore", 10, 10)
    ledger.apply_process_start(state, "PX-TIME-RB", "smelt", { ore = 5 }, 0, nil, nil, {
      started_at = "2026-03-13T00:00:00Z"
    })
    ledger.apply_process_complete(state, "PX-TIME-RB", {}, nil, nil, {
      completed_at = "2026-03-13T01:30:00Z"
    })

    store:rebuild_projections()

    local cur1 = assert(store.conn:execute("SELECT passive, status FROM process_instances WHERE process_instance_id = 'PX-TIME-RB'"))
    local row1 = cur1:fetch({}, "a")
    cur1:close()
    assert.is_not_nil(row1)
    assert.are.equal(0, tonumber(row1.passive))
    assert.are.equal("completed", row1.status)

    local cur2 = assert(store.conn:execute("SELECT amount_gold, elapsed_seconds, rate_gold_per_hour FROM process_time_costs WHERE process_instance_id = 'PX-TIME-RB'"))
    local row2 = cur2:fetch({}, "a")
    cur2:close()
    assert.is_not_nil(row2)
    assert.are.equal(38, tonumber(row2.amount_gold))
    assert.are.equal(5400, tonumber(row2.elapsed_seconds))
    assert.are.equal(25, tonumber(row2.rate_gold_per_hour))
  end)

  it("rebuild preserves process revenue and net result for explicit revenue fields", function()
    if not luasql then
      pending("LuaSQL sqlite3 not available")
      return
    end

    local reports = _G.AchaeadexLedger.Core.Reports
    local mem = memory_store.new()
    local state1 = ledger.new(mem)

    ledger.apply_opening_inventory(state1, "curatives", 10, 15)
    ledger.apply_process_start(state1, "PX-GOLD", "hunting", { curatives = 2 }, 50, nil, { year = 703 })
    ledger.apply_process_add_inputs(state1, "PX-GOLD", { curatives = 1 })
    ledger.apply_process_complete(state1, "PX-GOLD", {}, nil, { year = 703 }, {
      revenue_gold = 500
    })

    local report1 = reports.process(state1, "PX-GOLD")

    local db_path = os.tmpname()
    local sqlite = sqlite_store.new(db_path)
    for _, event in ipairs(mem:read_all()) do
      sqlite:append({ event_type = event.event_type, payload = event.payload, ts = event.ts })
    end
    sqlite:rebuild_projections()

    local mem2 = memory_store.new()
    local state2 = ledger.new(mem2)
    for _, event in ipairs(sqlite:read_all()) do
      ledger.apply_event(state2, event)
    end

    local report2 = reports.process(state2, "PX-GOLD")
    local year2 = reports.year(state2, 703)

    assert.are.equal(report1.revenue_gold, report2.revenue_gold)
    assert.are.equal(report1.total_process_cost_gold, report2.total_process_cost_gold)
    assert.are.equal(report1.net_result_gold, report2.net_result_gold)
    assert.are.equal(500, year2.totals.process_revenue)
    assert.are.equal(95, year2.totals.process_total_cost)
    assert.are.equal(0, year2.totals.process_basis_carried)
    assert.are.equal(405, year2.totals.process_net_result)
    assert.are.equal(405, year2.totals.process_profit_contribution)
    assert.are.equal(405, year2.totals.true_profit)
    assert.are.equal(0, inventory.get_qty(state2.inventory, "gold"))
  end)

  it("rebuild preserves immediate process write-offs and partial output basis", function()
    if not luasql then
      pending("LuaSQL sqlite3 not available")
      return
    end

    local reports = _G.AchaeadexLedger.Core.Reports
    local mem = memory_store.new()
    local state1 = ledger.new(mem)

    ledger.apply_opening_inventory(state1, "ore", 10, 10)
    ledger.apply_process(state1, "smelt", { ore = 5 }, { metal = 3 }, 10, { year = 704 })

    local db_path = os.tmpname()
    local sqlite = sqlite_store.new(db_path)
    for _, event in ipairs(mem:read_all()) do
      sqlite:append({ event_type = event.event_type, payload = event.payload, ts = event.ts })
    end

    local mem2 = memory_store.new()
    local state2 = ledger.new(mem2)
    for _, event in ipairs(sqlite:read_all()) do
      ledger.apply_event(state2, event)
    end

    local year2 = reports.year(state2, 704)

    assert.are.equal(3, inventory.get_qty(state2.inventory, "metal"))
    assert.are.equal(40 / 3, inventory.get_unit_cost(state2.inventory, "metal"))
    assert.are.equal(1, #(state2.process_write_offs or {}))
    assert.are.equal(20, state2.process_write_offs[1].amount_gold)
    assert.are.equal(20, year2.totals.process_losses)
    assert.are.equal(0, year2.totals.true_profit)
  end)

  it("rebuild preserves realized production revenue while capitalizing committed basis into outputs", function()
    if not luasql then
      pending("LuaSQL sqlite3 not available")
      return
    end

    local reports = _G.AchaeadexLedger.Core.Reports
    local mem = memory_store.new()
    local state1 = ledger.new(mem)

    ledger.apply_process_time_cost_rate(state1, 4781)
    ledger.apply_process_time_cost_cutover(state1, "2026-03-01T00:00:00Z")
    ledger.apply_opening_inventory(state1, "potash", 31, 1546 / 31)
    ledger.apply_commodity_set_standard_value(state1, "malachite", 1)
    ledger.apply_commodity_set_standard_value(state1, "realgar", 1)
    ledger.apply_commodity_set_standard_value(state1, "skins", 1)
    ledger.apply_process(state1, "hunting", { potash = 31 }, { malachite = 939, realgar = 61, skins = 54 }, 0, nil, {
      revenue_gold = 2790,
      time_hours = 1,
      completed_at = "2026-03-13T03:00:00Z"
    })

    local db_path = os.tmpname()
    local sqlite = sqlite_store.new(db_path)
    for _, event in ipairs(mem:read_all()) do
      sqlite:append({ event_type = event.event_type, payload = event.payload, ts = event.ts })
    end
    sqlite:rebuild_projections()

    local mem2 = memory_store.new()
    local state2 = ledger.new(mem2)
    for _, event in ipairs(sqlite:read_all()) do
      ledger.apply_event(state2, event)
    end

    local process_id = next(state2.process_instances)
    local report2 = reports.process(state2, process_id)
    local overall2 = reports.overall(state2)

    assert.are.equal(6327, report2.total_process_cost_gold)
    assert.are.equal(4781, report2.capitalized_basis_gold)
    assert.are.equal(1244, report2.net_result_gold)
    assert.are.equal(1244, overall2.totals.process_net_result)
    assert.are.equal(4781, overall2.totals.process_basis_carried)
  end)
end)
