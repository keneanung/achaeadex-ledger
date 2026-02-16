<p align="center">
  <img src="src/resources/logo.svg" width="140" alt="AchaeaDex Ledger logo" />
</p>

<h1 align="center">AchaeaDex Ledger</h1>

<p align="center">
  Profit and loss tracking for Achaea crafting (Mudlet) with strict accounting, pattern pools, and design capital recovery.
</p>

---

## What this is

**AchaeaDex Ledger** is a Mudlet package that tracks **profit and loss for commodity flows and crafted items** in Achaea.

The engine is generic and event-driven:
- multi-input / multi-output processes (including catalysts),
- deferred processes (start, add costs, complete later when outputs are known),
- strict capital recovery (design first, then shared pattern pool),
- WAC inventory costing and mark-to-market initialization.

This is an **accounting engine first**, Mudlet UI second.

---

## Economic model (short version)

Non-negotiables (see .github/instructions/economics.instructions.md for full detail):

- Opening inventory: mark-to-market per commodity
- Inventory costing: **Weighted Average Cost (WAC)** only
- Adjustments: future-only (no restatement by default)
- Patterns: activated as shared pools per type; strict recovery
- Design costs: tracked as capital; no forced amortization schedules
- Waterfall recovery: sale profit pays down **design -> pattern pool -> true profit**
- Design provenance: private vs public vs organization (public/org default: no recovery)
- Per-item fees: supported and counted as operational cost
- Sales price: actual realized price only
- Warnings: emitted for MtM, time cost = 0, and unrecovered capital

---

## Current capabilities

- Core ledger with WAC inventory and strict waterfall recovery
- Immediate and deferred processes (start, add inputs/fees, complete, abort)
- Design identity with aliasing (pre-final to final) and appearance-based attribution
- Orders and reports (overall, year, order, design, item)
- GMCP IRE.Time capture for year-based reporting
- Holdings reporting (inventory value, WIP value, unsold items value)
- ID auto-generation for designs, pools, items, sales, processes, and orders
- Discovery lists (commodities, patterns, designs, items, sales, orders, processes)
- Mudlet renderer with width-aware tables and optional color output
- Full busted test coverage for core behavior and reporting

---

## Commands (high level)

Use `adex help` in Mudlet for detailed usage and examples. Major command groups:

- `adex inv` for opening inventory
- `adex broker` for buys and sells
- `adex pattern` for pattern pools
- `adex design` for designs, aliases, and costs
- `adex process` for immediate and deferred processes
- `adex craft` and `adex sell`
- `adex order` for grouping sales
- `adex report` for overall/year/order/design/item
- `adex list` for discovery
- `adex sim` for capital recovery simulations
- `adex config` for output options

---

## Project structure

This repository is a **muddler** project.

- `src/scripts/core/` — pure Lua, no Mudlet APIs (unit-tested)
- `src/scripts/mudlet/` — Mudlet integration (commands, rendering, config)
- `tests/` — busted tests
- `build/` — generated .mpackage

---

## Quickstart (developer)

### 1) Run tests
```sh
eval "$(luarocks --lua-version 5.1 path)"
busted --verbose
```

### 2) Build the Mudlet package
```sh
./build.sh
```

---

## Mudlet usage

- Import the built .mpackage from the build directory.
- Run `adex help` for a full command glossary and examples.
- Use `adex config set color on|off` to toggle color output.

---

## Notes and limitations

- Manual entry is the MVP flow; parsing and triggers are optional.
- If a crafted item cannot be attributed to a design by appearance, the system requires manual resolution.
- Time cost is configurable and defaults to 0 (warnings are emitted).
