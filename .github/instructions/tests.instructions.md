---
applyTo: "**/*"
---

# Full Tests Instructions (Busted)

All core modules must be covered by busted tests.

Tests MUST validate correctness under:
1) Online apply path (append event + apply projector in one transaction)
2) Rebuild path (truncate projections + replay ledger deterministically)

All values are integer gold; no floating point.

------------------------------------------------------------
TEST 1 – WAC BLEND
------------------------------------------------------------

Given:
- OPENING_INVENTORY leather 10 @ 20
- BROKER_BUY leather 10 @ 40
Expected:
- WAC(leather) == 30

------------------------------------------------------------
TEST 2 – BROKER_SELL COST/REVENUE/PROFIT CONSISTENCY
------------------------------------------------------------

Given:
- OPENING_INVENTORY leather 10 @ 20
- BROKER_SELL leather qty=4 unit_price=35
Expected:
- cost == 4 * 20
- revenue == 4 * 35
- profit == revenue - cost
- inventory qty decreases by 4
- WAC remains 20 for remaining leather

------------------------------------------------------------
TEST 3 – GENERIC PROCESS_APPLY MULTI-INPUT OUTPUT BASIS
------------------------------------------------------------

Given:
- OPENING_INVENTORY fibre 10 @ 5
- OPENING_INVENTORY coal 10 @ 2
When:
- PROCESS_APPLY refine inputs {fibre:4, coal:4} outputs {cloth:4} gold_fee=0
Expected:
- fibre qty == 6
- coal qty == 6
- cloth qty == 4
- cloth total basis == (4*5 + 4*2)
- cloth unit basis == total_basis / 4

------------------------------------------------------------
TEST 4 – DEFERRED PROCESS START -> COMPLETE CREATES OUTPUT ON COMPLETE
------------------------------------------------------------

Given:
- OPENING_INVENTORY fibre 10 @ 5
- OPENING_INVENTORY coal 10 @ 2
When:
- PROCESS_START P1 process_id="refine" inputs {fibre:4, coal:4} gold_fee=1
- PROCESS_COMPLETE P1 outputs {cloth:4}
Expected:
- Before complete, cloth qty == 0
- After complete, cloth qty == 4
- cloth total basis == (4*5 + 4*2 + 1)

------------------------------------------------------------
TEST 5 – DEFERRED PROCESS IN-FLIGHT ADDITIONS + ABORT DISPOSITION
------------------------------------------------------------

Given:
- OPENING_INVENTORY ore 10 @ 3
- OPENING_INVENTORY flux 10 @ 1
When:
- PROCESS_START P2 inputs {ore:5}
- PROCESS_ADD_INPUTS P2 inputs {flux:2}
- PROCESS_ADD_FEE P2 gold_fee=4
- PROCESS_ABORT P2 disposition returned {ore:1} lost {ore:4, flux:2} outputs {}
Expected:
- ore qty net change: -5 +1 == -4
- flux qty net change: -2
- fee 4 is sunk
- process instance status == aborted

------------------------------------------------------------
TEST 6 – PROCESS_COMPLETE WITH NO OUTPUTS CREATES WRITE-OFF
------------------------------------------------------------

Given:
- OPENING_INVENTORY ore 10 @ 10
When:
- PROCESS_START P3 inputs {ore:5} gold_fee=10
- PROCESS_COMPLETE P3 outputs {}   (empty outputs)
Expected:
- ore decreases by 5
- No outputs created
- PROCESS_WRITE_OFF emitted with amount_gold == (5*10 + 10) == 60
- Overall/Year reports include Process losses line reflecting 60 (scope permitting)

------------------------------------------------------------
TEST 7 – PROCESS_COMPLETE WITH PARTIAL OUTPUTS CREATES WRITE-OFF FOR REMAINDER
------------------------------------------------------------

Given:
- OPENING_INVENTORY ore 10 @ 10
When:
- PROCESS_START P4 inputs {ore:5} gold_fee=0
- PROCESS_COMPLETE P4 outputs {metal:3}
And:
- Output basis assigned deterministically such that metal total basis == 30
Expected:
- committed_basis == 50
- output_basis == 30
- PROCESS_WRITE_OFF.amount_gold == 20

------------------------------------------------------------
TEST 8 – PATTERN RECOVERY WATERFALL: DESIGN FIRST
------------------------------------------------------------

