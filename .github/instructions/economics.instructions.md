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
  - Per-item production fee (if configured on the source)
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
  - private (player-created, tracked capital + recovery)
  - public (freely available; no capital + no recovery)
  - organization (organizational design; typically no capital + no recovery unless explicitly configured)
  - unknown (fallback; no recovery)

Design Identity:
  Designs have in-game identifiers that may change when finalized.
  The system must support mapping/aliasing between these identifiers for the same design record.

Appearance:
  Crafting messages reference a design by its appearance, not by id.
  The system must support resolution from appearance -> design for crafting attribution.

Deferred Process:
  A process begins at time T0, may accrue additional costs during execution, and only at completion time T1 is output known.

------------------------------------------------------------
INVENTORY VALUATION
------------------------------------------------------------

1) Opening inventory MUST be initialized mark-to-market (MtM), per commodity.
2) Inventory costing method MUST be Weighted Average Cost (WAC).
3) Adjustments are FUTURE-ONLY (no restatement of historical reports by default).
FIFO, LIFO, or other methods are not allowed.

------------------------------------------------------------
PRODUCTION SOURCES
------------------------------------------------------------

All crafted items link to a production source:
- source_kind: "design" | "skill"
- source_id: stable id

Design sources:
- may participate in recovery depending on provenance + recovery_enabled
- may link to pattern pools
- may define BOM and pricing policy

Skill sources:
- default recovery_enabled = 0 (no capital recovery)
- may define per-item fees and recipes in future

------------------------------------------------------------
GENERIC PROCESSES (REFINEMENT / TRANSFORMATION)
------------------------------------------------------------

1) Must support generic multi-input, multi-output processes.
2) Process has inputs, outputs, optional gold_fee.
3) Catalysts are normal input commodities.
4) Refinement MUST NOT be hardcoded.
5) Operational cost of outputs derives from:
   - WAC of consumed inputs
   - plus gold_fee
   - plus time cost (if enabled)

------------------------------------------------------------
DEFERRED PROCESSES (START -> COMPLETE/ABORT)
------------------------------------------------------------

1) Must support deferred processes: start, accrue costs, complete/abort.
2) Before completion, outputs MUST NOT be assumed.
3) Inputs and in-flight costs must be associated with stable process_instance_id.
4) At completion, output basis MUST include:
   - WAC of all consumed inputs (start + in-flight),
   - plus all gold fees,
   - plus time cost if enabled.

Abort:
- Returned inputs are restored to inventory.
- Lost inputs remain sunk.
- Optional partial outputs may exist.

No guessing:
- Completion outputs may be empty.
- Abort may default to "assume lost remainder" only if explicitly invoked via CLI semantics.

------------------------------------------------------------
PROCESS LOSS RECOGNITION (WRITE-OFF)
------------------------------------------------------------

When a deferred process completes/aborts with insufficient outputs:
- committed_basis_gold = input_basis + fees
- output_basis_gold = basis assigned to outputs
- process_loss_gold = committed_basis_gold - output_basis_gold
If process_loss_gold > 0:
- record PROCESS_WRITE_OFF
- treat as operational expense (reduces true profit)
- must be attributable to process_instance_id

------------------------------------------------------------
PATTERNS
------------------------------------------------------------

- Pattern pools grouped by pattern_type.
- Only one pool per type active at a time.
- Designs started while active must link to pool.
- Pattern capital is strictly recovered before true profit.

------------------------------------------------------------
DESIGN SOURCES
------------------------------------------------------------

1) Design costs accumulate as capital only for recovery-enabled designs.
2) No amortization schedules (no forced "break-even plan").
3) Each crafted item links to exactly one production source.
4) Design id aliasing supports in-game id changes (pre-final/final/other).

Public/organization defaults:
- recovery_enabled=0
- operational costs still apply (materials/fees/time).

------------------------------------------------------------
PER-ITEM PRODUCTION FEES
------------------------------------------------------------

- Per-item fee is operational cost, not capital.
- Applies to every item linked to that production source.

------------------------------------------------------------
TIME COST
------------------------------------------------------------

- Configurable gold/hour, default 0.
- When enabled, part of operational cost.

------------------------------------------------------------
CRAFT ATTRIBUTION VIA APPEARANCE
------------------------------------------------------------

- Crafted item may lack source_id initially.
- Resolve via appearance mapping to a design source_id.
- Never guess mappings if ambiguous.

------------------------------------------------------------
STRICT WATERFALL RECOVERY
------------------------------------------------------------

On sale of an item linked to a recovery-enabled design source:

1) operational_profit = sale_price - operational_cost
2) Apply in order:
   a) reduce design capital remaining
   b) reduce pattern capital remaining (if linked pool)
   c) remainder is true profit

For non-recovery sources:
- operational_profit becomes true profit immediately.

------------------------------------------------------------
DESIGN BOM (STANDARD MATERIAL RECIPE)
------------------------------------------------------------

- Design sources may define BOM { commodity -> qty }.
- If BOM exists and craft does not specify materials, consume BOM at WAC.
- Explicit materials override BOM.
- Material consumption is operational cost.

------------------------------------------------------------
STUB DESIGN SOURCES
------------------------------------------------------------

If a craft references unknown design source_id:
- create stub design source (recovery_enabled=0, provenance=unknown, no pool)
- allow enrichment later (type/name/provenance/recovery/BOM/pricing)

------------------------------------------------------------
SIMULATOR (STRICT MODE DEFAULT)
------------------------------------------------------------

Given:
  op_cost
  design_remaining
  pattern_remaining

If recovery enabled:
  capital_required = design_remaining + pattern_remaining
Else:
  capital_required = 0

If price given:
  units_needed = ceil(capital_required / (price - op_cost))

If units given:
  price_needed = op_cost + capital_required / units

Invalid:
  price <= op_cost
  units <= 0