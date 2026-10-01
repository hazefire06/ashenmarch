extends GutTest
## FLANK: a group picks an enemy ranged or support unit (the focus) and, when
## enemy melee screens it, walks round the end of the screen with plain moves
## before it strikes. FlankRoute is the pure geometry; the world tests run a
## raider group (TestUnits.scavenger, which prefers ranged and support) at two
## archer dummies behind a line of melee dummies, and without the line.
## Groups spawn straight from specs (AiDirector.spawn_group), no mission.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

## Catalog indices of the synthetic types.
const SCREEN: int = 0
const ARCHER: int = 1
const RAIDER: int = 2

## The pure fixture: a group at FROM after a target at TARGET, behind a line
## of nine points at z = 30 m, x = 36..44 m.
const FROM: Vector2i = Vector2i(40 * M, 5 * M)
const TARGET: Vector2i = Vector2i(40 * M, 34 * M)

## Ticks a world test runs at most waiting for the first swing.
const SWING_TICKS: int = 1800
## Least edge-to-edge distance (milli-units) a flanker keeps from every unit
## of the screen until it first swings: it goes round, not through.
const SCREEN_CLEAR: int = 2000

var _catalog: UnitCatalog

## What the last _run_until_swing saw: every FLANK_WAYPOINT, the first SWING
## by a group member and its tick, and the least edge distance from a member
## to a screen unit before that tick.
var _waypoints: Array[AiEvent] = []
var _swing: CombatEvent = null
var _swing_tick: int = -1
var _min_edge: int = 0


func before_all() -> void:
	var types: Array[UnitType] = [
		# Melee dummies: never fight back, never die in these tests.
		TestUnits.dummy(&"screen"),
		TestUnits.dummy(&"archer", {"role": UnitType.Role.RANGED}),
		TestUnits.scavenger(&"raider"),
	]
	_catalog = TestUnits.catalog(types)


# --- fixtures ---------------------------------------------------------------


## The nine-point screen line of the pure tests.
func _line() -> Array[Vector2i]:
	var points: Array[Vector2i] = []
	for x: int in range(36, 45):
		points.append(Vector2i(x * M, 30 * M))
	return points


func _world() -> World:
	return World.new(1, TestTerrains.flat(80, 60), _catalog)


## Nine LIGHT melee dummies at z = 30 m, x = 36..44 m, facing the raiders.
func _spawn_screen(world: World) -> Array[Unit]:
	var out: Array[Unit] = []
	for x: int in range(36, 45):
		out.append(world.spawn_unit(SCREEN, LIGHT, x * M, 30 * M, 0, -1))
	return out


## The two LIGHT archer dummies at (39, 34) and (41, 34) m, in that id order.
func _spawn_archers(world: World) -> Array[Unit]:
	var out: Array[Unit] = []
	out.append(world.spawn_unit(ARCHER, LIGHT, 39 * M, 34 * M, 0, -1))
	out.append(world.spawn_unit(ARCHER, LIGHT, 41 * M, 34 * M, 0, -1))
	return out


## count DARK raiders (3 unless given) in a box at (40, 5) m facing south,
## a FLANK group spawned as spec 0.
func _flankers(world: World, count: int = 3) -> AiGroup:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = &"raiders"
	var e: AiUnitEntry = AiUnitEntry.new()
	e.type_id = &"raider"
	e.counts = PackedInt32Array([count])
	g.units.append(e)
	g.spawns = PackedInt32Array([40 * M, 5 * M])
	g.facing_z = 1
	g.behavior = AiGroupSpec.Behavior.FLANK
	assert_eq(g.validate(_catalog), PackedStringArray(), "the spec is valid")
	return world.ai.spawn_group(world, g, 0, 0)


## Puts unit at (x, z) m, standing and holding there, as if it had walked.
func _place(unit: Unit, x: int, z: int) -> void:
	unit.x = x * M
	unit.z = z * M
	unit.goal_x = unit.x
	unit.goal_z = unit.z
	UnitOrders.hold(unit)


