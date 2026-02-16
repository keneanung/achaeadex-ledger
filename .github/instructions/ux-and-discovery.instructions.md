---
applyTo: "**/*"
---

# UX + Discovery Instructions (Help, ID generation, Listing)

These requirements improve usability and do not change any economic invariants.

------------------------------------------------------------
HELP / USER DOCUMENTATION
------------------------------------------------------------

Goal:
- Users must be able to operate the tool from inside Mudlet without reading source code.

Rules:
1) `adex help` must provide:
   - a one-line description of the project
   - a short glossary of key terms (design capital, pattern pool, operational cost, true profit)
   - each command with:
     - purpose (what it does)
     - required arguments
     - optional flags
     - at least one example invocation
2) Provide additional scoped help:
   - `adex help <topic>` where topic in:
     - inv, broker, pattern, design, process, craft, sell, report, order, sim
3) Help text must be stable, concise, and actionable. Avoid vague descriptions.

------------------------------------------------------------
INTERNAL ID GENERATION
------------------------------------------------------------

Problem:
- Requiring users to manually generate internal IDs is error-prone.

Rules:
1) The system MUST be able to generate internal IDs for:
   - designs
   - pattern pools
   - crafted items
   - sales
   - process instances
   - orders
2) Each command that currently requires an explicit ID must support an auto-ID mode:
   - If the user supplies the ID, use it (validate uniqueness).
   - If the user omits the ID, generate it.
3) Generated IDs must:
   - be unique across the relevant entity type
   - be deterministic in format (human-friendly)
   - be printable and copyable from command output

Recommended format (example; implementation may vary but must be consistent):
- D-<YYYYMMDD>-<short>     (design)
- P-<YYYYMMDD>-<short>     (pattern pool)
- I-<YYYYMMDD>-<short>     (crafted item)
- S-<YYYYMMDD>-<short>     (sale)
- X-<YYYYMMDD>-<short>     (process instance)
- O-<YYYYMMDD>-<short>     (order)

Where <short> can be a short random/base32 token.

4) When an ID is auto-generated, the command output MUST clearly include:
   - "created_id: <ID>"
   so the user can reference it later.

------------------------------------------------------------
LIST / DISCOVERY COMMANDS
------------------------------------------------------------

Problem:
- Without listing, users cannot retrieve IDs later.

Rules:
1) Implement list commands for key entities:

- `adex list commodities`
  - shows known commodities and current quantity and WAC (if available)
  - supports filter: `--name <substring>`
  - supports sorting: `--sort name|qty|wac`

- `adex list patterns`
  - shows pattern pools: id, type, name, status, remaining, activated_at, deactivated_at
  - filter: `--type <pattern_type>`, `--status active|closed`

- `adex list designs`
  - shows designs: id, type, name, provenance, recovery_enabled, pattern_pool_id, design_remaining
  - filter: `--type <design_type>`, `--provenance ...`, `--recovery 0|1`

- `adex list items`
  - shows crafted items: item_id, design_id (or unresolved), appearance_key, crafted_at, sold?(yes/no)
  - filter: `--design <design_id>`, `--sold 0|1`, `--unresolved 1`

- `adex list sales`
  - shows sales: sale_id, item_id, sold_at, sale_price, game_year (if known), order_id (if linked)
  - filter: `--year <year>`, `--order <order_id>`

- `adex list orders`
  - shows orders: id, status, customer, created_at, total_sales_count, total_revenue

- `adex list processes`
  - shows process instances: id, process_id, status, started_at, completed_at
  - filter: `--status in_flight|completed|aborted`, `--process <process_id>`

2) Lists must be concise and readable in Mudlet.
   - MVP: plain text table-like columns.
   - Must be stable enough to copy IDs from.

3) List output must not require access to raw SQLite or internal files.

------------------------------------------------------------
IMPLEMENTATION NOTES
------------------------------------------------------------

1) Core should provide functions returning structured data (Lua tables) for listing and help topics.
2) Mudlet layer formats and prints.
3) Do not duplicate business logic: listing is read-only views on stored state/events.
4) Add busted tests for:
   - ID generator uniqueness + format
   - list functions returning expected entries after creating entities

Mudlet-only parsing is not required; this is manual-first UX.
