---
applyTo: "**/*"
---

# Technical Instructions (Architecture + Implementation)

------------------------------------------------------------
PROJECT TYPE
------------------------------------------------------------

- Must be a muddler project.
- Output must compile into a Mudlet-importable .mpackage.

------------------------------------------------------------
REPO STRUCTURE
------------------------------------------------------------

/src
  /scripts
    /core        # Pure Lua, fully unit-tested
    /mudlet      # Mudlet integration layer
/tests           # busted tests
/build           # generated artifacts

Core logic MUST NOT depend on Mudlet APIs.

------------------------------------------------------------
LANGUAGE
------------------------------------------------------------

- Lua 5.1 compatible.
- Avoid non-Mudlet-safe dependencies.

------------------------------------------------------------
DATABASE
------------------------------------------------------------

Use SQLite for persistence.

Schema must be versioned.

------------------------------------------------------------
PERSISTENCE MODEL (AUTHORITATIVE LEDGER + MATERIALIZED PROJECTIONS)
------------------------------------------------------------

The system uses a hybrid model:

1) `ledger_events` is the authoritative, append-only audit log.
   - Every user-visible action MUST produce one or more ledger events.
   - Events are immutable once written.

2) Domain tables are MATERIALIZED PROJECTIONS (read models) derived from the ledger.
   - They exist for fast listing and reporting.
   - They MUST be updated only by applying ledger events.
   - Code MUST NOT write to domain tables “directly” as a primary action.

3) Transactional guarantee:
   - Appending an event and applying it to projections MUST occur in the same SQLite transaction:
     BEGIN
       insert ledger_events
       apply event(s) to domain tables
     COMMIT
   - If applying to projections fails, the event must not be committed.

4) Rebuild capability (required):
   - Provide a rebuild mechanism that can recreate domain tables from `ledger_events` deterministically.
   - This is used for integrity checks, recovery, and future migrations.

5) Single-writer assumption (MVP):
   - Assume a single Mudlet client writes to the DB at a time.
   - Do not implement multi-writer concurrency for MVP.

6) Read path:
   - Reports and list commands should read from the domain tables for performance and simplicity.
   - If any report needs derived values not stored, it may compute them from the domain tables or from the event stream,
     but must remain deterministic.

------------------------------------------------------------
PRODUCTION SOURCES (UNIFIED MODEL)
------------------------------------------------------------

All crafting originates from a Production Source.

production_sources:
- source_id: stable internal id
- source_kind: "design" | "skill"
- source_type: design_type for designs; skill category for skills (future: conjuration/augmentation/forging)
- recovery_enabled: default depends on provenance for designs; for skills default 0
- pattern_pool_id only applies to source_kind="design"
- per_item_fee_gold may apply to any source
- bom_json and pricing_policy_json are supported (design sources for MVP; skills future)

Design IDs remain meaningful by using:
- For design sources: source_id equals the internal design id (e.g., D1, D-YYYYMMDD-xxxx).

------------------------------------------------------------
MINIMUM TABLES (CANONICAL PROJECTIONS)
------------------------------------------------------------

schema_version(
  version INTEGER PRIMARY KEY,
  applied_at TEXT
)

ledger_events(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL,
  event_type TEXT NOT NULL,
  payload_json TEXT NOT NULL
)

production_sources(
  source_id TEXT PRIMARY KEY,
  source_kind TEXT NOT NULL,           -- "design" | "skill"
  source_type TEXT NOT NULL,           -- design_type (design) or skill category (skill)
  name TEXT,
  created_at TEXT NOT NULL,
  pattern_pool_id TEXT,                -- nullable; design sources only
  per_item_fee_gold INTEGER NOT NULL DEFAULT 0,
  bom_json TEXT,                       -- JSON map { commodity: qty } for standard recipe
  pricing_policy_json TEXT,            -- JSON policy for suggestions
  provenance TEXT NOT NULL,            -- "private" | "public" | "organization" | "unknown"
  recovery_enabled INTEGER NOT NULL,   -- 1/0
  status TEXT NOT NULL,                -- flexible: in_progress/approved/retired/stub etc
  capital_remaining_gold INTEGER NOT NULL DEFAULT 0
)

