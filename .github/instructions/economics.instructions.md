---
applyTo: "**/*"
---

# Economics Instructions (Non-Negotiable Invariants)

This file defines the accounting model. Implementation MUST NOT alter these rules.

------------------------------------------------------------
TERMINOLOGY
------------------------------------------------------------

Commodity:
  Stackable input material (leather, cloth, coal, skins, fibre, metals, gems, catalysts, etc.)

Operational Cost:
  Sum of:
  - Material consumption at WAC
  - Direct gold fees
  - Per-item design production fee (if configured)
  - Time cost (if enabled)

Operational Profit:
  sale_price - operational_cost

Design Capital:
  Accumulated gold spent on design creation (submission, resubmission, finalize).

Pattern Capital:
  Gold spent to activate a pattern. Shared across all designs of that type during an activation period.

True Profit:
  Portion of operational profit remaining after both:
  - Design capital
  - Pattern capital
  have been fully recovered.

Design Provenance:
  A classification of the design’s ownership and whether it participates in capital recovery.
  Minimum required categories:
  - private (player-created, tracked capital + recovery)
  - public (freely available; no capital + no recovery)
  - organization (organizational design; typically no capital + no recovery unless explicitly configured)

Design Identity:
  Designs have in-game identifiers that may change when finalized.
  - pre-final in-game id (draft/submitted stage)
  - final in-game id (after finalization)
  The system must support mapping/aliasing between these identifiers for the same design record.

Appearance:
  Crafting messages reference a design by its appearance (text/label), not by id.
  The system must support resolution from appearance -> design for crafting attribution.

Deferred Process:
  A process that begins at time T0, may accrue additional costs/events during execution,
  and only at completion time T1 is the final output known.
  Costs must be accounted deterministically and must not be guessed before completion.

------------------------------------------------------------
INVENTORY VALUATION
------------------------------------------------------------

1) Opening inventory MUST be initialized mark-to-market (MtM), per commodity.
2) Inventory costing method MUST be Weighted Average Cost (WAC).
3) Adjustments are FUTURE-ONLY (no restatement of historical reports by default).

FIFO, LIFO, or other methods are not allowed.

------------------------------------------------------------
GENERIC PROCESSES (REFINEMENT / TRANSFORMATION)
------------------------------------------------------------

1) The system MUST support generic multi-input, multi-output processes.
2) A process consists of:
   - inputs: { commodity -> qty }
   - outputs: { commodity -> qty }
   - optional gold_fee
3) Catalysts are regular input commodities.
4) Refinement MUST NOT be hardcoded (e.g., fibre/coal is just one case).
5) Operational cost of outputs derives from:
   - WAC of consumed inputs
   - plus gold_fee
   - plus time cost (if enabled)

------------------------------------------------------------
DEFERRED PROCESSES (START -> COMPLETE)
------------------------------------------------------------

1) The system MUST support deferred processes which:
   - start at time T0,
   - may accrue additional costs while in-flight,
   - complete at time T1 when outputs become known.
2) Before completion, outputs MUST NOT be assumed or synthesized.
3) Inputs and in-flight costs MUST be associated with a stable process_instance_id.
4) At completion, the total cost basis of outputs MUST include:
   - WAC of all input commodities consumed at start (or explicitly reserved),
   - plus any additional commodity inputs or catalysts added during in-flight events,
   - plus any gold fees incurred at start or during the process,
   - plus time cost if enabled (if time is recorded as a cost event).
5) If a deferred process fails/aborts:
   - the system must record it explicitly,
   - and must deterministically account for what happened to reserved/consumed inputs
     (e.g., returned, partially returned, lost, or transformed).
   No guessing is allowed.

------------------------------------------------------------
PATTERNS
------------------------------------------------------------

1) Patterns are grouped by pattern_type (e.g., shirt, boots, jewellery).
2) Activating a pattern creates a PatternPool.
3) Only ONE PatternPool per type may be active at a time.
4) Designs started while a pool is active MUST link to that pool.
5) Deactivating a pattern:
   - closes the pool
   - prevents new designs from linking
   - existing designs remain linked
