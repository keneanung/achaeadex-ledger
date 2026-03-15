describe("Cash accounts", function()
  local ledger
  local reports
  local memory_store
  local sqlite_store
  local luasql

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/json.lua")
    dofile("src/scripts/core/costing.lua")
    dofile("src/scripts/core/inventory.lua")
    dofile("src/scripts/core/cash.lua")
    dofile("src/scripts/core/deferred_processes.lua")
    dofile("src/scripts/core/pattern_pools.lua")
    dofile("src/scripts/core/production_sources.lua")
    dofile("src/scripts/core/recovery.lua")
    dofile("src/scripts/core/projector.lua")
    dofile("src/scripts/core/reports.lua")
    dofile("src/scripts/core/schema.lua")
    dofile("src/scripts/core/ledger.lua")
    dofile("src/scripts/core/storage/memory_event_store.lua")
    dofile("src/scripts/core/storage/sqlite_event_store.lua")

    ledger = _G.AchaeadexLedger.Core.Ledger
    reports = _G.AchaeadexLedger.Core.Reports
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
    sqlite_store = _G.AchaeadexLedger.Core.SQLiteEventStore

    local ok, module = pcall(require, "luasql.sqlite3")
    if ok then
      luasql = module
    else
      luasql = nil
    end
  end)

  it("tracks CASH_INIT balances", function()
    local state = ledger.new(memory_store.new())

    ledger.apply_cash_init(state, "gold", 100000)

    assert.are.equal(100000, state.cash_accounts.gold)
  end)

  it("tracks multiple currencies independently", function()
    local state = ledger.new(memory_store.new())

    ledger.apply_cash_init(state, "gold", 100000)
    ledger.apply_cash_init(state, "credits", 5)

    assert.are.equal(100000, state.cash_accounts.gold)
    assert.are.equal(5, state.cash_accounts.credits)
  end)

  it("applies CASH_ADJUST deltas", function()
    local state = ledger.new(memory_store.new())

    ledger.apply_cash_init(state, "gold", 100000)
    ledger.apply_cash_adjust(state, "gold", -500, "manual correction")

    assert.are.equal(99500, state.cash_accounts.gold)
  end)

  it("converts between currencies without affecting profit totals", function()
    local state = ledger.new(memory_store.new())

    ledger.apply_cash_init(state, "credits", 5)
    ledger.apply_currency_convert(state, "credits", 1, "gold", 600)

    assert.are.equal(4, state.cash_accounts.credits)
    assert.are.equal(600, state.cash_accounts.gold)

    local report = reports.overall(state)
    assert.are.equal(0, report.totals.revenue)
    assert.are.equal(0, report.totals.operational_profit)
    assert.are.equal(0, report.totals.true_profit)
    assert.are.equal(2, #report.cash_balances)
  end)

  it("integrates broker buys and item sales into gold cash", function()
    local state = ledger.new(memory_store.new())

    ledger.apply_cash_init(state, "gold", 1000)
    ledger.apply_broker_buy(state, "leather", 5, 20)
    ledger.apply_design_start(state, "D1", "shirt", "Test", "public", 0)
    ledger.apply_craft_item(state, "I1", "D1", 40, "{}", nil)
    ledger.apply_sell_item(state, "S1", "I1", 100, { year = 650 })

    assert.are.equal(1000 - 100 + 100, state.cash_accounts.gold)
  end)

  it("rebuild preserves cash balances", function()
    if not luasql then
      pending("LuaSQL sqlite3 not available")
      return
    end

    local db_path = os.tmpname()
    local store = sqlite_store.new(db_path)
    local state = ledger.new(store)

    ledger.apply_cash_init(state, "gold", 100000)
    ledger.apply_cash_init(state, "credits", 5)
    ledger.apply_cash_adjust(state, "gold", -500, "manual correction")
    ledger.apply_currency_convert(state, "credits", 1, "gold", 600)

    local before = {
      gold = state.cash_accounts.gold,
      credits = state.cash_accounts.credits
    }

    store:rebuild_projections()

    local cur = assert(store.conn:execute("SELECT currency, balance FROM cash_accounts ORDER BY currency ASC"))
    local rows = {}
    local row = cur:fetch({}, "a")
    while row do
      rows[row.currency] = tonumber(row.balance)
      row = cur:fetch({}, "a")
    end
    cur:close()

    assert.are.equal(before.gold, rows.gold)
    assert.are.equal(before.credits, rows.credits)

    local fresh = ledger.new(store)
    for _, event in ipairs(store:read_all()) do
      ledger.apply_event(fresh, event)
    end

    assert.are.equal(before.gold, fresh.cash_accounts.gold)
    assert.are.equal(before.credits, fresh.cash_accounts.credits)
  end)
end)