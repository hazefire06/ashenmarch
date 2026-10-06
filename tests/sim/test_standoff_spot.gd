extends GutTest
## StandoffSpot: where a STANDOFF unit can stand to shoot a target (find),
## whether where it stands will do (holds), and whether an enemy is inside its
## dead zone (threatened); an archer under a cliff's lip, whose every arrow
## from the foot meets the cliff, finds a spot its arrows clear the lip from.
## Also Lightning.is_clear_from, the clear-line check
## from a spot the caster isn't standing on, which must agree with is_clear
## from where it is. Pure calls on small worlds; nothing steps.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

## Catalog indices of the synthetic types.
const CASTER: int = 0
const DUMMY: int = 1
const ARCHER: int = 2
const STEEP: int = 3
const LURKER: int = 4

## 40 m x 900 permille: the radius a caster holds at.
const R: int = 36 * M

var _catalog: UnitCatalog
var _bolt: ProjectileType


func before_all() -> void:
	var types: Array[UnitType] = [
		TestUnits.caster(&"caster", {"ai_tactic": UnitType.AiTactic.STANDOFF, "ai_standoff_permille": 900}),
		TestUnits.dummy(&"dummy"),
		TestUnits.ranged(&"archer", {"ai_tactic": UnitType.AiTactic.STANDOFF, "ai_standoff_permille": 800}),
		# Loses all of its range up a 1:1 grade: 20 m at 1:1, 27 m at 1:2.
		TestUnits.caster(&"steep", {
			"ai_tactic": UnitType.AiTactic.STANDOFF, "ai_standoff_permille": 900,
			"uphill_range_permille": 1000,
		}),
		TestUnits.undead(&"lurker", {"hidden_in_deep_water": true}),
	]
	_catalog = TestUnits.catalog(types)
	_bolt = _catalog.find_projectile(&"lightning")


func _world(terrain: Terrain = null) -> World:
	return World.new(1, terrain if terrain != null else TestTerrains.flat(80, 40), _catalog)


func _spot(x: int, z: int) -> PackedInt64Array:
	return PackedInt64Array([x, z])


## 100 x 40 m: a plain at 0 m, then a cliff rising 2 m per m from x = 50 m to
## a plateau 6 m up from x = 53 m. Too steep to walk: the plain and the
## plateau are apart for the living.
func _cliff() -> Terrain:
	var size_x: int = 100
	var size_z: int = 40
	var heights: PackedInt32Array = PackedInt32Array()
	var water: PackedByteArray = PackedByteArray()
	var blocked: PackedByteArray = PackedByteArray()
	heights.resize(size_x * size_z)
	water.resize(size_x * size_z)
	blocked.resize(size_x * size_z)
	for j: int in size_z:
		for i: int in size_x:
			heights[j * size_x + i] = clampi((i - 50) * 2 * M, 0, 6 * M)
	return Terrain.new(
		size_x, size_z, TestTerrains.CELL, heights, water, blocked, TestTerrains.WALKABLE_SLOPE
	)


## RangedCombat's own test for a shot of unit at target's chest, launched as
## if it stood at (x, z): an arrow's flight that clears the ground and friends.
func _shoots_from(world: World, unit: Unit, target: Unit, x: int, z: int) -> bool:
	var p: ProjectileType = world.catalog.find_projectile(unit.type.ranged_projectile)
	var from_y: int = world.terrain.height_at(x, z) + unit.type.hover_height + unit.type.ranged_launch_height
	var chest: int = RangedCombat.chest_height(target, world.terrain.height_at(target.x, target.z))
	var launch: FlightState = FlightState.at_mm(x, from_y, z, 0, 0, 0)
	return RangedCombat.clear_launch_from(world, unit, launch, p, target.x, chest, target.z, true).ok


# --- find -------------------------------------------------------------------


func test_find_stands_straight_back_from_the_target_at_the_standoff_radius() -> void:
	var world: World = _world()
	var caster: Unit = world.spawn_unit(CASTER, DARK, 10 * M, 20 * M, 1, 0)
	var target: Unit = world.spawn_unit(DUMMY, LIGHT, 60 * M, 20 * M, -1, 0)
	assert_eq(StandoffSpot.find(world, caster, target), _spot(60 * M - R, 20 * M))


