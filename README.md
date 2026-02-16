<p align="center">
  <img src="src/resources/logo.svg" width="140" alt="AchaeaDex Ledger logo" />
</p>

<h1 align="center">AchaeaDex Ledger</h1>

<p align="center">
  Profit & Loss tracking for Achaea crafting flows (Mudlet) — with strict accounting, pattern pools, and design cost recovery.
</p>

---

## What this is

**AchaeaDex Ledger** is a Mudlet package that tracks **profit/loss for commodity flows and crafted items** in Achaea.

The MVP focus is tailoring and design workflows, but the engine is intentionally generic:
- multi-input / multi-output processes (including catalysts),
- deferred processes (start → accrue costs → complete later when outputs become known),
- strict capital recovery (design first, then shared pattern pool),
- WAC inventory costing and mark-to-market initialization.

This is an **accounting engine first**, Mudlet UI second.

---

## Economic model (short version)

Non-negotiables (see `.github/instructions/economics.instructions.md` for full detail):

- **Opening inventory:** mark-to-market per commodity
- **Inventory costing:** **Weighted Average Cost (WAC)** only
- **Adjustments:** future-only (no restatement by default)
- **Patterns:** activated as **shared pools** per type; strict recovery
- **Design costs:** tracked as capital; **no forced amortization schedules**
- **Waterfall recovery:** sale profit pays down **design → pattern pool → true profit**
- **Design provenance:** private vs public vs organization (public/org default: no capital recovery)
- **Per-item fees:** supported (e.g., jewellery setting fee), counted as operational cost
- **Sales price:** actual realized price only
- **Warnings:** emitted when estimates/zero time-cost/unrecovered capital apply

---

## Project Status

**Phase 1 - COMPLETED:**
- ✅ SQLite schema migration v1
- ✅ Core ledger module
- ✅ WAC inventory logic
- ✅ Busted tests for all core functionality

**Phase 2 - TODO:**
- ⏳ Mudlet integration layer
- ⏳ Command system
- ⏳ Manual entry interface

## Project structure

This repository is a **muddler** project.

- Desirable dev loop:
  1) run unit tests with **busted**
  2) build `.mpackage` with **muddler**
  3) import into Mudlet

Suggested layout:

- `src/scripts/core/` — pure Lua, no Mudlet APIs (unit-tested)
- `src/scripts/mudlet/` — Mudlet integration (aliases, triggers, UI)
- `tests/` — busted tests
- `build/` — generated `.mpackage`

---

## Quickstart (developer)

### 1) Run tests
```sh
busted
