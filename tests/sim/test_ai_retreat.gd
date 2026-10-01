extends GutTest
## RETREAT: a group whose hit points fall below retreat_below_permille of what
## it spawned with, while the enemies it can see near it outweigh what is left
## of it, falls back once. It is pulled out of any fight, walks to the retreat
## point (its spawn point if the spec names none), and then guards it. It never
## retreats a second time. Groups are spawned straight from specs
## (AiDirector.spawn_group) on flat ground, no mission.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

## Catalog indices of the synthetic types.
const GRUNT: int = 0
const POST: int = 1
const WEAKLING: int = 2
const LURKER: int = 3
const SCAVENGER: int = 4

## The spec's threshold and retreat point in most tests: half its health, and a
## point 25 m west of where the group stands.
const HALF: int = 500
const POINT: Vector2i = Vector2i(5 * M, 20 * M)

## Ticks in which a retreat must be called after the first think, and in which
## the survivors must have walked 25 m (2 m/s is 15 ticks a metre) and
## settled.
const CALL_TICKS: int = 15
const WALK_TICKS: int = 600

var _catalog: UnitCatalog


func before_all() -> void:
	var types: Array[UnitType] = [
		TestUnits.melee(&"grunt"),
		# Never hits back and takes a long time to kill, so a fight never ends.
		TestUnits.dummy(&"post"),
		# Never hits back, and weighs no more than a grunt.
		TestUnits.dummy(&"weakling", {"max_hp": 100}),
		# Lies out of sight in deep water.
		TestUnits.undead(&"lurker", {"hidden_in_deep_water": true}),
		# Tears parts off any body within 8 m, a 9-tick errand each.
		TestUnits.scavenger(&"scavenger"),
	]
	_catalog = TestUnits.catalog(types)


# --- fixtures ---------------------------------------------------------------


func _world(terrain: Terrain = null) -> World:
	return World.new(1, terrain if terrain != null else TestTerrains.flat(60, 40), _catalog)


## A DARK group of six units (grunts unless type_id says otherwise) at (30, 20)
## m, spawned as spec 0, with a retreat threshold and retreat point. An empty
## point means the spawn point.
func _group(
	world: World, behavior: AiGroupSpec.Behavior, permille: int = HALF,
	point: PackedInt32Array = PackedInt32Array([POINT.x, POINT.y]), type_id: StringName = &"grunt"
) -> AiGroup:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = &"pack"
	var e: AiUnitEntry = AiUnitEntry.new()
	e.type_id = type_id
	e.counts = PackedInt32Array([6])
	g.units.append(e)
	g.spawns = PackedInt32Array([30 * M, 20 * M])
	g.behavior = behavior
	g.alert_radius = M if behavior == AiGroupSpec.Behavior.AMBUSH else 0
	g.retreat_below_permille = permille
	g.retreat_point = point
	assert_eq(g.validate(_catalog), PackedStringArray(), "the spec is valid")
	return world.ai.spawn_group(world, g, 0, 0)


## Six 100k-hp LIGHT posts in a block at (x, 20) m, so the enemies near a group
## weigh far more than it does.
func _posts(world: World, x: int) -> Array[Unit]:
	var out: Array[Unit] = []
	for i: int in 6:
		out.append(world.spawn_unit(POST, LIGHT, x * M, (18 + i) * M, -1, 0))
	return out


## Kills the first count members, as a lost fight would.
func _lose(world: World, group: AiGroup, count: int) -> void:
	for i: int in count:
		world.get_unit(group.members[i]).kill()


func _distance(unit: Unit, x: int, z: int) -> int:
	return FixedMath.length(unit.x - x, unit.z - z)


func _events_of(world: World, kind: AiEvent.Kind) -> Array[AiEvent]:
	var out: Array[AiEvent] = []
	for e: AiEvent in world.ai_events:
		if e.kind == kind:
			out.append(e)
	return out


## Steps the world until it emits an event of kind, and returns it (null if
## none comes within ticks).
func _step_to_event(world: World, kind: AiEvent.Kind, ticks: int) -> AiEvent:
	for _t: int in ticks:
		world.step()
		var found: Array[AiEvent] = _events_of(world, kind)
		if not found.is_empty():
			return found[0]
	return null


