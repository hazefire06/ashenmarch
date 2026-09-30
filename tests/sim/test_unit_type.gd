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


func test_catalog_lookup() -> void:
	assert_eq(_catalog.index_of(&"shieldman"), 0)
	assert_eq(_catalog.index_of(&"husk"), 1)
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


func test_validate_rejects_half_defined_attacks() -> void:
	var t: UnitType = _valid_type()
	t.melee_damage = 5
	t.ranged_damage = 5
	t.ranged_min_range = 10_000
	t.ranged_max_range = 5_000
	assert_eq(t.validate().size(), 3, str(t.validate()))


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
