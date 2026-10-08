extends GutTest
## Waypoints and patrols (UnitRoute, Phase 11): a route visits its points in
## order and then holds; a loop wraps and a back-and-forth reverses; patrols
## fight and resume the leg they were on; a plain leg never picks a fight on
## arrival; four points at most; every other order clears the route; a leg
## that can't be finished ends it; and a world without routes hashes as
## before.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const BRAWLER: int = 0
const ARCHER: int = 1
const WEAKLING: int = 2

var _catalog: UnitCatalog


func before_all() -> void:
	_catalog = TestUnits.catalog([
		TestUnits.melee(&"brawler"),
		TestUnits.ranged(&"archer"),
		TestUnits.melee(&"weakling", {"max_hp": 5, "melee_damage": 0, "acquire_radius": 0}),
	])


func test_an_open_route_visits_its_points_in_order_then_holds() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(BRAWLER, LIGHT, 5 * M, 5 * M, 1000, 0)
	var ids: PackedInt32Array = PackedInt32Array([unit.id])
	_add_points(world, ids, [Vector2i(15, 5), Vector2i(15, 15), Vector2i(5, 15)])
	var visited: Array[int] = _indices(world, unit, 30 * 30)
	assert_eq(visited, [0, 1, 2], "each point once, in order")
	assert_eq(unit.order, Unit.Order.NONE, "then it holds")
	assert_true(unit.route.is_empty(), "with the route gone")
	assert_almost_eq(unit.x, 5 * M, 300)
	assert_almost_eq(unit.z, 15 * M, 300)


func test_a_loop_wraps_and_patrols_fight() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(BRAWLER, LIGHT, 5 * M, 5 * M, 1000, 0)
	var ids: PackedInt32Array = PackedInt32Array([unit.id])
	_add_points(world, ids, [Vector2i(12, 5), Vector2i(12, 12), Vector2i(5, 12)])
	world.enqueue(PatrolCommand.new(0, ids, UnitRoute.Mode.LOOP))
	world.step()
	assert_eq(unit.order, Unit.Order.ATTACK_MOVE, "the leg under way becomes an attack-move")
	assert_eq(_indices(world, unit, 40 * 30).slice(0, 6), [0, 1, 2, 0, 1, 2])


func test_a_back_and_forth_reverses_at_each_end() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(BRAWLER, LIGHT, 5 * M, 5 * M, 1000, 0)
	var ids: PackedInt32Array = PackedInt32Array([unit.id])
	_add_points(world, ids, [Vector2i(10, 5), Vector2i(15, 5), Vector2i(20, 5)])
	world.enqueue(PatrolCommand.new(0, ids, UnitRoute.Mode.BACK_AND_FORTH))
	assert_eq(_indices(world, unit, 40 * 30).slice(0, 7), [0, 1, 2, 1, 0, 1, 2])


func test_a_patrol_fights_what_it_meets_and_resumes_the_same_leg() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(BRAWLER, LIGHT, 5 * M, 5 * M, 1000, 0)
	var ids: PackedInt32Array = PackedInt32Array([unit.id])
	_add_points(world, ids, [Vector2i(25, 5), Vector2i(25, 15)])
	world.enqueue(PatrolCommand.new(0, ids, UnitRoute.Mode.LOOP))
	var foe: Unit = world.spawn_unit(WEAKLING, DARK, 15 * M, 6 * M, 0, -1000)
	var fought: bool = false
	for t: int in 15 * 30:
		world.step()
		if unit.target_id == foe.id:
			fought = true
			assert_eq([unit.order_x, unit.order_z, unit.route_index], [25 * M, 5 * M, 0], "still the first leg")
	assert_true(fought, "it took on the enemy on its way")
	assert_false(foe.is_alive())
	assert_true(unit.route_index >= 1 or unit.x > 20 * M, "and marched on")


