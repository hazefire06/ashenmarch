extends GutTest
## The shipped unit data is valid and says what CLAUDE.md says, and
## validation catches the mistakes that would break the sim silently.

var _catalog: UnitCatalog


func before_all() -> void:
	_catalog = TestTerrains.catalog()


func test_catalog_is_valid() -> void:
	assert_not_null(_catalog)
	assert_eq(_catalog.validate(), PackedStringArray())


func test_shieldman_is_living_light() -> void:
	var t: UnitType = _catalog.find(&"shieldman")
	assert_not_null(t)
	assert_eq(t.faction, UnitType.Faction.LIGHT)
	assert_eq(t.nature, UnitType.Nature.LIVING)
	assert_eq(t.mobility, Terrain.Mobility.LIVING)
	assert_eq(t.water_speed_permille.size(), UnitType.WATER_DEPTH_LEVELS)
	assert_gt(t.water_speed_permille[0], t.water_speed_permille[2], "water slows living units")
	assert_false(t.can_enter_depth(Terrain.LIVING_IMPASSABLE_DEPTH))


func test_husk_is_undead_dark_and_hides_in_deep_water() -> void:
	var t: UnitType = _catalog.find(&"husk")
	assert_not_null(t)
	assert_eq(t.faction, UnitType.Faction.DARK)
	assert_eq(t.nature, UnitType.Nature.UNDEAD)
	assert_eq(t.mobility, Terrain.Mobility.UNDEAD)
	assert_true(t.hidden_in_deep_water)
	assert_true(t.can_enter_depth(Terrain.MAX_WATER_DEPTH))
	assert_lt(t.move_speed, _catalog.find(&"shieldman").move_speed, "husks are slow")


func test_shieldman_has_a_shield_and_the_others_do_not() -> void:
	assert_gt(_catalog.find(&"shieldman").shield_block_permille, 0)
	for type_id: StringName in [&"reaver", &"husk", &"ripper"]:
		assert_eq(_catalog.find(type_id).shield_block_permille, 0, String(type_id))


func test_reaver_is_fast_hard_hitting_light_melee() -> void:
	var t: UnitType = _catalog.find(&"reaver")
	var shieldman: UnitType = _catalog.find(&"shieldman")
	assert_not_null(t)
	assert_eq(t.faction, UnitType.Faction.LIGHT)
	assert_eq(t.nature, UnitType.Nature.LIVING)
	assert_gt(t.move_speed, shieldman.move_speed, "fast")
	assert_gt(t.melee_damage, shieldman.melee_damage, "high damage")
	assert_lt(t.max_hp, shieldman.max_hp, "less sturdy")
	assert_gt(t.veterancy_speed_permille, 0, "gains speed with kills")


func test_ripper_is_a_fast_living_raider_that_hunts_ranged_and_support() -> void:
	var t: UnitType = _catalog.find(&"ripper")
	assert_not_null(t)
	assert_eq(t.faction, UnitType.Faction.DARK)
	assert_eq(t.nature, UnitType.Nature.LIVING)
	assert_eq(t.mobility, Terrain.Mobility.LIVING)
	for other: UnitType in _catalog.types:
		if other != t:
			assert_gt(t.move_speed, other.move_speed, "faster than %s" % other.id)
	assert_eq(
		t.preferred_target_roles,
		(1 << UnitType.Role.RANGED) | (1 << UnitType.Role.SUPPORT)
	)


func test_husks_do_not_learn() -> void:
	var t: UnitType = _catalog.find(&"husk")
	assert_eq(t.veterancy_accuracy_permille, 0)
	assert_eq(t.veterancy_attack_rate_permille, 0)
	assert_eq(t.veterancy_speed_permille, 0)


func test_catalog_lookup() -> void:
	assert_eq(_catalog.index_of(&"shieldman"), 0)
	assert_eq(_catalog.index_of(&"husk"), 1)
	assert_eq(_catalog.index_of(&"reaver"), 2)
	assert_eq(_catalog.index_of(&"ripper"), 3)
	assert_eq(_catalog.index_of(&"nobody"), -1)
	assert_null(_catalog.find(&"nobody"))


