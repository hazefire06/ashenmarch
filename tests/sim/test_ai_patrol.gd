extends GutTest
## PATROL: a group walks its waypoints one leg at a time (AiBehaviors.leg),
## looping or ping-ponging, through a gap in a wall, past a waypoint it can't
## reach, fighting what it meets on the way, and switching to its on_alert
## behavior when an enemy comes near. Groups are spawned straight from specs
## (AiDirector.spawn_group) on synthetic terrain, with no mission.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

## Catalog indices of the synthetic types.
const GRUNT: int = 0
const FOE: int = 1

## The members' centroid is at least this close to a waypoint the group
## reports reached.
const NEAR: int = 3 * M
## Every route here fits in this many ticks. The longest, the ping-pong, is
## 240 m of walking at a grunt's 4 m/s (1800 ticks), plus up to a think's wait
## (15 ticks) at each waypoint, plus the jams on arrival: a member whose
## formation slot lies behind a mate that has already stopped can take a few
## hundred ticks to squeeze past or give up (UnitMovement), and a leg waits
## for every member.
const RUN_TICKS: int = 3600

var _catalog: UnitCatalog


func before_all() -> void:
	var types: Array[UnitType] = [
		# Twice the stock pace, so five or six 40-57 m legs fit in RUN_TICKS.
		TestUnits.melee(&"grunt", {"move_speed": 4000}),
		TestUnits.melee(&"foe"),
	]
	_catalog = TestUnits.catalog(types)


# --- fixtures ---------------------------------------------------------------


func _world(terrain: Terrain = null) -> World:
	return World.new(1, terrain if terrain != null else TestTerrains.flat(60, 60), _catalog)


## A PATROL of four grunts spawning at (10, 10) m and walking points, given
## in metres as x, z pairs.
func _patrol_spec(
	points: Array[int], mode: AiGroupSpec.PatrolMode = AiGroupSpec.PatrolMode.LOOP
) -> AiGroupSpec:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = &"patrol"
	var e: AiUnitEntry = AiUnitEntry.new()
	e.type_id = &"grunt"
	e.counts = PackedInt32Array([4])
	g.units.append(e)
	g.spawns = PackedInt32Array([10 * M, 10 * M])
	g.behavior = AiGroupSpec.Behavior.PATROL
	var waypoints: PackedInt32Array = PackedInt32Array()
	for v: int in points:
		waypoints.append(v * M)
	g.waypoints = waypoints
	g.patrol_mode = mode
	assert_eq(g.validate(_catalog), PackedStringArray(), "the spec is valid")
	return g


## Steps the world until `want` waypoint events (reached or failed) have
## come, or until RUN_TICKS. One entry per event: [kind, waypoint index,
## distance from the members' centroid to the event's point, tick].
func _walk(world: World, group: AiGroup, want: int) -> Array[PackedInt64Array]:
	var seen: Array[PackedInt64Array] = []
	while world.tick < RUN_TICKS and seen.size() < want:
		world.step()
		for e: AiEvent in world.ai_events:
			if e.group_id != group.id:
				continue
			if e.kind != AiEvent.Kind.WAYPOINT_REACHED and e.kind != AiEvent.Kind.WAYPOINT_FAILED:
				continue
			var c: Vector2i = AiOrders.centroid(group.living(world))
			seen.append(PackedInt64Array([e.kind, e.value, FixedMath.length(c.x - e.x, c.y - e.z), world.tick]))
	return seen


## The waypoint indices of the reached events among seen, in order.
func _reached(seen: Array[PackedInt64Array]) -> Array[int]:
	var out: Array[int] = []
	for s: PackedInt64Array in seen:
		if s[0] == AiEvent.Kind.WAYPOINT_REACHED:
			out.append(s[1])
	return out


func _assert_all_near(seen: Array[PackedInt64Array]) -> void:
	for s: PackedInt64Array in seen:
		assert_lte(s[2], NEAR, "centroid %d mm from waypoint %d at tick %d" % [s[2], s[1], s[3]])


## Flat 60 x 60 m with a wall along z = 30 m, open only at x = 28..32 m.
func _walled() -> Terrain:
	var rows: Array[String] = []
	for j: int in 60:
		if j == 30:
			rows.append("#".repeat(28) + "....." + "#".repeat(27))
		else:
			rows.append(".".repeat(60))
	return TestTerrains.from_ascii(rows)


## Flat 60 x 60 m cut in two by a wall along z = 40 m, end to end: the far
## side is a pathing component of its own.
func _cut_off() -> Terrain:
	var rows: Array[String] = []
	for j: int in 60:
		rows.append("#".repeat(60) if j == 40 else ".".repeat(60))
	return TestTerrains.from_ascii(rows)


# --- walking the route ------------------------------------------------------


