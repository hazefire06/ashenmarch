extends GutTest
## ESCORT: a group that walks its route only while a unit of the player's is
## near, waiting where it stands when the friend falls behind or an enemy
## comes close. Groups are spawned straight from specs (AiDirector.spawn_group)
## on synthetic terrain, with no mission; a "friend" is a commanded unit of the
## group's side that a test moves by hand.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

## Catalog indices of the synthetic types.
const VILLAGER: int = 0
const FRIEND: int = 1
const FOE: int = 2
const LURKER: int = 3

const ESCORT_RADIUS: int = 12 * M
const ALERT_RADIUS: int = 10 * M
## Where the group spawns and the route it walks, in metres: east, then south.
const SPAWN: Vector2i = Vector2i(10, 30)
const ROUTE: Array[int] = [30, 30, 55, 30, 55, 50]
## A friend parked here is far from the whole route.
const AWAY: Vector2i = Vector2i(75, 5)
## Every walk here fits in this many ticks: 70 m of route at 4 m/s is 530
## ticks, plus the think each leg waits for and the jam at each stop.
const RUN_TICKS: int = 2400
## The members' centroid is at least this close to a waypoint the group
## reports reached.
const NEAR: int = 4 * M

var _catalog: UnitCatalog


func before_all() -> void:
	var types: Array[UnitType] = [
		# The villager: never fights. Twice the stock pace so a route fits in RUN_TICKS.
		TestUnits.dummy(&"villager", {"move_speed": 4000, "max_hp": 100}),
		TestUnits.dummy(&"friend"),
		TestUnits.dummy(&"foe"),
		TestUnits.undead(&"lurker", {"hidden_in_deep_water": true}),
	]
	_catalog = TestUnits.catalog(types)


# --- fixtures ---------------------------------------------------------------


func _world(terrain: Terrain = null) -> World:
	return World.new(1, terrain if terrain != null else TestTerrains.flat(80, 60), _catalog)


## An ESCORT of `count` villagers spawning at SPAWN, walking `points` (x, z
## pairs in metres), with a 12 m escort radius and no alert radius.
func _escort_spec(points: Array[int] = ROUTE, count: int = 1) -> AiGroupSpec:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = &"escort"
	g.faction = LIGHT
	var e: AiUnitEntry = AiUnitEntry.new()
	e.type_id = &"villager"
	e.counts = PackedInt32Array([count])
	g.units.append(e)
	g.spawns = PackedInt32Array([SPAWN.x * M, SPAWN.y * M])
	g.facing_x = 1
	g.behavior = AiGroupSpec.Behavior.ESCORT
	var waypoints: PackedInt32Array = PackedInt32Array()
	for v: int in points:
		waypoints.append(v * M)
	g.waypoints = waypoints
	g.escort_radius = ESCORT_RADIUS
	assert_eq(g.validate(_catalog), PackedStringArray(), "the spec is valid")
	return g


## The world, an escort group, and a friend standing beside it.
func _scene(spec: AiGroupSpec = null, terrain: Terrain = null) -> Array:
	var world: World = _world(terrain)
	var group: AiGroup = world.ai.spawn_group(world, spec if spec != null else _escort_spec(), 0, 0)
	var friend: Unit = world.spawn_unit(FRIEND, LIGHT, 0, 0, 1, 0)
	_beside(world, group, friend)
	return [world, group, friend]


## Puts the friend 3 m from the group's centroid.
func _beside(world: World, group: AiGroup, friend: Unit) -> void:
	var c: Vector2i = AiOrders.centroid(group.living(world))
	friend.x = c.x
	friend.z = c.y + 3 * M


## Puts the friend `distance` mm north of the group's first member, so that
## distance is the one the escort sees.
func _north_of_first(world: World, group: AiGroup, friend: Unit, distance: int) -> void:
	var first: Unit = group.living(world)[0]
	friend.x = first.x
	friend.z = first.z - distance


func _park(unit: Unit, at: Vector2i) -> void:
	unit.x = at.x * M
	unit.z = at.y * M