Given:
- Pattern capital remaining = 150
- Design capital remaining = 6000
- op_profit = 160
Expected:
- design_remaining == 5840
- pattern_remaining == 150
- true_profit == 0

------------------------------------------------------------
TEST 9 – PATTERN RECOVERY WATERFALL: PATTERN AFTER DESIGN
------------------------------------------------------------

Given:
- Design remaining = 50
- Pattern remaining = 150
- op_profit = 100
Expected:
- design_remaining == 0
- pattern_remaining == 100
- true_profit == 0

------------------------------------------------------------
TEST 10 – TRUE PROFIT AFTER CAPITAL RECOVERY
------------------------------------------------------------

Given:
- Design remaining = 0
- Pattern remaining = 20
- op_profit = 100
Expected:
- pattern_remaining == 0
- true_profit == 80

------------------------------------------------------------
TEST 11 – SHARED PATTERN POOL ACROSS MULTIPLE DESIGNS
------------------------------------------------------------

Given:
- Pattern pool remaining=150 shared for pattern_type="shirt"
- Design source D1 and D2 both linked to the pool
When:
- Sell item from D1 with op_profit=60
- Sell item from D2 with op_profit=100
Expected:
- pool remaining == 0
- true_profit == 10

------------------------------------------------------------
TEST 12 – DESIGN ID ALIASING PRE-FINAL -> FINAL
------------------------------------------------------------

Given:
- internal design source_id = D1
When:
- DESIGN_REGISTER_ALIAS D1 alias_id="1234" alias_kind="pre_final" active=1
- DESIGN_REGISTER_ALIAS D1 alias_id="9876" alias_kind="final" active=1
Optional:
- set "1234" active=0
Expected:
- resolve in-game id "1234" -> D1
- resolve in-game id "9876" -> D1

------------------------------------------------------------
TEST 13 – APPEARANCE MAPPING + LATE RESOLUTION
------------------------------------------------------------

Given:
- design source D1 exists
- DESIGN_REGISTER_APPEARANCE D1 appearance_key="simple black shirt" confidence="manual"
When:
- CRAFT_ITEM I1 with source_id NULL and appearance_key="simple black shirt"
- later CRAFT_RESOLVE_SOURCE (or legacy CRAFT_RESOLVE_DESIGN) mapping I1 -> D1
Expected:
- crafted_items.I1.source_id == D1
- selling I1 applies D1 recovery rules

------------------------------------------------------------
TEST 14 – PUBLIC/ORG DESIGN DEFAULTS TO NO RECOVERY
------------------------------------------------------------

Given:
- design source Dpub provenance="public" recovery_enabled=0
When:
- craft+sell item linked to Dpub with op_profit=100
Expected:
- applied_to_design_capital == 0
- applied_to_pattern_capital == 0
- true_profit includes full 100

------------------------------------------------------------
TEST 15 – PER-ITEM FEE IS OPERATIONAL COST
------------------------------------------------------------

Given:
- design source D1 per_item_fee_gold=15
- material cost=40
When:
- craft item linked to D1
Expected:
- operational_cost_gold == 55 (+ time if enabled)

------------------------------------------------------------
TEST 16 – DESIGN BOM USED WHEN NO EXPLICIT MATERIALS PROVIDED
------------------------------------------------------------

Given:
- Inventory leather 10 @ 20
- design source D1 BOM {leather:2}
When:
- CRAFT_ITEM linked to D1 with no materials specified
Expected:
- leather decreases by 2
- materials_cost_gold == 40
- materials_source == "design_bom"

------------------------------------------------------------
TEST 17 – EXPLICIT MATERIALS OVERRIDE BOM
------------------------------------------------------------

Given:
- Inventory leather 10 @ 20, cloth 10 @ 5
- design source D1 BOM {leather:2}
When:
- CRAFT_ITEM linked to D1 with explicit materials {cloth:3}
Expected:
- cloth decreases by 3
- leather does not decrease

------------------------------------------------------------
TEST 18 – STUB DESIGN SOURCE CREATED FOR UNKNOWN SOURCE_ID
------------------------------------------------------------

Given:
- Inventory cloth 10 @ 5
When:
- CRAFT_ITEM with source_id="D-UNKNOWN" and explicit materials {cloth:2}
Expected:
- production_sources contains source_id "D-UNKNOWN" with:
  - source_kind "design"
  - provenance "unknown" (or equivalent)
  - recovery_enabled 0
- crafted item links to source_id "D-UNKNOWN"