design_id_aliases(
  alias_id TEXT PRIMARY KEY,           -- in-game design id
  source_id TEXT NOT NULL,             -- production_sources.source_id (design source)
  alias_kind TEXT NOT NULL,            -- pre_final|final|other
  active INTEGER NOT NULL,             -- 1/0
  created_at TEXT NOT NULL
)

design_appearance_aliases(
  appearance_key TEXT PRIMARY KEY,     -- normalized appearance string
  source_id TEXT NOT NULL,             -- production_sources.source_id (design source)
  created_at TEXT NOT NULL,
  confidence TEXT NOT NULL             -- manual|parsed
)

pattern_pools(
  pattern_pool_id TEXT PRIMARY KEY,
  pattern_type TEXT NOT NULL,
  pattern_name TEXT,
  activated_at TEXT NOT NULL,
  deactivated_at TEXT,
  capital_initial_gold INTEGER NOT NULL,
  capital_remaining_gold INTEGER NOT NULL,
  status TEXT NOT NULL                 -- active|closed
)

crafted_items(
  item_id TEXT PRIMARY KEY,
  source_id TEXT,                      -- nullable if unresolved at craft time
  source_kind TEXT NOT NULL DEFAULT 'design',
  crafted_at TEXT NOT NULL,
  operational_cost_gold INTEGER NOT NULL,
  cost_breakdown_json TEXT NOT NULL,
  appearance_key TEXT,
  materials_json TEXT,                 -- JSON map { commodity: qty } (optional)
  materials_source TEXT                -- design_bom|explicit|manual|estimated (optional)
)

external_items(
  item_id TEXT PRIMARY KEY,
  name TEXT,
  acquired_at TEXT NOT NULL,
  basis_gold INTEGER NOT NULL,
  basis_source TEXT NOT NULL,
  status TEXT NOT NULL,
  note TEXT
)

sales(
  sale_id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL,
  sold_at TEXT NOT NULL,
  sale_price_gold INTEGER NOT NULL,
  game_time_year INTEGER,
  game_time_month INTEGER,
  game_time_day INTEGER,
  game_time_hour INTEGER,
  game_time_minute INTEGER,
  settlement_id TEXT                   -- optional: link to order_settlements
)

orders(
  order_id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL,
  customer TEXT,
  note TEXT,
  status TEXT NOT NULL                 -- open|closed|cancelled
)

order_sales(
  order_id TEXT NOT NULL,
  sale_id TEXT NOT NULL,
  PRIMARY KEY (order_id, sale_id)
)

order_items(
  order_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  PRIMARY KEY (order_id, item_id)
)

order_settlements(
  settlement_id TEXT PRIMARY KEY,
  order_id TEXT NOT NULL,
  amount_gold INTEGER NOT NULL,
  received_at TEXT NOT NULL,
  method TEXT NOT NULL                 -- "cost_weighted" (MVP)
)

process_instances(
  process_instance_id TEXT PRIMARY KEY,
  process_id TEXT NOT NULL,
  started_at TEXT NOT NULL,
  completed_at TEXT,
  status TEXT NOT NULL,                -- in_flight|completed|aborted
  note TEXT
)

------------------------------------------------------------
LEGACY TABLES / COLUMNS (MAY EXIST IN OLDER DBS)
------------------------------------------------------------

These may exist in older installations and should be supported via migrations + rebuild:

designs(
  design_id TEXT PRIMARY KEY,
  design_type TEXT NOT NULL,
  name TEXT,
  created_at TEXT NOT NULL,
  pattern_pool_id TEXT,
  per_item_fee_gold INTEGER NOT NULL DEFAULT 0,
  bom_json TEXT,
  pricing_policy_json TEXT,
  provenance TEXT NOT NULL,
  recovery_enabled INTEGER NOT NULL,
  status TEXT NOT NULL,
  capital_remaining_gold INTEGER NOT NULL DEFAULT 0
)

Legacy crafted_items column:
- crafted_items.design_id (replaced by crafted_items.source_id/source_kind)

SQLite internal table may exist:
- sqlite_sequence (normal)

------------------------------------------------------------
INDEXES (REQUIRED)
------------------------------------------------------------

