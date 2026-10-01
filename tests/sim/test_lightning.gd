extends GutTest
## Lightning: a bolt is a straight line that strikes every body along it,
## friend and foe, shields or not, and sets off charges it passes; the ground
## stops it. A caster can't hit anything inside its dead zone, won't fire at
## a target with a friend anywhere on the line, and never finishes a cast
## while it is being hit in melee, so sustained melee kills it. Bolts of one
## tick strike together.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

## Catalog indices of the synthetic types.
const CASTER: int = 0
const DUMMY: int = 1
const BRAWLER: int = 2
const SHIELDED: int = 3
const FRAIL_CASTER: int = 4

var _catalog: UnitCatalog
var _bolt: ProjectileType


func before_all() -> void:
	var types: Array[UnitType] = [
		TestUnits.caster(&"caster"),
		TestUnits.dummy(&"dummy"),
		TestUnits.melee(&"brawler"),
		TestUnits.dummy(&"shielded", {"shield_block_permille": 1000}),
		TestUnits.caster(&"frail_caster", {"max_hp": 10}),
	]
	_catalog = TestUnits.catalog(types)
	_bolt = _catalog.find_projectile(&"lightning")


func test_a_bolt_strikes_every_body_on_its_line_friend_and_foe() -> void:
	var world: World = _world()
	var caster: Unit = world.spawn_unit(CASTER, LIGHT, 5 * M, 20 * M, 1, 0)
	var enemy: Unit = world.spawn_unit(DUMMY, DARK, 20 * M, 20 * M, -1, 0)
	var friend: Unit = world.spawn_unit(DUMMY, LIGHT, 30 * M, 20 * M, -1, 0)
	var aside: Unit = world.spawn_unit(DUMMY, DARK, 20 * M, 25 * M, -1, 0)
	# A ground attack ignores friends: the line runs down to (35, 20) m,
	# through the enemy's middle and the friend's legs.
	world.enqueue(GroundAttackCommand.new(0, PackedInt32Array([caster.id]), 35 * M, 20 * M))
	var bolts: Array[ProjectileEvent] = _bolts(world, 60)
	assert_eq(bolts.size(), 1)
	assert_eq(bolts[0].unit_id, caster.id)
	assert_almost_eq(bolts[0].end_x, 35 * M, 500, "it ends where it meets the ground")
	_assert_struck(enemy)
	_assert_struck(friend)
	assert_eq(aside.hp, aside.type.max_hp, "5 m off the line, untouched")
	assert_eq(caster.hp, caster.type.max_hp)


func test_a_shield_doesnt_stop_it() -> void:
	var world: World = _world()
	var caster: Unit = world.spawn_unit(CASTER, LIGHT, 5 * M, 20 * M, 1, 0)
	var shield: Unit = world.spawn_unit(SHIELDED, DARK, 20 * M, 20 * M, -1, 0)
	_bolts(world, 90)
	_assert_struck(shield)


func test_the_ground_stops_it() -> void:
	var world: World = World.new(1, _ridge(), _catalog)
	var caster: Unit = world.spawn_unit(CASTER, LIGHT, 5 * M, 20 * M, 1, 0)
	var behind: Unit = world.spawn_unit(DUMMY, DARK, 20 * M, 20 * M, -1, 0)
	Lightning.strike(world, caster, _index(), 20 * M, 1000, 20 * M, 40 * M)
	assert_eq(behind.hp, behind.type.max_hp, "behind the ridge")
	var bolt: ProjectileEvent = _last_bolt(world)
	assert_lt(bolt.end_x, 13 * M, "the line ends on the ridge")
	assert_gt(bolt.end_x, 11 * M)
	world.projectile_events.clear()
	assert_eq(_bolts(world, 120).size(), 0, "and it won't cast at what it can't hit")


func test_it_sets_off_charges_along_the_line() -> void:
	var world: World = _world()
	var caster: Unit = world.spawn_unit(CASTER, LIGHT, 5 * M, 20 * M, 1, 0)
	var on_line: Projectile = _lay(world, &"satchel", 15 * M, 20 * M)
	var off_line: Projectile = _lay(world, &"satchel", 15 * M, 23 * M)
	Lightning.strike(world, caster, _index(), 20 * M, 0, 20 * M, 40 * M)
	assert_true(on_line.detonating)
	assert_eq(on_line.instigator_id, caster.id, "credited to the caster")
	assert_false(off_line.detonating)


