describe("Checkpoint helper", function()
  local checkpoint

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/checkpoint.lua")
    checkpoint = _G.AchaeadexLedger.Core.Checkpoint
  end)

  it("diffs currencies and omits zero deltas", function()
    local previous = {
      currencies = {
        gold = 100,
        bank = 50,
        boundcredits = 2,
        unboundcredits = 1,
        lessons = 10,
        mayancrowns = 0,
        unboundmayancrowns = 0
      }
    }
    local current = {
      currencies = {
        gold = 140,
        bank = 50,
        boundcredits = 2,
        unboundcredits = 4,
        lessons = 10,
        mayancrowns = 0,
        unboundmayancrowns = 0
      }
    }

    local diff = checkpoint.diff_snapshots(previous, current)

    assert.are.equal(2, #diff.sections.currencies.changes)
    assert.are.equal("gold", diff.sections.currencies.changes[1].resource)
    assert.are.equal(40, diff.sections.currencies.changes[1].delta)
    assert.are.equal("unboundcredits", diff.sections.currencies.changes[2].resource)
    assert.are.equal(3, diff.sections.currencies.changes[2].delta)

    local lines = checkpoint.render_diff(diff)
    assert.are.same({
      "Gold: +40",
      "Unbound credits: +3",
      "Inventory: unknown",
      "Rift: unknown"
    }, lines)
  end)

  it("groups inventory items by normalized display name", function()
    local snapshot = checkpoint.build_snapshot({
      currencies = {},
      inventory_known = true,
      inventory_items = {
        ["1"] = { id = 1, name = "Health Elixir" },
        ["2"] = { id = 2, name = "  health   elixir  " },
        ["3"] = { id = 3, name = "Pearl Ring" }
      },
      rift_known = false
    })

    assert.are.equal(2, snapshot.inventory["health elixir"])
    assert.are.equal(1, snapshot.inventory["pearl ring"])
  end)

  it("diffs grouped inventory counts", function()
    local previous = {
      currencies = {},
      inventory = {
        ["health elixir"] = 3,
        ["pearl ring"] = 1
      }
    }
    local current = {
      currencies = {},
      inventory = {
        ["health elixir"] = 1,
        ["pearl ring"] = 2
      }
    }

    local diff = checkpoint.diff_snapshots(previous, current)

    assert.are.equal(2, #diff.sections.inventory.changes)
    assert.are.equal(-2, diff.sections.inventory.changes[1].delta)
    assert.are.equal(1, diff.sections.inventory.changes[2].delta)

    local lines = checkpoint.render_diff(diff)
    assert.are.same({
      "Inventory:",
      "  health elixir: -2",
      "  pearl ring: +1",
      "Rift: unknown"
    }, lines)
  end)

  it("diffs rift contents", function()
    local previous = {
      currencies = {},
      rift = {
        moss = 50,
        goldenseal = 10
      }
    }
    local current = {
      currencies = {},
      rift = {
        moss = 30,
        goldenseal = 15
      }
    }

    local diff = checkpoint.diff_snapshots(previous, current)

    assert.are.equal(2, #diff.sections.rift.changes)
    assert.are.equal("goldenseal", diff.sections.rift.changes[1].resource)
    assert.are.equal(5, diff.sections.rift.changes[1].delta)
    assert.are.equal("moss", diff.sections.rift.changes[2].resource)
    assert.are.equal(-20, diff.sections.rift.changes[2].delta)
  end)

  it("handles partial or missing snapshots without erroring", function()
    local previous = {
      currencies = {
        gold = 100
      },
      inventory = nil,
      rift = nil
    }
    local current = {
      currencies = {
        gold = nil
      },
      inventory = {
        moss = 1
      },
      rift = nil
    }

    local diff = checkpoint.diff_snapshots(previous, current)
    local lines = checkpoint.render_diff(diff)

    assert.is_true(diff.sections.currencies.unknown)
    assert.is_true(diff.sections.inventory.unknown)
    assert.is_true(diff.sections.rift.unknown)
    assert.are.same({
      "Currencies: unknown",
      "Inventory: unknown",
      "Rift: unknown"
    }, lines)
  end)

  it("emits single-change diff entries", function()
    local previous = {
      currencies = {
        gold = 100,
        bank = 10,
        boundcredits = 0,
        unboundcredits = 0,
        lessons = 0,
        mayancrowns = 0,
        unboundmayancrowns = 0
      },
      inventory = {
        ["health elixir"] = 2
      },
      rift = {
        moss = 30
      }
    }
    local current = {
      currencies = {
        gold = 101,
        bank = 10,
        boundcredits = 0,
        unboundcredits = 0,
        lessons = 0,
        mayancrowns = 0,
        unboundmayancrowns = 0
      },
      inventory = {
        ["health elixir"] = 1
      },
      rift = {
        moss = 35
      }
    }

    local diff = checkpoint.diff_snapshots(previous, current)

    assert.are.equal(3, #diff.changes)
    assert.are.same({ "currency", "inventory", "rift" }, {
      diff.changes[1].type,
      diff.changes[2].type,
      diff.changes[3].type
    })
    assert.are.equal(1, diff.changes[1].delta)
    assert.are.equal(-1, diff.changes[2].delta)
    assert.are.equal(5, diff.changes[3].delta)
  end)

  it("renders zero-delta snapshots clearly", function()
    local snapshot = {
      currencies = {
        gold = 100,
        bank = 50,
        boundcredits = 0,
        unboundcredits = 0,
        lessons = 0,
        mayancrowns = 0,
        unboundmayancrowns = 0
      },
      inventory = {
        ["health elixir"] = 2
      },
      rift = {
        moss = 10
      }
    }

    local diff = checkpoint.diff_snapshots(snapshot, checkpoint.copy_snapshot(snapshot))
    local lines = checkpoint.render_diff(diff)

    assert.are.same({ "No changes since checkpoint." }, lines)
  end)
end)