## Steps the world until the group's behavior is behavior; false if it isn't
## within ticks.
func _step_to_behavior(world: World, group: AiGroup, behavior: AiGroupSpec.Behavior, ticks: int) -> bool:
	for _t: int in ticks:
		if group.behavior == behavior:
			return true
		world.step()
	return group.behavior == behavior


## Steps the world for ticks and counts the RETREAT events it emits.
func _count_retreats(world: World, ticks: int) -> int:
	var n: int = 0
	for _t: int in ticks:
		world.step()
		n += _events_of(world, AiEvent.Kind.RETREAT).size()
	return n


# --- falling back -----------------------------------------------------------


func test_a_hunt_that_loses_four_of_six_calls_a_retreat_to_the_point_and_then_guards_it() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.HUNT)
	_posts(world, 34)
	_lose(world, group, 4)
	var event: AiEvent = _step_to_event(world, AiEvent.Kind.RETREAT, CALL_TICKS)
	assert_not_null(event, "a retreat is called within a think interval")
	if event == null:
		return
	assert_eq(event.group_id, group.id)
	assert_eq(Vector2i(event.x, event.z), POINT, "toward the retreat point")
	assert_true(group.retreated)
	assert_eq(group.behavior, AiGroupSpec.Behavior.RETREAT)
	assert_true(_step_to_behavior(world, group, AiGroupSpec.Behavior.GUARD, WALK_TICKS), "then it guards")
	assert_eq(Vector2i(group.anchor_x, group.anchor_z), POINT, "the retreat point is its post")
	var survivors: Array[Unit] = group.living(world)
	assert_eq(survivors.size(), 2)
	for unit: Unit in survivors:
		assert_lte(_distance(unit, POINT.x, POINT.y), 3 * M, "unit %d is at the retreat point" % unit.id)
	var c: Vector2i = AiOrders.centroid(survivors)
	assert_lte(FixedMath.length(c.x - POINT.x, c.y - POINT.y), AiBehaviors.LEG_ARRIVE_RADIUS)


func test_the_retreat_is_announced_before_the_march_it_orders() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.HUNT)
	_posts(world, 34)
	_lose(world, group, 4)
	var kinds: Array[AiEvent.Kind] = []
	for _t: int in CALL_TICKS:
		world.step()
		for e: AiEvent in world.ai_events:
			kinds.append(e.kind)
		if not kinds.is_empty():
			break
	assert_eq(
		kinds, [AiEvent.Kind.BEHAVIOR, AiEvent.Kind.RETREAT, AiEvent.Kind.ORDER],
		"the new behavior, the retreat, then the march at the point"
	)
	if kinds.size() != 3:
		return
	var behavior: AiEvent = _events_of(world, AiEvent.Kind.BEHAVIOR)[0]
	assert_eq(behavior.value, AiGroupSpec.Behavior.RETREAT)
	var order: AiEvent = _events_of(world, AiEvent.Kind.ORDER)[0]
	assert_eq(Vector2i(order.x, order.z), POINT)
	assert_eq(order.value, 0, "a plain move: it isn't looking for a fight")


func test_a_retreat_pulls_members_out_of_the_fight_they_are_in() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.HUNT)
	_lose(world, group, 4)
	var survivors: Array[Unit] = group.living(world)
	# A post 1 m east of each survivor: in reach, so the fight starts at once.
	for unit: Unit in survivors:
		world.spawn_unit(POST, LIGHT, unit.x + M, unit.z, -1, 0)
	var fought: bool = false
	var event: AiEvent = null
	for _t: int in CALL_TICKS:
		for unit: Unit in survivors:
			fought = fought or not AiOrders.is_free(world, unit)
		world.step()
		var found: Array[AiEvent] = _events_of(world, AiEvent.Kind.RETREAT)
		if not found.is_empty():
			event = found[0]
			break
	assert_true(fought, "the survivors were in the middle of a fight before the retreat came")
	assert_not_null(event, "and a retreat came")
	for unit: Unit in survivors:
		assert_eq(unit.target_id, 0, "unit %d dropped its fight" % unit.id)
		assert_eq(unit.windup_left, 0, "and its swing")
		assert_eq(unit.order, Unit.Order.MOVE, "and is walking away")
		assert_lte(FixedMath.length(unit.goal_x - POINT.x, unit.goal_z - POINT.y), 3 * M, "toward the point")
		assert_true(AiOrders.is_free(world, unit), "free to be ordered again")
	for i: int in group.members.size():
		assert_eq(group.ordered_attack[i], 0, "a plain move")