- ledger_events(ts)
- sales(item_id), sales(sold_at), sales(settlement_id)
- crafted_items(source_id), crafted_items(item_id)
- external_items(status), external_items(basis_source)
- pattern_pools(pattern_type, status)
- production_sources(source_kind), production_sources(source_type), production_sources(provenance), production_sources(recovery_enabled)
- order_sales(order_id), order_sales(sale_id)
- order_items(order_id), order_items(item_id)
- order_settlements(order_id)
- process_instances(status), process_instances(process_id)
- design_id_aliases(source_id)
- design_appearance_aliases(source_id)

------------------------------------------------------------
EVENT TYPES (AUTHORITATIVE)
------------------------------------------------------------

Inventory:
- OPENING_INVENTORY
- BROKER_BUY
- BROKER_SELL

Processes:
- PROCESS_APPLY
- PROCESS_START
- PROCESS_ADD_INPUTS
- PROCESS_ADD_FEE
- PROCESS_COMPLETE
- PROCESS_ABORT
- PROCESS_WRITE_OFF

Patterns:
- PATTERN_ACTIVATE
- PATTERN_DEACTIVATE

Design Sources:
- DESIGN_START
- DESIGN_UPDATE
- DESIGN_REGISTER_ALIAS
- DESIGN_REGISTER_APPEARANCE
- DESIGN_SET_BOM
- DESIGN_SET_PRICING
- DESIGN_COST
- DESIGN_SET_PER_ITEM_FEE

Crafting & Sales:
- CRAFT_ITEM
- CRAFT_RESOLVE_SOURCE
- SELL_ITEM

External Items:
- ITEM_REGISTER_EXTERNAL
- ITEM_UPDATE_EXTERNAL

Orders:
- ORDER_CREATE
- ORDER_ADD_ITEM
- ORDER_ADD_SALE
- ORDER_SETTLE
- ORDER_CLOSE (optional)

------------------------------------------------------------
EVENT PAYLOAD SPECIFICATIONS (MUST SUPPORT)
------------------------------------------------------------

OPENING_INVENTORY supports:
{
  commodity,
  qty,
  unit_cost
}

BROKER_BUY supports:
{
  commodity,
  qty,
  unit_cost
}

BROKER_SELL supports:
{
  commodity,
  qty,
  unit_price,
  cost,
  revenue,
  profit
}

PROCESS_APPLY must support:
{
  process_id,
  inputs: { commodity: qty },
  outputs: { commodity: qty },
  gold_fee
}

PROCESS_START must support:
{
  process_instance_id,
  process_id,
  inputs: { commodity: qty },         -- inputs committed at start (may be empty)
  gold_fee,                           -- optional
  note
}

PROCESS_ADD_INPUTS must support:
{
  process_instance_id,
  inputs: { commodity: qty },         -- additional inputs/catalysts added while in-flight
  note
}

PROCESS_ADD_FEE must support:
{
  process_instance_id,
  gold_fee,
  note
}

PROCESS_COMPLETE must support:
{
  process_instance_id,
  outputs: { commodity: qty },        -- MAY be empty
  note
}

PROCESS_ABORT must support:
{
  process_instance_id,
  disposition: {
    returned: { commodity: qty },     -- returned to inventory (may be empty)
    lost: { commodity: qty },         -- permanently lost/consumed (may be empty)
    outputs: { commodity: qty }       -- optional partial outputs on failure
  },
  note
}

PROCESS_WRITE_OFF supports:
{
  process_instance_id,
  amount_gold,
  game_time?,                          -- same shape as SELL_ITEM.game_time
  reason?,
  note?
}

PROCESS_SET_GAME_TIME supports:
{
  process_instance_id,
  scope,                               -- start|complete|abort|write_off|all
  game_time,                           -- same shape as SELL_ITEM.game_time
  note?
}

DESIGN_START supports:
{
  design_id,                          -- maps to source_id for design sources
  design_type,                        -- maps to source_type
  name,
  provenance,
  recovery_enabled,
  pattern_pool_id?,
  status?,
  bom?,
  created_at?
}

DESIGN_UPDATE supports:
{
  design_id,                          -- maps to source_id
  design_type?,
  name?,
  provenance?,
  recovery_enabled?,
  status?,
  pattern_pool_id?
}