## Steps once and adds the group's escort-relevant events to log.
func _step(world: World, group: AiGroup, log: Array[AiEvent]) -> void:
	world.step()
	for e: AiEvent in world.ai_events:
		if e.group_id == group.id:
			log.append(e)


## Steps up to `ticks` times with the friend beside the group before each step.
## Stops early once stop_at returns true.
func _walk_with_friend(
	world: World, group: AiGroup, friend: Unit, log: Array[AiEvent], ticks: int, stop_at: Callable
) -> void:
	for _t: int in ticks:
		_beside(world, group, friend)
		_step(world, group, log)
		if stop_at.call():
			return


func _of_kind(log: Array[AiEvent], kind: AiEvent.Kind) -> Array[AiEvent]:
	var out: Array[AiEvent] = []
	for e: AiEvent in log:
		if e.kind == kind:
			out.append(e)
	return out


## The waypoint indices of the WAYPOINT_REACHED events in log, in order.
func _reached(log: Array[AiEvent]) -> Array[int]:
	var out: Array[int] = []
	for e: AiEvent in _of_kind(log, AiEvent.Kind.WAYPOINT_REACHED):
		out.append(e.value)
	return out


func _positions(group: AiGroup, world: World) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for unit: Unit in group.living(world):
		out.append(Vector2i(unit.x, unit.z))
	return out


# --- walking the route ------------------------------------------------------


func test_it_walks_a_three_waypoint_route_with_a_friend_beside_it_and_arrives() -> void:
	var s: Array = _scene(_escort_spec(ROUTE, 2))
	var world: World = s[0]
	var group: AiGroup = s[1]
	var friend: Unit = s[2]
	var log: Array[AiEvent] = []
	_walk_with_friend(world, group, friend, log, RUN_TICKS, func() -> bool: return group.phase == 2)
	assert_eq(group.phase, 2, "arrived")
	assert_eq(_reached(log), [0, 1, 2], "every waypoint, in order")
	assert_eq(_of_kind(log, AiEvent.Kind.ESCORT_WAIT).size(), 0, "it never had to wait")
	assert_eq(_of_kind(log, AiEvent.Kind.WAYPOINT_FAILED).size(), 0)
	assert_eq(group.behavior, AiGroupSpec.Behavior.ESCORT, "never switched")
	var c: Vector2i = AiOrders.centroid(group.living(world))
	assert_lte(FixedMath.length(c.x - 55 * M, c.y - 50 * M), NEAR, "at the last waypoint")
	assert_eq(group.waypoint_index, 2, "the index stays on the last waypoint")
	assert_false(group.leg_active)


func test_each_reached_event_is_at_its_waypoint_and_the_members_are_near_it() -> void:
	var s: Array = _scene(_escort_spec(ROUTE, 2))
	var world: World = s[0]
	var group: AiGroup = s[1]
	var friend: Unit = s[2]
	var log: Array[AiEvent] = []
	var seen: int = 0
	for _t: int in RUN_TICKS:
		_beside(world, group, friend)
		world.step()
		for e: AiEvent in world.ai_events:
			if e.kind == AiEvent.Kind.WAYPOINT_REACHED and e.group_id == group.id:
				assert_eq(Vector2i(e.x, e.z), Vector2i(ROUTE[2 * e.value] * M, ROUTE[2 * e.value + 1] * M))
				var c: Vector2i = AiOrders.centroid(group.living(world))
				assert_lte(FixedMath.length(c.x - e.x, c.y - e.z), NEAR, "near waypoint %d" % e.value)
				seen += 1
		if group.phase == 2:
			break
	assert_eq(seen, 3)
	assert_eq(log.size(), 0)