func test_the_march_is_ordered_once_not_at_every_think() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.HUNT)
	_posts(world, 34)
	_lose(world, group, 4)
	var orders: int = 0
	while world.tick < WALK_TICKS and group.behavior != AiGroupSpec.Behavior.GUARD:
		world.step()
		orders += _events_of(world, AiEvent.Kind.ORDER).size()
	assert_eq(group.behavior, AiGroupSpec.Behavior.GUARD)
	assert_eq(orders, 1, "one march, however many thinks the walk takes")


func test_a_retreat_with_no_point_falls_back_to_the_spawn_point() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.HUNT, HALF, PackedInt32Array())
	# The survivors have wandered 20 m east of where the group spawned.
	_lose(world, group, 4)
	for unit: Unit in group.living(world):
		unit.x += 20 * M
		unit.goal_x = unit.x
	_posts(world, 54)
	var spawn: Vector2i = Vector2i(group.spawn_x, group.spawn_z)
	var event: AiEvent = _step_to_event(world, AiEvent.Kind.RETREAT, CALL_TICKS)
	assert_not_null(event)
	if event == null:
		return
	assert_eq(Vector2i(event.x, event.z), spawn)
	assert_true(_step_to_behavior(world, group, AiGroupSpec.Behavior.GUARD, WALK_TICKS))
	assert_eq(Vector2i(group.anchor_x, group.anchor_z), spawn)
	for unit: Unit in group.living(world):
		assert_lte(_distance(unit, spawn.x, spawn.y), 3 * M, "unit %d is back at the spawn point" % unit.id)


func test_a_retreat_that_cannot_reach_the_point_guards_the_point_all_the_same() -> void:
	# A river across the middle of the map: the point is on the far bank.
	var rows: Array[String] = []
	for j: int in 40:
		rows.append("3".repeat(60) if j == 12 else ".".repeat(60))
	var world: World = _world(TestTerrains.from_ascii(rows))
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.HUNT, HALF, PackedInt32Array([5 * M, 2 * M]))
	_posts(world, 34)
	_lose(world, group, 4)
	var event: AiEvent = _step_to_event(world, AiEvent.Kind.RETREAT, CALL_TICKS)
	assert_not_null(event)
	assert_true(_step_to_behavior(world, group, AiGroupSpec.Behavior.GUARD, WALK_TICKS), "the leg fails, and it guards")
	assert_eq(Vector2i(group.anchor_x, group.anchor_z), Vector2i(5 * M, 2 * M))
	assert_eq(group.behavior, AiGroupSpec.Behavior.GUARD)


func test_a_member_mid_errand_is_pulled_off_it_and_the_retreat_completes() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.HUNT, HALF, PackedInt32Array([POINT.x, POINT.y]), &"scavenger")
	_lose(world, group, 4)
	# The survivors go for the bodies at their feet. With no enemy about yet
	# the group has no reason to retreat; wait for one to be mid-wind-up.
	var picker: Unit = null
	for _t: int in 60:
		world.step()
		for unit: Unit in group.living(world):
			if unit.order == Unit.Order.INTERACT and unit.act_left > 0:
				picker = unit
				break
		if picker != null:
			break
	assert_not_null(picker, "a survivor is in the middle of tearing a part off a body")
	if picker == null:
		return
	assert_false(group.retreated)
	_posts(world, 34)
	AiBehaviors.think(world, group)
	assert_eq(group.behavior, AiGroupSpec.Behavior.RETREAT)
	assert_eq(picker.order, Unit.Order.MOVE, "the retreat took it off the errand")
	assert_eq(picker.act_left, 0, "and left no half-done wind-up behind")
	assert_eq(picker.interact_id, 0)
	assert_true(AiOrders.is_free(world, picker))
	assert_true(_step_to_behavior(world, group, AiGroupSpec.Behavior.GUARD, WALK_TICKS), "the leg ends: it guards")
	assert_eq(Vector2i(group.anchor_x, group.anchor_z), POINT)
	for unit: Unit in group.living(world):
		assert_lte(_distance(unit, POINT.x, POINT.y), 3 * M, "unit %d is at the retreat point" % unit.id)


