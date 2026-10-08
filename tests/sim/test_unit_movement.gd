extends GutTest
## Units walk at their type's speed, slowed by water depth and uphill grade;
## living units never set foot in deep water while undead wade through it;
## bodies don't stack; formation orders end with every unit on its slot; and
## orders respect state (dead units ignore them).

const M: int = 1000
const TICKS_PER_SECOND: int = World.TICK_RATE
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

var _catalog: UnitCatalog
var _shieldman: int
var _husk: int


func before_all() -> void:
	_catalog = TestTerrains.catalog()
	_shieldman = _catalog.index_of(&"shieldman")
	_husk = _catalog.index_of(&"husk")


func test_walks_at_type_speed_on_flat_ground() -> void:
	var world: World = World.new(1, TestTerrains.flat(80, 20), _catalog)
	var u: Unit = world.spawn_unit(_shieldman, LIGHT, 5 * M, 10 * M, 1, 0)
	_move(world, [u], 75 * M, 10 * M)
	var start: int = u.x
	_run(world, TICKS_PER_SECOND * 2)
	assert_almost_eq(u.x - start, 2 * u.type.move_speed, 3, "mm per 2 s")
	assert_eq(u.z, 10 * M, "straight line")
	assert_eq(u.state, Unit.State.MOVING)
	assert_eq([u.facing_x, u.facing_z], [FixedMath.DIR_ONE, 0], "faces the way it walks")


func test_water_depth_slows_by_the_type_table() -> void:
	var table: PackedInt32Array = _catalog.types[_shieldman].water_speed_permille
	for depth: int in [1, 2]:
		var rows: Array[String] = []
		for j: int in 20:
			rows.append(str(depth).repeat(80))
		var world: World = World.new(1, TestTerrains.from_ascii(rows), _catalog)
		var u: Unit = world.spawn_unit(_shieldman, LIGHT, 5 * M, 10 * M, 1, 0)
		_move(world, [u], 75 * M, 10 * M)
		var start: int = u.x
		_run(world, TICKS_PER_SECOND * 2)
		var expected: int = 2 * u.type.move_speed * table[depth] / 1000
		assert_almost_eq(u.x - start, expected, 3, "depth %d" % depth)


func test_uphill_is_slower_and_across_the_slope_is_not() -> void:
	# 500 permille grade: slowdown 500 permille per 1000 of grade = 250 lost.
	var terrain: Terrain = TestTerrains.ramp_x(80, 80, 500)
	var speed: int = _catalog.types[_shieldman].move_speed
	var uphill_rate: int = 1000 - 500 * _catalog.types[_shieldman].uphill_slowdown_permille / 1000
	var cases: Array[Array] = [
		[Vector2i(10 * M, 40 * M), Vector2i(70 * M, 40 * M), speed * uphill_rate / 1000, "uphill"],
		[Vector2i(70 * M, 40 * M), Vector2i(10 * M, 40 * M), speed, "downhill"],
		[Vector2i(40 * M, 10 * M), Vector2i(40 * M, 70 * M), speed, "across"],
	]
	for c: Array in cases:
		var from: Vector2i = c[0]
		var to: Vector2i = c[1]
		var world: World = World.new(1, terrain, _catalog)
		var u: Unit = world.spawn_unit(_shieldman, LIGHT, from.x, from.y, 0, -1)
		_move(world, [u], to.x, to.y)
		var start: Vector2i = Vector2i(u.x, u.z)
		_run(world, TICKS_PER_SECOND * 2)
		var walked: int = FixedMath.length(u.x - start.x, u.z - start.y)
		assert_almost_eq(walked, 2 * int(c[2]), 4, c[3])


func test_living_units_never_stand_in_deep_water() -> void:
	var world: World = World.new(1, _creek_terrain(), _catalog)
	var u: Unit = world.spawn_unit(_shieldman, LIGHT, 5 * M, 10 * M, 1, 0)
	_move(world, [u], 30 * M, 10 * M)
	var wet_ticks: Array[int] = []
	for t: int in TICKS_PER_SECOND * 15:
		world.step()
		if not world.terrain.is_passable(u.x, u.z, Terrain.Mobility.LIVING):
			wet_ticks.append(t)
	assert_eq(wet_ticks.size(), 0, "stood on impassable ground at ticks %s" % [wet_ticks])
	assert_eq(u.state, Unit.State.IDLE, "gives up at the bank")
	assert_lt(u.x, 20 * M, "still on the near side")