func test_a_group_that_has_arrived_holds_and_ignores_the_friend_leaving() -> void:
	var s: Array = _scene(_escort_spec([30, 30], 2))
	var world: World = s[0]
	var group: AiGroup = s[1]
	var friend: Unit = s[2]
	var log: Array[AiEvent] = []
	_walk_with_friend(world, group, friend, log, RUN_TICKS, func() -> bool: return group.phase == 2)
	assert_eq(group.phase, 2)
	_park(friend, AWAY)
	var held: Array[Vector2i] = _positions(group, world)
	log.clear()
	for _t: int in 120:
		_step(world, group, log)
	assert_eq(log.size(), 0, "no events: nothing left to do")
	assert_eq(group.phase, 2)
	assert_eq(_positions(group, world), held, "the members hold")


# --- the friend -------------------------------------------------------------


func test_it_waits_where_it_stands_when_the_friend_walks_away() -> void:
	var s: Array = _scene()
	var world: World = s[0]
	var group: AiGroup = s[1]
	var friend: Unit = s[2]
	var log: Array[AiEvent] = []
	_walk_with_friend(world, group, friend, log, 100, func() -> bool: return false)
	assert_eq(group.phase, 0, "walking with the friend beside it")
	var moved: Vector2i = AiOrders.centroid(group.living(world))
	assert_gt(moved.x, SPAWN.x * M + 3 * M, "it is under way")
	_park(friend, AWAY)
	log.clear()
	var waited_at: int = -1
	for _t: int in 40:
		_step(world, group, log)
		if not _of_kind(log, AiEvent.Kind.ESCORT_WAIT).is_empty():
			waited_at = world.tick
			break
	assert_gt(waited_at, 0, "it waited at its next think")
	assert_eq(group.phase, 1)
	var waits: Array[AiEvent] = _of_kind(log, AiEvent.Kind.ESCORT_WAIT)
	assert_eq(waits.size(), 1)
	var c: Vector2i = AiOrders.centroid(group.living(world))
	assert_lte(FixedMath.length(waits[0].x - c.x, waits[0].z - c.y), 300, "reported where it stands")
	assert_eq(waits[0].value, group.waypoint_index, "and the waypoint it is waiting to walk to")
	assert_false(group.leg_active, "the leg is over")
	for unit: Unit in group.living(world):
		assert_eq(unit.order, Unit.Order.NONE, "told to hold")
	for i: int in group.members.size():
		var unit: Unit = world.get_unit(group.members[i])
		assert_lte(
			FixedMath.length(group.ordered_x[i] - unit.x, group.ordered_z[i] - unit.z), 300,
			"its recorded order is where it stands, so a new leg sends it"
		)
		assert_eq(group.ordered_target[i], 0)
	# It really holds.
	for _t: int in 5:
		world.step()
	var held: Array[Vector2i] = _positions(group, world)
	for _t: int in 90:
		world.step()
	assert_eq(_positions(group, world), held, "no unit moves while it waits")
	assert_eq(group.phase, 1)


func test_it_walks_on_when_the_friend_returns_and_the_new_leg_is_fresh() -> void:
	var s: Array = _scene()
	var world: World = s[0]
	var group: AiGroup = s[1]
	var friend: Unit = s[2]
	var log: Array[AiEvent] = []
	_walk_with_friend(world, group, friend, log, 100, func() -> bool: return false)
	_park(friend, AWAY)
	for _t: int in 40:
		_step(world, group, log)
	assert_eq(group.phase, 1, "waiting")
	# A pause in the middle of a retry: the next leg must not inherit it.
	group.leg_retried = true
	var index_before: int = group.waypoint_index
	log.clear()
	var resumed: bool = false
	for _t: int in 40:
		_beside(world, group, friend)
		_step(world, group, log)
		if not _of_kind(log, AiEvent.Kind.ESCORT_GO).is_empty():
			resumed = true
			break
	assert_true(resumed, "it resumed at its next think")
	var go: AiEvent = _of_kind(log, AiEvent.Kind.ESCORT_GO)[0]
	assert_eq(go.value, index_before, "toward the waypoint it was walking to")
	assert_eq(Vector2i(go.x, go.z), Vector2i(ROUTE[2 * index_before] * M, ROUTE[2 * index_before + 1] * M))
	assert_eq(group.phase, 0)
	assert_true(group.leg_active, "a leg is under way again")
	assert_false(group.leg_retried, "and it is a fresh one")
	assert_false(_of_kind(log, AiEvent.Kind.ORDER).is_empty(), "the members were sent")
	var before: Array[Vector2i] = _positions(group, world)
	_walk_with_friend(world, group, friend, log, 60, func() -> bool: return false)
	assert_ne(_positions(group, world), before, "they are walking")
	# And it carries on to the end.
	_walk_with_friend(world, group, friend, log, RUN_TICKS, func() -> bool: return group.phase == 2)
	assert_eq(group.phase, 2)
	assert_eq(_reached(log), [0, 1, 2])


