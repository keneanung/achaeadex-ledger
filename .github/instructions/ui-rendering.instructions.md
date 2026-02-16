---
applyTo: "**/*"
---

# UI Rendering Instructions (Mudlet Output Formatting)

Goal:
- Improve readability of CLI output in Mudlet with tables, wrapping, and color.
- Do not change core accounting logic or report computations.

Rules:
1) Core returns structured data; Mudlet layer renders it.
   - No business logic in renderers.
2) Output width must adapt using getWindowWrap().
3) Provide color + plain modes:
   - default color=on
   - allow `adex config set color on|off`
   - plain mode must not include color escape sequences
4) IDs must remain easy to copy:
   - IDs appear as plain text tokens (no splitting)
   - IDs are the first column in list tables
5) Tables must wrap long fields (name/appearance) to fit width.
6) Reports should be sectioned:
   - title + divider
   - key metrics block (aligned labels/values)
   - optional holdings block
   - optional line-item tables (order/design)
   - warnings block at end

Implementation:
- Add a mudlet renderer module, e.g. src/scripts/mudlet/render.lua with helpers:
  - wrap(text, width)
  - pad_right(text, width)
  - format_gold(n) with thousands separators
  - table_render(rows, col_specs, width)
- Rendering should use cecho if color enabled, else echo.

Help output should be improved similarly:
- describe what commands do
- examples
- align command names and descriptions

Acceptance:
- `adex report overall`, `adex report year`, `adex report design`, `adex list *` outputs are readable at common widths (80–140 cols).
- Output degrades gracefully at small widths (40–60 cols) without truncating IDs.