func test_find_swings_round_a_friend_in_the_line_one_way_then_the_other() -> void:
	var world: World = _world()
	var caster: Unit = world.spawn_unit(CASTER, DARK, 10 * M, 20 * M, 1, 0)
	var target: Unit = world.spawn_unit(DUMMY, LIGHT, 60 * M, 20 * M, -1, 0)
	world.spawn_unit(DUMMY, DARK, 40 * M, 20 * M, -1, 0)
	# Swung 22.5 degrees (binary 64) to the right of facing west, which is
	# north: offset (-R cos, -R sin) = (-33259, -13777).
	var first: PackedInt64Array = _spot(26_741, 6223)
	assert_eq(StandoffSpot.find(world, caster, target), first, "22.5 degrees one way")
	# A second friend on that line sends it 22.5 degrees the other way.
	world.spawn_unit(DUMMY, DARK, 43_370, 13_111, -1, 0)
	assert_eq(StandoffSpot.find(world, caster, target), _spot(26_741, 33_777), "then the other")


func test_find_skips_spots_off_the_map_and_gives_up_when_none_is_left() -> void:
	var world: World = _world()
	# Straight back (north) and 22.5 degrees either way lie past z = 39 m;
	# 45 degrees one way is the first on the map: (-25456, 25456) off it.
	var caster: Unit = world.spawn_unit(CASTER, DARK, 40 * M, 15 * M, 0, -1)
	var target: Unit = world.spawn_unit(DUMMY, LIGHT, 40 * M, 10 * M, 0, 1)
	assert_eq(StandoffSpot.find(world, caster, target), _spot(14_544, 35_456))
	var narrow: World = _world(TestTerrains.flat(80, 12))
	caster = narrow.spawn_unit(CASTER, DARK, 40 * M, 8 * M, 0, -1)
	target = narrow.spawn_unit(DUMMY, LIGHT, 40 * M, 5 * M, 0, 1)
	assert_eq(StandoffSpot.find(narrow, caster, target), PackedInt64Array(), "no spot 36 m out fits on the map")


func test_find_skips_a_spot_with_an_enemy_in_its_dead_zone() -> void:
	var world: World = _world()
	var caster: Unit = world.spawn_unit(CASTER, DARK, 10 * M, 20 * M, 1, 0)
	var target: Unit = world.spawn_unit(DUMMY, LIGHT, 60 * M, 20 * M, -1, 0)
	# 9.9 m from the straight-back spot (24, 20): inside 8 + 2 m.
	world.spawn_unit(DUMMY, LIGHT, 24 * M, 29_900, -1, 0)
	assert_eq(StandoffSpot.find(world, caster, target), _spot(26_741, 6223))


func test_find_skips_a_spot_in_another_pathing_component() -> void:
	# A wall at x = 20 m: the spots straight back and 22.5 degrees off
	# (x about 14 and 17 m) are across it; one 45 degrees off (x about 24.5
	# m) is on the caster's side.
	var rows: Array[String] = []
	for j: int in 60:
		rows.append(".".repeat(20) + "#" + ".".repeat(59))
	var world: World = _world(TestTerrains.from_ascii(rows))
	var caster: Unit = world.spawn_unit(CASTER, DARK, 40 * M, 31 * M, -1, 0)
	var target: Unit = world.spawn_unit(DUMMY, LIGHT, 50 * M, 30 * M, -1, 0)
	var spot: PackedInt64Array = StandoffSpot.find(world, caster, target)
	assert_eq(spot.size(), 2)
	if spot.size() != 2:
		return
	assert_gt(spot[0], 20 * M, "on the caster's side of the wall")
	assert_almost_eq(FixedMath.length(spot[0] - target.x, spot[1] - target.z), R, 2)


func test_find_skips_spots_downhill_of_the_target_out_of_uphill_range() -> void:
	# Ground rising 1 m in 2 along +x: from 36 m downhill the target's chest
	# is 17 m up, and the steep caster's range is only about 27 m.
	var world: World = _world(TestTerrains.ramp_x(80, 40, 500))
	var below: Unit = world.spawn_unit(STEEP, DARK, 10 * M, 20 * M, 1, 0)
	var target: Unit = world.spawn_unit(DUMMY, LIGHT, 60 * M, 20 * M, -1, 0)
	assert_eq(StandoffSpot.find(world, below, target), PackedInt64Array(), "every spot is downhill")
	var above: Unit = world.spawn_unit(STEEP, DARK, 70 * M, 20 * M, -1, 0)
	var low_target: Unit = world.spawn_unit(DUMMY, LIGHT, 40 * M, 20 * M, 1, 0)
	assert_eq(StandoffSpot.find(world, above, low_target), _spot(76 * M, 20 * M), "uphill of it, full range")