func test_undead_wade_through_deep_water() -> void:
	var world: World = World.new(1, _creek_terrain(), _catalog)
	var u: Unit = world.spawn_unit(_husk, DARK, 5 * M, 10 * M, 1, 0)
	_move(world, [u], 32 * M, 10 * M)
	_run(world, TICKS_PER_SECOND * 25)
	assert_eq(u.state, Unit.State.IDLE)
	assert_almost_eq(u.x, 32 * M, UnitMovement.ARRIVE_RADIUS)


func test_stacked_units_spread_apart() -> void:
	var world: World = World.new(1, TestTerrains.flat(40, 40), _catalog)
	var group: Array[Unit] = []
	for i: int in 20:
		group.append(world.spawn_unit(_shieldman, LIGHT, 20 * M, 20 * M, 0, -1))
	_run(world, TICKS_PER_SECOND * 5)
	var min_d: int = _min_pairwise_distance(group)
	assert_gte(min_d, 2 * 400 - 50, "closest pair %d mm apart" % min_d)


func test_formation_order_puts_every_unit_on_its_slot() -> void:
	var world: World = World.new(1, TestTerrains.flat(80, 80), _catalog)
	var group: Array[Unit] = []
	for i: int in 20:
		group.append(world.spawn_unit(_shieldman, LIGHT, (10 + (i % 5) * 2) * M, (10 + (i / 5) * 2) * M, 0, -1))
	world.enqueue(MoveUnitsCommand.new(world.tick, _ids(group), 50 * M, 50 * M, Formations.Kind.LONG_LINE))
	_run(world, TICKS_PER_SECOND * 25)
	var off_slot: Array[String] = []
	for u: Unit in group:
		if u.state != Unit.State.IDLE:
			off_slot.append("%d still %s" % [u.id, Unit.State.keys()[u.state]])
		var d: int = FixedMath.length(u.x - u.goal_x, u.z - u.goal_z)
		if d > 500:
			off_slot.append("%d is %d mm off" % [u.id, d])
		if u.facing_x != group[0].facing_x or u.facing_z != group[0].facing_z:
			off_slot.append("%d faces (%d, %d)" % [u.id, u.facing_x, u.facing_z])
	assert_eq(off_slot.size(), 0, str(off_slot))
	# Facing points from where the group started toward the target (south-east).
	assert_gt(group[0].facing_x, 0)
	assert_gt(group[0].facing_z, 0)
	assert_gte(_min_pairwise_distance(group), 2 * 400)
	# Long line: all on one rank, so spread across ~19 spacings.
	var xs: Array[int] = []
	for u: Unit in group:
		xs.append(u.x)
	assert_gt(xs.max() - xs.min(), 10 * M)


func test_group_marches_at_its_slowest_members_pace() -> void:
	var world: World = World.new(1, TestTerrains.flat(80, 30), _catalog)
	var fast: Unit = world.spawn_unit(_shieldman, LIGHT, 5 * M, 10 * M, 1, 0)
	var slow: Unit = world.spawn_unit(_husk, LIGHT, 5 * M, 20 * M, 1, 0)
	world.enqueue(MoveUnitsCommand.new(world.tick, _ids([fast, slow]), 60 * M, 15 * M, Formations.Kind.LONG_LINE))
	world.step()
	var start: int = fast.x
	_run(world, TICKS_PER_SECOND * 2)
	assert_almost_eq(fast.x - start, 2 * slow.type.move_speed, 40)


func test_stop_halts_and_dead_units_ignore_orders() -> void:
	var world: World = World.new(1, TestTerrains.flat(80, 20), _catalog)
	var u: Unit = world.spawn_unit(_shieldman, LIGHT, 5 * M, 10 * M, 1, 0)
	_move(world, [u], 75 * M, 10 * M)
	_run(world, 10)
	world.enqueue(StopUnitsCommand.new(world.tick, _ids([u])))
	world.step()
	var stopped_at: int = u.x
	_run(world, 10)
	assert_eq(u.state, Unit.State.IDLE)
	assert_eq(u.x, stopped_at, "stays put after stop")

	u.kill()
	assert_eq(u.state, Unit.State.DEAD)
	assert_false(u.transition_to(Unit.State.IDLE), "death is terminal")
	_move(world, [u], 75 * M, 10 * M)
	_run(world, 10)
	assert_eq(u.state, Unit.State.DEAD)
	assert_eq(u.x, stopped_at, "dead units don't move")