## Steps the world until a member of group swings (or SWING_TICKS pass),
## recording what the test asserts on (see the fields above).
func _run_until_swing(world: World, group: AiGroup, screen: Array[Unit]) -> void:
	_waypoints = []
	_swing = null
	_swing_tick = -1
	_min_edge = 1 << 40
	while world.tick < SWING_TICKS and _swing == null:
		world.step()
		for e: AiEvent in world.ai_events:
			if e.kind == AiEvent.Kind.FLANK_WAYPOINT:
				_waypoints.append(e)
		for e: CombatEvent in world.combat_events:
			if e.kind == CombatEvent.Kind.SWING and group.spawned_ids.has(e.attacker_id):
				_swing = e
				_swing_tick = world.tick
				break
		if _swing != null:
			break
		for unit: Unit in group.living(world):
			for post: Unit in screen:
				_min_edge = mini(_min_edge, Targeting.edge_distance(unit, post))


func _is_archer(world: World, unit_id: int) -> bool:
	var unit: Unit = world.get_unit(unit_id)
	return unit != null and unit.type_index == ARCHER


## Steps the world until group emits FLANK_WAYPOINTs, and returns them
## (empty if none come within 60 ticks).
func _next_route(world: World, group: AiGroup) -> Array[AiEvent]:
	var out: Array[AiEvent] = []
	for _t: int in 60:
		world.step()
		for e: AiEvent in world.ai_events:
			if e.kind == AiEvent.Kind.FLANK_WAYPOINT and e.group_id == group.id:
				out.append(e)
		if not out.is_empty():
			return out
	return out


# --- FlankRoute -------------------------------------------------------------


func test_distance_to_segment_measures_to_the_nearest_point_of_it() -> void:
	var a: Vector2i = Vector2i(0, 0)
	var b: Vector2i = Vector2i(10 * M, 0)
	assert_eq(FlankRoute.distance_to_segment(Vector2i(5 * M, 3 * M), a, b), 3 * M, "beside it")
	assert_eq(FlankRoute.distance_to_segment(Vector2i(13 * M, 4 * M), a, b), 5 * M, "past b")
	assert_eq(FlankRoute.distance_to_segment(Vector2i(-3 * M, -4 * M), a, b), 5 * M, "before a")
	assert_eq(FlankRoute.distance_to_segment(Vector2i(3 * M, 4 * M), a, a), 5 * M, "a point segment")
	assert_eq(
		FlankRoute.distance_to_segment(Vector2i(M, M), Vector2i(-10 * M, 10 * M), Vector2i(10 * M, -10 * M)),
		1414, "a diagonal through negative coordinates, floored"
	)


func test_a_screen_line_blocks_the_way_and_no_screen_does_not() -> void:
	assert_true(FlankRoute.blocked(FROM, TARGET, _line()), "the line stands across the way")
	var none: Array[Vector2i] = []
	assert_false(FlankRoute.blocked(FROM, TARGET, none), "nothing in the way")
	var aside: Array[Vector2i] = []
	for point: Vector2i in _line():
		aside.append(point + Vector2i(20 * M, 0))
	assert_false(FlankRoute.blocked(FROM, TARGET, aside), "a line 16 m off to the side is clear")


func test_both_routes_go_round_the_end_of_the_line() -> void:
	var sides: Array[int] = []
	for side: int in [1, -1]:
		var route: PackedInt64Array = FlankRoute.route(FROM, TARGET, _line(), side)
		assert_eq(route.size(), 4, "two waypoints")
		if route.size() != 4:
			return
		var w1: Vector2i = Vector2i(route[0], route[1])
		var w2: Vector2i = Vector2i(route[2], route[3])
		for w: Vector2i in [w1, w2]:
			assert_gte(
				absi(w.x - 40 * M), 4 * M + FlankRoute.SIDE_MARGIN, "side %d: past the end plus the margin" % side
			)
		assert_lt(w1.y, 30 * M, "side %d: W1 is in front of the line" % side)
		assert_eq(w2.y, TARGET.y, "side %d: W2 is level with the target" % side)
		assert_eq(signi(w1.x - 40 * M), signi(w2.x - 40 * M), "side %d: both on one side" % side)
		sides.append(signi(w1.x - 40 * M))
		# Both legs of the route keep the margin. (The strike from W2 is the
		# target's business: it may stand just behind its screen.)
		var walk: Array[Vector2i] = [FROM, w1, w2]
		for k: int in 2:
			for point: Vector2i in _line():
				assert_gte(
					FlankRoute.distance_to_segment(point, walk[k], walk[k + 1]), FlankRoute.SIDE_MARGIN,
					"side %d, leg %d clears %s" % [side, k, point]
				)
	assert_eq(sides, [-1, 1], "+1 turns forward (south) to the west, -1 to the east")