func test_a_walking_group_tolerates_a_friend_a_little_past_the_radius() -> void:
	# Walking, the radius is 2 m wider (hysteresis), so a friend at 13 m of a
	# 12 m radius doesn't stop it at its first think.
	var s: Array = _scene()
	var world: World = s[0]
	var group: AiGroup = s[1]
	var friend: Unit = s[2]
	var log: Array[AiEvent] = []
	for _t: int in 20:
		_north_of_first(world, group, friend, ESCORT_RADIUS + M)
		_step(world, group, log)
	assert_eq(group.phase, 0, "13 m is inside the 14 m a walking group allows")
	assert_eq(_of_kind(log, AiEvent.Kind.ESCORT_WAIT).size(), 0)
	# But it doesn't resume from a wait for it.
	_north_of_first(world, group, friend, ESCORT_RADIUS + 5 * M)
	var go_log: Array[AiEvent] = []
	for _t: int in 40:
		_north_of_first(world, group, friend, ESCORT_RADIUS + 5 * M)
		_step(world, group, go_log)
	assert_eq(group.phase, 1, "17 m is too far: it waits")
	for _t: int in 60:
		_north_of_first(world, group, friend, ESCORT_RADIUS + M)
		_step(world, group, go_log)
	assert_eq(group.phase, 1, "and 13 m isn't near enough to set it going: a paused group needs the plain 12 m")
	assert_eq(_of_kind(go_log, AiEvent.Kind.ESCORT_GO).size(), 0)
	for _t: int in 40:
		_north_of_first(world, group, friend, ESCORT_RADIUS - M)
		_step(world, group, go_log)
	assert_eq(group.phase, 0, "11 m does")
	assert_eq(_of_kind(go_log, AiEvent.Kind.ESCORT_GO).size(), 1)


func test_only_a_living_commanded_unit_of_the_groups_side_is_a_friend() -> void:
	var s: Array = _scene()
	var world: World = s[0]
	var group: AiGroup = s[1]
	var friend: Unit = s[2]
	_park(friend, AWAY)
	var c: Vector2i = AiOrders.centroid(group.living(world))
	# Beside the group: a dead friend, an enemy, another AI group's Light unit.
	var dead: Unit = world.spawn_unit(FRIEND, LIGHT, c.x, c.y + 2 * M, 1, 0)
	dead.kill()
	world.spawn_unit(FOE, DARK, c.x, c.y - 2 * M, 1, 0)
	var other: AiGroupSpec = _escort_spec()
	other.name = &"other"
	other.behavior = AiGroupSpec.Behavior.IDLE
	other.spawns = PackedInt32Array([c.x + 2 * M, c.y + 2 * M])
	var other_group: AiGroup = world.ai.spawn_group(world, other, 1, 0)
	assert_eq(other_group.members.size(), 1)
	var log: Array[AiEvent] = []
	for _t: int in 60:
		_step(world, group, log)
	assert_eq(group.phase, 1, "none of them is a friend: the group waits")
	_beside(world, group, friend)
	for _t: int in 40:
		_beside(world, group, friend)
		_step(world, group, log)
	assert_eq(group.phase, 0, "a commanded Light unit is")
	assert_eq(_of_kind(log, AiEvent.Kind.ESCORT_GO).size(), 1)