func test_a_plain_leg_does_not_pick_a_fight_on_arrival() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(BRAWLER, LIGHT, 5 * M, 5 * M, 1000, 0)
	var ids: PackedInt32Array = PackedInt32Array([unit.id])
	# An enemy right by the first point: a plain move would hold there and
	# fight it; a route walks on.
	world.spawn_unit(WEAKLING, DARK, 15 * M, 6200, 0, -1000)
	_add_points(world, ids, [Vector2i(15, 5), Vector2i(15, 20), Vector2i(30, 20)])
	for t: int in 20 * 30:
		world.step()
		if not unit.route.is_empty():
			assert_eq(unit.target_id, 0, "tick %d: on a plain route it fights no one" % world.tick)


func test_four_points_at_most() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(BRAWLER, LIGHT, 5 * M, 5 * M, 1000, 0)
	_add_points(world, PackedInt32Array([unit.id]), [
		Vector2i(10, 5), Vector2i(15, 5), Vector2i(20, 5), Vector2i(25, 5), Vector2i(30, 5),
	])
	world.step()
	assert_eq(UnitRoute.point_count(unit), UnitRoute.MAX_POINTS)
	assert_eq(UnitRoute.last_point(unit), Vector2i(25 * M, 5 * M), "the fifth was ignored")


func test_a_patrol_needs_two_points_and_a_new_point_replaces_it() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(BRAWLER, LIGHT, 5 * M, 5 * M, 1000, 0)
	var ids: PackedInt32Array = PackedInt32Array([unit.id])
	_add_points(world, ids, [Vector2i(10, 5)])
	world.enqueue(PatrolCommand.new(0, ids, UnitRoute.Mode.LOOP))
	world.step()
	assert_eq(unit.route_mode, UnitRoute.Mode.OPEN, "one point can't make a patrol")
	_add_points(world, ids, [Vector2i(10, 10)], world.tick)
	world.enqueue(PatrolCommand.new(world.tick, ids, UnitRoute.Mode.LOOP))
	world.step()
	assert_eq(unit.route_mode, UnitRoute.Mode.LOOP)
	_add_points(world, ids, [Vector2i(30, 30)], world.tick)
	world.step()
	assert_eq(unit.route_mode, UnitRoute.Mode.OPEN, "a point after a patrol starts a new route")
	assert_eq(UnitRoute.point_count(unit), 1)


func test_every_other_order_clears_the_route() -> void:
	var orders: Dictionary[String, Callable] = {
		"move": func(ids: PackedInt32Array) -> SimCommand: return MoveUnitsCommand.new(1, ids, 20 * M, 20 * M, 0),
		"attack-move": func(ids: PackedInt32Array) -> SimCommand: return AttackMoveCommand.new(1, ids, 20 * M, 20 * M, 0),
		"stop": func(ids: PackedInt32Array) -> SimCommand: return StopUnitsCommand.new(1, ids),
		"guard": func(ids: PackedInt32Array) -> SimCommand: return GuardCommand.new(1, ids),
		"scatter": func(ids: PackedInt32Array) -> SimCommand: return ScatterCommand.new(1, ids),
		"retreat": func(ids: PackedInt32Array) -> SimCommand: return RetreatCommand.new(1, ids, 0),
		"ground attack": func(ids: PackedInt32Array) -> SimCommand: return GroundAttackCommand.new(1, ids, 30 * M, 30 * M),
	}
	for order_name: String in orders:
		var world: World = _world()
		var unit: Unit = world.spawn_unit(ARCHER, LIGHT, 5 * M, 5 * M, 1000, 0)
		var ids: PackedInt32Array = PackedInt32Array([unit.id])
		_add_points(world, ids, [Vector2i(15, 5), Vector2i(15, 15)])
		world.step()
		world.enqueue(orders[order_name].call(ids))
		world.step()
		assert_true(unit.route.is_empty(), "%s clears the route" % order_name)


func test_a_special_keeps_the_route() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(ARCHER, LIGHT, 5 * M, 5 * M, 1000, 0)
	var ids: PackedInt32Array = PackedInt32Array([unit.id])
	_add_points(world, ids, [Vector2i(15, 5), Vector2i(15, 15)])
	world.enqueue(UseSpecialCommand.new(1, ids))
	_run(world, 3)
	assert_eq(UnitRoute.point_count(unit), 2)


