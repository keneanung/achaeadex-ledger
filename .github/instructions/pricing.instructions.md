---
applyTo: "**/*"
---

# Pricing Instructions (Suggested Prices + Lump-Sum Allocation)

These rules define price suggestion tooling and lump-sum order allocation.
They MUST NOT change accounting invariants (WAC, MtM opening, strict waterfall, provenance rules).

------------------------------------------------------------
SUGGESTED PRICING (ADVISORY ONLY)
------------------------------------------------------------

Goal:
- Automate price suggestions from an item’s creation cost basis at craft time.
- Suggested prices are NOT revenue. Only actual sale prices are revenue.

Definitions:
- base_cost_gold: the crafted item’s computed operational cost basis (materials at WAC + per-item fee + time cost if enabled).
- rounded_base_gold: base_cost_gold rounded UP to the next configured rounding step.

Rounding:
- Default rounding step: 50 gold
- rounded_base_gold = ceil(base_cost_gold / round_to_gold) * round_to_gold

Strategy:
- Only MARKUP strategy is required for MVP.
- markup means profit is computed as a percentage of rounded_base_gold.

Tiers:
- The system supports three tiers: low / mid / high.

Default global pricing policy (used when no source-level override exists for a design source):
- round_to_gold = 50
- tier low:
  - markup_percent = 0.60
  - min_profit_gold = 200
  - max_profit_gold = 1500
- tier mid:
  - markup_percent = 0.90
  - min_profit_gold = 400
  - max_profit_gold = 3000
- tier high:
  - markup_percent = 1.20
  - min_profit_gold = 600
  - max_profit_gold = 6000

Price formula:
- raw_profit = rounded_base_gold * markup_percent
- profit = clamp(raw_profit, min_profit_gold, max_profit_gold)
- suggested_price = rounded_base_gold + profit
- suggested_price must be rounded UP to the next round_to_gold step.

Source-level override:
- A design source MAY define its own pricing policy (pricing_policy_json).
- If present, source policy overrides global defaults for that source.

Craft-time behavior:
- When a craft is recorded, the system SHOULD be able to show suggested prices (low/mid/high)
  based on that item’s base_cost_gold.
- The system MAY store suggested prices with the crafted item for convenience.

Commands (MVP):
- adex price suggest <item_id>
  - prints base_cost_gold, rounded_base_gold and suggested prices for low/mid/high
  - indicates which policy was used (source override vs default)
- adex price order <order_id> [--tier low|mid|high|all] [--round <gold>] [--include-sold 0|1]
  - prints per-item suggestions and order-level lump-sum rollups
  - defaults: tier=all, include-sold=0, round from policy unless overridden
  - if order is settled/closed, suggestions remain informational only
- adex design pricing set <design_id> [policy fields...]
  - sets/updates pricing policy for the design source (design_id == source_id)

------------------------------------------------------------
LUMP-SUM ORDER SETTLEMENT (WEIGHTED ALLOCATION)
------------------------------------------------------------

Goal:
- Support orders where revenue is paid as a single lump sum, without itemized per-item prices.
- Allocate revenue across items deterministically so per-item P&L and recovery still function.

Rules:
1) An order may contain items (crafted_items).
2) A settlement records a single received amount for an order.
3) Allocation method (MVP): cost_weighted by each item’s base_cost_gold (operational_cost_gold).
4) Allocation MUST NOT apply any rounding-to-50 rule. Allocation is exact integer gold.

Allocation algorithm:
- Given items i=1..n with cost_i (operational_cost_gold) and total payment R:
  - total_cost = sum(cost_i)
  - for i=1..n-1:
      alloc_i = floor(R * cost_i / total_cost)
  - alloc_n = R - sum(alloc_1..alloc_{n-1})
- This guarantees sum(alloc_i) == R.

5) After settlement, the system creates one sale record per item with sale_price_gold = alloc_i.
   These sales must be linked back to the order and settlement for traceability.

Data requirements:
- Order items table: order_items(order_id, item_id)
- Order settlements table: order_settlements(settlement_id, order_id, amount_gold, received_at, method)

Reporting:
- Order report must show settlement amount, method, and per-item allocation breakdown.

------------------------------------------------------------
BACKWARD COMPATIBILITY
------------------------------------------------------------

- Pricing policies previously stored on designs must be treated as pricing_policy_json on the design source (source_id).
- The user-facing commands remain "design pricing set", accepting design_id which equals source_id.