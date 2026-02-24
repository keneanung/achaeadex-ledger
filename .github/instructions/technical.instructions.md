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

2) Domain tables (designs, pattern_pools, crafted_items, sales, orders, process_instances, alias tables)
   are MATERIALIZED PROJECTIONS (read models) derived from the ledger.
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
   - If any report needs derived values not stored, it may compute them from domain tables or from the event stream,
     but must remain deterministic.

------------------------------------------------------------
MINIMUM TABLES
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

designs(
  design_id TEXT PRIMARY KEY,         -- internal stable id (never changes)
  design_type TEXT NOT NULL,          -- used for pattern linking, simulator grouping, etc.
  name TEXT,
  created_at TEXT NOT NULL,
  pattern_pool_id TEXT,               -- nullable if design not linked or not eligible
  per_item_fee_gold INTEGER NOT NULL DEFAULT 0,
  bom_json TEXT,                      -- JSON map of standard materials (BOM)
  pricing_policy_json TEXT,           -- JSON policy override for price suggestions
  provenance TEXT NOT NULL,           -- "private" | "public" | "organization"
  recovery_enabled INTEGER NOT NULL,  -- 1/0; private defaults to 1, public/org default 0
  status TEXT NOT NULL,               -- in_progress/approved/retired etc (flexible)
  capital_remaining_gold INTEGER NOT NULL DEFAULT 0
)

-- Supports in-game ID changes (draft->final). Multiple aliases may map to one design.
design_id_aliases(
  alias_id TEXT PRIMARY KEY,          -- the in-game design id string
  design_id TEXT NOT NULL,            -- internal stable design_id
  alias_kind TEXT NOT NULL,           -- "pre_final" | "final" | "other"
  active INTEGER NOT NULL,            -- 1/0; latest final id can be active=1, old pre_final can be active=0
  created_at TEXT NOT NULL
)

-- Supports craft attribution when craft output only references appearance.
design_appearance_aliases(
  appearance_key TEXT PRIMARY KEY,    -- normalized appearance string/key
  design_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  confidence TEXT NOT NULL            -- "manual" | "parsed" (MVP: manual only recommended)
)

pattern_pools(
  pattern_pool_id TEXT PRIMARY KEY,
  pattern_type TEXT NOT NULL,
  pattern_name TEXT,
  activated_at TEXT NOT NULL,
  deactivated_at TEXT,
  capital_initial_gold INTEGER NOT NULL,
  capital_remaining_gold INTEGER NOT NULL,
  status TEXT NOT NULL                -- active/closed
)

crafted_items(
  item_id TEXT PRIMARY KEY,
  design_id TEXT,                     -- nullable if unresolved at craft time; must be resolvable later
  crafted_at TEXT NOT NULL,
  operational_cost_gold INTEGER NOT NULL,
  cost_breakdown_json TEXT NOT NULL,
  materials_json TEXT,                -- JSON map of materials used at craft
  materials_source TEXT,              -- "design_bom" | "explicit" | "manual"
  appearance_key TEXT                 -- store the observed appearance string/key for later resolution
)

sales(
  sale_id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL,
  sold_at TEXT NOT NULL,
  sale_price_gold INTEGER NOT NULL,
  settlement_id TEXT                  -- optional link to order_settlements
)

orders(
  order_id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL,
  customer TEXT,
  note TEXT,
  status TEXT NOT NULL
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
  method TEXT NOT NULL
)

-- Tracks deferred/in-flight processes so they can be completed later with known outputs.
process_instances(
  process_instance_id TEXT PRIMARY KEY,
  process_id TEXT NOT NULL,           -- e.g. refine, tan, smelt, cure, ferment, etc.
  started_at TEXT NOT NULL,
  completed_at TEXT,
  status TEXT NOT NULL,               -- "in_flight" | "completed" | "aborted"
  note TEXT
)

------------------------------------------------------------
INDEXES (REQUIRED)
------------------------------------------------------------

Add indexes to keep reads fast:

- ledger_events(id) (implicit by PK), and ledger_events(ts) if used for filtering
- sales(item_id), sales(sold_at)
- crafted_items(design_id), crafted_items(item_id)
- pattern_pools(pattern_type, status)
- designs(design_type), designs(provenance), designs(recovery_enabled)
- order_sales(order_id), order_sales(sale_id)
- order_items(order_id), order_items(item_id)
- order_settlements(order_id)
- sales(settlement_id)
- process_instances(status), process_instances(process_id)
- design_id_aliases(design_id)
- design_appearance_aliases(design_id)