6) Pattern capital is STRICTLY accounted:
   - Must be fully recovered before true profit exists.

------------------------------------------------------------
DESIGNS
------------------------------------------------------------

1) Design costs accumulate as capital ONLY for designs that participate in capital recovery.
2) No amortization schedules.
3) No expected sales commitments.
4) Each crafted item links to exactly one design.
5) Design provenance impacts capital and recovery:
   - private designs: capital tracked + recovered via waterfall
   - public designs: no design capital and do not participate in recovery
   - organization designs: default behavior is same as public (no capital, no recovery) unless explicitly configured to behave like private
6) Design identity must handle in-game id changes:
   - A single internal design record may have multiple in-game IDs over time (aliases).
   - Finalization may replace the pre-final in-game ID with a new final in-game ID.
   - Both must resolve to the same internal design record.

------------------------------------------------------------
PER-ITEM DESIGN PRODUCTION FEES
------------------------------------------------------------

1) A design may define a per-item production fee.
   Examples:
     - jewellery setting fee
     - engraving fee
     - workshop fee
2) This fee is part of OPERATIONAL COST.
3) It is applied to EVERY crafted item of that design.
4) It is NOT capital.
5) Public and organization designs may have per-item production fees (if the game imposes them);
   such fees remain operational cost, even when design capital recovery is disabled.

------------------------------------------------------------
TIME COST
------------------------------------------------------------

1) Time cost is configurable (gold/hour).
2) Default = 0.
3) When enabled, it is part of operational cost.

------------------------------------------------------------
CRAFT ATTRIBUTION VIA APPEARANCE
------------------------------------------------------------

1) Crafting may not reference design IDs; instead, it may reference an appearance string.
2) The system MUST support resolving a crafted item to a design using appearance.
3) If appearance cannot be resolved deterministically:
   - The system MUST require explicit user resolution (manual mapping) rather than guessing.
4) Misattribution is worse than missing attribution:
   - If uncertain, do not assign a design automatically.

------------------------------------------------------------
STRICT WATERFALL RECOVERY
------------------------------------------------------------

For every sale:

1) operational_profit = sale_price - operational_cost

2) Apply in this order:

   a) Reduce design capital remaining (only if the linked design participates in recovery)
   b) Reduce pattern pool capital remaining (only if the linked design participates in recovery and has a linked pool)
   c) Remainder becomes true profit

This order MUST NEVER change.

Note:
- For public/organization designs that do not participate in recovery, operational profit becomes true profit immediately.

------------------------------------------------------------
REPORTING REQUIREMENTS
------------------------------------------------------------

Per sold item, report must show:

- sale_price
- operational_cost breakdown
- operational_profit
- applied_to_design_capital
- applied_to_pattern_capital
- true_profit
- remaining design capital (if applicable)
- remaining pattern capital (if applicable)

Warnings MUST appear when:
- Opening inventory uses MtM
- Time cost = 0
- Design capital remaining > 0 (for designs participating in recovery)
- Pattern capital remaining > 0 (for linked pools)

Additionally:
- Reports must clearly show design provenance (private/public/organization).
- If a craft was attributed via appearance mapping, report should indicate that mapping source.
- Reports involving deferred processes must indicate whether a process was completed or still in-flight
  when presenting inventory/output availability.

------------------------------------------------------------
SIMULATOR (STRICT MODE DEFAULT)
------------------------------------------------------------

Given:
  op_cost
  design_remaining
  pattern_remaining

For designs participating in recovery:
  capital_required = design_remaining + pattern_remaining

For designs NOT participating in recovery (public/organization default):
  capital_required = 0

If price given:
  units_needed = ceil(capital_required / (price - op_cost))

If units given:
  price_needed = op_cost + capital_required / units

Invalid:
  price <= op_cost
  units <= 0
technical.instructions.md