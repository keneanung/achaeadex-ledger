---
applyTo: "**/*"
---

# Reporting Instructions (Overall, Yearly, Orders, Design View)

This file specifies reporting capabilities. It MUST NOT change existing economic invariants
(WAC, MtM opening, strict waterfall recovery, deferred processes, provenance rules).

All reports must be derived from the authoritative ledger / projections in a deterministic way.

------------------------------------------------------------
GENERAL REQUIREMENTS
------------------------------------------------------------

1) Reports must be deterministic and auditable.
2) All monetary values are integer gold.
3) Reports must emit warnings:
   - Opening inventory uses MtM
   - Time cost = 0
   - Design capital remaining > 0 (for recovery-enabled design sources)
   - Pattern capital remaining > 0 (for recovery-enabled design sources linked to pools)
   - Estimated materials used (if present)
4) Reports must display provenance + recovery_enabled for design sources.

Implementation:
- Prefer implementing reports in core (src/scripts/core/**) and rendering in Mudlet layer.

------------------------------------------------------------
GAME TIME (IRE.Time via GMCP)
------------------------------------------------------------

Goal:
- Enable reports grouped by in-game year.

Rules:
1) Mudlet integration must register GMCP module IRE.Time (gmod registration).
2) When recording a sale (SELL_ITEM), attach game_time if available:
   { year:int, month?:int, day?:int, hour?:int, minute?:int }
3) If game_time unavailable:
   - store null/omit
   - year-based reports must warn and exclude those sales by default unless explicitly included

Minimum required field: year

------------------------------------------------------------
OVERALL REPORT
------------------------------------------------------------

Command:
- adex report overall

Content (minimum):
- Revenue (sum of sale_price)
- Operational cost (sum of operational_cost)
- Operational profit = revenue - operational_cost
- Process losses (sum PROCESS_WRITE_OFF.amount_gold)
- Applied to design capital (sum)
- Applied to pattern capital (sum)
- True profit (sum), MUST be reduced by process losses
- Outstanding design capital (sum remaining for recovery-enabled design sources)
- Outstanding pattern capital (sum remaining across pools)

Warnings section:
- MtM present
- time cost = 0
- any unrecovered design/pattern capital

------------------------------------------------------------
YEAR REPORT (IN-GAME YEAR)
------------------------------------------------------------

Commands:
- adex report year <year>
- adex report year current

Behavior:
1) Filters by sale.game_time.year == <year>.
2) Sales with unknown game_time excluded by default and trigger a warning.

Content:
Same rollups as overall report, but restricted to that year.

Holdings snapshot (current as-of now):
- Inventory value (WAC)
- WIP value (in-flight processes)
- Unsold crafted items value (optional)
- Process losses total (overall sum; not year-filtered unless snapshots exist)

------------------------------------------------------------
ORDERS (GROUPING SALES)
------------------------------------------------------------

Goal:
- Group multiple sales into an order and produce a detailed report.

Data model (minimum):
- orders(order_id TEXT PK, created_at TEXT, customer TEXT NULL, note TEXT NULL, status TEXT)
- order_sales(order_id TEXT, sale_id TEXT, PRIMARY KEY(order_id, sale_id))
- order_items(order_id TEXT, item_id TEXT, PRIMARY KEY(order_id, item_id))
- order_settlements(settlement_id TEXT PK, order_id TEXT, amount_gold INT, received_at TEXT, method TEXT)

Order report:
- adex report order <order_id>
- Shows per-sale line items, per-item breakdown, and totals.
- Does NOT include global holdings.

------------------------------------------------------------
DESIGN VIEW (DESIGN SOURCES)
------------------------------------------------------------

Design report is based on production_sources where source_kind="design" (design_id == source_id).

Command:
- adex report design <design_id> [--items] [--orders] [--year <year>]

Design report content (minimum):

Header:
- design_id (source_id), name, design_type (source_type)
- provenance, recovery_enabled
- linked pattern_pool_id (if any)
- per_item_fee_gold
- design capital: remaining (if recovery_enabled)
- linked pattern pool: remaining (if recovery_enabled and linked)

Performance:
- crafted_count
- sold_count
- revenue
- operational_cost_total
- operational_profit_total
- process_losses_total (optional; global unless linked)
- applied_to_design_capital_total
- applied_to_pattern_capital_total
- true_profit_total

If --items:
- list sold items with per-item breakdown: item_id, sold_at, sale_price, operational_cost, true_profit

If --orders:
- list order_ids that include sales of this design (and optionally totals per order)

Warnings:
- time cost = 0
- unresolved crafts (crafted_items.source_id is NULL but appearance_key exists)
- sales with unknown game_time (if year filtering used)

Holdings (scoped):
- Unsold crafted items value for this design source (if applicable)

------------------------------------------------------------
ITEM REPORT
------------------------------------------------------------

- adex report item <item_id>

If sold:
- per-item P&L
If unsold:
- show operational_cost_gold as unsold basis

No global holdings.

------------------------------------------------------------
HOLDINGS / TIED-UP VALUE (INVENTORY, WIP, UNSOLD ITEMS)
------------------------------------------------------------

Definitions:
- Inventory value (WAC): sum(qty_on_hand * wac_unit_cost)
- WIP: sum(committed input basis + committed fees) for in-flight processes
- Unsold items value: sum(operational_cost_gold) for crafted_items not yet sold (optional)

Which reports include holdings:
A) Overall report: MUST include inventory + WIP + unsold + process losses line and true profit reduced by losses.
B) Year report: MUST include year activity + current holdings snapshot.
C) Order report: MUST NOT include global holdings.
D) Design report: MUST include design-scoped unsold items value; no global inventory.
E) Item report: MUST show unsold basis if unsold; no global inventory.

Warnings:
- If holdings component cannot be computed (e.g., missing WAC), emit WARNING.

------------------------------------------------------------
BACKWARD COMPATIBILITY
------------------------------------------------------------

- If older projections used crafted_items.design_id, treat it as design source_id.
- If legacy event type CRAFT_RESOLVE_DESIGN exists, treat it as resolving crafted_items.source_id.
- Reports must function after rebuild regardless of legacy table shapes.