func test_find_with_the_unit_on_top_of_the_target_looks_north() -> void:
	var world: World = _world()
	var target: Unit = world.spawn_unit(DUMMY, LIGHT, 40 * M, 38 * M, 0, 1)
	var caster: Unit = world.spawn_unit(CASTER, DARK, 40 * M, 38 * M, 0, 1)
	caster.x = target.x
	caster.z = target.z
	assert_eq(StandoffSpot.find(world, caster, target), _spot(40 * M, 2 * M))


func test_find_for_an_archer_wants_no_friend_near_the_straight_line() -> void:
	var world: World = _world()
	var archer: Unit = world.spawn_unit(ARCHER, DARK, 10 * M, 20 * M, 1, 0)
	var target: Unit = world.spawn_unit(DUMMY, LIGHT, 60 * M, 20 * M, -1, 0)
	var radius: int = 40 * M
	assert_eq(StandoffSpot.find(world, archer, target), _spot(60 * M - radius, 20 * M), "50 m x 800 permille")
	var friend: Unit = world.spawn_unit(DUMMY, DARK, 40 * M, 21_400, -1, 0)
	var spot: PackedInt64Array = StandoffSpot.find(world, archer, target)
	assert_ne(spot, _spot(60 * M - radius, 20 * M), "1.4 m off the line is in the corridor")
	friend.z = 21_600
	assert_eq(StandoffSpot.find(world, archer, target), _spot(60 * M - radius, 20 * M), "1.6 m off is not")


func test_an_archer_under_a_cliff_lip_wont_hold_and_finds_a_spot_it_can_shoot_over_it_from() -> void:
	var world: World = _world(_cliff())
	# 2 m short of the foot, the target 27 m in from the lip, 32 m off: in
	# range, but every flight from here meets the cliff.
	var archer: Unit = world.spawn_unit(ARCHER, DARK, 48 * M, 20 * M, 1, 0)
	var target: Unit = world.spawn_unit(DUMMY, LIGHT, 80 * M, 20 * M, -1, 0)
	assert_false(_shoots_from(world, archer, target, archer.x, archer.z), "RangedCombat can't shoot from the foot")
	assert_false(StandoffSpot.holds(world, archer, target), "so the foot won't do, in range or not")
	var spot: PackedInt64Array = StandoffSpot.find(world, archer, target)
	assert_eq(spot.size(), 2, "a spot farther back")
	if spot.size() != 2:
		return
	assert_lt(spot[0], archer.x, "on the plain, back from the cliff")
	assert_true(_shoots_from(world, archer, target, spot[0], spot[1]), "the arrow clears the lip from it")
	archer.x = spot[0]
	archer.z = spot[1]
	assert_true(StandoffSpot.holds(world, archer, target), "and standing there will do")


func test_find_offers_no_spot_within_a_moves_arrival_radius_of_the_unit() -> void:
	var world: World = _world()
	var target: Unit = world.spawn_unit(DUMMY, LIGHT, 60 * M, 20 * M, -1, 0)
	var archer: Unit = world.spawn_unit(ARCHER, DARK, 10 * M, 20 * M, 1, 0)
	# A friend on the line 1.6 m behind the straight-back spot (20, 20): out of
	# that spot's corridor.
	world.spawn_unit(DUMMY, DARK, 18_400, 20 * M, 1, 0)
	assert_eq(StandoffSpot.find(world, archer, target), _spot(20 * M, 20 * M), "from 10 m: the spot will do")
	# 20 cm past the spot the friend is 1.4 m behind the archer, in its
	# corridor: where it stands won't do. The spot 20 cm away would, but a move
	# there ends before it starts, so it would be sent there at every think.
	archer.x = 19_800
	assert_false(StandoffSpot.holds(world, archer, target))
	var spot: PackedInt64Array = StandoffSpot.find(world, archer, target)
	assert_eq(spot.size(), 2, "swung round instead")
	if spot.size() != 2:
		return
	assert_gt(FixedMath.length(spot[0] - archer.x, spot[1] - archer.z), UnitMovement.ARRIVE_RADIUS)
	assert_almost_eq(FixedMath.length(spot[0] - target.x, spot[1] - target.z), 40 * M, 2, "on the circle")


# --- holds, threatened ------------------------------------------------------