------------------------------------------------------------
EVENT TYPES (REQUIRED FOR REBUILD)
------------------------------------------------------------

All of the following user-visible mutations MUST be represented as events in ledger_events:

Inventory:
- OPENING_INVENTORY
- BROKER_BUY

Processes:
- PROCESS_APPLY
- PROCESS_START
- PROCESS_ADD_INPUTS
- PROCESS_ADD_FEE
- PROCESS_COMPLETE
- PROCESS_ABORT

Patterns:
- PATTERN_ACTIVATE
- PATTERN_DEACTIVATE

Designs:
- DESIGN_START (or equivalent creation event)
- DESIGN_COST
- DESIGN_SET_PER_ITEM_FEE
- DESIGN_SET_BOM
- DESIGN_SET_PRICING
- DESIGN_UPDATE
- DESIGN_REGISTER_ALIAS
- DESIGN_REGISTER_APPEARANCE

Crafting & Sales:
- CRAFT_ITEM
- CRAFT_RESOLVE_DESIGN
- SELL_ITEM

Orders:
- ORDER_CREATE
- ORDER_ADD_ITEM
- ORDER_ADD_SALE
- ORDER_SETTLE
- ORDER_CLOSE (optional but recommended)

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
  outputs: { commodity: qty },        -- now known
  note
}

PROCESS_ABORT must support:
{
  process_instance_id,
  disposition: {
    returned: { commodity: qty },     -- returned to inventory
    lost: { commodity: qty },         -- permanently lost/consumed with no output
    outputs: { commodity: qty }       -- optional partial outputs on failure (if applicable)
  },
  note
}

DESIGN_REGISTER_ALIAS supports:
{
  design_id,
  alias_id,           -- in-game id
  alias_kind,         -- pre_final|final|other
  active              -- 1/0
}

DESIGN_REGISTER_APPEARANCE supports:
{
  design_id,
  appearance_key,     -- normalized appearance
  confidence          -- manual|parsed
}

DESIGN_SET_BOM supports:
{
  design_id,
  bom                -- { commodity: qty }
}

DESIGN_SET_PRICING supports:
{
  design_id,
  pricing_policy     -- JSON-serializable policy override
}

DESIGN_UPDATE supports:
{
  design_id,
  design_type?,
  name?,
  provenance?,
  recovery_enabled?,
  status?,
  pattern_pool_id?   -- derived when recovery_enabled=1
}

CRAFT_ITEM supports:
{
  item_id,
  design_id (optional),
  appearance_key (optional but recommended),
  operational_cost_gold,
  breakdown_json,
  materials (optional),
  materials_source (optional),
  materials_cost_gold (optional)
}

CRAFT_RESOLVE_DESIGN supports:
{
  item_id,
  design_id,
  reason              -- e.g. "manual_map" | "appearance_map"
}

SELL_ITEM supports:
{
  sale_id,
  item_id,
  sale_price_gold,
  sold_at,
  game_time?,
  settlement_id?     -- if created from order settlement
}

ORDER_ADD_ITEM supports:
{
  order_id,
  item_id
}

ORDER_SETTLE supports:
{
  settlement_id,
  order_id,
  amount_gold,
  method,            -- "cost_weighted"
  received_at
}

------------------------------------------------------------
GENERIC PROCESS SEMANTICS
------------------------------------------------------------

1) PROCESS_APPLY is for immediate processes where outputs are known at event time.
2) Deferred processes MUST use PROCESS_START/COMPLETE (and optional ADD_* events).
3) Inventory accounting rules for deferred processes:
   - Inputs committed via PROCESS_START and PROCESS_ADD_INPUTS are treated as consumed/reserved deterministically.
   - Outputs do not exist until PROCESS_COMPLETE or PROCESS_ABORT disposition includes outputs.
   - No output may be assumed prior to completion.

Implementation note:
- For simplicity and determinism, treat committed inputs as consumed from inventory at the time they are committed.
- If the game semantics are "reserved then consumed", the system may represent this as a separate internal bucket,
  but accounting must remain deterministic and testable.

------------------------------------------------------------
DESIGN WORKFLOW REQUIREMENTS
------------------------------------------------------------

1) A design has a stable internal design_id.
2) In-game IDs can change at finalization. The system must support:
   - registering a pre-final alias id
   - registering a final alias id
   - marking alias active/inactive
   - resolving either alias id to internal design_id