func test_a_looping_patrol_reaches_its_waypoints_in_order() -> void:
	var world: World = _world()
	var group: AiGroup = world.ai.spawn_group(world, _patrol_spec([50, 10, 50, 50, 10, 50]), 0, 0)
	var seen: Array[PackedInt64Array] = _walk(world, group, 5)
	assert_eq(_reached(seen), [0, 1, 2, 0, 1], "after the last waypoint it wraps to the first")
	_assert_all_near(seen)


func test_a_ping_pong_patrol_turns_back_at_either_end() -> void:
	var world: World = _world()
	var spec: AiGroupSpec = _patrol_spec([50, 10, 50, 50, 10, 50], AiGroupSpec.PatrolMode.PING_PONG)
	var group: AiGroup = world.ai.spawn_group(world, spec, 0, 0)
	var seen: Array[PackedInt64Array] = _walk(world, group, 6)
	assert_eq(_reached(seen), [0, 1, 2, 1, 0, 1])
	_assert_all_near(seen)


func test_reaching_a_waypoint_reports_it_and_starts_the_next_leg_at_once() -> void:
	var world: World = _world()
	var group: AiGroup = world.ai.spawn_group(world, _patrol_spec([50, 10, 50, 50]), 0, 0)
	var orders: Array[AiEvent] = []
	while world.tick < RUN_TICKS:
		world.step()
		var reached: bool = false
		for e: AiEvent in world.ai_events:
			if e.kind == AiEvent.Kind.WAYPOINT_REACHED:
				reached = true
				assert_eq(Vector2i(e.x, e.z), Vector2i(50 * M, 10 * M), "the event is at the waypoint")
				assert_eq(e.value, 0)
			elif e.kind == AiEvent.Kind.ORDER:
				orders.append(e)
		if reached:
			break
	assert_eq(group.waypoint_index, 1, "on to the next waypoint")
	assert_true(group.leg_active)
	assert_eq(Vector2i(group.leg_x, group.leg_z), Vector2i(50 * M, 50 * M))
	assert_eq(orders.size(), 2, "one order per leg: the first and, the same tick it ended, the second")
	if orders.size() != 2:
		return
	assert_eq(Vector2i(orders[1].x, orders[1].z), Vector2i(50 * M, 50 * M))
	assert_eq(orders[1].value, 1, "a patrol attack-moves")
	assert_eq(orders[0].unit_id, group.members[0], "the event names the bucket's lowest id")
	for unit: Unit in group.living(world):
		assert_eq(unit.order, Unit.Order.ATTACK_MOVE)


func test_a_patrol_finds_the_gap_in_a_wall() -> void:
	var world: World = _world(_walled())
	var group: AiGroup = world.ai.spawn_group(world, _patrol_spec([50, 50, 10, 10]), 0, 0)
	var seen: Array[PackedInt64Array] = _walk(world, group, 2)
	assert_eq(_reached(seen), [0, 1], "across the wall and back")
	_assert_all_near(seen)
	assert_eq(world.movement.queued_paths(), 0, "no path solve left waiting")


func test_a_waypoint_it_cannot_reach_is_retried_once_then_skipped() -> void:
	var world: World = _world(_cut_off())
	var group: AiGroup = world.ai.spawn_group(world, _patrol_spec([30, 50, 10, 10]), 0, 0)
	var seen: Array[PackedInt64Array] = _walk(world, group, 3)
	assert_eq(seen.size(), 3)
	if seen.size() != 3:
		return
	assert_eq(seen[0][0], AiEvent.Kind.WAYPOINT_FAILED)
	assert_eq(seen[0][1], -1, "the first failure is a retry")
	assert_eq(seen[1][0], AiEvent.Kind.WAYPOINT_FAILED)
	assert_eq(seen[1][1], 0, "the second gives up on waypoint 0")
	assert_eq(seen[2][0], AiEvent.Kind.WAYPOINT_REACHED)
	assert_eq(seen[2][1], 1, "and the patrol walks on")
	assert_lte(seen[2][2], NEAR)


func test_a_leg_is_not_over_while_a_member_that_got_there_is_still_fighting() -> void:
	var world: World = _world()
	var group: AiGroup = world.ai.spawn_group(world, _patrol_spec([50, 10, 50, 50]), 0, 0)
	var units: Array[Unit] = group.living(world)
	var running: AiBehaviors.LegResult = AiBehaviors.LegResult.RUNNING
	assert_eq(AiBehaviors.leg(world, group, units, 10 * M, 12 * M, true), running, "the leg starts")
	for unit: Unit in units:
		UnitOrders.hold(unit)
	# Holding units fight what walks up to them: this one has.
	units[1].target_id = units[0].id
	assert_eq(AiBehaviors.leg(world, group, units, 10 * M, 12 * M, true), running, "one is busy")
	units[1].target_id = 0
	assert_eq(AiBehaviors.leg(world, group, units, 10 * M, 12 * M, true), AiBehaviors.LegResult.ARRIVED)
	assert_false(group.leg_active)