func test_a_friend_beside_any_one_member_is_enough() -> void:
	var s: Array = _scene(_escort_spec(ROUTE, 4))
	var world: World = s[0]
	var group: AiGroup = s[1]
	var friend: Unit = s[2]
	_park(friend, AWAY)
	var log: Array[AiEvent] = []
	for _t: int in 40:
		_step(world, group, log)
	assert_eq(group.phase, 1, "waiting")
	# 11.5 m beyond the member farthest from the centroid, on the far side
	# from the others: inside the radius of that member, outside it of the
	# centroid (by about a metre).
	var units: Array[Unit] = group.living(world)
	var c: Vector2i = AiOrders.centroid(units)
	var far: Unit = units[0]
	for unit: Unit in units:
		if FixedMath.length(unit.x - c.x, unit.z - c.y) > FixedMath.length(far.x - c.x, far.z - c.y):
			far = unit
	var out: Vector2i = FixedMath.normalize(far.x - c.x, far.z - c.y, ESCORT_RADIUS - M / 2)
	friend.x = far.x + out.x
	friend.z = far.z + out.y
	assert_gt(FixedMath.length(friend.x - c.x, friend.z - c.y), ESCORT_RADIUS, "not within the radius of the centroid")
	for _t: int in 40:
		_step(world, group, log)
	assert_eq(group.phase, 0, "but within the radius of one member, which is what counts")
	assert_eq(_of_kind(log, AiEvent.Kind.ESCORT_GO).size(), 1)


# --- enemies ----------------------------------------------------------------


func test_a_visible_enemy_inside_the_alert_radius_makes_it_wait_and_it_resumes_when_it_is_gone() -> void:
	var spec: AiGroupSpec = _escort_spec()
	spec.alert_radius = ALERT_RADIUS
	var s: Array = _scene(spec)
	var world: World = s[0]
	var group: AiGroup = s[1]
	var friend: Unit = s[2]
	var foe: Unit = world.spawn_unit(FOE, DARK, SPAWN.x * M, SPAWN.y * M - 8 * M, 0, 1)
	var log: Array[AiEvent] = []
	_walk_with_friend(world, group, friend, log, 40, func() -> bool: return false)
	assert_eq(group.phase, 1, "8 m from a foe with a 10 m alert radius")
	assert_eq(_of_kind(log, AiEvent.Kind.ESCORT_WAIT).size(), 1)
	assert_eq(group.behavior, AiGroupSpec.Behavior.ESCORT, "an alert never switches an escort")
	assert_eq(_of_kind(log, AiEvent.Kind.BEHAVIOR).size(), 0)
	# The friend is beside it all along, so the foe alone is what holds it.
	foe.kill()
	_walk_with_friend(world, group, friend, log, 40, func() -> bool: return false)
	assert_eq(group.phase, 0, "the foe is dead: on it goes")
	assert_eq(_of_kind(log, AiEvent.Kind.ESCORT_GO).size(), 1)


func test_a_paused_group_needs_the_foe_2_m_beyond_the_alert_radius_to_resume() -> void:
	var spec: AiGroupSpec = _escort_spec()
	spec.alert_radius = ALERT_RADIUS
	var s: Array = _scene(spec)
	var world: World = s[0]
	var group: AiGroup = s[1]
	var friend: Unit = s[2]
	var foe: Unit = world.spawn_unit(FOE, DARK, SPAWN.x * M, SPAWN.y * M - 8 * M, 0, 1)
	var log: Array[AiEvent] = []
	_walk_with_friend(world, group, friend, log, 40, func() -> bool: return false)
	assert_eq(group.phase, 1)
	var at: Vector2i = AiOrders.centroid(group.living(world))
	foe.z = at.y - ALERT_RADIUS - M
	_walk_with_friend(world, group, friend, log, 60, func() -> bool: return false)
	assert_eq(group.phase, 1, "11 m: outside the radius but not by the margin")
	foe.z = at.y - ALERT_RADIUS - 3 * M
	_walk_with_friend(world, group, friend, log, 40, func() -> bool: return false)
	assert_eq(group.phase, 0, "13 m: clear of it")


