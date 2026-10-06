extends GutTest
## Skirmish armies: unit costs, the AI's army templates and how they fill a
## budget, an army's validation, and the order an army deploys in.

const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const SKIRMISH_CATALOG: String = "res://data/skirmish/skirmish.tres"

var _shipped: UnitCatalog
var _skirmish: SkirmishCatalog
# Synthetic types with round costs, so a fill's arithmetic is checked by hand.
var _catalog: UnitCatalog


func before_all() -> void:
	_shipped = TestTerrains.catalog()
	_skirmish = load(SKIRMISH_CATALOG)
	_catalog = TestUnits.catalog([
		TestUnits.melee(&"pike", {"cost": 30}),
		TestUnits.ranged(&"bow", {"cost": 45}),
		TestUnits.melee(&"cheap", {"cost": 1}),
		TestUnits.melee(&"ghoul", {"cost": 20, "faction": DARK}),
		TestUnits.melee(&"free", {"cost": 0}),
		TestUnits.healer(&"medic", {"cost": 50}),
		TestUnits.melee(&"spear", {"cost": 30}),
	])


func _template(ids: Array[StringName], shares: PackedInt32Array, side: UnitType.Faction = LIGHT) -> ArmyTemplate:
	var t: ArmyTemplate = ArmyTemplate.new()
	t.id = &"test"
	t.display_name = "Test"
	t.faction = side
	t.type_ids = ids
	t.shares_permille = shares
	return t


func _army(counts: Dictionary, side: UnitType.Faction = LIGHT) -> Army:
	var army: Army = Army.new(side)
	for type_id: StringName in counts:
		army.set_count(type_id, counts[type_id])
	return army


# --- Shipped data ---------------------------------------------------------


func test_shipped_catalog_validates() -> void:
	assert_eq(_shipped.validate(), PackedStringArray())
	assert_eq(_skirmish.validate(_shipped), PackedStringArray())


func test_every_combatant_has_a_cost_and_the_villager_none() -> void:
	for t: UnitType in _shipped.types:
		var combatant: bool = t.has_melee() or t.has_ranged() or t.special_ability != UnitType.Special.NONE
		if combatant:
			assert_gt(t.cost, 0, "%s can be bought" % t.id)
		else:
			assert_eq(t.cost, 0, "%s can't be bought" % t.id)
	assert_eq(_shipped.find(&"villager").cost, 0)


func test_both_sides_have_four_templates_and_a_balanced_one() -> void:
	for side: UnitType.Faction in [LIGHT, DARK]:
		var ids: Array[StringName] = []
		for t: ArmyTemplate in _skirmish.templates_for(side):
			ids.append(t.id)
		assert_eq(ids.size(), 4, "faction %d" % side)
	assert_not_null(_skirmish.template(&"light_balanced"))
	assert_not_null(_skirmish.template(&"dark_balanced"))
	assert_null(_skirmish.template(&"nope"))


func test_every_template_fills_every_budget_validly() -> void:
	for t: ArmyTemplate in _skirmish.templates:
		for budget: int in _skirmish.budgets:
			var army: Army = t.fill(budget, _shipped)
			assert_eq(army.validate(_shipped, budget), PackedStringArray(), "%s at %d" % [t.id, budget])
			assert_eq(army.faction, t.faction)
			# Spent down: nothing the template fields is still affordable,
			# unless the army is full.
			if army.size() < Army.MAX_UNITS:
				var left: int = budget - army.cost(_shipped)
				for type_id: StringName in t.type_ids:
					assert_gt(_shipped.find(type_id).cost, left, "%s at %d: %s affordable" % [t.id, budget, type_id])
			for type_id: StringName in t.type_ids:
				assert_gt(army.count_of(type_id), 0, "%s at %d fields %s" % [t.id, budget, type_id])


func test_budgets_and_time_limits_are_offered() -> void:
	assert_eq(_skirmish.budgets, PackedInt32Array([600, 1000, 1500]))
	assert_eq(_skirmish.default_budget, 1000)
	assert_eq(_skirmish.time_limits_minutes, PackedInt32Array([5, 10, 15, 20]))
	assert_eq(_skirmish.default_time_limit_minutes, 10)