# --- meeting enemies --------------------------------------------------------


func test_a_patrol_fights_what_it_meets_and_then_walks_on() -> void:
	var world: World = _world()
	var group: AiGroup = world.ai.spawn_group(world, _patrol_spec([50, 10, 50, 50]), 0, 0)
	var foe: Unit = world.spawn_unit(FOE, LIGHT, 30 * M, 10 * M, -1, 0)
	var kill_tick: int = -1
	var first_reached: int = -1
	var behavior_events: int = 0
	while world.tick < RUN_TICKS and first_reached < 0:
		world.step()
		for e: CombatEvent in world.combat_events:
			if e.kind == CombatEvent.Kind.KILL and e.target_id == foe.id and group.spawned_ids.has(e.attacker_id):
				kill_tick = world.tick
		for e: AiEvent in world.ai_events:
			if e.kind == AiEvent.Kind.WAYPOINT_REACHED:
				first_reached = world.tick
				assert_eq(e.value, 0)
			elif e.kind == AiEvent.Kind.BEHAVIOR:
				behavior_events += 1
	assert_gt(kill_tick, 0, "a member killed the foe on the route")
	assert_gt(first_reached, kill_tick, "then the patrol reached the next waypoint")
	assert_eq(behavior_events, 0, "with no alert radius it stays on patrol")
	assert_eq(group.behavior, AiGroupSpec.Behavior.PATROL)


func test_an_enemy_inside_the_alert_radius_turns_the_patrol_to_its_alert_behavior() -> void:
	var world: World = _world()
	var spec: AiGroupSpec = _patrol_spec([50, 10, 50, 50])
	spec.alert_radius = 10 * M
	var group: AiGroup = world.ai.spawn_group(world, spec, 0, 0)
	var foe: Unit = world.spawn_unit(FOE, LIGHT, 30 * M, 18 * M, -1, 0)
	var switched: int = -1
	while world.tick < RUN_TICKS and switched < 0:
		world.step()
		for e: AiEvent in world.ai_events:
			if e.kind == AiEvent.Kind.BEHAVIOR and e.group_id == group.id:
				assert_eq(e.value, AiGroupSpec.Behavior.HUNT)
				switched = world.tick
	assert_gt(switched, 0, "the foe 8 m off the route alerted the patrol")
	assert_eq(group.behavior, AiGroupSpec.Behavior.HUNT)
	var nearest: int = 1 << 40
	for unit: Unit in group.living(world):
		nearest = mini(nearest, FixedMath.length(unit.x - foe.x, unit.z - foe.z))
	assert_lte(nearest, spec.alert_radius + 200, "it switched once a member came within the radius")
	for _t: int in 300:
		world.step()
	assert_false(foe.is_alive(), "the hunt ran it down")


func test_an_enemy_outside_the_alert_radius_leaves_the_patrol_alone() -> void:
	var world: World = _world()
	var spec: AiGroupSpec = _patrol_spec([50, 10, 50, 50])
	spec.alert_radius = 10 * M
	var group: AiGroup = world.ai.spawn_group(world, spec, 0, 0)
	world.spawn_unit(FOE, LIGHT, 30 * M, 22 * M, -1, 0)
	var seen: Array[PackedInt64Array] = _walk(world, group, 1)
	assert_eq(_reached(seen), [0], "the first leg passes 12 m from it")
	assert_eq(group.behavior, AiGroupSpec.Behavior.PATROL)


func test_switch_to_plans_the_new_behavior_at_once() -> void:
	var world: World = _world()
	var group: AiGroup = world.ai.spawn_group(world, _patrol_spec([50, 10, 50, 50]), 0, 0)
	var foe: Unit = world.spawn_unit(FOE, LIGHT, 40 * M, 40 * M, -1, 0)
	world.ai_events.clear()
	AiBehaviors.switch_to(world, group, AiGroupSpec.Behavior.HUNT)
	assert_eq(group.behavior, AiGroupSpec.Behavior.HUNT)
	assert_false(group.think_now, "it has just planned; no second plan next tick")
	var kinds: Array[int] = []
	for e: AiEvent in world.ai_events:
		kinds.append(e.kind)
	assert_eq(kinds, [AiEvent.Kind.BEHAVIOR, AiEvent.Kind.ORDER])
	if kinds.size() != 2:
		return
	assert_eq(Vector2i(world.ai_events[1].x, world.ai_events[1].z), Vector2i(foe.x, foe.z))
	for i: int in group.members.size():
		assert_eq(group.ordered_target[i], foe.id)