func test_nothing_inside_the_dead_zone() -> void:
	var world: World = _world()
	var caster: Unit = world.spawn_unit(CASTER, LIGHT, 10 * M, 20 * M, 1, 0)
	var close: Unit = world.spawn_unit(DUMMY, DARK, 16 * M, 20 * M, -1, 0)
	assert_eq(_bolts(world, 120).size(), 0, "6 m off, inside its 8 m dead zone")
	assert_eq(close.hp, close.type.max_hp)
	world.enqueue(GroundAttackCommand.new(world.tick, PackedInt32Array([caster.id]), 15 * M, 20 * M))
	var cant: int = 0
	for _t: int in 10:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			cant += 1 if e.kind == ProjectileEvent.Kind.CANT_REACH else 0
	assert_eq(cant, 1, "a ground attack inside it is refused")


func test_it_wont_cast_with_a_friend_on_the_line() -> void:
	var world: World = _world()
	world.spawn_unit(CASTER, LIGHT, 5 * M, 20 * M, 1, 0)
	world.spawn_unit(DUMMY, DARK, 20 * M, 20 * M, -1, 0)
	var friend: Unit = world.spawn_unit(DUMMY, LIGHT, 32 * M, 20 * M, -1, 0)
	assert_eq(_bolts(world, 120).size(), 0, "the friend 12 m behind the target is on the line")
	world.despawn_entity(friend.id)
	assert_gt(_bolts(world, 120).size(), 0)


func test_a_friend_beyond_the_target_counts_with_the_spread_widening() -> void:
	# The spread swings the whole line about the caster, so 25 m out it can
	# stray 2.5 times as far as at a target 10 m out. A friend 1.3 m off the
	# line there was once outside the check and got struck now and then.
	var spread_caster: UnitType = TestUnits.caster(&"spread_caster", {"ranged_spread_permille": 30})
	var world: World = World.new(1, TestTerrains.flat(40, 40), TestUnits.catalog([spread_caster, TestUnits.dummy(&"dummy")]))
	world.spawn_unit(0, LIGHT, 5 * M, 20 * M, 1, 0)
	world.spawn_unit(1, DARK, 15 * M, 20 * M, -1, 0)
	var friend: Unit = world.spawn_unit(1, LIGHT, 30 * M, 21_300, -1, 0)
	assert_eq(_bolts(world, 150).size(), 0, "it holds fire")
	assert_eq(friend.hp, friend.type.max_hp)


func test_sustained_melee_shuts_it_down_and_kills_it() -> void:
	var world: World = _world()
	var caster: Unit = world.spawn_unit(CASTER, LIGHT, 10 * M, 20 * M, 1, 0)
	world.spawn_unit(DUMMY, DARK, 30 * M, 20 * M, -1, 0)
	world.spawn_unit(BRAWLER, DARK, 10 * M, 20_900, 0, -1)
	assert_eq(_bolts(world, 20 * World.TICK_RATE).size(), 0, "a blow every 15 ticks; a 30-tick cast never finishes")
	assert_false(caster.is_alive())


func test_bolts_of_one_tick_strike_together() -> void:
	# Re-picks are staggered by (tick + id) % 6, so the two casters start
	# casting on the same tick only if their ids differ by 6: five spectators
	# far off between them.
	var world: World = _world()
	var a: Unit = world.spawn_unit(FRAIL_CASTER, LIGHT, 10 * M, 20 * M, 1, 0)
	for i: int in 5:
		world.spawn_unit(DUMMY, LIGHT, 2 * M + i * M, 2 * M, 0, 1)
	var b: Unit = world.spawn_unit(FRAIL_CASTER, DARK, 30 * M, 20 * M, -1, 0)
	assert_eq(b.id - a.id, 6)
	var ticks: Array[int] = []
	for _t: int in 90:
		var at: int = world.tick
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			if e.kind == ProjectileEvent.Kind.BOLT:
				ticks.append(at)
	assert_eq(ticks.size(), 2, "both cast")
	assert_eq(ticks[0], ticks[1], "in the same tick")
	assert_false(a.is_alive())
	assert_false(b.is_alive(), "though the first bolt killed the second caster")