func test_a_leg_ended_far_from_its_point_ends_the_route() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(BRAWLER, LIGHT, 5 * M, 5 * M, 1000, 0)
	var ids: PackedInt32Array = PackedInt32Array([unit.id])
	_add_points(world, ids, [Vector2i(15, 5), Vector2i(15, 15)])
	world.enqueue(PatrolCommand.new(0, ids, UnitRoute.Mode.LOOP))
	world.step()
	# As if it had given up 10 m short of its point.
	world.movement.order_stop(unit)
	assert_false(UnitRoute.advance(world, unit))
	assert_true(unit.route.is_empty())


func test_the_group_keeps_its_formation_at_each_point() -> void:
	var world: World = _world()
	var ids: PackedInt32Array = PackedInt32Array()
	for i: int in 3:
		ids.append(world.spawn_unit(BRAWLER, LIGHT, (5 + 2 * i) * M, 5 * M, 0, 1000).id)
	_add_points(world, ids, [Vector2i(20, 10), Vector2i(20, 30)], 0, Formations.Kind.LONG_LINE)
	_run(world, 30 * 30)
	var xs: Array[int] = []
	for unit_id: int in ids:
		var unit: Unit = world.get_unit(unit_id)
		assert_almost_eq(unit.z, 30 * M, 400, "unit %d on the line at the last point" % unit_id)
		xs.append(unit.x)
	xs.sort()
	assert_gt(xs[2] - xs[0], 2 * M, "spread along it")


func test_a_world_without_routes_hashes_as_before() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(BRAWLER, LIGHT, 5 * M, 5 * M, 1000, 0)
	var before: PackedInt64Array = unit.hash_fields()
	_add_points(world, PackedInt32Array([unit.id]), [Vector2i(15, 5)])
	world.step()
	assert_gt(unit.hash_fields().size(), before.size() + 4, "a route is hashed")
	world.enqueue(StopUnitsCommand.new(world.tick, PackedInt32Array([unit.id])))
	world.step()
	var after: PackedInt64Array = unit.hash_fields()
	assert_eq(after.size(), before.size(), "no route, no route fields")


func test_routes_are_the_same_every_time() -> void:
	var a: World = _world()
	var b: World = _world()
	for w: World in [a, b]:
		var ids: PackedInt32Array = PackedInt32Array()
		for i: int in 4:
			ids.append(w.spawn_unit(BRAWLER, LIGHT, (5 + 2 * i) * M, 5 * M, 0, 1000).id)
		_add_points(w, ids, [Vector2i(30, 8), Vector2i(30, 30), Vector2i(8, 30)], 0, Formations.Kind.WEDGE)
		w.enqueue(PatrolCommand.new(40, ids, UnitRoute.Mode.BACK_AND_FORTH))
		w.spawn_unit(WEAKLING, DARK, 30 * M, 20 * M, 0, -1000)
	for t: int in 1200:
		a.step()
		b.step()
		if (t + 1) % 100 == 0:
			assert_eq(a.state_hash(), b.state_hash(), "tick %d" % (t + 1))


func _world() -> World:
	return World.new(1, TestTerrains.flat(40, 40), _catalog)


func _add_points(
	world: World, ids: PackedInt32Array, points: Array, at_tick: int = 0,
	formation: Formations.Kind = Formations.Kind.SHORT_LINE
) -> void:
	for p: Vector2i in points:
		world.enqueue(RoutePointCommand.new(at_tick, ids, p.x * M, p.y * M, formation, false))


# The route indices the unit walks toward, in order, over `ticks`.
func _indices(world: World, unit: Unit, ticks: int) -> Array[int]:
	var seen: Array[int] = []
	for t: int in ticks:
		world.step()
		if unit.route.is_empty():
			continue
		if seen.is_empty() or seen[-1] != unit.route_index:
			seen.append(unit.route_index)
	return seen


func _run(world: World, ticks: int) -> void:
	for t: int in ticks:
		world.step()