func test_lateral_reach_is_shorter_round_the_nearer_end() -> void:
	# The target is 2 m from the line's west end and 6 m from its east end.
	var from: Vector2i = Vector2i(38 * M, 5 * M)
	var target: Vector2i = Vector2i(38 * M, 34 * M)
	assert_eq(FlankRoute.lateral_reach(from, target, _line(), 1), 2 * M + FlankRoute.SIDE_MARGIN)
	assert_eq(FlankRoute.lateral_reach(from, target, _line(), -1), 6 * M + FlankRoute.SIDE_MARGIN)
	# A screen wholly on one side still keeps the margin on the other.
	var west: Array[Vector2i] = [Vector2i(30 * M, 30 * M)]
	assert_eq(FlankRoute.lateral_reach(from, target, west, -1), FlankRoute.SIDE_MARGIN)


# --- the behavior -----------------------------------------------------------


func test_flankers_go_round_the_screen_and_strike_an_archer() -> void:
	var world: World = _world()
	var screen: Array[Unit] = _spawn_screen(world)
	_spawn_archers(world)
	var group: AiGroup = _flankers(world)
	_run_until_swing(world, group, screen)
	var xs: Array[int] = []
	for e: AiEvent in _waypoints:
		xs.append(e.x)
	gut.p("waypoints %s, min edge %d, first swing tick %d at %d" % [
		_waypoints.map(func(e: AiEvent) -> Vector3i: return Vector3i(e.x, e.z, e.value)),
		_min_edge, _swing_tick, _swing.target_id if _swing != null else 0,
	])
	var outside: bool = false
	for x: int in xs:
		outside = outside or x < 30 * M or x > 50 * M
	assert_true(outside, "a waypoint past x in [30, 50] m: %s" % [xs])
	assert_not_null(_swing, "a raider swung within %d ticks" % SWING_TICKS)
	if _swing == null:
		return
	assert_gte(_min_edge, SCREEN_CLEAR, "the raiders kept clear of the screen until they struck")
	assert_true(_is_archer(world, _swing.target_id), "the first swing is at an archer")


func test_a_box_of_five_also_rounds_the_screen_clear_of_it() -> void:
	# A realistic Ripper group: a box of five is three wide, so its nearest
	# member passes the screen's end 1.4 m inside the route's line. This pins
	# FlankRoute.SIDE_MARGIN against AiFlank.CONTACT for it.
	var world: World = _world()
	var screen: Array[Unit] = _spawn_screen(world)
	_spawn_archers(world)
	var group: AiGroup = _flankers(world, 5)
	_run_until_swing(world, group, screen)
	gut.p("five: waypoints %s, min edge %d, first swing tick %d at %d" % [
		_waypoints.map(func(e: AiEvent) -> Vector3i: return Vector3i(e.x, e.z, e.value)),
		_min_edge, _swing_tick, _swing.target_id if _swing != null else 0,
	])
	assert_eq(_waypoints.size(), 2, "a route round the screen")
	assert_not_null(_swing, "a raider swung within %d ticks" % SWING_TICKS)
	if _swing == null:
		return
	assert_gte(_min_edge, SCREEN_CLEAR, "all five kept clear of the screen until they struck")
	assert_true(_is_archer(world, _swing.target_id), "the first swing is at an archer")


func test_with_no_screen_the_flankers_strike_straight_away() -> void:
	var world: World = _world()
	_spawn_archers(world)
	var group: AiGroup = _flankers(world)
	var none: Array[Unit] = []
	_run_until_swing(world, group, none)
	gut.p("control: first swing tick %d at %d" % [_swing_tick, _swing.target_id if _swing != null else 0])
	assert_eq(_waypoints.size(), 0, "no route: nothing stands in the way")
	assert_eq(group.phase, 2, "striking")
	assert_not_null(_swing, "a raider swung within %d ticks" % SWING_TICKS)
	if _swing == null:
		return
	assert_true(_is_archer(world, _swing.target_id), "the first swing is at an archer")


