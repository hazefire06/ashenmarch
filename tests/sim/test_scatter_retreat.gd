extends GutTest
## Scatter (B) and Retreat (R), Phase 11. Scatter: every unit runs away from
## the group's centroid, so the group ends far more spread out. Retreat: the
## group falls back from the nearest visible enemy and ends facing it; with
## none in sight, it backs off against its facing and keeps facing forward.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const BRAWLER: int = 0
const LURKER: int = 1

var _catalog: UnitCatalog


func before_all() -> void:
	_catalog = TestUnits.catalog([
		TestUnits.melee(&"brawler"),
		TestUnits.undead(&"lurker", {"hidden_in_deep_water": true}),
	])


func test_scatter_spreads_the_group_out() -> void:
	var world: World = _world()
	var ids: PackedInt32Array = _block(world, 20 * M, 20 * M)
	var before: int = _mean_spread(world)
	world.enqueue(ScatterCommand.new(0, ids))
	_run(world, 8 * 30)
	assert_gt(_mean_spread(world), before + 5 * M, "the group ends well spread out")
	for unit: Unit in world.units:
		assert_eq(unit.order, Unit.Order.NONE, "unit %d holds where it ran to" % unit.id)


func test_a_unit_on_the_centroid_runs_too() -> void:
	var world: World = _world()
	# A plus sign: the middle unit is exactly on the centroid.
	var ids: PackedInt32Array = PackedInt32Array()
	for at: Vector2i in [Vector2i(20, 20), Vector2i(18, 20), Vector2i(22, 20), Vector2i(20, 18), Vector2i(20, 22)]:
		ids.append(world.spawn_unit(BRAWLER, LIGHT, at.x * M, at.y * M, 0, -1000).id)
	var middle: Unit = world.get_unit(ids[0])
	world.enqueue(ScatterCommand.new(0, ids))
	_run(world, 8 * 30)
	assert_gt(FixedMath.length(middle.x - 20 * M, middle.z - 20 * M), 4 * M)


func test_scatter_is_the_same_every_time() -> void:
	var a: World = _world()
	var b: World = _world()
	var ids: PackedInt32Array = _block(a, 20 * M, 20 * M)
	_block(b, 20 * M, 20 * M)
	a.enqueue(ScatterCommand.new(0, ids))
	b.enqueue(ScatterCommand.new(0, ids))
	_run(a, 200)
	_run(b, 200)
	assert_eq(a.state_hash(), b.state_hash())


func test_retreat_falls_back_from_the_nearest_enemy_and_faces_it() -> void:
	var world: World = _world()
	var ids: PackedInt32Array = _block(world, 25 * M, 20 * M)
	world.spawn_unit(BRAWLER, DARK, 35 * M, 20 * M, -1000, 0)
	world.enqueue(RetreatCommand.new(0, ids, Formations.Kind.SHORT_LINE))
	_run(world, 12 * 30)
	var center: Vector2i = _centroid(world, ids)
	assert_almost_eq(center.x, 10 * M, 1500, "15 m back from the enemy's side")
	assert_almost_eq(center.y, 20 * M, 1500)
	for unit_id: int in ids:
		var unit: Unit = world.get_unit(unit_id)
		assert_eq([unit.facing_x, unit.facing_z], [1000, 0], "unit %d faces the enemy" % unit_id)


func test_retreat_ignores_an_enemy_hidden_in_deep_water() -> void:
	# Deep water on the west; a lurker under it. The group faces east, so with
	# the lurker unseen it backs off west, toward the water but stops short.
	var rows: Array[String] = []
	for j: int in 40:
		rows.append("3".repeat(4) + ".".repeat(36))
	var world: World = World.new(1, TestTerrains.from_ascii(rows), _catalog)
	world.spawn_unit(LURKER, DARK, 2 * M, 20 * M, 1000, 0)
	var ids: PackedInt32Array = _block(world, 25 * M, 20 * M, 1000)
	world.enqueue(RetreatCommand.new(0, ids, Formations.Kind.SHORT_LINE))
	_run(world, 12 * 30)
	var center: Vector2i = _centroid(world, ids)
	assert_lt(center.x, 15 * M, "backed off west, against its facing")
	for unit_id: int in ids:
		var unit: Unit = world.get_unit(unit_id)
		assert_eq([unit.facing_x, unit.facing_z], [1000, 0], "unit %d still faces east" % unit_id)


func test_retreat_with_no_enemy_backs_off_against_the_facing() -> void:
	var world: World = _world()
	var ids: PackedInt32Array = _block(world, 20 * M, 25 * M, 0, -1000)
	world.enqueue(RetreatCommand.new(0, ids, Formations.Kind.SHORT_LINE))
	_run(world, 12 * 30)
	var center: Vector2i = _centroid(world, ids)
	assert_gt(center.y, 35 * M, "facing north, it backed off south")
	for unit_id: int in ids:
		var unit: Unit = world.get_unit(unit_id)
		assert_eq([unit.facing_x, unit.facing_z], [0, -1000])


func test_retreat_drops_the_fight() -> void:
	var world: World = _world()
	var ids: PackedInt32Array = _block(world, 25 * M, 20 * M)
	var enemy: Unit = world.spawn_unit(BRAWLER, DARK, 27 * M, 20 * M, -1000, 0)
	_run(world, 30)
	var fighting: bool = false
	for unit_id: int in ids:
		fighting = fighting or world.get_unit(unit_id).target_id == enemy.id
	assert_true(fighting, "someone was fighting the enemy")
	world.enqueue(RetreatCommand.new(world.tick, ids, Formations.Kind.SHORT_LINE))
	world.step()
	for unit_id: int in ids:
		var unit: Unit = world.get_unit(unit_id)
		assert_eq(unit.target_id, 0, "unit %d dropped its fight" % unit_id)
		assert_eq(unit.order, Unit.Order.MOVE)


func _world() -> World:
	return World.new(1, TestTerrains.flat(40, 40), _catalog)


# Six brawlers in two rows of three around (x, z), facing (fx, fz).
func _block(world: World, x: int, z: int, fx: int = 1000, fz: int = 0) -> PackedInt32Array:
	var ids: PackedInt32Array = PackedInt32Array()
	for i: int in 6:
		var dx: int = (i % 3 - 1) * 1500
		var dz: int = (i / 3) * 1500 - 750
		ids.append(world.spawn_unit(BRAWLER, LIGHT, x + dx, z + dz, fx, fz).id)
	return ids


func _centroid(world: World, ids: PackedInt32Array) -> Vector2i:
	var sum: Vector2i = Vector2i.ZERO
	for unit_id: int in ids:
		var unit: Unit = world.get_unit(unit_id)
		sum += Vector2i(unit.x, unit.z)
	return sum / ids.size()


# Mean distance between every pair of LIGHT units.
func _mean_spread(world: World) -> int:
	var total: int = 0
	var pairs: int = 0
	for i: int in world.units.size():
		for j: int in range(i + 1, world.units.size()):
			var a: Unit = world.units[i]
			var b: Unit = world.units[j]
			if a.faction == LIGHT and b.faction == LIGHT:
				total += FixedMath.length(a.x - b.x, a.z - b.z)
				pairs += 1
	return total / maxi(pairs, 1)


func _run(world: World, ticks: int) -> void:
	for t: int in ticks:
		world.step()
