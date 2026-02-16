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
  provenance TEXT NOT NULL,           -- "private" | "public" | "organization"
  recovery_enabled INTEGER NOT NULL,  -- 1/0; private defaults to 1, public/org default 0
  status TEXT NOT NULL                -- in_progress/approved/retired etc (flexible)
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
  appearance_key TEXT                 -- store the observed appearance string/key for later resolution
)

sales(
  sale_id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL,
  sold_at TEXT NOT NULL,
  sale_price_gold INTEGER NOT NULL
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
EVENT TYPES
------------------------------------------------------------

OPENING_INVENTORY
BROKER_BUY
BROKER_SELL

-- Immediate (fully-known) process application:
PROCESS_APPLY

-- Deferred process lifecycle:
PROCESS_START
PROCESS_ADD_INPUTS
PROCESS_ADD_FEE
PROCESS_COMPLETE
PROCESS_ABORT

DESIGN_COST
PATTERN_ACTIVATE
PATTERN_DEACTIVATE
DESIGN_SET_PER_ITEM_FEE
DESIGN_REGISTER_ALIAS
DESIGN_REGISTER_APPEARANCE
CRAFT_ITEM
SELL_ITEM
CRAFT_RESOLVE_DESIGN

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

CRAFT_ITEM supports:
{
  item_id,
  design_id (optional),
  appearance_key (optional but recommended),
  operational_cost_gold,
  breakdown_json
}

CRAFT_RESOLVE_DESIGN supports:
{
  item_id,
  design_id,
  reason              -- e.g. "manual_map" | "appearance_map"
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
COMMANDS (MVP)
------------------------------------------------------------

inv init
broker buy
pattern activate
pattern deactivate

design start <design_id> <type> <name> [--provenance private|public|organization] [--recovery 0|1]
design alias add <design_id> <alias_id> <pre_final|final|other> [--active 0|1]
design appearance map <design_id> <appearance_key>         -- manual mapping

design cost <design_id> <amount> <kind>
design set-fee <design_id> <amount>

-- Immediate process:
process apply <process_id> --inputs <k=v,...> --outputs <k=v,...> [--fee <gold>] [--note <text>]

-- Deferred process lifecycle:
process start <process_instance_id> <process_id> [--inputs <k=v,...>] [--fee <gold>] [--note <text>]
process add-inputs <process_instance_id> --inputs <k=v,...> [--note <text>]
process add-fee <process_instance_id> --fee <gold> [--note <text>]
process complete <process_instance_id> --outputs <k=v,...> [--note <text>]
process abort <process_instance_id> --returned <k=v,...> --lost <k=v,...> [--outputs <k=v,...>] [--note <text>]

craft <item_id> [<design_id>] <operational_cost> [--appearance <appearance_key>]
craft resolve <item_id> <design_id>                         -- binds after the fact (manual)

sell <sale_id> <item_id> <sale_price>

report item <item_id>
sim price <design_id> <price>
sim units <design_id> <units>

Manual entry only required for MVP.
Triggers/parsing are optional and must not be required.

------------------------------------------------------------
BUILD
------------------------------------------------------------

Build script must:
1) eval "$(luarocks --lua-version 5.1 path)"
2) Run busted
3) Build with muddler
4) Output .mpackage into /build
