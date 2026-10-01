extends GutTest
## What a side can see. A unit that hides in deep water (a Husk at depth 3+)
## is submerged until it surfaces to fight or wades out; the enemy doesn't
## see it then unless one of their living units is within its reveal radius.
## Its own side always sees it. Submerged units still can't be targeted or
## hit, whoever sees them (MeleeCombat, RangedCombat, ProjectileSystem).

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const WALKER: int = 0
const LURKER: int = 1
const FLOATER: int = 2

var _catalog: UnitCatalog


func before_all() -> void:
	_catalog = TestUnits.catalog([
		TestUnits.dummy(&"walker"),
		TestUnits.dummy(&"lurker", {
			"nature": UnitType.Nature.UNDEAD, "mobility": Terrain.Mobility.UNDEAD,
			"water_speed_permille": PackedInt32Array([1000, 1000, 1000, 1000, 1000]),
			"hidden_in_deep_water": true, "reveal_radius": 4000,
		}),
		TestUnits.dummy(&"floater", {
			"nature": UnitType.Nature.UNDEAD, "mobility": Terrain.Mobility.FLOATING,
			"water_speed_permille": PackedInt32Array([1000, 1000, 1000, 1000, 1000]),
		}),
	])


func test_a_submerged_lurker_is_hidden_from_the_enemy_but_not_its_own_side() -> void:
	var world: World = _world()
	var lurker: Unit = world.spawn_unit(LURKER, DARK, 30 * M, 20 * M, -1, 0)
	world.spawn_unit(WALKER, LIGHT, 5 * M, 20 * M, 1, 0)
	assert_true(Visibility.is_submerged(world.terrain, lurker))
	assert_false(Visibility.seen_by(world, lurker, LIGHT))
	assert_true(Visibility.seen_by(world, lurker, DARK))


func test_an_enemy_close_enough_sees_it() -> void:
	var world: World = _world()
	var lurker: Unit = world.spawn_unit(LURKER, DARK, 22 * M, 20 * M, -1, 0)
	var walker: Unit = world.spawn_unit(WALKER, LIGHT, 17 * M, 20 * M, 1, 0)
	assert_false(Visibility.seen_by(world, lurker, LIGHT), "5 m off: still hidden")
	walker.x = 18 * M
	assert_true(Visibility.seen_by(world, lurker, LIGHT), "4 m off: seen")


func test_a_dead_body_reveals_nothing() -> void:
	var world: World = _world()
	var lurker: Unit = world.spawn_unit(LURKER, DARK, 22 * M, 20 * M, -1, 0)
	var walker: Unit = world.spawn_unit(WALKER, LIGHT, 19 * M, 20 * M, 1, 0)
	walker.kill()
	assert_false(Visibility.seen_by(world, lurker, LIGHT))


func test_it_is_seen_once_it_surfaces() -> void:
	var world: World = _world()
	var wading: Unit = world.spawn_unit(LURKER, DARK, 17 * M, 10 * M, -1, 0)
	assert_eq(world.terrain.water_depth_at(wading.x, wading.z), 2)
	assert_false(Visibility.is_submerged(world.terrain, wading), "too shallow to hide in")
	assert_true(Visibility.seen_by(world, wading, LIGHT))
	var fighting: Unit = world.spawn_unit(LURKER, DARK, 30 * M, 10 * M, -1, 0)
	fighting.state = Unit.State.ATTACKING
	assert_true(Visibility.seen_by(world, fighting, LIGHT), "it came up to fight")


func test_a_floater_over_deep_water_is_seen() -> void:
	var world: World = _world()
	var floater: Unit = world.spawn_unit(FLOATER, DARK, 30 * M, 20 * M, -1, 0)
	assert_eq(world.terrain.water_depth_at(floater.x, floater.z), 3)
	assert_true(Visibility.seen_by(world, floater, LIGHT))


func test_the_husk_reveals_itself_within_a_few_metres() -> void:
	var husk: UnitType = TestTerrains.catalog().find(&"husk")
	assert_true(husk.hidden_in_deep_water)
	assert_eq(husk.reveal_radius, 4000)


func test_reveal_radius_cant_be_negative() -> void:
	var t: UnitType = TestUnits.dummy(&"t")
	t.reveal_radius = -1
	assert_eq(t.validate().size(), 1, str(t.validate()))


# 40 x 30 m: dry west of x = 15 m, then depth 2 to x = 20 m, then depth 3.
func _world() -> World:
	var rows: Array[String] = []
	for j: int in 30:
		rows.append(".".repeat(15) + "2".repeat(5) + "3".repeat(20))
	return World.new(1, TestTerrains.from_ascii(rows), _catalog)