func test_a_foe_just_outside_the_alert_radius_does_not_stop_a_walking_group() -> void:
	var spec: AiGroupSpec = _escort_spec()
	spec.alert_radius = ALERT_RADIUS
	var s: Array = _scene(spec)
	var world: World = s[0]
	var group: AiGroup = s[1]
	var friend: Unit = s[2]
	world.spawn_unit(FOE, DARK, SPAWN.x * M, SPAWN.y * M - 11 * M, 0, 1)
	var log: Array[AiEvent] = []
	for _t: int in 20:
		_beside(world, group, friend)
		_step(world, group, log)
	assert_eq(group.phase, 0, "11 m of a 10 m alert radius")
	assert_eq(_of_kind(log, AiEvent.Kind.ESCORT_WAIT).size(), 0)


func test_a_group_with_no_alert_radius_is_never_stopped_by_enemies() -> void:
	var s: Array = _scene()
	var world: World = s[0]
	var group: AiGroup = s[1]
	var friend: Unit = s[2]
	world.spawn_unit(FOE, DARK, SPAWN.x * M + 2 * M, SPAWN.y * M - 2 * M, 0, 1)
	var log: Array[AiEvent] = []
	_walk_with_friend(world, group, friend, log, 60, func() -> bool: return false)
	assert_eq(group.phase, 0, "a foe 2 m off, and no alert radius")
	assert_eq(_of_kind(log, AiEvent.Kind.ESCORT_WAIT).size(), 0)


func test_an_enemy_hiding_in_deep_water_does_not_stop_it_until_it_surfaces() -> void:
	var rows: Array[String] = []
	for j: int in 60:
		var row: String = ".".repeat(80)
		if j >= 20 and j < 26:
			row = ".".repeat(12) + "3".repeat(6) + ".".repeat(62)
		rows.append(row)
	var spec: AiGroupSpec = _escort_spec()
	spec.alert_radius = ALERT_RADIUS
	var s: Array = _scene(spec, TestTerrains.from_ascii(rows))
	var world: World = s[0]
	var group: AiGroup = s[1]
	var friend: Unit = s[2]
	var lurker: Unit = world.spawn_unit(LURKER, DARK, 15 * M, 23 * M, 0, 1)
	assert_true(Visibility.is_submerged(world.terrain, lurker), "the lurker is under")
	var log: Array[AiEvent] = []
	_walk_with_friend(world, group, friend, log, 20, func() -> bool: return false)
	var c: Vector2i = AiOrders.centroid(group.living(world))
	assert_lt(FixedMath.length(c.x - lurker.x, c.y - lurker.z), ALERT_RADIUS, "within the alert radius all the same")
	assert_eq(group.phase, 0, "a submerged enemy isn't seen")
	assert_eq(_of_kind(log, AiEvent.Kind.ESCORT_WAIT).size(), 0)
	lurker.surfaced = true
	_walk_with_friend(world, group, friend, log, 20, func() -> bool: return false)
	assert_eq(group.phase, 1, "once it has shown itself it counts")


# --- failing legs -----------------------------------------------------------


