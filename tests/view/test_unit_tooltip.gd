extends GutTest
## UnitTooltip.describe: the hover text for a fresh unit (no kill bonus shown),
## a veteran (accuracy and attack-rate bonuses from kills, in whole percent),
## a wounded unit in the middle of a fight, and a dead one. The shipped
## Shieldman gives the real-data cases; a synthetic type pins the exact text
## so retuning the data can't hide a formatting change. Units with a ranged
## attack add lines for ammunition and their special, and name the ranged
## activities.

const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const HALF: int = Veterancy.HALF_CAP_KILLS

var _catalog: UnitCatalog


func before_all() -> void:
	_catalog = load("res://data/units/catalog.tres") as UnitCatalog


func _unit(type_id: StringName, faction: UnitType.Faction) -> Unit:
	var index: int = _catalog.index_of(type_id)
	assert(index >= 0, "no %s in the catalog" % type_id)
	return Unit.new(1, 0, 0, 0, _catalog.types[index], index, faction)


func test_fresh_living_unit() -> void:
	var unit: Unit = _unit(&"shieldman", LIGHT)
	var t: UnitType = unit.type
	var lines: PackedStringArray = UnitTooltip.describe(unit).split("\n")
	assert_eq(lines.size(), 5)
	assert_eq(lines[0], "Shieldman (Light)")
	assert_eq(lines[1], "HP %d/%d · Idle" % [t.max_hp, t.max_hp])
	assert_eq(lines[2], "Kills 0")
	assert_eq(lines[3], "Accuracy %d%%" % (t.melee_accuracy_permille / 10), "no bonus, so no 'from kills'")
	assert_eq(lines[4], "Attack rate +0% · Speed +0%")


func test_veteran_shows_bonuses_from_kills() -> void:
	var unit: Unit = _unit(&"shieldman", LIGHT)
	var t: UnitType = unit.type
	unit.kills = HALF  # exactly half of each cap
	var lines: PackedStringArray = UnitTooltip.describe(unit).split("\n")
	var accuracy_bonus: int = t.veterancy_accuracy_permille / 2
	assert_eq(lines[2], "Kills %d" % HALF)
	assert_eq(
		lines[3],
		"Accuracy %d%% (+%d from kills)" % [
			(t.melee_accuracy_permille + accuracy_bonus + 5) / 10, (accuracy_bonus + 5) / 10
		]
	)
	assert_eq(lines[4], "Attack rate +%d%% · Speed +0%%" % ((t.veterancy_attack_rate_permille / 2 + 5) / 10))


func test_exact_text_for_a_pinned_veteran() -> void:
	var t: UnitType = TestUnits.melee(&"pinned", {
		"display_name": "Pinned", "max_hp": 100, "melee_accuracy_permille": 800,
		"veterancy_accuracy_permille": 120, "veterancy_attack_rate_permille": 250,
		"veterancy_speed_permille": 100,
	})
	var unit: Unit = Unit.new(1, 0, 0, 0, t, 0, DARK)
	unit.kills = HALF
	unit.hp = 64
	unit.state = Unit.State.ATTACKING
	# Bonuses at HALF kills are half the caps: accuracy +60 (860 total), attack
	# rate +125 (12.5%, rounds to 13), speed +50.
	assert_eq(
		UnitTooltip.describe(unit),
		"Pinned (Dark)\nHP 64/100 · Attacking\nKills 4\nAccuracy 86% (+6 from kills)\nAttack rate +13% · Speed +5%"
	)


func test_activity_names() -> void:
	var unit: Unit = _unit(&"husk", DARK)
	unit.state = Unit.State.MOVING
	assert_true(UnitTooltip.describe(unit).contains("· Moving"))
	unit.state = Unit.State.ATTACKING
	assert_true(UnitTooltip.describe(unit).contains("· Attacking"))


func test_dead_unit_is_only_name_and_kills() -> void:
	var unit: Unit = _unit(&"shieldman", LIGHT)
	unit.kills = 3
	unit.kill()
	assert_eq(UnitTooltip.describe(unit), "Shieldman (Light) — dead\nKills 3")
	var husk: Unit = _unit(&"husk", DARK)
	husk.kill()
	assert_eq(UnitTooltip.describe(husk), "Husk (Dark) — dead\nKills 0")


func test_melee_units_have_no_ranged_lines() -> void:
	for type_id: StringName in [&"shieldman", &"reaver", &"husk", &"ripper"]:
		var lines: PackedStringArray = UnitTooltip.describe(_unit(type_id, LIGHT), _catalog).split("\n")
		assert_eq(lines.size(), 5, "%s" % type_id)