func test_template_files_say_their_enums_by_their_legend() -> void:
	# Each file's legend reads "faction: 0 LIGHT, 1 DARK" and its id says the
	# side, so a wrong number fails here.
	for t: ArmyTemplate in _skirmish.templates:
		var expected: UnitType.Faction = DARK if String(t.id).begins_with("dark_") else LIGHT
		assert_eq(t.faction, expected, String(t.id))
	assert_eq(UnitType.Faction.LIGHT, 0)
	assert_eq(UnitType.Faction.DARK, 1)


# --- Fill ------------------------------------------------------------------


func test_fill_rounds_down_then_spends_the_rest_on_the_furthest_below() -> void:
	# 1000 points, 600 to pike (30), 400 to bow (45): 20 pike (600), 8 bow
	# (360). 40 left: the bow is 40 below its share and the pike 0, so a bow
	# (45) would be next but isn't affordable; a pike (30) is, so it goes.
	# 10 left: nothing.
	var army: Army = _template([&"pike", &"bow"], PackedInt32Array([600, 400])).fill(1000, _catalog)
	assert_eq(army.count_of(&"pike"), 21)
	assert_eq(army.count_of(&"bow"), 8)
	assert_eq(army.cost(_catalog), 990)


func test_fill_breaks_ties_by_entry_order() -> void:
	# 100 points, 500 each to two 30-point types: 1 each (60), 40 left, both
	# 20 below their share: the first entry takes it. 10 left: nothing.
	var army: Army = _template([&"spear", &"pike"], PackedInt32Array([500, 500])).fill(100, _catalog)
	assert_eq(army.count_of(&"spear"), 2)
	assert_eq(army.count_of(&"pike"), 1)
	var swapped: Army = _template([&"pike", &"spear"], PackedInt32Array([500, 500])).fill(100, _catalog)
	assert_eq(swapped.count_of(&"pike"), 2)
	assert_eq(swapped.count_of(&"spear"), 1)


func test_fill_skips_what_it_cant_afford() -> void:
	# 61 points, half each: 1 pike (30), 30 cheap (30); 1 left: only a cheap
	# is affordable, though neither is below its share.
	var army: Army = _template([&"pike", &"cheap"], PackedInt32Array([500, 500])).fill(61, _catalog)
	assert_eq(army.count_of(&"pike"), 1)
	assert_eq(army.count_of(&"cheap"), 31)
	assert_eq(army.cost(_catalog), 61)


func test_fill_stops_at_the_cap_in_both_passes() -> void:
	var army: Army = _template([&"cheap"], PackedInt32Array([1000])).fill(1000, _catalog)
	assert_eq(army.size(), Army.MAX_UNITS)
	var mixed: Army = _template([&"cheap", &"pike"], PackedInt32Array([900, 100])).fill(1500, _catalog)
	assert_eq(mixed.size(), Army.MAX_UNITS)
	assert_eq(mixed.count_of(&"cheap"), Army.MAX_UNITS, "the first pass hits the cap before the pike")
	assert_eq(mixed.validate(_catalog, 1500), PackedStringArray())


func test_fill_of_an_invalid_template_is_empty() -> void:
	var bad: ArmyTemplate = _template([&"pike"], PackedInt32Array([900]))
	assert_eq(bad.fill(1000, _catalog).size(), 0)
	assert_push_error("doesn't validate")


func test_fill_is_deterministic() -> void:
	for t: ArmyTemplate in _skirmish.templates:
		var a: Army = t.fill(1000, _shipped)
		var b: Army = t.fill(1000, _shipped)
		assert_eq(a.type_list(_shipped), b.type_list(_shipped), String(t.id))


# --- Template validation ----------------------------------------------------


