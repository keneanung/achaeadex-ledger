---
applyTo: "**/*"
---

# Tests Full Addendum

This addendum supplements `tests.instructions.md` with process time-cost requirements.

Required coverage:
- Deferred active completion emits `PROCESS_ADD_TIME_COST` before finalization.
- Deferred active abort emits `PROCESS_ADD_TIME_COST` before finalization.
- Passive deferred processes emit no time-cost event.
- Immediate `PROCESS_APPLY` emits time-cost event only when `--time` / explicit duration is supplied.
- Historical processes before cutover remain passive by default.
- Rebuild preserves passive state and time-cost outcomes.
- Shared costing helpers use deterministic `ceil(elapsed_seconds * rate / 3600)` rounding.
- Standardized breakdown keys are present where applicable.

Cash coverage:
- `CASH_INIT` initializes opening balances without affecting profit.
- Multiple currencies are tracked independently.
- `CASH_ADJUST` applies signed balance corrections.
- `CURRENCY_CONVERT` debits one cash account and credits another without creating profit.
- Rebuild preserves `cash_accounts` balances deterministically.
- Cash remains separate from commodity inventory and WAC.