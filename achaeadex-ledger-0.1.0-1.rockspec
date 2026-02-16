package = "achaeadex-ledger"
version = "0.1.0-1"

source = {
  url = "git+https://github.com/keneanung/achaeadex-ledger.git"
}

description = {
  summary = "Achaea DEX Ledger - WAC accounting system for Achaea crafting",
  detailed = [[
    A double-entry, event-sourced accounting system for Achaea crafting with:
    - Weighted Average Cost (WAC) inventory valuation
    - Strict waterfall capital recovery
    - Generic process support (refinement, transformation)
    - Deferred process lifecycle management
    - Design and pattern capital tracking
  ]],
  homepage = "https://github.com/keneanung/achaeadex-ledger",
  license = "MIT"
}

dependencies = {
  "lua >= 5.1, < 5.2",
  "lsqlite3 >= 0.9.5"
}

build = {
  type = "builtin",
  modules = {
    ["achaeadex-ledger.schema"] = "src/scripts/core/schema.lua",
    ["achaeadex-ledger.inventory"] = "src/scripts/core/inventory.lua",
    ["achaeadex-ledger.ledger"] = "src/scripts/core/ledger.lua"
  }
}