func test_with_nothing_to_flank_the_group_hunts() -> void:
	var world: World = _world()
	var near: Unit = world.spawn_unit(SCREEN, LIGHT, 40 * M, 30 * M, 0, -1)
	world.spawn_unit(SCREEN, LIGHT, 20 * M, 50 * M, 0, -1)
	var group: AiGroup = _flankers(world)
	var order: AiEvent = null
	for _t: int in 60:
		world.step()
		for e: AiEvent in world.ai_events:
			assert_ne(e.kind, AiEvent.Kind.FLANK_WAYPOINT, "no route without a focus")
			if e.kind == AiEvent.Kind.ORDER and order == null:
				order = e
		if order != null:
			break
	assert_not_null(order, "the group was sent somewhere")
	if order == null:
		return
	assert_eq(Vector2i(order.x, order.z), Vector2i(near.x, near.z), "at the nearest, as a hunt would")
	assert_eq(order.value, 1, "attack-moving")
	assert_eq(group.focus_id, 0, "melee isn't in flank_roles")


func test_a_flank_that_is_hurt_strikes_at_once() -> void:
	var world: World = _world()
	_spawn_screen(world)
	var archers: Array[Unit] = _spawn_archers(world)
	var group: AiGroup = _flankers(world)
	assert_false(_next_route(world, group).is_empty(), "a route was planned")
	assert_eq(group.phase, 1, "approaching")
	assert_eq(group.focus_id, archers[0].id, "the nearer archer, the lower id on a tie")
	world.get_unit(group.members[0]).hp -= 10
	var order: AiEvent = null
	for _t: int in AiDirector.THINK_TICKS:
		world.step()
		for e: AiEvent in world.ai_events:
			if e.kind == AiEvent.Kind.ORDER and order == null:
				order = e
		if order != null:
			break
	assert_eq(group.phase, 2, "found out at the next think: strike")
	assert_not_null(order)
	if order == null:
		return
	assert_eq(Vector2i(order.x, order.z), Vector2i(archers[0].x, archers[0].z), "at the focus")
	assert_eq(order.value, 1, "attack-moving")


func test_an_enemy_in_contact_on_the_approach_strikes_at_once() -> void:
	var world: World = _world()
	_spawn_screen(world)
	var archers: Array[Unit] = _spawn_archers(world)
	var group: AiGroup = _flankers(world)
	assert_false(_next_route(world, group).is_empty(), "a route was planned")
	assert_eq(group.phase, 1, "approaching")
	var hp: int = AiOrders.hp_sum(group.living(world))
	# A dummy that never hits back, 2 m center to center (1.2 m edge to edge)
	# from a member: well inside CONTACT.
	var member: Unit = world.get_unit(group.members[0])
	world.spawn_unit(SCREEN, LIGHT, member.x - 2 * M, member.z, 1, 0)
	var order: AiEvent = null
	for _t: int in AiDirector.THINK_TICKS:
		world.step()
		for e: AiEvent in world.ai_events:
			if e.kind == AiEvent.Kind.ORDER and order == null:
				order = e
		if order != null:
			break
	assert_eq(AiOrders.hp_sum(group.living(world)), hp, "nobody was hurt: contact alone")
	assert_eq(group.phase, 2, "found out at the next think: strike")
	assert_not_null(order)
	if order == null:
		return
	assert_eq(Vector2i(order.x, order.z), Vector2i(archers[0].x, archers[0].z), "at the focus")
	assert_eq(order.value, 1, "attack-moving")