func test_a_leg_that_fails_does_not_advance_the_waypoint() -> void:
	# Flat 80 x 60 m cut by a wall along z = 40 m, end to end: the first
	# waypoint is across it, where the group can never go.
	var rows: Array[String] = []
	for j: int in 60:
		rows.append("#".repeat(80) if j == 40 else ".".repeat(80))
	var points: Array[int] = [30, 50, 30, 30]
	var s: Array = _scene(_escort_spec(points), TestTerrains.from_ascii(rows))
	var world: World = s[0]
	var group: AiGroup = s[1]
	var friend: Unit = s[2]
	var log: Array[AiEvent] = []
	var failed_at: int = -1
	for _t: int in RUN_TICKS:
		_beside(world, group, friend)
		_step(world, group, log)
		for e: AiEvent in log:
			if e.kind == AiEvent.Kind.WAYPOINT_FAILED and e.value == 0:
				failed_at = world.tick
		if failed_at > 0:
			break
	assert_gt(failed_at, 0, "the leg to waypoint 0 failed (after its one retry)")
	assert_eq(group.waypoint_index, 0, "and the escort did not skip on to waypoint 1")
	assert_eq(group.phase, 0, "still walking, not arrived")
	var retries: int = 0
	for e: AiEvent in log:
		if e.kind == AiEvent.Kind.WAYPOINT_FAILED and e.value == -1:
			retries += 1
	assert_eq(retries, 1, "it retried once first")
	# Left alone it keeps trying the same waypoint, never the next one.
	log.clear()
	_walk_with_friend(world, group, friend, log, 900, func() -> bool: return false)
	assert_eq(group.waypoint_index, 0)
	assert_eq(_reached(log), [], "no waypoint was ever reached")
	assert_false(_of_kind(log, AiEvent.Kind.WAYPOINT_FAILED).is_empty(), "it kept trying")
	assert_eq(_of_kind(log, AiEvent.Kind.ESCORT_WAIT).size(), 0, "with the friend beside it, it never waited")


# --- never retreats ---------------------------------------------------------


func test_an_escort_never_retreats_even_when_its_spec_says_to() -> void:
	# A group that starts as a PATROL may carry a retreat threshold; switched
	# to ESCORT by a trigger it must not abandon the escort for it.
	var spec: AiGroupSpec = _escort_spec()
	spec.behavior = AiGroupSpec.Behavior.PATROL
	spec.waypoints = PackedInt32Array([30 * M, 30 * M, 55 * M, 30 * M])
	spec.retreat_below_permille = 500
	var s: Array = _scene(spec)
	var world: World = s[0]
	var group: AiGroup = s[1]
	var friend: Unit = s[2]
	world.ai.set_behavior(world, group, AiGroupSpec.Behavior.ESCORT)
	group.living(world)[0].hp = 10
	world.spawn_unit(FOE, DARK, SPAWN.x * M, SPAWN.y * M - 5 * M, 0, 1)
	var log: Array[AiEvent] = []
	_walk_with_friend(world, group, friend, log, 120, func() -> bool: return false)
	assert_eq(_of_kind(log, AiEvent.Kind.RETREAT).size(), 0)
	assert_eq(group.behavior, AiGroupSpec.Behavior.ESCORT)
	assert_false(group.retreated)


# --- the data ---------------------------------------------------------------


func test_escort_needs_waypoints_and_a_radius() -> void:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = &"e"
	assert_eq(g.params_errors(AiGroupSpec.Behavior.ESCORT).size(), 2, str(g.params_errors(AiGroupSpec.Behavior.ESCORT)))
	g.waypoints = PackedInt32Array([1000, 2000])
	var errors: PackedStringArray = g.params_errors(AiGroupSpec.Behavior.ESCORT)
	assert_eq(errors.size(), 1, "one waypoint is enough, but it needs a radius: %s" % [errors])
	assert_string_contains(errors[0], "escort_radius")
	g.escort_radius = 5000
	assert_eq(g.params_errors(AiGroupSpec.Behavior.ESCORT), PackedStringArray())
	g.waypoints = PackedInt32Array([1000, 2000, 3000])
	errors = g.params_errors(AiGroupSpec.Behavior.ESCORT)
	assert_eq(errors.size(), 1, "waypoints are x, z pairs")
	assert_string_contains(errors[0], "pairs")


func test_a_starting_escort_may_not_have_a_retreat_threshold() -> void:
	var g: AiGroupSpec = _escort_spec()
	g.retreat_below_permille = 300
	var errors: PackedStringArray = g.validate(_catalog)
	assert_eq(errors.size(), 1, str(errors))
	assert_string_contains(errors[0], "ESCORT")
	assert_string_contains(errors[0], "retreat")