func test_validate_rejects_missing_numbers() -> void:
	var t: UnitType = _valid_type()
	t.max_hp = 0
	t.move_speed = 0
	var errors: PackedStringArray = t.validate()
	assert_eq(errors.size(), 2, str(errors))


func test_validate_rejects_bad_water_table() -> void:
	var t: UnitType = _valid_type()
	t.water_speed_permille = PackedInt32Array([1000, 800])
	assert_eq(t.validate().size(), 1)
	# An undead unit that stops dead in deep water would be stuck there.
	t.mobility = Terrain.Mobility.UNDEAD
	t.water_speed_permille = PackedInt32Array([1000, 900, 800, 0, 0])
	assert_eq(t.validate().size(), 2, str(t.validate()))


func test_longbow_sapper_and_drifter_say_what_claude_md_says() -> void:
	var longbow: UnitType = _catalog.find(&"longbow")
	var sapper: UnitType = _catalog.find(&"sapper")
	var drifter: UnitType = _catalog.find(&"drifter")
	assert_eq(longbow.faction, UnitType.Faction.LIGHT)
	assert_eq(longbow.special_ability, UnitType.Special.FIRE_ARROW)
	assert_eq(longbow.special_charges, 1, "one fire arrow")
	assert_gt(longbow.melee_damage, 0, "a dagger in melee")
	assert_eq(sapper.special_ability, UnitType.Special.SATCHEL)
	assert_eq(sapper.special_charges, 4, "four charges per mission")
	assert_eq(sapper.ranged_ammo, -1, "unlimited bottle grenades")
	assert_eq(sapper.ranged_aim, UnitType.AimStyle.LOB)
	assert_lt(sapper.move_speed, longbow.move_speed, "slow")
	assert_gt(sapper.uphill_spread_permille, 3 * longbow.uphill_spread_permille, "uphill hurts throws far more")
	assert_eq(drifter.faction, UnitType.Faction.DARK)
	assert_eq(drifter.nature, UnitType.Nature.UNDEAD)
	assert_eq(drifter.mobility, Terrain.Mobility.FLOATING)
	assert_gt(drifter.hover_height, 0)


func test_every_shipped_ranged_unit_can_reach_its_max_range() -> void:
	# The range in the data must be one the physics can deliver on level
	# ground, by the unit's own aim style or its fallback.
	for t: UnitType in _catalog.types:
		if not t.has_ranged():
			continue
		var p: ProjectileType = _catalog.find_projectile(t.ranged_projectile)
		var from: FlightState = FlightState.at_mm(0, t.ranged_launch_height, 0, 0, 0, 0)
		var target_y: int = 0 if p.is_explosive() else 1000
		var speed: int = FlightState.speed_from_mm_per_s(t.ranged_launch_speed)
		var reached: bool = false
		for style: UnitType.AimStyle in [UnitType.AimStyle.DIRECT, UnitType.AimStyle.LOB]:
			var s: AimSolution = Ballistics.solve(
				style, from, t.ranged_max_range * FlightState.SUB, target_y * FlightState.SUB, 0,
				speed, t.ranged_lob_grade_permille, p.drag_ppm_per_m
			)
			reached = reached or s.ok
		assert_true(reached, "%s reaches %d m" % [t.id, t.ranged_max_range / 1000])


func test_validate_rejects_half_defined_melee() -> void:
	var t: UnitType = _valid_type()
	t.melee_damage = 5
	# reach, windup, cooldown, acquire_radius, and accuracy are all missing.
	assert_eq(t.validate().size(), 5, str(t.validate()))
	t.melee_reach = 700
	t.melee_windup_ticks = 6
	t.melee_cooldown_ticks = 24
	t.acquire_radius = 8000
	t.melee_accuracy_permille = 1001
	assert_eq(t.validate().size(), 1, str(t.validate()))
	t.melee_accuracy_permille = 1000
	assert_eq(t.validate(), PackedStringArray())