func test_a_group_behind_a_wall_shares_one_route() -> void:
	# A wall between the group and the target forces A*; the first solve's
	# route serves the other nineteen in the same tick (Phase 10).
	var world: World = World.new(1, TestTerrains.from_ascii(_wall_rows(60, 40, 30, 35)), _catalog)
	var group: Array[Unit] = []
	for i: int in 20:
		group.append(world.spawn_unit(_shieldman, LIGHT, (5 + (i % 5) * 2) * M, (5 + (i / 5) * 2) * M, 0, -1))
	world.enqueue(MoveUnitsCommand.new(world.tick, _ids(group), 50 * M, 10 * M, Formations.Kind.BOX))
	world.step()
	assert_eq(world.movement.queued_paths(), 0, "everyone has a path after one tick")
	for u: Unit in group:
		assert_true(u.has_path(), "unit %d" % u.id)
		assert_eq(u.waypoint_z(), 35 * M, "unit %d heads for the wall's end" % u.id)
	# Everyone setting out at once reaches the box as a column, so the last
	# few take a while to squeeze into their slots: 44 s here, against 39 s
	# when the solves were spread over four ticks.
	_run(world, TICKS_PER_SECOND * 50)
	var not_arrived: Array[int] = []
	for u: Unit in group:
		if u.state != Unit.State.IDLE or u.x < 31 * M:
			not_arrived.append(u.id)
	assert_eq(not_arrived.size(), 0, "units that didn't get around the wall: %s" % [not_arrived])


func test_path_solves_are_capped_per_tick() -> void:
	# Eight units behind a wall bound for goals too far apart to share a route:
	# each needs its own A*, at most MAX_PATH_SOLVES_PER_TICK a tick.
	var world: World = World.new(1, TestTerrains.from_ascii(_wall_rows(120, 240, 60, 230)), _catalog)
	var group: Array[Unit] = []
	for i: int in 8:
		group.append(world.spawn_unit(_shieldman, LIGHT, 20 * M, (10 + i * 25) * M, 0, -1))
	for i: int in 8:
		world.movement.order_move(world, group[i], 100 * M, (10 + i * 25) * M, 0, 0, 0)
	assert_eq(world.movement.queued_paths(), 8)
	world.step()
	assert_eq(world.movement.queued_paths(), 8 - UnitMovement.MAX_PATH_SOLVES_PER_TICK)
	world.step()
	assert_eq(world.movement.queued_paths(), 0)


# A size_x by size_z map with a wall down column `wall_x` for its first
# `wall_rows` rows.
func _wall_rows(size_x: int, size_z: int, wall_x: int, wall_rows: int) -> Array[String]:
	var rows: Array[String] = []
	for j: int in size_z:
		var row: String = ".".repeat(size_x)
		if j < wall_rows:
			row = row.substr(0, wall_x) + "#" + row.substr(wall_x + 1)
		rows.append(row)
	return rows


# Deep water (depth 3) in columns 15..19, shallow shoulders beside it.
func _creek_terrain() -> Terrain:
	var rows: Array[String] = []
	for j: int in 20:
		rows.append(".............12333332 1............".replace(" ", "1"))
	return TestTerrains.from_ascii(rows)


func _move(world: World, group: Array, x: int, z: int) -> void:
	world.enqueue(MoveUnitsCommand.new(world.tick, _ids(group), x, z, Formations.Kind.SHORT_LINE))
	world.step()


func _run(world: World, ticks: int) -> void:
	for t: int in ticks:
		world.step()


func _ids(group: Array) -> PackedInt32Array:
	var ids: PackedInt32Array = PackedInt32Array()
	for u: Unit in group:
		ids.append(u.id)
	return ids


func _min_pairwise_distance(group: Array[Unit]) -> int:
	var best: int = 1 << 40
	for a: int in group.size():
		for b: int in range(a + 1, group.size()):
			best = mini(best, FixedMath.length(group[a].x - group[b].x, group[a].z - group[b].z))
	return best