func test_a_focus_killed_mid_route_gets_a_route_to_the_next_one() -> void:
	var world: World = _world()
	_spawn_screen(world)
	var archers: Array[Unit] = _spawn_archers(world)
	var group: AiGroup = _flankers(world)
	assert_false(_next_route(world, group).is_empty(), "a route was planned")
	assert_eq(group.focus_id, archers[0].id)
	archers[0].kill()
	var replanned: Array[AiEvent] = _next_route(world, group)
	assert_eq(replanned.size(), 2, "a new route, two waypoints")
	assert_eq(group.focus_id, archers[1].id, "the other archer")
	assert_eq(Vector2i(group.plan_x, group.plan_z), Vector2i(archers[1].x, archers[1].z))
	assert_eq(group.phase, 1, "approaching again")
	for e: AiEvent in replanned:
		assert_gt(e.x, 44 * M, "round the east end, the nearer one to (41, 34)")


func test_a_flank_fighting_by_the_screen_keeps_fighting_when_its_focus_dies() -> void:
	var world: World = _world()
	var screen: Array[Unit] = _spawn_screen(world)
	var archers: Array[Unit] = _spawn_archers(world)
	var group: AiGroup = _flankers(world)
	_run_until_swing(world, group, screen)
	assert_not_null(_swing, "the flank struck")
	# Let every member close in on the focus.
	var engaged: bool = false
	while world.tick < SWING_TICKS and not engaged:
		world.step()
		engaged = true
		for unit: Unit in group.living(world):
			engaged = engaged and unit.target_id == archers[0].id
	assert_true(engaged, "all three are on the focus")
	assert_eq(group.phase, 2)
	archers[0].kill()
	# Through the next think: the new focus is planned for while the members
	# stand by the screen and the other archer, so they must not walk off.
	for _t: int in AiDirector.THINK_TICKS + 1:
		world.step()
		for e: AiEvent in world.ai_events:
			if e.group_id != group.id:
				continue
			assert_ne(e.kind, AiEvent.Kind.FLANK_WAYPOINT, "no route away from a fight")
			if e.kind == AiEvent.Kind.ORDER:
				assert_eq(e.value, 1, "attack-moves only, no plain move away")
	assert_eq(group.focus_id, archers[1].id, "the other archer")
	assert_eq(group.phase, 2, "still striking")
	for _t: int in 30:
		world.step()
	for unit: Unit in group.living(world):
		assert_eq(unit.target_id, archers[1].id, "unit %d took up the new focus" % unit.id)


func test_set_behavior_wipes_the_flank_plan() -> void:
	var world: World = _world()
	var group: AiGroup = _flankers(world)
	group.phase = 1
	group.focus_id = 3
	group.route = PackedInt64Array([1, 2, 3, 4])
	group.route_index = 1
	group.plan_x = 5
	group.plan_z = 6
	world.ai.set_behavior(world, group, AiGroupSpec.Behavior.HUNT)
	assert_eq(group.phase, 0)
	assert_eq(group.focus_id, 0)
	assert_true(group.route.is_empty())
	assert_eq(group.route_index, 0)
	assert_eq(Vector2i(group.plan_x, group.plan_z), Vector2i.ZERO)


func test_a_focus_that_moves_far_gets_a_new_route() -> void:
	var world: World = _world()
	_spawn_screen(world)
	var archers: Array[Unit] = _spawn_archers(world)
	var group: AiGroup = _flankers(world)
	assert_false(_next_route(world, group).is_empty(), "a route was planned")
	assert_eq(Vector2i(group.plan_x, group.plan_z), Vector2i(39 * M, 34 * M), "planned where the focus stood")
	_place(archers[0], 39, 44)
	var replanned: Array[AiEvent] = _next_route(world, group)
	assert_eq(replanned.size(), 2, "a new route, two waypoints")
	assert_eq(group.focus_id, archers[0].id, "the same focus")
	assert_eq(Vector2i(group.plan_x, group.plan_z), Vector2i(39 * M, 44 * M))
	assert_eq(group.phase, 1, "approaching again")
	if replanned.size() == 2:
		assert_gt(replanned[1].z, 40 * M, "the new W2 is level with where the focus went")


func test_the_planned_focus_position_is_hashed() -> void:
	var world: World = _world()
	var group: AiGroup = _flankers(world)
	var before: PackedInt64Array = group.hash_fields()
	group.plan_x += 1
	assert_ne(group.hash_fields(), before, "plan_x")
	before = group.hash_fields()
	group.plan_z += 1
	assert_ne(group.hash_fields(), before, "plan_z")