DESIGN_REGISTER_ALIAS supports:
{
  design_id,                          -- maps to source_id
  alias_id,                           -- in-game id
  alias_kind,                         -- pre_final|final|other
  active                              -- 1/0
}

DESIGN_REGISTER_APPEARANCE supports:
{
  design_id,                          -- maps to source_id
  appearance_key,
  confidence                           -- manual|parsed
}

DESIGN_SET_BOM supports:
{
  design_id,                          -- maps to source_id
  bom                                 -- { commodity: qty }
}

DESIGN_SET_PRICING supports:
{
  design_id,                          -- maps to source_id
  pricing_policy                      -- JSON-serializable policy override
}

DESIGN_COST supports:
{
  design_id,                          -- maps to source_id
  amount_gold,
  kind                                -- submission|resubmission|finalization|other
}

DESIGN_SET_PER_ITEM_FEE supports:
{
  design_id,                          -- maps to source_id
  amount_gold
}

CRAFT_ITEM supports:
{
  item_id,
  source_id?,                         -- preferred (new)
  source_kind?,                       -- preferred (new), default "design"
  design_id?,                         -- legacy alias for source_id (design sources)
  appearance_key?,
  operational_cost_gold,
  breakdown_json,
  materials?,
  materials_source?,
  materials_cost_gold?
}

CRAFT_RESOLVE_SOURCE supports:
{
  item_id,
  source_id,
  source_kind,
  reason                               -- manual_map|appearance_map|other
}

SELL_ITEM supports:
{
  sale_id,
  item_id,
  sale_price_gold,
  sold_at,
  game_time?,                          -- object, must include year if present
  settlement_id?                       -- if created from order settlement
}

ORDER_CREATE supports:
{
  order_id,
  created_at?,
  customer?,
  note?,
  status?
}

ORDER_ADD_ITEM supports:
{
  order_id,
  item_id
}

ORDER_ADD_SALE supports:
{
  order_id,
  sale_id
}

ORDER_SETTLE supports:
{
  settlement_id,
  order_id,
  amount_gold,
  method,                              -- "cost_weighted"
  received_at
}

ORDER_CLOSE supports:
{
  order_id,
  closed_at?,
  status?
}

------------------------------------------------------------
BACKWARD COMPATIBILITY (LEDGER + PROJECTOR)
------------------------------------------------------------

Ledger events are immutable and MUST NOT be rewritten.

The projector MUST support legacy event payload shapes by translating them at apply time.

Legacy support requirements:
1) For any event payload that references designs by `design_id`:
   - treat `design_id` as `source_id` with `source_kind="design"`.

2) Legacy craft resolution event type:
   - If event_type is CRAFT_RESOLVE_DESIGN, interpret payload.design_id as source_id and apply as CRAFT_RESOLVE_SOURCE.

3) Legacy craft event payload:
   - If payload.source_id is missing and payload.design_id exists, use that value as source_id (design kind).

4) Domain tables:
   - Migrations may move legacy tables/columns into the new schema.
   - Rebuild must populate canonical projections regardless of legacy schema.

------------------------------------------------------------
PROJECTOR (APPLY EVENTS TO PROJECTIONS)
------------------------------------------------------------

- Deterministic and idempotent.
- Online write path: append event -> apply -> commit.
- Rebuild: truncate projections -> replay ledger -> apply.

PROCESS_WRITE_OFF:
- Must be persisted for reporting.
- Must not modify inventory.

------------------------------------------------------------
COMMANDS (MVP TOPICS)
------------------------------------------------------------

- inv
- broker
- pattern
- design
- process
- craft
- sell
- order
- report
- item
- sim
- price
- maintenance
- list
- config

------------------------------------------------------------
MAINTENANCE COMMANDS (MVP)
------------------------------------------------------------

- adex maintenance stats
- adex maintenance rebuild
- adex maintenance vacuum (optional)

------------------------------------------------------------
BUILD
------------------------------------------------------------

Build script must:
1) eval "$(luarocks --lua-version 5.1 path)"
2) Run busted
3) Build with muddler
4) Output .mpackage into /build