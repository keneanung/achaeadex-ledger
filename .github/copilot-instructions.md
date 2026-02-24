# Repository-wide Copilot Instructions

This repository is a Mudlet (Lua) package built with muddler and tested with busted.

You MUST follow the economic invariants in:
- .github/instructions/economics.instructions.md

You MUST follow the technical constraints in:
- .github/instructions/technical.instructions.md

You MUST keep the tests in:
- .github/instructions/tests.instructions.md
up to date and make them pass.

You MUST follow the reporting requirements in:
- .github/instructions/reporting.instructions.md

You MUST follow the UX and discovery requirements in:
- .github/instructions/ux-and-discovery.instructions.md

You MUST follow the pricing rules in:
- .github/instructions/pricing.instructions.md

Do not simplify accounting rules.
Do not change waterfall order.
Do not replace WAC with FIFO.
Do not introduce forced amortization schedules.

If something is unclear:
- Preserve invariants.
- Add a TODO.
- Add or adjust a failing test that highlights the ambiguity.

Primary goals:
1) Correct accounting (WAC, strict waterfall recovery, shared pattern pools)
2) Clean architecture (core logic testable outside Mudlet)
3) Fast feedback loop (busted unit tests)
4) Mudlet compatibility (.mpackage via muddler)
