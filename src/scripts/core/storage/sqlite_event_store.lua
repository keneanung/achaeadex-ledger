-- LuaSQL sqlite3 EventStore implementation

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local sqlite_store = _G.AchaeadexLedger.Core.SQLiteEventStore or {}

local function get_schema()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.Schema then
    error("AchaeadexLedger.Core.Schema is not loaded")
  end

  return _G.AchaeadexLedger.Core.Schema
end

local function get_json()
  if not _G.AchaeadexLedger
    or not _G.AchaeadexLedger.Core
    or not _G.AchaeadexLedger.Core.Json then
    error("AchaeadexLedger.Core.Json is not loaded")
  end

  return _G.AchaeadexLedger.Core.Json
end

local function exec_sql(conn, sql)
  local result, err = conn:execute(sql)
  if not result then
    error("SQL execution failed: " .. tostring(err))
  end
  if type(result) == "userdata" then
    result:close()
  end
end

local function has_table(conn, name)
  local cur = assert(conn:execute(string.format(
    "SELECT name FROM sqlite_master WHERE type='table' AND name='%s'",
    name
  )))
  local row = cur:fetch({}, "a")
  cur:close()
  return row ~= nil
end

local function get_version(conn)
  if not has_table(conn, "schema_version") then
    return 0
  end
  local cur = assert(conn:execute("SELECT MAX(version) AS version FROM schema_version"))
  local row = cur:fetch({}, "a")
  cur:close()
  return row and tonumber(row.version) or 0
end

local function apply_migration(conn, version, sql)
  for statement in string.gmatch(sql, "[^;]+") do
    local trimmed = statement:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then
      exec_sql(conn, trimmed .. ";")
    end
  end

  exec_sql(conn, string.format(
    "INSERT INTO schema_version (version, applied_at) VALUES (%d, '%s')",
    version,
    os.date("!%Y-%m-%dT%H:%M:%SZ")
  ))
end

local function migrate(conn)
  local schema = get_schema()
  local current_version = get_version(conn)
  for version = current_version + 1, #schema.migrations do
    apply_migration(conn, version, schema.migrations[version])
  end
end

function sqlite_store.new(db_path)
  local ok, luasql = pcall(require, "luasql.sqlite3")
  if not ok or not luasql then
    error("LuaSQL sqlite3 not available")
  end

  local env
  if type(luasql) == "table" and type(luasql.sqlite3) == "function" then
    env = luasql.sqlite3()
  elseif type(luasql) == "function" then
    env = luasql()
  else
    error("LuaSQL sqlite3 module shape is unsupported")
  end

  local conn = env:connect(db_path)
  if not conn then
    error("Failed to open SQLite database")
  end

  migrate(conn)

  local store = {
    env = env,
    conn = conn
  }

  setmetatable(store, { __index = sqlite_store })

  return store
end

function sqlite_store:append(event)
  assert(type(event) == "table", "event must be a table")
  assert(type(event.event_type) == "string", "event_type must be a string")

  local json = get_json()
  local ts = event.ts or os.date("!%Y-%m-%dT%H:%M:%SZ")
  local payload_json = json.encode(event.payload or {})

  local insert_sql = string.format(
    "INSERT INTO ledger_events (ts, event_type, payload_json) VALUES ('%s', '%s', '%s')",
    ts:gsub("'", "''"),
    event.event_type:gsub("'", "''"),
    payload_json:gsub("'", "''")
  )

  exec_sql(self.conn, insert_sql)

  local cur = assert(self.conn:execute("SELECT last_insert_rowid() AS id"))
  local row = cur:fetch({}, "a")
  cur:close()
  return row and tonumber(row.id) or 0
end

function sqlite_store:read_all()
  local json = get_json()
  local events = {}

  local cur = assert(self.conn:execute("SELECT id, ts, event_type, payload_json FROM ledger_events ORDER BY id ASC"))
  local row = cur:fetch({}, "a")
  while row do
    local payload = json.decode(row.payload_json or "{}") or {}
    table.insert(events, {
      id = tonumber(row.id) or 0,
      ts = row.ts,
      event_type = row.event_type,
      payload = payload
    })
    row = cur:fetch({}, "a")
  end
  cur:close()

  return events
end

_G.AchaeadexLedger.Core.LuaSQLEventStore = sqlite_store
_G.AchaeadexLedger.Core.SQLiteEventStore = sqlite_store

return sqlite_store
