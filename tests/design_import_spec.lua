-- Busted tests for passive nds design parsing and upsert behavior

describe("Design passive parser", function()
  local parser
  local importer
  local ledger
  local memory_store

  before_each(function()
    _G.AchaeadexLedger = nil
    dofile("src/scripts/core/json.lua")
    dofile("src/scripts/core/inventory.lua")
    dofile("src/scripts/core/deferred_processes.lua")
    dofile("src/scripts/core/pattern_pools.lua")
    dofile("src/scripts/core/production_sources.lua")
    dofile("src/scripts/core/recovery.lua")
    dofile("src/scripts/core/costing.lua")
    dofile("src/scripts/core/ledger.lua")
    dofile("src/scripts/core/storage/memory_event_store.lua")
    dofile("src/scripts/core/design_details_parser.lua")
    dofile("src/scripts/core/design_auto_import.lua")

    parser = _G.AchaeadexLedger.Core.DesignDetailsParser
    importer = _G.AchaeadexLedger.Core.DesignAutoImport
    ledger = _G.AchaeadexLedger.Core.Ledger
    memory_store = _G.AchaeadexLedger.Core.MemoryEventStore
  end)

  local function parse_block(block)
    local parsed, err = parser.parse(block, { player_name = "Keneanung" })
    assert.is_nil(err)
    assert.is_not_nil(parsed)
    return parsed
  end

  it("parses tailoring public cloth", function()
    local block = [[
Design37131   Designer: Nicolina   Owner: *public
This is a tailoring design.
Type: coat  Comms: cloth 4
Appearance (short_desc)
a long coat of studded stygian leather
]]

    local parsed = parse_block(block)
    assert.are.equal("37131", parsed.alias_id)
    assert.are.equal("public", parsed.provenance)
    assert.are.equal(0, parsed.recovery_enabled)
    assert.are.equal("tailoring", parsed.source_type)
    assert.are.equal(4, parsed.bom.cloth)
  end)

  it("parses tailoring organization cloth", function()
    local block = [[
Design27823   Designer: Magenta   Owner: the City of Hashan
This is a tailoring design.
Type: tunic  Comms: cloth 2
Appearance (short_desc)
a corduroy tunic in charcoal and velvet
Months of usefulness left: Presrvd.
]]

    local parsed = parse_block(block)
    assert.are.equal("organization", parsed.provenance)
    assert.are.equal(0, parsed.recovery_enabled)
    assert.are.equal("Presrvd.", parsed.metadata.months_usefulness)
  end)

  it("parses tailoring private leather", function()
    local block = [[
Design39723   Designer: Keneanung   Owner: Keneanung
This is a tailoring design.
Type: boots  Comms: leather 4
Appearance (short_desc)
a pair of silver-threaded leather boots
Months of usefulness left: 137 mo.
]]

    local parsed = parse_block(block)
    assert.are.equal("private", parsed.provenance)
    assert.are.equal(1, parsed.recovery_enabled)
    assert.are.equal(4, parsed.bom.leather)
    assert.are.equal("137 mo.", parsed.metadata.months_usefulness)
  end)

  it("parses jewellery with crafting fee and gems", function()
    local block = [[
Design35300   Designer: Azaka   Owner: *public
This is a jewellery design.
Type: necklace  Comms: silver 3  Crafting Fee: 7790
This pattern requires 3 gems.
Appearance (short_desc)
a silver necklace of interlocking links and gems
]]

    local parsed = parse_block(block)
    assert.are.equal("jewellery", parsed.source_type)
    assert.are.equal("necklace", parsed.design_type)
    assert.are.equal(3, parsed.bom.silver)
    assert.are.equal(3, parsed.bom.gems)
    assert.are.equal(7790, parsed.per_item_fee_gold)
  end)

  it("parses jewellery with NO gems", function()
    local block = [[
Design27433   Designer: Argwin   Owner: the City of Hashan
This is a jewellery design.
Type: armband  Comms: leather 3  Crafting Fee: 10500
This pattern requires NO gems.
Appearance (short_desc)
a Hashani armband of black leather
]]

    local parsed = parse_block(block)
    assert.are.equal(3, parsed.bom.leather)
    assert.is_nil(parsed.bom.gems)
    assert.are.equal(10500, parsed.per_item_fee_gold)
  end)

  it("parses furniture with samples and crafting fee", function()
    local block = [[
Design34252   Designer: Kaburia   Owner: the City of Hashan
This is a furniture design.
Type: bookcase  Comms: wood 1000 Samples: 2 ruby  Crafting Fee: 450000
Appearance (short_desc)
a monolithic obsidian bookcase
]]

    local parsed = parse_block(block)
    assert.are.equal("furniture", parsed.source_type)
    assert.are.equal(1000, parsed.bom.wood)
    assert.are.equal(450000, parsed.per_item_fee_gold)
    assert.is_not_nil(parsed.metadata.samples)
    assert.are.equal(2, parsed.metadata.samples.ruby)
    assert.is_nil(parsed.bom.ruby)
  end)

  it("parses artistry mediums and sessions", function()
    local block = [[
Design35308   Designer: Aina   Owner: the City of Hashan
             Private: Y   HideMark: N
This design cannot be shared. It has a passcode of 0
This is an artistry design.
Type: canvas  Mediums: 30 oilpaint red, 30 oilpaint blue, 30 oilpaint yellow Sessions: 70
Appearance (short_desc)
an oil canvas triptych painting titled "Sundered"
Dropped (long_desc)
Hashan's stylised progress is illustrated upon this massive triptych canvas.
Months of usefulness left: Presrvd.
]]

    local parsed = parse_block(block)
    assert.are.equal("artistry", parsed.source_type)
    assert.are.equal("canvas", parsed.design_type)
    assert.are.equal(30, parsed.bom["oilpaint red"])
    assert.are.equal(30, parsed.bom["oilpaint blue"])
    assert.are.equal(30, parsed.bom["oilpaint yellow"])
    assert.is_nil(parsed.bom.sessions)
    assert.are.equal(70, parsed.metadata.sessions)
    assert.are.equal("Presrvd.", parsed.metadata.months_usefulness)
  end)

  it("parses beverages ingredients and generic sections", function()
    local block = [[
Design30399   Designer: Glathna   Owner: the City of Hashan
             Private: Y   HideMark: N
This design cannot be shared. It has a passcode of 0
This is a beverages design.
Type: kawhe  Ingredients: 1 milk, 1 spices, 1 water  Method: steeping  Aged: NO
Generic
iced kawhe and horse milk
In Vessel
Lightly sweetened mare's milk and kawhe promises a bittersweet drink.
First Drunk Ideal
Swirling the iced beverage, you lift the drink to take a swig.
Third Drunk Ideal
Lifting an iced kawhe and horsemilk to $drinker_his lips.
Nose Ideal
smells like roasted kawhe beans ground in a freezing stable.
Taste Ideal
tastes like roasted kawhe beans ground in a freezing stable.
Months of usefulness left: Presrvd.
]]

    local parsed = parse_block(block)
    assert.are.equal("beverages", parsed.source_type)
    assert.are.equal("kawhe", parsed.design_type)
    assert.are.equal(1, parsed.bom.milk)
    assert.are.equal(1, parsed.bom.spices)
    assert.are.equal(1, parsed.bom.water)
    assert.are.equal("steeping", parsed.metadata.method)
    assert.are.equal("NO", parsed.metadata.aged)
    assert.are.equal("iced kawhe and horse milk", parsed.short_desc)
    assert.are.equal("iced kawhe and horse milk", parsed.metadata.generic)
    assert.is_not_nil(parsed.metadata.in_vessel)
    assert.is_not_nil(parsed.metadata.first_drunk_ideal)
    assert.is_not_nil(parsed.metadata.third_drunk_ideal)
    assert.is_not_nil(parsed.metadata.nose_ideal)
    assert.is_not_nil(parsed.metadata.taste_ideal)
  end)

  it("parses cooking ingredients and eaten/smell/taste sections", function()
    local block = [[
Design27406   Designer: Kaburia   Owner: the City of Hashan
             Private: Y   HideMark: N
This design cannot be shared. It has a passcode of 0
This is a cooking design.
Type: cookie  Ingredients: 1 spices, 1 dough, 1 sugar
Appearance (short_desc)
a polar bear shaped cookie glazed in vanilla
Dropped (long_desc)
Left abandoned, a polar bear shaped cookie lies here.
Examined (extended_desc)
Cut into the shape of a small bear, this wafer cookie is baked to a point of firm softness.
First Eaten
After removing its small silken scarf with care, you take a bite into the bear shaped cookie.
Third Eaten
$+eater carefully removes the small silk scarf from a polar bear shaped cookie before taking a bite.
Smell
carries a strong vanilla scent.
Taste
teases you with a hint of wafer behind a primarily vanilla flavour.
Months of usefulness left: Presrvd.
]]

    local parsed = parse_block(block)
    assert.are.equal("cooking", parsed.source_type)
    assert.are.equal("cookie", parsed.design_type)
    assert.are.equal(1, parsed.bom.spices)
    assert.are.equal(1, parsed.bom.dough)
    assert.are.equal(1, parsed.bom.sugar)
    assert.are.equal("a polar bear shaped cookie glazed in vanilla", parsed.short_desc)
    assert.is_not_nil(parsed.metadata.first_eaten)
    assert.is_not_nil(parsed.metadata.third_eaten)
    assert.are.equal("carries a strong vanilla scent.", parsed.metadata.smell)
    assert.are.equal("teases you with a hint of wafer behind a primarily vanilla flavour.", parsed.metadata.taste)
  end)

  it("classifies single-token non-owner as foreign provenance", function()
    local block = [[
Design99999   Designer: Nynevah   Owner: Nynevah
This is a tailoring design.
Type: coat  Comms: cloth 4
Appearance (short_desc)
a severe black coat
]]

    local parsed = parse_block(block)
    assert.are.equal("foreign", parsed.provenance)
    assert.are.equal(0, parsed.recovery_enabled)
  end)

  it("requires short_desc and fails otherwise", function()
    local block = [[
Design23088   Designer: Laedha   Owner: *public
This is a tailoring design.
Type: boots  Comms: leather 4
]]

    local parsed, err = parser.parse(block, { player_name = "Keneanung" })
    assert.is_nil(parsed)
    assert.is_true(string.find(err or "", "short_desc", 1, true) ~= nil)
  end)

  it("upserts idempotently from parsed details", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    local block = [[
Design37110   Designer: Ildiko   Owner: the City of Hashan
This is a jewellery design.
Type: ring  Comms: gold 1  Crafting Fee: 5620
This pattern requires 1 gems.
Appearance (short_desc)
a dark planet ring
Dropped (long_desc)
A dusky golden ring gleams faintly here, like starlight smothered in ash.
Examined (extended_desc)
Ghostly trails of obsidian swirl across the surface of this ring.
Months of usefulness left: Presrvd.
]]

    local first, first_err = importer.parse_and_upsert(state, block, { player_name = "Keneanung" })
    assert.is_nil(first_err)
    assert.is_not_nil(first)
    assert.is_true(first.created)
    assert.are.equal("D-37110", first.source_id)

    local source = state.production_sources["D-37110"]
    assert.is_not_nil(source)
    assert.are.equal("ring", source.source_type)
    assert.are.equal("organization", source.provenance)
    assert.are.equal(0, source.recovery_enabled)
    assert.are.equal(1, source.bom.gold)
    assert.are.equal(1, source.bom.gems)
    assert.are.equal(5620, source.per_item_fee_gold)
    assert.is_not_nil(source.metadata)
    assert.is_nil(source.metadata.samples)

    local event_count_before = #store:read_all()
    local second, second_err = importer.parse_and_upsert(state, block, { player_name = "Keneanung" })
    assert.is_nil(second_err)
    assert.is_not_nil(second)
    local event_count_after = #store:read_all()
    assert.are.equal(event_count_before, event_count_after)
  end)

  it("auto-import defaults private-owner designs to non-recoverable", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    local block = [[
Design39724   Designer: Keneanung   Owner: Keneanung
This is a tailoring design.
Type: boots  Comms: leather 4
Appearance (short_desc)
a pair of dark leather boots
]]

    local result, err = importer.parse_and_upsert(state, block, { player_name = "Keneanung" })
    assert.is_nil(err)
    assert.is_not_nil(result)
    assert.is_true(result.created)

    local source = state.production_sources[result.source_id]
    assert.is_not_nil(source)
    assert.are.equal("private", source.provenance)
    assert.are.equal(0, source.recovery_enabled)
  end)

  it("upserts beverages parsed from generic short description", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    local block = [[
Design30399   Designer: Glathna   Owner: the City of Hashan
This is a beverages design.
Type: kawhe  Ingredients: 1 milk, 1 spices, 1 water  Method: steeping  Aged: NO
Generic
iced kawhe and horse milk
Months of usefulness left: Presrvd.
]]

    local result, err = importer.parse_and_upsert(state, block, { player_name = "Keneanung" })
    assert.is_nil(err)
    assert.is_not_nil(result)

    local source = state.production_sources[result.source_id]
    assert.is_not_nil(source)
    assert.are.equal("kawhe", source.source_type)
    assert.are.equal(1, source.bom.milk)
    assert.are.equal(1, source.bom.spices)
    assert.are.equal(1, source.bom.water)
  end)

  it("updates existing design when probe reveals different details", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    local first_block = [[
Design55555   Designer: Ildiko   Owner: the City of Hashan
This is a jewellery design.
Type: ring  Comms: gold 1
Appearance (short_desc)
a simple ring
Months of usefulness left: Presrvd.
]]

    local first, first_err = importer.parse_and_upsert(state, first_block, { player_name = "Keneanung" })
    assert.is_nil(first_err)
    assert.is_not_nil(first)

    local source_id = first.source_id
    local event_count_before = #store:read_all()

    local second_block = [[
Design55555   Designer: Ildiko   Owner: *public
This is a jewellery design.
Type: armband  Comms: leather 3  Crafting Fee: 5620
This pattern requires NO gems.
Appearance (short_desc)
a tsol'aa love armband
Dropped (long_desc)
A tsol'aa love armband lies here forlorn.
Months of usefulness left: 137 mo.
]]

    local second, second_err = importer.parse_and_upsert(state, second_block, { player_name = "Keneanung" })
    assert.is_nil(second_err)
    assert.is_not_nil(second)
    assert.is_true(second.updated)

    local source = state.production_sources[source_id]
    assert.are.equal("a tsol'aa love armband", source.name)
    assert.are.equal("armband", source.source_type)
    assert.are.equal("public", source.provenance)
    assert.are.equal(3, source.bom.leather)
    assert.is_nil(source.bom.gold)
    assert.are.equal(5620, source.per_item_fee_gold)
    assert.is_not_nil(source.metadata)
    assert.are.equal("137 mo.", source.metadata.months_usefulness)

    local event_count_after = #store:read_all()
    assert.is_true(event_count_after > event_count_before)
  end)

  it("keeps active pattern link intact when probe suggests different type", function()
    local store = memory_store.new()
    local state = ledger.new(store)

    ledger.apply_pattern_activate(state, "P-ARMBAND", "armband", "Armband pool", 150)
    ledger.apply_design_start(state, "D-LINK", "armband", "Bound Armband", "private", 1)
    ledger.apply_design_alias(state, "D-LINK", "8238", "other", 1)

    local source_before = state.production_sources["D-LINK"]
    assert.is_not_nil(source_before)
    assert.are.equal("armband", source_before.source_type)
    assert.are.equal("P-ARMBAND", source_before.pattern_pool_id)

    local block = [[
Design8238   Designer: Keneanung   Owner: Keneanung
This is a jewellery design.
Type: ring  Comms: leather 3  Crafting Fee: 5620
Appearance (short_desc)
a tsol'aa love armband
Months of usefulness left: Presrvd.
]]

    local result, err = importer.parse_and_upsert(state, block, { player_name = "Keneanung" })
    assert.is_nil(err)
    assert.is_not_nil(result)

    local source_after = state.production_sources["D-LINK"]
    assert.are.equal("armband", source_after.source_type)
    assert.are.equal("P-ARMBAND", source_after.pattern_pool_id)

    local found_warning = false
    for _, warning in ipairs(result.warnings or {}) do
      if string.find(warning, "pattern link is active", 1, true) then
        found_warning = true
        break
      end
    end
    assert.is_true(found_warning)
  end)
end)