func test_validate_rejects_half_defined_ranged() -> void:
	var t: UnitType = _valid_type()
	t.ranged_projectile = &"arrow"
	# launch speed, lob grade, launch height, max range, cooldown, the
	# min < max rule, and ammo are all missing.
	assert_eq(t.validate().size(), 7, str(t.validate()))
	t.ranged_launch_speed = 30_000
	t.ranged_lob_grade_permille = 600
	t.ranged_launch_height = 1500
	t.ranged_min_range = 10_000
	t.ranged_max_range = 5_000
	t.ranged_cooldown_ticks = 30
	t.ranged_ammo = -1
	assert_eq(t.validate().size(), 1, "min range beyond max: %s" % [t.validate()])
	t.ranged_max_range = 40_000
	t.ranged_spread_permille = 1001
	t.uphill_spread_permille = -1
	assert_eq(t.validate().size(), 2, str(t.validate()))
	t.ranged_spread_permille = 30
	t.uphill_spread_permille = 800
	assert_eq(t.validate(), PackedStringArray())


func test_validate_rejects_half_defined_specials() -> void:
	var t: UnitType = _valid_type()
	t.special_ability = UnitType.Special.SATCHEL
	assert_eq(t.validate().size(), 2, "charges and projectile: %s" % [t.validate()])
	t.special_charges = 4
	t.special_projectile = &"satchel"
	assert_eq(t.validate(), PackedStringArray())
	t.special_ability = UnitType.Special.FIRE_ARROW
	assert_eq(t.validate().size(), 1, "a fire arrow needs a bow: %s" % [t.validate()])


func test_catalog_rejects_unknown_and_unsuitable_projectiles() -> void:
	var catalog: UnitCatalog = UnitCatalog.new()
	var t: UnitType = _valid_type()
	t.special_ability = UnitType.Special.SATCHEL
	t.special_charges = 4
	t.special_projectile = &"satchel"
	catalog.types.append(t)
	assert_eq(catalog.validate().size(), 1, "unknown projectile: %s" % [catalog.validate()])
	var arrow: ProjectileType = ProjectileType.new()
	arrow.id = &"satchel"
	arrow.display_name = "Not a satchel"
	arrow.radius = 20
	arrow.impact_damage = 10
	catalog.projectile_types.append(arrow)
	assert_eq(catalog.validate().size(), 1, "a sticking charge: %s" % [catalog.validate()])


func test_validate_rejects_out_of_range_permille_and_role_bits() -> void:
	var t: UnitType = _valid_type()
	t.shield_block_permille = 1001
	t.veterancy_accuracy_permille = -1
	t.veterancy_attack_rate_permille = 2000
	t.veterancy_speed_permille = -5
	t.preferred_target_roles = 8
	assert_eq(t.validate().size(), 5, str(t.validate()))


func test_catalog_rejects_duplicate_ids() -> void:
	var catalog: UnitCatalog = UnitCatalog.new()
	catalog.types.append(_valid_type())
	catalog.types.append(_valid_type())
	assert_eq(catalog.validate().size(), 1)


func _valid_type() -> UnitType:
	var t: UnitType = UnitType.new()
	t.id = &"tester"
	t.display_name = "Tester"
	t.max_hp = 10
	t.body_radius = 400
	t.body_height = 1800
	t.move_speed = 2000
	t.water_speed_permille = PackedInt32Array([1000, 800, 600, 0, 0])
	assert_eq(t.validate(), PackedStringArray(), "baseline must be valid")
	return t


func test_a_test_catalog_gets_its_own_copies_of_the_shipped_projectiles() -> void:
	# Tests tweak projectile types; the shipped ones are cached resources
	# every load() shares, so a tweak must never reach them.
	var shipped: UnitCatalog = TestTerrains.catalog()
	var mine: UnitCatalog = TestUnits.catalog([TestUnits.dummy(&"dummy")])
	for i: int in shipped.projectile_types.size():
		assert_ne(mine.projectile_types[i], shipped.projectile_types[i], "a copy of %s" % shipped.projectile_types[i].id)
		assert_eq(mine.projectile_types[i].id, shipped.projectile_types[i].id)
	var grenade: ProjectileType = mine.find_projectile(&"grenade")
	grenade.fizzle_permille = 0
	assert_gt(TestUnits.projectile(&"grenade").fizzle_permille, 0, "the shipped grenade is untouched")