func test_a_bolt_never_strikes_anything_far_off_its_line() -> void:
	# Bodies far to the side of the line, within its span along it, once
	# overflowed the swept-cylinder test (its terms grow with the square of
	# the distance) and read as struck: the demo's bolt hit the ford, 180 m
	# off.
	var world: World = World.new(1, TestTerrains.flat(260, 60), _catalog)
	var caster: Unit = world.spawn_unit(CASTER, DARK, 10 * M, 5 * M, 0, 1)
	var near: Unit = world.spawn_unit(DUMMY, LIGHT, 10 * M, 25 * M, 0, -1)
	var far: Array[Unit] = []
	var far_friends: Array[Unit] = []
	for k: int in 6:
		far.append(world.spawn_unit(DUMMY, LIGHT, (150 + 20 * k) * M, (15 + 6 * k) * M, 0, -1))
		far_friends.append(world.spawn_unit(DUMMY, DARK, (160 + 20 * k) * M, (15 + 6 * k) * M, 0, -1))
	assert_true(Lightning.is_clear(world, caster, _bolt, 10 * M, 1000, 25 * M, true, 200, 0, 40 * M), "no far friend blocks it")
	Lightning.strike(world, caster, _index(), 10 * M, 1000, 25 * M, 40 * M)
	_assert_struck(near)
	for unit: Unit in far + far_friends:
		assert_eq(unit.hp, unit.type.max_hp, "%d m to the side, untouched" % [unit.x / M - 10])


func test_the_same_seed_casts_the_same_bolts() -> void:
	var hashes: Array[String] = []
	for _run: int in 2:
		var world: World = _world()
		world.spawn_unit(CASTER, LIGHT, 5 * M, 20 * M, 1, 0)
		world.spawn_unit(DUMMY, DARK, 25 * M, 18 * M, -1, 0)
		world.spawn_unit(DUMMY, DARK, 30 * M, 24 * M, -1, 0)
		_bolts(world, 300)
		hashes.append(world.state_hash())
	assert_eq(hashes[0], hashes[1])


# --- helpers

func _world() -> World:
	return World.new(1, TestTerrains.flat(40, 40), _catalog)


func _index() -> int:
	return _catalog.projectile_index_of(&"lightning")


func _assert_struck(unit: Unit) -> void:
	var lost: int = unit.type.max_hp - unit.hp
	var lo: int = _bolt.impact_damage * 9 / 10
	var hi: int = _bolt.impact_damage * 11 / 10 + 1
	assert_between(lost, lo, hi, "%s struck once" % unit.type.id)


func _bolts(world: World, ticks: int) -> Array[ProjectileEvent]:
	var out: Array[ProjectileEvent] = []
	for _t: int in ticks:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			if e.kind == ProjectileEvent.Kind.BOLT:
				out.append(e)
	return out


func _last_bolt(world: World) -> ProjectileEvent:
	var last: ProjectileEvent = null
	for e: ProjectileEvent in world.projectile_events:
		if e.kind == ProjectileEvent.Kind.BOLT:
			last = e
	return last


func _lay(world: World, id: StringName, x: int, z: int) -> Projectile:
	return world.drop_object(world.catalog.projectile_index_of(id), x, z, 0)


# Flat ground with a 3 m ridge across it at x = 12 m.
func _ridge() -> Terrain:
	var size: int = 40
	var heights: PackedInt32Array = PackedInt32Array()
	var water: PackedByteArray = PackedByteArray()
	var blocked: PackedByteArray = PackedByteArray()
	heights.resize(size * size)
	water.resize(size * size)
	blocked.resize(size * size)
	for j: int in size:
		heights[j * size + 12] = 3000
		blocked[j * size + 12] = 1
	return Terrain.new(size, size, TestTerrains.CELL, heights, water, blocked, TestTerrains.WALKABLE_SLOPE)