func test_an_escort_needs_no_alert_radius_and_a_negative_escort_radius_is_rejected() -> void:
	var g: AiGroupSpec = _escort_spec()
	assert_eq(g.alert_radius, 0)
	assert_eq(g.validate(_catalog), PackedStringArray(), "no alert radius is fine")
	g.escort_radius = -5
	assert_gt(g.validate(_catalog).size(), 0)


func test_a_set_behavior_to_escort_is_checked_against_the_groups_parameters() -> void:
	var plain: AiGroupSpec = MissionFixtures.group(&"crowd", 2)
	var trigger: TriggerSpec = MissionFixtures.timer(&"go", 10)
	trigger.actions.append(MissionFixtures.behavior_action(&"crowd", AiGroupSpec.Behavior.ESCORT))
	var script: MissionScript = MissionFixtures.script([plain], [trigger])
	var errors: PackedStringArray = script.validate(MissionFixtures.catalog())
	assert_gt(errors.size(), 0, "a group with no route can't be told to escort")
	var found: bool = false
	for error: String in errors:
		found = found or error.contains("ESCORT needs")
	assert_true(found, str(errors))
	plain.waypoints = PackedInt32Array([20 * M, 20 * M])
	plain.escort_radius = 8 * M
	assert_eq(script.validate(MissionFixtures.catalog()), PackedStringArray())


func test_escort_is_appended_to_the_behavior_and_event_enums() -> void:
	assert_eq(AiGroupSpec.Behavior.ESCORT, AiGroupSpec.Behavior.RETREAT + 1, "appended, so hashed values hold")
	assert_eq(AiEvent.Kind.ESCORT_WAIT, AiEvent.Kind.RETREAT + 1)
	assert_eq(AiEvent.Kind.ESCORT_GO, AiEvent.Kind.ESCORT_WAIT + 1)


# --- determinism ------------------------------------------------------------


func _scripted_run(world_seed: int) -> Dictionary:
	var world: World = World.new(world_seed, TestTerrains.flat(80, 60), _catalog)
	var spec: AiGroupSpec = _escort_spec(ROUTE, 2)
	spec.alert_radius = ALERT_RADIUS
	var group: AiGroup = world.ai.spawn_group(world, spec, 0, 0)
	var friend: Unit = world.spawn_unit(FRIEND, LIGHT, 0, 0, 1, 0)
	var foe: Unit = world.spawn_unit(FOE, DARK, 40 * M, 5 * M, 0, 1)
	var events: Array[PackedInt64Array] = []
	var hashes: PackedStringArray = PackedStringArray()
	for t: int in 1500:
		# The friend falls away for a stretch, and a foe wanders by once.
		if t >= 150 and t < 330:
			_park(friend, AWAY)
		else:
			_beside(world, group, friend)
		foe.z = 5 * M + t * 25
		world.step()
		for e: AiEvent in world.ai_events:
			events.append(PackedInt64Array([world.tick]) + e.to_array())
		if t % 100 == 99:
			hashes.append(world.state_hash())
	return {"events": events, "hashes": hashes, "phase": group.phase}


func test_same_seed_same_events_and_hashes() -> void:
	var a: Dictionary = _scripted_run(7)
	var b: Dictionary = _scripted_run(7)
	var kinds: Dictionary[int, int] = {}
	for e: PackedInt64Array in a["events"]:
		kinds[e[1]] = kinds.get(e[1], 0) + 1
	assert_gt(kinds.get(AiEvent.Kind.ESCORT_WAIT, 0), 0, "the run pauses")
	assert_gt(kinds.get(AiEvent.Kind.ESCORT_GO, 0), 0, "and resumes")
	assert_gt(kinds.get(AiEvent.Kind.WAYPOINT_REACHED, 0), 0, "and gets somewhere")
	assert_eq((a["events"] as Array).size(), (b["events"] as Array).size())
	for i: int in mini((a["events"] as Array).size(), (b["events"] as Array).size()):
		assert_eq(a["events"][i], b["events"][i], "event %d" % i)
	assert_eq(a["hashes"], b["hashes"], "identical state hashes every 100 ticks")
	assert_eq(a["phase"], b["phase"])