func test_template_validation_lists_every_problem() -> void:
	var t: ArmyTemplate = ArmyTemplate.new()
	t.type_ids = [&"pike", &"pike", &"ghoul", &"free", &"nope"]
	t.shares_permille = PackedInt32Array([300, 300, 300, 0, 50])
	var errors: PackedStringArray = t.validate(_catalog)
	var text: String = "\n".join(errors)
	for expected: String in [
		"id is empty", "display_name is empty", "pike is listed twice",
		"ghoul is not on the template's side", "free can't be bought",
		"free needs a positive share", "unknown unit type nope", "shares add up to 950",
	]:
		assert_string_contains(text, expected)


func test_template_needs_parallel_arrays_and_an_entry() -> void:
	var t: ArmyTemplate = _template([&"pike"], PackedInt32Array([500, 500]))
	assert_string_contains("\n".join(t.validate(_catalog)), "differ in length")
	var empty: ArmyTemplate = _template([], PackedInt32Array())
	assert_string_contains("\n".join(empty.validate(_catalog)), "at least one entry")


# --- Army -------------------------------------------------------------------


func test_army_counts_and_cost() -> void:
	var army: Army = _army({&"pike": 3, &"bow": 2})
	assert_eq(army.size(), 5)
	assert_eq(army.cost(_catalog), 3 * 30 + 2 * 45)
	army.set_count(&"pike", 0)
	assert_false(army.counts.has(&"pike"), "0 removes the type")
	assert_eq(army.count_of(&"pike"), 0)
	assert_eq(army.size(), 2)


func test_army_validation_lists_every_problem() -> void:
	var army: Army = _army({&"ghoul": 1, &"free": 1, &"nope": 1, &"pike": 4})
	var text: String = "\n".join(army.validate(_catalog, 100))
	for expected: String in [
		"ghoul is not on this army's side", "free can't be bought",
		"unknown unit type nope", "over the budget of 100",
	]:
		assert_string_contains(text, expected)
	assert_string_contains("\n".join(Army.new().validate(_catalog, 100)), "at least one unit")
	var big: Army = _army({&"cheap": Army.MAX_UNITS + 1})
	assert_string_contains("\n".join(big.validate(_catalog, 1000)), "at most 60 units")
	assert_eq(_army({&"pike": 2}).validate(_catalog, 60), PackedStringArray(), "exactly at budget")


func test_type_list_is_role_then_catalog_order_whatever_was_added_first() -> void:
	var army: Army = _army({&"medic": 1, &"bow": 2, &"pike": 1, &"cheap": 2})
	# Melee by catalog index (pike 0, cheap 2), then ranged (bow), then
	# support (medic).
	assert_eq(army.type_list(_catalog), [&"pike", &"cheap", &"cheap", &"bow", &"bow", &"medic"] as Array[StringName])
	var other: Army = _army({&"cheap": 2, &"pike": 1, &"medic": 1, &"bow": 2})
	assert_eq(other.type_list(_catalog), army.type_list(_catalog))


func test_copy_shares_nothing() -> void:
	var army: Army = _army({&"pike": 2}, LIGHT)
	var other: Army = army.copy()
	other.set_count(&"pike", 5)
	assert_eq(army.count_of(&"pike"), 2)
	assert_eq(other.faction, LIGHT)


# --- UnitType additions -----------------------------------------------------


func test_unit_type_rejects_a_negative_cost_and_a_medic_without_heal() -> void:
	var t: UnitType = TestUnits.melee(&"x")
	t.cost = -1
	assert_string_contains("\n".join(t.validate()), "cost can't be negative")
	var m: UnitType = TestUnits.melee(&"y")
	m.ai_tactic = UnitType.AiTactic.MEDIC
	assert_string_contains("\n".join(m.validate()), "MEDIC needs the HEAL special")
	var h: UnitType = TestUnits.healer(&"z", {"ai_tactic": UnitType.AiTactic.MEDIC})
	assert_eq(h.validate(), PackedStringArray())
	var odd: UnitType = TestUnits.melee(&"w")
	odd.set("ai_tactic", 9)
	assert_string_contains("\n".join(odd.validate()), "ai_tactic 9 is not an AiTactic")