# --- once only --------------------------------------------------------------


## A group that has retreated and is guarding the point, hurt again, with a
## heavy enemy 17 m from it: well inside the threat radius, outside the 10 m
## guard radius (so the guard doesn't go out to fight it). Only the retreated
## flag could stop a second retreat here.
func _guarding_and_hurt_again(world: World) -> AiGroup:
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.HUNT)
	_posts(world, 34)
	_lose(world, group, 4)
	assert_eq(_count_retreats(world, WALK_TICKS), 1, "one retreat on the way")
	assert_eq(group.behavior, AiGroupSpec.Behavior.GUARD)
	world.spawn_unit(POST, LIGHT, 22 * M, 20 * M, -1, 0)
	var left: Array[Unit] = group.living(world)
	left[0].kill()
	left[1].hp = 1
	return group


func test_a_further_loss_never_calls_a_second_retreat() -> void:
	var world: World = _world()
	var group: AiGroup = _guarding_and_hurt_again(world)
	assert_eq(_count_retreats(world, 150), 0, "no second retreat after it is hurt again")
	assert_true(group.retreated)
	assert_eq(group.behavior, AiGroupSpec.Behavior.GUARD)


func test_the_same_group_would_retreat_again_were_it_not_for_the_flag() -> void:
	var world: World = _world()
	var group: AiGroup = _guarding_and_hurt_again(world)
	group.retreated = false
	assert_eq(_count_retreats(world, CALL_TICKS), 1, "the scenario meets every other condition")


func test_a_loss_that_arrives_while_retreating_does_not_restart_the_retreat() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.HUNT)
	_posts(world, 34)
	_lose(world, group, 4)
	var event: AiEvent = _step_to_event(world, AiEvent.Kind.RETREAT, CALL_TICKS)
	assert_not_null(event)
	group.living(world)[0].hp = 1
	assert_eq(_count_retreats(world, 150), 0)
	assert_eq(group.behavior, AiGroupSpec.Behavior.RETREAT, "still walking, 150 ticks in")


# --- when it doesn't --------------------------------------------------------


func test_a_threshold_of_zero_never_retreats() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.HUNT, 0)
	_posts(world, 34)
	_lose(world, group, 5)
	assert_eq(_count_retreats(world, 300), 0)
	assert_false(group.retreated)
	assert_eq(group.behavior, AiGroupSpec.Behavior.HUNT)


func test_a_group_exactly_at_its_threshold_stands() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.HUNT)
	_posts(world, 34)
	_lose(world, group, 3)
	assert_eq(_count_retreats(world, 300), 0, "half left is not below half")
	assert_eq(group.behavior, AiGroupSpec.Behavior.HUNT)


func test_a_group_with_no_enemy_in_sight_does_not_retreat() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.IDLE)
	_lose(world, group, 4)
	assert_eq(_count_retreats(world, 300), 0)
	assert_false(group.retreated)


func test_enemies_that_weigh_no_more_than_the_group_do_not_drive_it_off() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.IDLE)
	# 100 hp against the two survivors' 200.
	world.spawn_unit(WEAKLING, LIGHT, 34 * M, 20 * M, -1, 0)
	_lose(world, group, 4)
	assert_eq(_count_retreats(world, 300), 0)
	assert_false(group.retreated)
	assert_eq(group.behavior, AiGroupSpec.Behavior.IDLE)


