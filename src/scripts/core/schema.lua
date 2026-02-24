-- Schema migration module for Achaeadex Ledger
-- Manages SQLite schema versioning and migrations

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local schema = _G.AchaeadexLedger.Core.Schema or {}

-- Migration v1: Initial schema
schema.migrations = {
  [1] = [[
    CREATE TABLE IF NOT EXISTS schema_version (
      version INTEGER PRIMARY KEY,
      applied_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS ledger_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts TEXT NOT NULL,
      event_type TEXT NOT NULL,
      payload_json TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS designs (
      design_id TEXT PRIMARY KEY,
      design_type TEXT NOT NULL,
      name TEXT,
      created_at TEXT NOT NULL,
      pattern_pool_id TEXT,
      per_item_fee_gold INTEGER NOT NULL DEFAULT 0,
      provenance TEXT NOT NULL,
      recovery_enabled INTEGER NOT NULL,
      status TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS design_id_aliases (
      alias_id TEXT PRIMARY KEY,
      design_id TEXT NOT NULL,
      alias_kind TEXT NOT NULL,
      active INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY (design_id) REFERENCES designs(design_id)
    );

    CREATE TABLE IF NOT EXISTS design_appearance_aliases (
      appearance_key TEXT PRIMARY KEY,
      design_id TEXT NOT NULL,
      created_at TEXT NOT NULL,
      confidence TEXT NOT NULL,
      FOREIGN KEY (design_id) REFERENCES designs(design_id)
    );

    CREATE TABLE IF NOT EXISTS pattern_pools (
      pattern_pool_id TEXT PRIMARY KEY,
      pattern_type TEXT NOT NULL,
      pattern_name TEXT,
      activated_at TEXT NOT NULL,
      deactivated_at TEXT,
      capital_initial_gold INTEGER NOT NULL,
      capital_remaining_gold INTEGER NOT NULL,
      status TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS crafted_items (
      item_id TEXT PRIMARY KEY,
      design_id TEXT,
      crafted_at TEXT NOT NULL,
      operational_cost_gold INTEGER NOT NULL,
      cost_breakdown_json TEXT NOT NULL,
      appearance_key TEXT,
      FOREIGN KEY (design_id) REFERENCES designs(design_id)
    );

    CREATE TABLE IF NOT EXISTS sales (
      sale_id TEXT PRIMARY KEY,
      item_id TEXT NOT NULL,
      sold_at TEXT NOT NULL,
      sale_price_gold INTEGER NOT NULL,
      FOREIGN KEY (item_id) REFERENCES crafted_items(item_id)
    );

    CREATE TABLE IF NOT EXISTS process_instances (
      process_instance_id TEXT PRIMARY KEY,
      process_id TEXT NOT NULL,
      started_at TEXT NOT NULL,
      completed_at TEXT,
      status TEXT NOT NULL,
      note TEXT
    );
  ]],
  [2] = [[
    CREATE TABLE IF NOT EXISTS orders (
      order_id TEXT PRIMARY KEY,
      created_at TEXT NOT NULL,
      customer TEXT,
      note TEXT,
      status TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS order_sales (
      order_id TEXT NOT NULL,
      sale_id TEXT NOT NULL,
      PRIMARY KEY (order_id, sale_id),
      FOREIGN KEY (order_id) REFERENCES orders(order_id),
      FOREIGN KEY (sale_id) REFERENCES sales(sale_id)
    );

    ALTER TABLE sales ADD COLUMN game_time_year INTEGER;
    ALTER TABLE sales ADD COLUMN game_time_month INTEGER;
    ALTER TABLE sales ADD COLUMN game_time_day INTEGER;
    ALTER TABLE sales ADD COLUMN game_time_hour INTEGER;
    ALTER TABLE sales ADD COLUMN game_time_minute INTEGER;
  ]],
  [3] = [[
    ALTER TABLE designs ADD COLUMN capital_remaining_gold INTEGER NOT NULL DEFAULT 0;

    CREATE INDEX IF NOT EXISTS idx_ledger_events_ts ON ledger_events(ts);
    CREATE INDEX IF NOT EXISTS idx_sales_item_id ON sales(item_id);
    CREATE INDEX IF NOT EXISTS idx_sales_sold_at ON sales(sold_at);
    CREATE INDEX IF NOT EXISTS idx_crafted_items_design_id ON crafted_items(design_id);
    CREATE INDEX IF NOT EXISTS idx_crafted_items_item_id ON crafted_items(item_id);
    CREATE INDEX IF NOT EXISTS idx_pattern_pools_type_status ON pattern_pools(pattern_type, status);
    CREATE INDEX IF NOT EXISTS idx_designs_type ON designs(design_type);
    CREATE INDEX IF NOT EXISTS idx_designs_provenance ON designs(provenance);
    CREATE INDEX IF NOT EXISTS idx_designs_recovery ON designs(recovery_enabled);
    CREATE INDEX IF NOT EXISTS idx_order_sales_order_id ON order_sales(order_id);
    CREATE INDEX IF NOT EXISTS idx_order_sales_sale_id ON order_sales(sale_id);
    CREATE INDEX IF NOT EXISTS idx_process_instances_status ON process_instances(status);
    CREATE INDEX IF NOT EXISTS idx_process_instances_process_id ON process_instances(process_id);
    CREATE INDEX IF NOT EXISTS idx_design_id_aliases_design_id ON design_id_aliases(design_id);
    CREATE INDEX IF NOT EXISTS idx_design_appearance_aliases_design_id ON design_appearance_aliases(design_id);
  ]],
  [4] = [[
    ALTER TABLE designs ADD COLUMN bom_json TEXT;
    ALTER TABLE crafted_items ADD COLUMN materials_json TEXT;
    ALTER TABLE crafted_items ADD COLUMN materials_source TEXT;
  ]],
  [5] = [[
    ALTER TABLE designs ADD COLUMN pricing_policy_json TEXT;
    ALTER TABLE sales ADD COLUMN settlement_id TEXT;

    CREATE TABLE IF NOT EXISTS order_items (
      order_id TEXT NOT NULL,
      item_id TEXT NOT NULL,
      PRIMARY KEY (order_id, item_id),
      FOREIGN KEY (order_id) REFERENCES orders(order_id),
      FOREIGN KEY (item_id) REFERENCES crafted_items(item_id)
    );

    CREATE TABLE IF NOT EXISTS order_settlements (
      settlement_id TEXT PRIMARY KEY,
      order_id TEXT NOT NULL,
      amount_gold INTEGER NOT NULL,
      received_at TEXT NOT NULL,
      method TEXT NOT NULL,
      FOREIGN KEY (order_id) REFERENCES orders(order_id)
    );

    CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON order_items(order_id);
    CREATE INDEX IF NOT EXISTS idx_order_items_item_id ON order_items(item_id);
    CREATE INDEX IF NOT EXISTS idx_order_settlements_order_id ON order_settlements(order_id);
    CREATE INDEX IF NOT EXISTS idx_sales_settlement_id ON sales(settlement_id);
  ]],
  [6] = [[
    CREATE TABLE IF NOT EXISTS process_write_offs (
      write_off_id INTEGER PRIMARY KEY AUTOINCREMENT,
      process_instance_id TEXT NOT NULL,
      amount_gold INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      reason TEXT,
      note TEXT,
      FOREIGN KEY (process_instance_id) REFERENCES process_instances(process_instance_id)
    );

    CREATE INDEX IF NOT EXISTS idx_process_write_offs_instance ON process_write_offs(process_instance_id);
  ]]
}

-- Apply a specific migration
function schema.apply_migration(db, version)
  local migration = schema.migrations[version]
  if not migration then
    error("Migration version " .. version .. " not found")
  end

  local result = db:exec(migration)
  if result ~= 0 then  -- lsqlite3 returns 0 on success
    error("Failed to apply migration " .. version .. ": " .. db:errmsg())
  end

  -- Record the migration
  local stmt, err = db:prepare([[
    INSERT INTO schema_version (version, applied_at)
    VALUES (?, datetime('now'))
  ]])

  if not stmt then
    error("Failed to prepare statement: " .. tostring(err))
  end

  stmt:bind_values(version)
  stmt:step()
  stmt:finalize()

  return true
end

-- Get current schema version
function schema.get_version(db)
  -- Check if schema_version table exists
  local stmt, err = db:prepare([[
    SELECT name FROM sqlite_master 
    WHERE type='table' AND name='schema_version'
  ]])

  if not stmt then
    error("Failed to prepare statement: " .. tostring(err))
  end

  local has_table = false
  for _ in stmt:nrows() do
    has_table = true
    break
  end
  stmt:finalize()

  if not has_table then
    return 0
  end

  -- Get the latest version
  stmt, err = db:prepare([[
    SELECT MAX(version) AS version FROM schema_version
  ]])

  if not stmt then
    error("Failed to prepare statement: " .. tostring(err))
  end

  local version = 0
  for row in stmt:nrows() do
    if row.version then
      version = tonumber(row.version)
    end
  end
  stmt:finalize()

  return version
end

-- Migrate to the latest version
function schema.migrate(db, target_version)
  target_version = target_version or #schema.migrations
  local current_version = schema.get_version(db)

  if current_version >= target_version then
    return current_version
  end

  for version = current_version + 1, target_version do
    schema.apply_migration(db, version)
  end

  return schema.get_version(db)
end

_G.AchaeadexLedger.Core.Schema = schema

return schema