------------------------------------------------------------
TEST 19 – ENRICH STUB DESIGN SOURCE LATER
------------------------------------------------------------

Given:
- stub design source exists
When:
- DESIGN_UPDATE sets name/type/provenance/recovery/status fields
- DESIGN_SET_BOM updates BOM
Expected:
- future crafts use updated BOM
- report design shows updated fields

------------------------------------------------------------
TEST 20 – SIMULATOR STRICT MODE
------------------------------------------------------------

Given:
- op_cost=50
- design_remaining=6000
- pattern_remaining=150
- price=200
Expected:
- units_needed == 41
And:
- given units=41 returns price_needed == 200 (or nearest exact per integer math policy)

------------------------------------------------------------
TEST 21 – SIMULATOR INVALID INPUTS
------------------------------------------------------------

Given:
- price <= op_cost OR units <= 0
Expected:
- error returned; no division by zero

------------------------------------------------------------
TEST 22 – PRICE SUGGESTION DEFAULTS + ROUNDING
------------------------------------------------------------

Given:
- crafted item base_cost_gold = 1210
- default pricing policy round_to_gold=50
Expected:
- rounded_base_gold = 1250
- low (0.60, min 200, cap 1500): suggested == 2000
- mid (0.90, min 400, cap 3000): raw 2375 -> rounded up == 2400
- high (1.20, min 600, cap 6000): suggested == 2750

------------------------------------------------------------
TEST 23 – PRICE SUGGESTION PROFIT CAP FOR EXPENSIVE ITEM
------------------------------------------------------------

Given:
- base_cost_gold = 8000
Expected:
- high tier profit_raw 9600 capped to 6000
- suggested == 14000

------------------------------------------------------------
TEST 24 – ORDER SETTLEMENT COST-WEIGHTED ALLOCATION (NO ROUNDING)
------------------------------------------------------------

Given:
- Order O1 contains items I1/I2/I3 with operational_cost_gold:
  I1=1000, I2=2000, I3=3000
When:
- ORDER_SETTLE amount_gold=9000 method="cost_weighted"
Expected:
- allocations: 1500, 3000, 4500 (floor + remainder)
- sum allocated == 9000 exactly
- created sales link to settlement_id
- order report totals == 9000 revenue and matches per-item lines

------------------------------------------------------------
TEST 25 – BACKWARD COMPAT: LEGACY CRAFT_ITEM PAYLOAD WITH design_id ONLY
------------------------------------------------------------

Given:
- ledger contains CRAFT_ITEM payload includes design_id="D1" and omits source_id/source_kind
When:
- maintenance rebuild replays events
Expected:
- crafted_items.source_id == "D1"
- crafted_items.source_kind == "design"

------------------------------------------------------------
TEST 26 – BACKWARD COMPAT: LEGACY EVENT TYPE CRAFT_RESOLVE_DESIGN
------------------------------------------------------------

Given:
- ledger contains event_type="CRAFT_RESOLVE_DESIGN" payload {item_id="I1", design_id="D1", reason="manual_map"}
When:
- rebuild
Expected:
- crafted_items.I1.source_id == "D1"
- crafted_items.I1.source_kind == "design"

------------------------------------------------------------
TEST 27 – BACKWARD COMPAT: LEGACY DESIGN EVENTS REPLAY INTO production_sources
------------------------------------------------------------

Given:
- DESIGN_START/UPDATE/SET_BOM/SET_PRICING payloads use design_id and omit source_id
When:
- rebuild
Expected:
- production_sources contains source_id == design_id with source_kind=="design"
- fields updated deterministically (type/name/provenance/recovery/status/pool/bom/pricing)

------------------------------------------------------------
TEST 28 – REBUILD CONSISTENCY SMOKE TEST
------------------------------------------------------------

Given:
- perform a sequence of actions (design start, pattern activate, craft, sell, process start/complete, order settle)
When:
- record report totals snapshot
- run maintenance rebuild
- recompute report totals
Expected:
- totals match exactly:
  - revenue
  - operational cost
  - operational profit
  - process losses
  - applied to design capital
  - applied to pattern capital
  - true profit
  - outstanding design capital
  - outstanding pattern capital

------------------------------------------------------------
TEST EXECUTION
------------------------------------------------------------

- Run tests with busted.
- Tests MUST pass for:
  1) online apply path (append event + apply projector)
  2) rebuild path (truncate projections + replay ledger)