func test_enemies_that_weigh_exactly_what_the_group_does_do_not_drive_it_off() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.IDLE)
	# 100 + 100 hp against the two survivors' 200: the rule is strictly more.
	world.spawn_unit(WEAKLING, LIGHT, 34 * M, 20 * M, -1, 0)
	world.spawn_unit(WEAKLING, LIGHT, 34 * M, 22 * M, -1, 0)
	_lose(world, group, 4)
	assert_eq(_count_retreats(world, 300), 0)
	assert_false(group.retreated)
	assert_eq(group.behavior, AiGroupSpec.Behavior.IDLE)


func test_enemies_that_outweigh_the_group_by_a_point_drive_it_off() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.IDLE)
	world.spawn_unit(WEAKLING, LIGHT, 34 * M, 20 * M, -1, 0)
	var heavier: Unit = world.spawn_unit(WEAKLING, LIGHT, 34 * M, 22 * M, -1, 0)
	heavier.hp = 101
	_lose(world, group, 4)
	assert_eq(_count_retreats(world, CALL_TICKS), 1, "201 hp of enemies against 200")


func test_enemies_beyond_the_threat_radius_do_not_count() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.IDLE)
	_lose(world, group, 4)
	var centroid: Vector2i = AiOrders.centroid(group.living(world))
	var edge: int = AiBehaviors.RETREAT_THREAT_RADIUS
	world.spawn_unit(POST, LIGHT, centroid.x - edge - 100, centroid.y, 1, 0)
	assert_eq(_count_retreats(world, 300), 0, "a heavy enemy 100 mm past the radius is not a threat")
	var near: Unit = world.spawn_unit(POST, LIGHT, centroid.x + edge - 100, centroid.y, -1, 0)
	assert_not_null(near)
	assert_eq(_count_retreats(world, CALL_TICKS), 1, "one 100 mm inside it is")


func test_an_enemy_hidden_in_deep_water_is_not_a_threat_until_it_surfaces() -> void:
	var rows: Array[String] = []
	for j: int in 40:
		rows.append(".".repeat(35) + "4444" + ".".repeat(21))
	var world: World = _world(TestTerrains.from_ascii(rows))
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.IDLE)
	var lurker: Unit = world.spawn_unit(LURKER, LIGHT, 37 * M, 20 * M, -1, 0)
	assert_true(Visibility.is_submerged(world.terrain, lurker), "it is out of sight")
	_lose(world, group, 4)
	assert_eq(_count_retreats(world, 300), 0, "what the group can't see doesn't drive it off")
	lurker.surfaced = true
	assert_eq(_count_retreats(world, CALL_TICKS), 1, "once it is up it does")


func test_an_ambush_that_is_losing_springs_before_it_retreats() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, AiGroupSpec.Behavior.AMBUSH)
	_posts(world, 45)
	_lose(world, group, 4)
	var kinds: Array[AiEvent.Kind] = []
	for _t: int in CALL_TICKS:
		world.step()
		for e: AiEvent in world.ai_events:
			kinds.append(e.kind)
		if kinds.has(AiEvent.Kind.RETREAT):
			break
	assert_eq(kinds.count(AiEvent.Kind.RETREAT), 1)
	assert_lt(kinds.find(AiEvent.Kind.AMBUSH_SPRUNG), kinds.find(AiEvent.Kind.RETREAT), "the lurkers come up first")
	for unit: Unit in group.living(world):
		assert_true(unit.surfaced)


func test_a_retreat_is_deterministic() -> void:
	var hashes: Array[String] = []
	var logs: Array[PackedInt64Array] = []
	for _run: int in 2:
		var world: World = _world()
		var group: AiGroup = _group(world, AiGroupSpec.Behavior.HUNT)
		_posts(world, 34)
		_lose(world, group, 4)
		var events: PackedInt64Array = PackedInt64Array()
		for _t: int in WALK_TICKS:
			world.step()
			for e: AiEvent in world.ai_events:
				events.append_array(e.to_array())
		hashes.append(world.state_hash())
		logs.append(events)
	assert_eq(hashes[0], hashes[1])
	assert_eq(logs[0], logs[1])
