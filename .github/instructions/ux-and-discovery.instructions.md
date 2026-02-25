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
  inv, broker, pattern, design, item, process, craft, sell, report, order, sim, price, list, maintenance, config
3) Help text must be stable, concise, and actionable.

------------------------------------------------------------
INTERNAL ID GENERATION
------------------------------------------------------------

Rules:
1) The system MUST be able to generate internal IDs for:
   - production sources (design sources and skill sources)
   - pattern pools
   - crafted items
   - sales
   - process instances
   - orders
   - settlements
2) Each command that requires an explicit ID must support auto-ID mode.
3) Generated IDs must be unique, consistent, and copyable.

Recommended formats:
- D-<YYYYMMDD>-<short>     (design source_id)
- P-<YYYYMMDD>-<short>     (pattern pool)
- I-<YYYYMMDD>-<short>     (crafted item)
- S-<YYYYMMDD>-<short>     (sale)
- X-<YYYYMMDD>-<short>     (process instance)
- O-<YYYYMMDD>-<short>     (order)
- T-<YYYYMMDD>-<short>     (settlement)

4) When auto-generated, output must include:
   - "created_id: <ID>"

------------------------------------------------------------
LIST / DISCOVERY COMMANDS
------------------------------------------------------------

Rules:
1) Implement list commands:

- `adex list commodities`
  - commodity, qty, WAC, value (qty*WAC if available)
  - filters: --name, sorting

- `adex list patterns`
  - pattern_pool_id, type, name, status, remaining, activated_at, deactivated_at
  - filters: --type, --status

- `adex list designs`
  - lists design sources (production_sources where source_kind="design"):
    source_id, source_type (design_type), name, provenance, recovery_enabled, pattern_pool_id, capital_remaining
  - filters: --type, --provenance, --recovery

- `adex list items`
  - item_id, kind(crafted|external), source_id(or external), appearance/name, created/acquired_at, sold?(yes/no)
  - filters: --source <source_id>, --sold 0|1, --unresolved 1

- `adex item add [<item_id>] <name> <basis_gold> [--basis purchase|mtm|gift|unknown] [--note <text>]`
  - registers external items with explicit basis for later augmentation/sale attribution

- `adex list sales`
  - sale_id, item_id, sold_at, sale_price, game_year (if known), order_id/settlement_id (if linked)
  - filters: --year, --order

- `adex list orders`
  - order_id, status, customer, created_at, total_items, total_revenue

- `adex list processes`
  - process_instance_id, process_id, status, started_at, completed_at
  - filters: --status, --process

- `adex process list --needs-year`
  - lists PROCESS_WRITE_OFF entries with unresolved game-year attribution

- `adex process set-year <process_instance_id> <year> [--scope write_off|start|complete|abort|all] [--note <text>]`
  - records PROCESS_SET_GAME_TIME correction event (no history rewrite)

2) Lists must be concise and readable in Mudlet; stable enough to copy IDs from.

------------------------------------------------------------
IMPLEMENTATION NOTES
------------------------------------------------------------

1) Core should provide functions returning structured data (Lua tables) for listing and help topics.
2) Mudlet layer formats and prints.
3) Do not duplicate business logic: listing is read-only views.
4) Add busted tests for:
   - ID generator uniqueness + format
   - list functions returning expected entries after creating entities

------------------------------------------------------------
BACKWARD COMPATIBILITY
------------------------------------------------------------

- User-facing "design" commands accept design_id, which equals the design source_id.
- Legacy references to design_id in outputs should be treated as design source_id.