func test_holds_and_threatened() -> void:
	var world: World = _world()
	var caster: Unit = world.spawn_unit(CASTER, DARK, 24 * M, 20 * M, 1, 0)
	var target: Unit = world.spawn_unit(DUMMY, LIGHT, 60 * M, 20 * M, -1, 0)
	assert_true(StandoffSpot.holds(world, caster, target), "36 m, clear")
	assert_false(StandoffSpot.threatened(world, caster))
	caster.x = 19 * M
	assert_false(StandoffSpot.holds(world, caster, target), "41 m: out of range")
	caster.x = 51 * M
	assert_false(StandoffSpot.holds(world, caster, target), "9 m: in the dead zone")
	assert_true(StandoffSpot.threatened(world, caster), "the target itself is 9 m off")
	caster.x = 49 * M
	assert_true(StandoffSpot.holds(world, caster, target), "11 m")
	assert_false(StandoffSpot.threatened(world, caster))
	var friend: Unit = world.spawn_unit(DUMMY, DARK, 55 * M, 20 * M, -1, 0)
	assert_false(StandoffSpot.holds(world, caster, target), "a friend in the line")
	friend.kill()
	var other: Unit = world.spawn_unit(DUMMY, LIGHT, 49 * M, 29 * M, -1, 0)
	assert_false(StandoffSpot.holds(world, caster, target), "another enemy 9 m off")
	assert_true(StandoffSpot.threatened(world, caster))
	other.kill()
	assert_false(StandoffSpot.threatened(world, caster), "the dead don't threaten")


func test_an_enemy_hidden_under_water_doesnt_threaten() -> void:
	var rows: Array[String] = []
	for j: int in 40:
		rows.append(".".repeat(40) + "4444" + ".".repeat(36))
	var world: World = _world(TestTerrains.from_ascii(rows))
	var caster: Unit = world.spawn_unit(CASTER, DARK, 35 * M, 20 * M, 1, 0)
	var lurker: Unit = world.spawn_unit(LURKER, LIGHT, 42 * M, 20 * M, -1, 0)
	assert_true(Visibility.is_submerged(world.terrain, lurker))
	assert_false(StandoffSpot.threatened(world, caster), "it can't see it")
	lurker.surfaced = true
	assert_true(StandoffSpot.threatened(world, caster))


# --- Lightning.is_clear_from ------------------------------------------------


func test_is_clear_from_the_launch_point_agrees_with_is_clear() -> void:
	var world: World = _world()
	var caster: Unit = world.spawn_unit(CASTER, DARK, 5 * M, 20 * M, 1, 0)
	var target: Unit = world.spawn_unit(DUMMY, LIGHT, 35 * M, 20 * M, -1, 0)
	var friend: Unit = world.spawn_unit(DUMMY, DARK, 20 * M, 20 * M, -1, 0)
	var y: int = RangedCombat.chest_height(target, 0)
	var from: PackedInt64Array = Lightning.launch_point(caster)
	var margin: int = RangedCombat.PATH_MARGIN
	var reach: int = 40 * M
	assert_false(Lightning.is_clear(world, caster, _bolt, target.x, y, target.z, true, margin, 0, reach))
	assert_eq(
		Lightning.is_clear_from(world, caster, from, _bolt, target.x, y, target.z, true, margin, 0, reach),
		false, "blocked by the friend, both ways"
	)
	friend.z = 30 * M
	assert_true(Lightning.is_clear(world, caster, _bolt, target.x, y, target.z, true, margin, 0, reach))
	assert_eq(
		Lightning.is_clear_from(world, caster, from, _bolt, target.x, y, target.z, true, margin, 0, reach),
		true, "clear, both ways"
	)


func test_is_clear_from_another_spot_checks_the_line_from_there() -> void:
	var world: World = _world()
	var caster: Unit = world.spawn_unit(CASTER, DARK, 5 * M, 20 * M, 1, 0)
	var target: Unit = world.spawn_unit(DUMMY, LIGHT, 35 * M, 20 * M, -1, 0)
	world.spawn_unit(DUMMY, DARK, 20 * M, 20 * M, -1, 0)
	var y: int = RangedCombat.chest_height(target, 0)
	var spot: PackedInt64Array = PackedInt64Array([5 * M, 1600, 5 * M])
	assert_true(Lightning.is_clear_from(
		world, caster, spot, _bolt, target.x, y, target.z, true, RangedCombat.PATH_MARGIN, 0, 40 * M
	), "from 15 m south the line misses the friend")