func test_longbow_shows_unlimited_arrows_and_its_fire_arrow() -> void:
	var lines: PackedStringArray = UnitTooltip.describe(_unit(&"longbow", LIGHT), _catalog).split("\n")
	assert_eq(lines.size(), 7)
	assert_eq(lines[0], "Longbow (Light)", "the five melee lines come first")
	assert_eq(lines[5], "Arrows: unlimited")
	assert_eq(lines[6], "Fire arrow: 1")


func test_fire_arrow_nocked_and_spent() -> void:
	var unit: Unit = _unit(&"longbow", LIGHT)
	unit.fire_nocked = true
	assert_true(UnitTooltip.describe(unit, _catalog).ends_with("\nFire arrow: nocked"))
	unit.fire_nocked = false
	unit.special_left = 0
	assert_true(UnitTooltip.describe(unit, _catalog).ends_with("\nFire arrow: 0"))


func test_sapper_shows_grenades_and_satchels() -> void:
	var unit: Unit = _unit(&"sapper", LIGHT)
	var lines: PackedStringArray = UnitTooltip.describe(unit, _catalog).split("\n")
	assert_eq(lines.size(), 7)
	assert_eq(lines[5], "Bottle grenades: unlimited", "the projectile's display name, plural")
	assert_eq(lines[6], "Satchels: 4")
	unit.special_left = 3
	assert_true(UnitTooltip.describe(unit, _catalog).ends_with("\nSatchels: 3"))
	unit.special_left = 0
	assert_true(UnitTooltip.describe(unit, _catalog).ends_with("\nSatchels: 0"))


func test_an_archer_without_a_special_has_only_the_ammo_line() -> void:
	var lines: PackedStringArray = UnitTooltip.describe(_unit(&"drifter", DARK), _catalog).split("\n")
	assert_eq(lines.size(), 6)
	assert_eq(lines[5], "Arrows: unlimited")


func test_limited_ammo_is_a_count() -> void:
	var t: UnitType = TestUnits.ranged(&"quiver", {"display_name": "Quiver", "ranged_ammo": 12})
	var unit: Unit = Unit.new(1, 0, 0, 0, t, 0, LIGHT)
	assert_true(UnitTooltip.describe(unit, _catalog).ends_with("\nArrows: 12"))
	unit.ammo_left = 7
	assert_true(UnitTooltip.describe(unit, _catalog).ends_with("\nArrows: 7"))
	unit.ammo_left = 0
	assert_true(UnitTooltip.describe(unit, _catalog).ends_with("\nArrows: 0"))


func test_ammo_without_a_catalog_falls_back_to_the_projectile_id() -> void:
	var unit: Unit = _unit(&"sapper", LIGHT)
	assert_true(UnitTooltip.describe(unit).contains("\nGrenades: unlimited"), "the id, capitalized")
	assert_true(UnitTooltip.describe(unit, _catalog).contains("\nBottle grenades: unlimited"))


func test_exact_text_for_a_pinned_archer() -> void:
	var t: UnitType = TestUnits.thrower(&"pinned_thrower", {
		"display_name": "Pinned", "max_hp": 100, "melee_accuracy_permille": 800,
	})
	var unit: Unit = Unit.new(1, 0, 0, 0, t, 0, LIGHT)
	unit.state = Unit.State.SHOOTING
	unit.special_left = 2
	assert_eq(
		UnitTooltip.describe(unit, _catalog),
		"Pinned (Light)\nHP 100/100 · Shooting\nKills 0\nAccuracy 80%\nAttack rate +0% · Speed +0%"
		+ "\nBottle grenades: unlimited\nSatchels: 2"
	)


func test_ranged_activity_names() -> void:
	var unit: Unit = _unit(&"longbow", LIGHT)
	unit.state = Unit.State.SHOOTING
	assert_true(UnitTooltip.describe(unit, _catalog).contains("· Shooting"))
	unit.order = Unit.Order.GROUND_ATTACK
	assert_true(UnitTooltip.describe(unit, _catalog).contains("· Bombarding"), "shooting at the ground")
	unit.state = Unit.State.IDLE
	assert_true(UnitTooltip.describe(unit, _catalog).contains("· Bombarding"), "between shots")
	unit.state = Unit.State.MOVING
	assert_true(UnitTooltip.describe(unit, _catalog).contains("· Moving"), "still walking into range")
	unit.order = Unit.Order.ATTACK_MOVE
	unit.state = Unit.State.SHOOTING
	assert_true(UnitTooltip.describe(unit, _catalog).contains("· Shooting"), "other orders keep the state's name")


func test_dead_archer_is_still_only_name_and_kills() -> void:
	var unit: Unit = _unit(&"longbow", LIGHT)
	unit.kills = 2
	unit.kill()
	assert_eq(UnitTooltip.describe(unit, _catalog), "Longbow (Light) — dead\nKills 2")
