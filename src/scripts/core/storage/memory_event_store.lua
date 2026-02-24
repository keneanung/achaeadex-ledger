-- In-memory EventStore implementation for tests

_G.AchaeadexLedger = _G.AchaeadexLedger or {}
_G.AchaeadexLedger.Core = _G.AchaeadexLedger.Core or {}

local memory = _G.AchaeadexLedger.Core.MemoryEventStore or {}

function memory.new()
  local store = {
    events = {},
    next_id = 1
  }
  setmetatable(store, { __index = memory })
  return store
end

function memory:append(event)
  assert(type(event) == "table", "event must be a table")
  assert(type(event.event_type) == "string", "event_type must be a string")

  local id = self.next_id
  self.next_id = self.next_id + 1

  local stored = {
    id = id,
    ts = event.ts or os.date("!%Y-%m-%dT%H:%M:%SZ"),
    event_type = event.event_type,
    payload = event.payload or {}
  }

  table.insert(self.events, stored)

  return id
end

function memory:read_all()
  local results = {}
  for _, event in ipairs(self.events) do
    table.insert(results, {
      id = event.id,
      ts = event.ts,
      event_type = event.event_type,
      payload = event.payload
    })
  end
  return results
end

function memory:append_events_and_apply(events)
  assert(type(events) == "table", "events must be a table")
  for _, event in ipairs(events) do
    local id = self:append(event)
    event.id = id
  end
  return events
end

_G.AchaeadexLedger.Core.MemoryEventStore = memory

return memory
