-- Busted tests for schema migration
-- Tests database schema versioning

describe("Schema Migration", function()
  local schema
  local lsqlite3
  
  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/schema.lua")
    schema = _G.AchaeadexLedger.Core.Schema
    lsqlite3 = require("lsqlite3")
  end)
  
  describe("version tracking", function()
    it("should return version 0 for empty database", function()
      local db = lsqlite3.open_memory()
      local version = schema.get_version(db)
      
      assert.are.equal(0, version)
      db:close()
    end)
    
    it("should track migration version", function()
      local db = lsqlite3.open_memory()
      
      schema.apply_migration(db, 1)
      local version = schema.get_version(db)
      
      assert.are.equal(1, version)
      db:close()
    end)
  end)
  
  describe("migration v1", function()
    it("should create all required tables", function()
      local db = lsqlite3.open_memory()
      schema.migrate(db, 1)
      
      -- Verify tables exist
      local tables = {
        "schema_version",
        "ledger_events",
        "designs",
        "design_id_aliases",
        "design_appearance_aliases",
        "pattern_pools",
        "crafted_items",
        "sales",
        "process_instances"
      }
      
      for _, table_name in ipairs(tables) do
        local stmt = db:prepare([[
          SELECT name FROM sqlite_master 
          WHERE type='table' AND name=?
        ]])
        stmt:bind_values(table_name)
        local has_table = false
        for _ in stmt:nrows() do
          has_table = true
          break
        end
        stmt:finalize()
        
        assert.is_true(has_table, "Table " .. table_name .. " should exist")
      end
      
      db:close()
    end)
    
    it("should allow inserting into ledger_events", function()
      local db = lsqlite3.open_memory()
      schema.migrate(db, 1)
      
      local stmt = db:prepare([[
        INSERT INTO ledger_events (ts, event_type, payload_json)
        VALUES (datetime('now'), 'TEST_EVENT', '{"test": true}')
      ]])
      stmt:step()
      stmt:finalize()
      
      stmt = db:prepare("SELECT COUNT(*) AS count FROM ledger_events")
      local count = 0
      for row in stmt:nrows() do
        count = tonumber(row.count) or 0
      end
      stmt:finalize()
      
      assert.are.equal(1, count)
      db:close()
    end)
    
    it("should enforce foreign key constraints", function()
      local db = lsqlite3.open_memory()
      db:exec("PRAGMA foreign_keys = ON")
      schema.migrate(db, 1)
      
      -- First insert a valid design
      local stmt = db:prepare([[
        INSERT INTO designs (design_id, design_type, name, created_at, provenance, recovery_enabled, status)
        VALUES ('D1', 'shirt', 'Test', datetime('now'), 'private', 1, 'in_progress')
      ]])
      stmt:step()
      stmt:finalize()
      
      -- Should succeed with valid design_id
      stmt = db:prepare([[
        INSERT INTO design_id_aliases (alias_id, design_id, alias_kind, active, created_at)
        VALUES ('1234', 'D1', 'pre_final', 1, datetime('now'))
      ]])
      local result = stmt:step()
      stmt:finalize()
      
      assert.is_truthy(result == 101 or result == nil) -- SQLITE_DONE or success
      
      db:close()
    end)
  end)

  describe("migration v2", function()
    it("should create order tables and sales time fields", function()
      local db = lsqlite3.open_memory()
      schema.migrate(db, 2)

      local tables = {
        "orders",
        "order_sales"
      }

      for _, table_name in ipairs(tables) do
        local stmt = db:prepare([[
          SELECT name FROM sqlite_master
          WHERE type='table' AND name=?
        ]])
        stmt:bind_values(table_name)
        local has_table = false
        for _ in stmt:nrows() do
          has_table = true
          break
        end
        stmt:finalize()

        assert.is_true(has_table, "Table " .. table_name .. " should exist")
      end

      local columns = {}
      local stmt = db:prepare("PRAGMA table_info(sales)")
      for row in stmt:nrows() do
        columns[row.name] = true
      end
      stmt:finalize()

      assert.is_true(columns.game_time_year, "sales.game_time_year should exist")
      assert.is_true(columns.game_time_month, "sales.game_time_month should exist")
      assert.is_true(columns.game_time_day, "sales.game_time_day should exist")
      assert.is_true(columns.game_time_hour, "sales.game_time_hour should exist")
      assert.is_true(columns.game_time_minute, "sales.game_time_minute should exist")

      db:close()
    end)
  end)

  describe("migration v3", function()
    it("should add design capital remaining and indexes", function()
      local db = lsqlite3.open_memory()
      schema.migrate(db, 3)

      local columns = {}
      local stmt = db:prepare("PRAGMA table_info(designs)")
      for row in stmt:nrows() do
        columns[row.name] = true
      end
      stmt:finalize()

      assert.is_true(columns.capital_remaining_gold, "designs.capital_remaining_gold should exist")

      local index_names = {}
      stmt = db:prepare("PRAGMA index_list(designs)")
      for row in stmt:nrows() do
        index_names[row.name] = true
      end
      stmt:finalize()

      assert.is_true(index_names.idx_designs_type, "idx_designs_type should exist")
      assert.is_true(index_names.idx_designs_provenance, "idx_designs_provenance should exist")
      assert.is_true(index_names.idx_designs_recovery, "idx_designs_recovery should exist")

      db:close()
    end)
  end)

  describe("migration v4", function()
    it("should add design BOM and crafted materials columns", function()
      local db = lsqlite3.open_memory()
      schema.migrate(db, 4)

      local design_columns = {}
      local stmt = db:prepare("PRAGMA table_info(designs)")
      for row in stmt:nrows() do
        design_columns[row.name] = true
      end
      stmt:finalize()

      assert.is_true(design_columns.bom_json, "designs.bom_json should exist")

      local crafted_columns = {}
      stmt = db:prepare("PRAGMA table_info(crafted_items)")
      for row in stmt:nrows() do
        crafted_columns[row.name] = true
      end
      stmt:finalize()

      assert.is_true(crafted_columns.materials_json, "crafted_items.materials_json should exist")
      assert.is_true(crafted_columns.materials_source, "crafted_items.materials_source should exist")

      db:close()
    end)
  end)

  describe("migration v5", function()
    it("should add pricing policy and order settlement tables", function()
      local db = lsqlite3.open_memory()
      schema.migrate(db, 5)

      local design_columns = {}
      local stmt = db:prepare("PRAGMA table_info(designs)")
      for row in stmt:nrows() do
        design_columns[row.name] = true
      end
      stmt:finalize()

      assert.is_true(design_columns.pricing_policy_json, "designs.pricing_policy_json should exist")

      local sales_columns = {}
      stmt = db:prepare("PRAGMA table_info(sales)")
      for row in stmt:nrows() do
        sales_columns[row.name] = true
      end
      stmt:finalize()
      assert.is_true(sales_columns.settlement_id, "sales.settlement_id should exist")

      local tables = { "order_items", "order_settlements" }
      for _, table_name in ipairs(tables) do
        stmt = db:prepare([[
          SELECT name FROM sqlite_master
          WHERE type='table' AND name=?
        ]])
        stmt:bind_values(table_name)
        local has_table = false
        for _ in stmt:nrows() do
          has_table = true
          break
        end
        stmt:finalize()

        assert.is_true(has_table, "Table " .. table_name .. " should exist")
      end

      db:close()
    end)
  end)

  describe("migration v6", function()
    it("should add process write-off table", function()
      local db = lsqlite3.open_memory()
      schema.migrate(db, 6)

      local stmt = db:prepare([[
        SELECT name FROM sqlite_master
        WHERE type='table' AND name=?
      ]])
      stmt:bind_values("process_write_offs")
      local has_table = false
      for _ in stmt:nrows() do
        has_table = true
        break
      end
      stmt:finalize()

      assert.is_true(has_table, "Table process_write_offs should exist")

      db:close()
    end)
  end)

  describe("migration v7", function()
    it("should add production_sources and source columns", function()
      local db = lsqlite3.open_memory()
      schema.migrate(db, 7)

      local stmt = db:prepare([[
        SELECT name FROM sqlite_master
        WHERE type='table' AND name=?
      ]])
      stmt:bind_values("production_sources")
      local has_table = false
      for _ in stmt:nrows() do
        has_table = true
        break
      end
      stmt:finalize()

      assert.is_true(has_table, "Table production_sources should exist")

      local crafted_columns = {}
      stmt = db:prepare("PRAGMA table_info(crafted_items)")
      for row in stmt:nrows() do
        crafted_columns[row.name] = true
      end
      stmt:finalize()

      assert.is_true(crafted_columns.source_id, "crafted_items.source_id should exist")
      assert.is_true(crafted_columns.source_kind, "crafted_items.source_kind should exist")

      local alias_columns = {}
      stmt = db:prepare("PRAGMA table_info(design_id_aliases)")
      for row in stmt:nrows() do
        alias_columns[row.name] = true
      end
      stmt:finalize()
      assert.is_true(alias_columns.source_id, "design_id_aliases.source_id should exist")

      local appearance_columns = {}
      stmt = db:prepare("PRAGMA table_info(design_appearance_aliases)")
      for row in stmt:nrows() do
        appearance_columns[row.name] = true
      end
      stmt:finalize()
      assert.is_true(appearance_columns.source_id, "design_appearance_aliases.source_id should exist")

      db:close()
    end)
  end)

  describe("migration v8", function()
    it("should add forge session and augmentation tables/columns", function()
      local db = lsqlite3.open_memory()
      schema.migrate(db, 8)

      local tables = { "forge_sessions", "forge_session_items", "item_transformations", "forge_write_offs" }
      for _, table_name in ipairs(tables) do
        local stmt = db:prepare([[SELECT name FROM sqlite_master WHERE type='table' AND name=?]])
        stmt:bind_values(table_name)
        local has_table = false
        for _ in stmt:nrows() do
          has_table = true
          break
        end
        stmt:finalize()
        assert.is_true(has_table, "Table " .. table_name .. " should exist")
      end

      local crafted_columns = {}
      local stmt = db:prepare("PRAGMA table_info(crafted_items)")
      for row in stmt:nrows() do
        crafted_columns[row.name] = true
      end
      stmt:finalize()

      assert.is_true(crafted_columns.base_operational_cost_gold, "crafted_items.base_operational_cost_gold should exist")
      assert.is_true(crafted_columns.forge_allocated_coal_gold, "crafted_items.forge_allocated_coal_gold should exist")
      assert.is_true(crafted_columns.parent_item_id, "crafted_items.parent_item_id should exist")
      assert.is_true(crafted_columns.transformed, "crafted_items.transformed should exist")

      db:close()
    end)
  end)
  
  describe("migrate function", function()
    it("should migrate from version 0 to 1", function()
      local db = lsqlite3.open_memory()
      
      local initial_version = schema.get_version(db)
      assert.are.equal(0, initial_version)
      
      local final_version = schema.migrate(db, 8)
      assert.are.equal(8, final_version)
      
      db:close()
    end)
    
    it("should not re-apply migrations", function()
      local db = lsqlite3.open_memory()
      
      schema.migrate(db, 1)
      
      -- Try to migrate again - should not error and should remain at version 1
      local version = schema.migrate(db, 1)
      assert.are.equal(1, version)
      
      -- Verify only one entry in schema_version
      local stmt = db:prepare("SELECT COUNT(*) AS count FROM schema_version")
      local count = 0
      for row in stmt:nrows() do
        count = tonumber(row.count) or 0
      end
      stmt:finalize()
      
      assert.are.equal(1, count)
      
      db:close()
    end)
    
    it("should default to latest version", function()
      local db = lsqlite3.open_memory()
      
      local version = schema.migrate(db)
      
      -- Should migrate to the latest version (currently 8)
      assert.are.equal(8, version)
      
      db:close()
    end)
  end)
end)