3) Craft attribution may come only via appearance:
   - Provide a manual command to map an appearance_key to a design_id.
   - Craft events may initially store appearance_key and design_id=NULL.
   - Later, CRAFT_RESOLVE_DESIGN binds the crafted item to a design_id.

4) The system must never guess mapping if ambiguous:
   - If an appearance_key maps to multiple designs, require manual resolution.
   - Default confidence is "manual" for MVP.

------------------------------------------------------------
WATERFALL IMPLEMENTATION
------------------------------------------------------------

On SELL_ITEM:

1) Compute operational_profit
2) If the linked design has recovery_enabled=1:
   - Reduce design capital
   - Reduce pattern capital (if design has a pattern_pool_id)
   - Remaining becomes true profit
3) If recovery_enabled=0:
   - operational_profit is true profit immediately

Never compute amortization per unit.

------------------------------------------------------------
PROJECTOR (APPLY EVENTS TO PROJECTIONS)
------------------------------------------------------------

1) Implement an event projector that applies a ledger event to the domain tables.
2) The projector MUST be deterministic and idempotent for rebuild purposes.
3) The online write path MUST be:
   - append event -> apply projector -> commit transaction
4) The rebuild path MUST:
   - truncate domain tables
   - replay all ledger_events in order (by id)
   - apply projector for each event
   - produce the same domain table state as normal operation

5) Reports and lists should use the domain tables, not recompute everything by replaying events each time.

------------------------------------------------------------
COMMANDS (MVP)
------------------------------------------------------------

inv init
broker buy
pattern activate
pattern deactivate

design start <design_id> <type> <name> [--provenance private|public|organization] [--recovery 0|1]
design update <design_id> [--type <type>] [--name <name>] [--provenance private|public|organization] [--recovery 0|1]
design alias add <design_id> <alias_id> <pre_final|final|other> [--active 0|1]
design appearance map <design_id> <appearance_key>         -- manual mapping

design bom set <design_id> --materials <k=v,...>
design bom show <design_id>

design cost <design_id> <amount> <kind>
design set-fee <design_id> <amount>
design pricing set <design_id> [--round <gold>] [--low-markup <pct>] [--low-min <gold>] [--low-max <gold>]
                              [--mid-markup <pct>] [--mid-min <gold>] [--mid-max <gold>]
                              [--high-markup <pct>] [--high-min <gold>] [--high-max <gold>]

-- Immediate process:
process apply <process_id> --inputs <k=v,...> --outputs <k=v,...> [--fee <gold>] [--note <text>]

-- Deferred process lifecycle:
process start <process_instance_id> <process_id> [--inputs <k=v,...>] [--fee <gold>] [--note <text>]
process add-inputs <process_instance_id> --inputs <k=v,...> [--note <text>]
process add-fee <process_instance_id> --fee <gold> [--note <text>]
process complete <process_instance_id> --outputs <k=v,...> [--note <text>]
process abort <process_instance_id> --returned <k=v,...> --lost <k=v,...> [--outputs <k=v,...>] [--note <text>]

craft <item_id> [--materials <k=v,...>] [--appearance <appearance_key>] [--design <design_id>] [--time <hours>] [--cost <gold>]
craft resolve <item_id> <design_id>                         -- binds after the fact (manual)

sell <sale_id> <item_id> <sale_price>

order add-item <order_id> <item_id>
order settle <order_id> <amount_gold> [--method cost_weighted]

report item <item_id>
sim price <design_id> <price>
sim units <design_id> <units>
price suggest <item_id>

Manual entry only required for MVP.
Triggers/parsing are optional and must not be required.

------------------------------------------------------------
MAINTENANCE COMMANDS (MVP)
------------------------------------------------------------

Provide at least:

- adex maintenance stats
  - prints: ledger_events count, DB size (if available), last event id, and optionally last rebuild timestamp

- adex maintenance rebuild
  - rebuilds domain tables by replaying ledger_events
  - prints: counts per domain table after rebuild
  - MUST NOT lose ledger_events

Optional:
- adex maintenance vacuum
  - runs SQLite VACUUM (manual, user-invoked)

------------------------------------------------------------
BUILD
------------------------------------------------------------

Build script must:
1) eval "$(luarocks --lua-version 5.1 path)"
2) Run busted
3) Build with muddler
4) Output .mpackage into /build
