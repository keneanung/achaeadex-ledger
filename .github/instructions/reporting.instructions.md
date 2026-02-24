---
applyTo: "**/*"
---

# Reporting Instructions (Overall, Yearly, Orders, Design View)

This file specifies additional reporting capabilities. It MUST NOT change existing economic invariants
(WAC, MtM opening, strict waterfall recovery, deferred processes, provenance rules).

All reports must be derived from the authoritative ledger / persisted records in a deterministic way.

------------------------------------------------------------
GENERAL REQUIREMENTS
------------------------------------------------------------

1) Reports must be deterministic and auditable.
   - Prefer computing from stored events/records rather than relying on current in-memory state.

2) All monetary values are integer gold. No floating point values.

3) Reports must emit warnings consistent with existing rules:
   - Opening inventory uses MtM
   - Time cost = 0
   - Design capital remaining > 0 (for recovery-enabled designs)
   - Pattern capital remaining > 0 (for recovery-enabled designs linked to a pool)

4) Reports must clearly display the provenance of designs (private/public/organization) and recovery_enabled.

5) The implementation should prefer adding reports as core functionality (src/scripts/core/**),
   with Mudlet integration only calling into core.

------------------------------------------------------------
GAME TIME (IRE.Time via GMCP)
------------------------------------------------------------

Goal:
- Enable reports grouped by in-game year.

Rules:
1) The Mudlet integration layer must register GMCP module IRE.Time.
   - Use gmod registration as required by Mudlet so gmcp.IRE.Time is populated.
2) When recording a sale (SELL_ITEM), the system MUST attach game_time information captured at that moment,
   if available.
3) If game_time is not available at sale time:
   - store game_time = null (or omit) for that sale
   - year-based reports must warn that some sales have unknown game_time and are excluded unless explicitly included

Data representation:
- game_time object stored with the sale (either in sales table or ledger event payload):
  { year: int, month: int?, day: int?, hour: int?, minute: int? }

Minimum required field:
- year

------------------------------------------------------------
OVERALL REPORT
------------------------------------------------------------

Command:
- adex report overall

Content (minimum):
- Revenue (sum of sale_price)
- Operational cost (sum of operational_cost)
- Operational profit = revenue - operational_cost
- Applied to design capital (sum)
- Applied to pattern capital (sum)
- True profit (sum)
- Outstanding design capital (sum of remaining for recovery-enabled designs)
- Outstanding pattern capital (sum of remaining for active/closed pools)

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
2) Sales with unknown game_time are excluded by default and must trigger a warning:
   "Some sales have unknown game time and were excluded."

Content (minimum):
Same rollups as overall report, but restricted to that year:
- Revenue
- Operational cost
- Operational profit
- Applied to design capital
- Applied to pattern capital
- True profit

Optional (nice-to-have):
- Top designs by revenue / true profit (list top N)

------------------------------------------------------------
ORDERS (GROUPING SALES)
------------------------------------------------------------

Goal:
- Group multiple sales into a named order and produce a detailed report.

Data model (minimum):
- orders(order_id TEXT PK, created_at TEXT, customer TEXT NULL, note TEXT NULL, status TEXT)
- order_sales(order_id TEXT, sale_id TEXT, PRIMARY KEY(order_id, sale_id))

Ledger events (minimum):
- ORDER_CREATE { order_id, customer?, note? }
- ORDER_ADD_SALE { order_id, sale_id }
- ORDER_CLOSE { order_id } (optional but recommended)

Commands:
- adex order create <order_id> [--customer "<name>"] [--note "<text>"]
- adex order add <order_id> <sale_id>
- adex order close <order_id>
- adex report order <order_id>

Rules:
1) Orders group SALES (sale_id), not crafts.
2) Adding a sale to an order must fail if:
   - order_id does not exist
   - sale_id does not exist
3) A sale may be part of multiple orders only if explicitly allowed.
   - MVP default: disallow; adding a sale already linked to another order must error.

Order report content (minimum):
- Header: order_id, customer, status, created_at, note (if present)
- Line items: for each sale in the order:
  - sale_id, item_id, design_id (if known), appearance (if known)
  - sale_price
  - operational_cost
  - operational_profit
  - applied_to_design_capital
  - applied_to_pattern_capital
  - true_profit
- Totals: same rollups as overall report but for the order only.
- Warnings applicable to included sales (time_cost=0, unrecovered pools, unknown design mapping, etc.)

------------------------------------------------------------
DESIGN VIEW REPORTS
------------------------------------------------------------

Commands:
- adex report design <design_id>
- adex report design <design_id> --items
- adex report design <design_id> --orders
- adex report design <design_id> --year <year>   (optional but recommended)

Design report content (minimum):

Header:
- design_id, name, design_type
- provenance, recovery_enabled
- linked pattern_pool_id (if any)
- per_item_fee_gold
- design capital: initial and remaining (if recovery_enabled)
- linked pattern pool: remaining (if recovery_enabled and linked)

Performance:
- crafted_count
- sold_count
- revenue
- operational_cost_total
- operational_profit_total
- applied_to_design_capital_total
- applied_to_pattern_capital_total
- true_profit_total

If --items:
- list sold items with per-item breakdown: item_id, sold_at, sale_price, operational_cost, true_profit

If --orders:
- list order_ids that include sales of this design (and optionally totals per order)

Warnings:
- time cost = 0
- design has unresolved crafts (crafted_items.design_id is NULL but appearance_key exists)
- design has sales with unknown game_time (if year filtering is used)

------------------------------------------------------------
HOLDINGS / TIED-UP VALUE (INVENTORY, WIP, UNSOLD ITEMS)
------------------------------------------------------------

Goal:
- Reports must show not only P&L-style totals, but also the value currently tied up in holdings.

Definitions:
- Inventory value (WAC): sum over all on-hand commodities of qty_on_hand * wac_unit_cost.
- In-flight process value (WIP): sum of committed input cost basis + committed fees for process instances with status=in_flight.
  (Only if deferred processes track committed basis; otherwise omit.)
- Unsold crafted items value: sum of operational_cost_gold for crafted_items not yet sold.
  (Optional; include only if crafted_items can exist unsold.)

Rules:
1) Reports MUST include the relevant holdings section unless explicitly excluded below.
2) Holdings must be computed deterministically from stored state/events (no guessing).

Which reports include which holdings:

A) Overall report:
- MUST include:
  - Inventory value (WAC)
  - In-flight process value (WIP), if applicable
  - Unsold crafted items value, if applicable
  - Process losses (sum of PROCESS_WRITE_OFF.amount_gold)
  - True profit MUST be reduced by Process losses.

B) Year report (in-game year):
- MUST include two holdings sections:
  1) Holdings snapshot (current, as-of now):
     - Inventory value (WAC)
     - WIP value (if applicable)
     - Unsold crafted items value (if applicable)
     - Process losses (sum of PROCESS_WRITE_OFF.amount_gold)
     - True profit MUST be reduced by Process losses.
  2) Year activity (year-filtered P&L rollups):
     - revenue, costs, applied capital, true profit, etc.

Rationale:
- Holdings are not naturally “year-filterable” unless snapshots exist.
- Therefore: year report shows (a) year activity and (b) current holdings.

C) Order report:
- MUST include:
  - Order totals (P&L for the order’s sales)
- MUST NOT include global inventory holdings (not relevant to order scope).
- MAY include a small note:
  - "Holdings not shown for order scope."

D) Design report:
- MUST include:
  - Design-specific holdings:
    - Unsold crafted items value for that design (if applicable)
  - MUST NOT include global inventory value (unless an optional flag is introduced later).
  - MAY include WIP value if a process instance can be explicitly linked to a design (future feature). MVP: omit.

E) Item report:
- MUST include:
  - If sold: the existing per-item P&L (already present).
  - If not sold: show its operational_cost_gold as “Unsold item cost basis”.
- MUST NOT include global inventory value.

Warnings:
- If any holdings component cannot be computed (e.g., missing WAC for a commodity):
  - emit a WARNING describing which component is incomplete.


------------------------------------------------------------
TEST REQUIREMENTS (BUSTED)
------------------------------------------------------------

Add tests (core level, no Mudlet dependencies):

1) Overall report totals:
   - create 2 sales
   - verify overall totals match sum of item contributions.

2) Year report:
   - create sales in two years (game_time injected into events/records)
   - verify year report includes only matching ones
   - verify unknown game_time excluded and warning emitted.

3) Order report:
   - create order, add sales, report totals and line items.

4) Design report:
   - create design, craft+sell 2 items
   - verify counts and totals
   - verify recovery contributions align with waterfall results.

Mudlet integration may have light smoke coverage (optional), but correctness is enforced by core tests.
