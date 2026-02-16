---
applyTo: "**/*"
---

# Tests Instructions (Busted)

All core modules must be covered by busted tests.

------------------------------------------------------------
TEST 1 – WAC BLEND
------------------------------------------------------------

OPENING leather 10 @ 20
BUY leather 10 @ 40
Expected WAC = 30

------------------------------------------------------------
TEST 2 – GENERIC PROCESS_APPLY
------------------------------------------------------------

OPENING fibre 10 @ 5
OPENING coal 10 @ 2

PROCESS_APPLY:
  inputs: fibre=4, coal=4
  outputs: cloth=4
  gold_fee=0

Expected:
  fibre=6
  coal=6
  cloth=4
  cloth unit cost reflects consumed input WAC

------------------------------------------------------------
TEST 3 – PER ITEM FEE
------------------------------------------------------------

Design D1 per_item_fee=15
Craft item with material cost 40
Expected operational_cost=55

------------------------------------------------------------
TEST 4 – STRICT WATERFALL
------------------------------------------------------------

Pattern remaining=150
Design remaining=6000
op_profit=160

Expected:
  design_remaining=5840
  pattern_remaining=150
  true_profit=0

------------------------------------------------------------
TEST 5 – PATTERN RECOVERY AFTER DESIGN
------------------------------------------------------------

Design remaining=50
Pattern remaining=150
op_profit=100

Expected:
  design_remaining=0
  pattern_remaining=100
  true_profit=0

------------------------------------------------------------
TEST 6 – TRUE PROFIT
------------------------------------------------------------

Design remaining=0
Pattern remaining=20
op_profit=100

Expected:
  pattern_remaining=0
  true_profit=80

------------------------------------------------------------
TEST 7 – SHARED PATTERN POOL
------------------------------------------------------------

Two designs share pool=150.
Sell D1 profit=60.
Sell D2 profit=100.

Expected:
  pattern_remaining=0
  true_profit=10

------------------------------------------------------------
TEST 8 – SIMULATOR
------------------------------------------------------------

op_cost=50
design_remaining=6000
pattern_remaining=150

price=200

Expected units_needed=41
Expected price_needed(41)=200

------------------------------------------------------------
TEST 9 – INVALID SIMULATOR INPUT
------------------------------------------------------------

price <= op_cost
Expected: error, no division by zero.

------------------------------------------------------------
TEST 10 – DESIGN ID ALIASING (PRE-FINAL -> FINAL)
------------------------------------------------------------

Given:
- internal design_id = D1
- register alias_id = "1234" as pre_final active=1 -> resolves to D1
- register alias_id = "9876" as final active=1 -> resolves to D1
- mark "1234" active=0 (optional)

Expected:
- resolve("1234") == D1
- resolve("9876") == D1

------------------------------------------------------------
TEST 11 – CRAFT ATTRIBUTION VIA APPEARANCE + LATE RESOLUTION
------------------------------------------------------------

Given:
- design D1 exists
- map appearance_key "simple black shirt" -> D1 (manual mapping)
- craft item I1 with design_id = NULL and appearance_key="simple black shirt"
- later resolve craft I1 -> D1 via appearance map or craft resolve event

Expected:
- item I1 ends linked to D1
- selling I1 uses D1 recovery rules

------------------------------------------------------------
TEST 12 – PUBLIC/ORG DESIGN HAS NO RECOVERY BY DEFAULT
------------------------------------------------------------

Given:
- design Dpub provenance=public recovery_enabled=0
- craft+sell item with op_profit=100
Expected:
- applied_to_design_capital=0
- applied_to_pattern_capital=0
- true_profit increases by 100

Note:
- Operational costs still apply normally for public/org designs.
- Per-item production fees still count as operational cost even if recovery is disabled.

------------------------------------------------------------
TEST 13 – DEFERRED PROCESS (START -> COMPLETE)
------------------------------------------------------------

Scenario:
- OPENING fibre 10 @ 5
- OPENING coal 10 @ 2
- PROCESS_START P1 process_id="refine" inputs={fibre:4, coal:4} gold_fee=1
  (inputs are committed/consumed deterministically at start)
- Before completion: inventory shows fibre=6, coal=6 and cloth=0
- PROCESS_COMPLETE P1 outputs={cloth:4}

Expected:
- cloth increases by 4 only at completion
- total cost basis for produced cloth includes:
  - consumed fibre cost (4*5=20)
  - consumed coal cost (4*2=8)
  - gold fee (1)
- no output exists prior to completion

------------------------------------------------------------
TEST 14 – DEFERRED PROCESS WITH IN-FLIGHT ADDITIONS + ABORT DISPOSITION
------------------------------------------------------------

Scenario:
- OPENING ore 10 @ 3
- OPENING flux 10 @ 1
- PROCESS_START P2 process_id="smelt" inputs={ore:5} gold_fee=0
- PROCESS_ADD_INPUTS P2 inputs={flux:2}
- PROCESS_ADD_FEE P2 gold_fee=4
- PROCESS_ABORT P2 disposition:
    returned={ore:1}
    lost={ore:4, flux:2}
    outputs={}
Expected:
- returned ore is restored to inventory
- lost inputs are removed from inventory
- no outputs produced
- fees are accounted as costs of the failed process (no guessing)
