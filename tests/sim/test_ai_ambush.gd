extends GutTest
## AMBUSH: a group of undead lurks submerged in a pool, holding, until an enemy
## comes within alert_radius of a member, a member is hurt, or an enemy walks
## into one; or until a script sets another behavior. Then it springs: every
## member surfaces (Unit.surfaced: visible and targetable in deep water for
## good), one AMBUSH_SPRUNG is emitted, and the group switches to its on_alert
## behavior and hunts at once. Groups spawn straight from specs
## (AiDirector.spawn_group) except in the trigger test, which runs a mission.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

## Catalog indices of the synthetic types.
const LURKER: int = 0
const WALKER: int = 1
const POST: int = 2

## The alert radius the pool ambushes use.
const ALERT: int = 6 * M
## The deepest water level; the pool is made of it.
const POOL_DEPTH: int = 4
## Ticks in which a sprung group must have a lurker on the walker.
const ATTACK_TICKS: int = 300

var _catalog: UnitCatalog


func before_all() -> void:
	var types: Array[UnitType] = [
		TestUnits.melee(&"lurker", {
			"nature": UnitType.Nature.UNDEAD,
			"mobility": Terrain.Mobility.UNDEAD,
			"hidden_in_deep_water": true,
			"water_speed_permille": PackedInt32Array([1000, 1000, 1000, 1000, 1000]),
		}),
		TestUnits.melee(&"walker"),
		# Never hits back and takes a long time to kill.
		TestUnits.dummy(&"post"),
	]
	_catalog = TestUnits.catalog(types)


# --- fixtures ---------------------------------------------------------------


## 40 x 20 m of grass with a 10 x 8 m pool of depth-4 water, x 15..24 and
## z 6..13, so a walker along z = 5 skirts its north bank.
func _pool() -> Terrain:
	var rows: Array[String] = []
	for j: int in 20:
		if j >= 6 and j <= 13:
			rows.append(".".repeat(15) + "4".repeat(10) + ".".repeat(15))
		else:
			rows.append(".".repeat(40))
	return TestTerrains.from_ascii(rows)


func _world(terrain: Terrain = null) -> World:
	return World.new(1, terrain if terrain != null else _pool(), _catalog)


## An AMBUSH spec of three lurkers in a box at (x, z) metres, springing into
## on_alert (HUNT unless given) when something comes within alert_radius.
func _spec(
	x: int = 20, z: int = 10, alert_radius: int = ALERT,
	on_alert: AiGroupSpec.Behavior = AiGroupSpec.Behavior.HUNT
) -> AiGroupSpec:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = &"lurkers"
	var e: AiUnitEntry = AiUnitEntry.new()
	e.type_id = &"lurker"
	e.counts = PackedInt32Array([3])
	g.units.append(e)
	g.spawns = PackedInt32Array([x * M, z * M])
	g.formation = Formations.Kind.BOX
	g.behavior = AiGroupSpec.Behavior.AMBUSH
	g.alert_radius = alert_radius
	g.on_alert = on_alert
	assert_eq(g.validate(_catalog), PackedStringArray(), "the spec is valid")
	return g


## A world with the pool's ambush group (spec 0) and a walker at (from_x,
## from_z) metres sent to (to_x, to_z) at tick 0.
func _walk_world(
	world_seed: int, from_x: int, from_z: int, to_x: int, to_z: int
) -> World:
	var world: World = World.new(world_seed, _pool(), _catalog)
	world.ai.spawn_group(world, _spec(), 0, 0)
	var walker: Unit = world.spawn_unit(WALKER, LIGHT, from_x * M, from_z * M, 1, 0)
	world.enqueue(MoveUnitsCommand.new(
		0, PackedInt32Array([walker.id]), to_x * M, to_z * M, Formations.Kind.BOX
	))
	return world


func _walker(world: World) -> Unit:
	for unit: Unit in world.units:
		if unit.type_index == WALKER:
			return unit
	return null


## The AMBUSH_SPRUNG events of the last step.
func _sprung(world: World) -> Array[AiEvent]:
	var out: Array[AiEvent] = []
	for e: AiEvent in world.ai_events:
		if e.kind == AiEvent.Kind.AMBUSH_SPRUNG:
			out.append(e)
	return out


func _near(walker: Unit, group: AiGroup, world: World) -> bool:
	for unit: Unit in group.living(world):
		if FixedMath.length(unit.x - walker.x, unit.z - walker.z) <= ALERT:
			return true
	return false


## The first think of group at or after tick: groups think when
## (tick + id) % THINK_TICKS == 0.
func _first_think_from(group: AiGroup, tick: int) -> int:
	var t: int = tick
	while (t + group.id) % AiDirector.THINK_TICKS != 0:
		t += 1
	return t


func _all_submerged(world: World, group: AiGroup) -> bool:
	for unit: Unit in group.living(world):
		if not Visibility.is_submerged(world.terrain, unit):
			return false
	return true


# --- lurking ----------------------------------------------------------------


func test_lurkers_wait_submerged_and_unseen_until_something_comes_near() -> void:
	var world: World = _walk_world(1, 2, 5, 38, 5)
	var group: AiGroup = world.ai.groups[0]
	var walker: Unit = _walker(world)
	assert_eq(group.members.size(), 3)
	for _t: int in 60:
		world.step()
		assert_false(_near(walker, group, world), "the walker is still far off")
		assert_eq(_sprung(world).size(), 0)
		for unit: Unit in group.living(world):
			assert_eq(world.terrain.water_depth_at(unit.x, unit.z), POOL_DEPTH, "the pool is deep")
			assert_true(Visibility.is_submerged(world.terrain, unit), "lurker %d is under" % unit.id)
			assert_false(Visibility.seen_by(world, unit, LIGHT), "and the light side can't see it")
			assert_false(unit.surfaced)
	assert_eq(group.behavior, AiGroupSpec.Behavior.AMBUSH)


func test_a_lurker_told_to_walk_is_told_to_hold_at_the_next_think() -> void:
	var world: World = _world()
	var group: AiGroup = world.ai.spawn_group(world, _spec(), 0, 0)
	world.step()
	var lurker: Unit = world.get_unit(group.members[0])
	UnitOrders.move(world, PackedInt32Array([lurker.id]), 24 * M, 12 * M, Formations.Kind.BOX)
	assert_eq(lurker.order, Unit.Order.MOVE)
	var tick: int = world.tick
	while world.tick <= tick + AiDirector.THINK_TICKS:
		world.step()
	assert_eq(lurker.order, Unit.Order.NONE, "it holds again")
	assert_eq(lurker.state, Unit.State.IDLE)
	assert_eq(group.behavior, AiGroupSpec.Behavior.AMBUSH, "and nothing sprang it")


# --- springing --------------------------------------------------------------


func test_a_walker_coming_within_the_alert_radius_springs_the_ambush() -> void:
	var world: World = _walk_world(1, 2, 5, 38, 5)
	var group: AiGroup = world.ai.groups[0]
	var walker: Unit = _walker(world)
	var first_near: int = -1
	var sprung_tick: int = -1
	var sprung: Array[AiEvent] = []
	while world.tick < 600 and sprung_tick < 0:
		var t: int = world.tick
		if first_near < 0 and _near(walker, group, world):
			first_near = t
		world.step()
		sprung = _sprung(world)
		if not sprung.is_empty():
			sprung_tick = t
	assert_gt(first_near, 0, "the walker did come within 6 m")
	assert_eq(
		sprung_tick, _first_think_from(group, first_near),
		"sprang at the group's first think once the walker was within range"
	)
	assert_eq(sprung.size(), 1, "one AMBUSH_SPRUNG")
	if sprung.size() == 1:
		assert_eq(sprung[0].group_id, group.id)
		assert_eq(sprung[0].value, 3, "three lurkers")
		var c: Vector2i = AiOrders.centroid(group.living(world))
		assert_lte(FixedMath.length(sprung[0].x - c.x, sprung[0].z - c.y), M, "reported at the group's centroid")
	assert_eq(group.behavior, AiGroupSpec.Behavior.HUNT)
	for unit: Unit in group.living(world):
		assert_true(unit.surfaced, "lurker %d surfaced" % unit.id)
		assert_eq(world.terrain.water_depth_at(unit.x, unit.z), POOL_DEPTH, "still in the deep water")
		assert_false(Visibility.is_submerged(world.terrain, unit), "so it is no longer submerged")
		assert_true(Visibility.seen_by(world, unit, LIGHT), "and the light side sees it")
	var attacked: bool = false
	for _t: int in ATTACK_TICKS:
		world.step()
		for unit: Unit in group.living(world):
			if unit.state == Unit.State.ATTACKING and unit.target_id == walker.id:
				attacked = true
		if attacked:
			break
	assert_true(attacked, "a lurker is on the walker within %d ticks" % ATTACK_TICKS)


func test_a_walker_that_keeps_its_distance_never_springs_it() -> void:
	var world: World = _walk_world(1, 2, 0, 38, 0)
	var group: AiGroup = world.ai.groups[0]
	for _t: int in 600:
		world.step()
		assert_eq(_sprung(world).size(), 0)
	assert_eq(group.behavior, AiGroupSpec.Behavior.AMBUSH)
	assert_true(_all_submerged(world, group))
	for unit: Unit in group.living(world):
		assert_false(unit.surfaced)


func test_a_hurt_lurker_springs_the_group_at_its_next_think() -> void:
	var world: World = _world()
	var group: AiGroup = world.ai.spawn_group(world, _spec(), 0, 0)
	for _t: int in 20:
		world.step()
		assert_eq(_sprung(world).size(), 0, "nothing near, nothing hurt")
	world.get_unit(group.members[1]).hp -= 10
	var hurt_at: int = world.tick
	var sprung_tick: int = -1
	while world.tick < hurt_at + 2 * AiDirector.THINK_TICKS and sprung_tick < 0:
		var t: int = world.tick
		world.step()
		if not _sprung(world).is_empty():
			sprung_tick = t
	assert_eq(sprung_tick, _first_think_from(group, hurt_at), "at the group's next think")
	assert_eq(group.behavior, AiGroupSpec.Behavior.HUNT)
	for unit: Unit in group.living(world):
		assert_true(unit.surfaced, "the unhurt ones surface too")


func test_an_enemy_walking_into_a_lurker_springs_the_group() -> void:
	# Dry ground, and a radius so small that only contact can spring it. The
	# post never swings, so no lurker is hurt either.
	var world: World = _world(TestTerrains.flat(40, 20))
	var group: AiGroup = world.ai.spawn_group(world, _spec(20, 10, 100), 0, 0)
	var lurker: Unit = world.get_unit(group.members[0])
	world.spawn_unit(POST, LIGHT, lurker.x + 1200, lurker.z, -1, 0)
	var sprung_tick: int = -1
	while world.tick < 60 and sprung_tick < 0:
		var t: int = world.tick
		world.step()
		if not _sprung(world).is_empty():
			sprung_tick = t
	assert_gt(sprung_tick, 0, "the lurker swung at the post and the group sprang")
	assert_eq(group.behavior, AiGroupSpec.Behavior.HUNT)
	assert_eq(group.last_hp, group.start_hp, "no one was hurt")
	for unit: Unit in group.living(world):
		assert_true(unit.surfaced)


func test_a_trigger_that_sets_another_behavior_springs_it_on_that_tick() -> void:
	var turn: TriggerSpec = TriggerSpec.new()
	turn.name = &"turn"
	turn.condition = TriggerSpec.Condition.TIMER
	turn.ticks = PackedInt32Array([60])
	var action: TriggerAction = TriggerAction.new()
	action.kind = TriggerAction.Kind.SET_BEHAVIOR
	action.group = &"lurkers"
	action.behavior = AiGroupSpec.Behavior.HUNT
	turn.actions.append(action)
	var spec: AiGroupSpec = _spec()
	spec.spawn_at_start = true
	var script: MissionScript = MissionScript.new()
	script.groups = [spec]
	script.triggers = [turn]
	var world: World = _world()
	assert_true(world.start_mission(script, 0))
	# Far from the pool and parked, so only the trigger can spring it.
	var walker: Unit = world.spawn_unit(WALKER, LIGHT, 35 * M, 1 * M, -1, 0)
	var sprung_ticks: Array[int] = []
	var order_ticks: Array[int] = []
	while world.tick < 90:
		var t: int = world.tick
		world.step()
		for e: AiEvent in world.ai_events:
			if e.kind == AiEvent.Kind.AMBUSH_SPRUNG:
				sprung_ticks.append(t)
			elif e.kind == AiEvent.Kind.ORDER:
				order_ticks.append(t)
	assert_eq(world.mission.fired_tick[0], 60)
	assert_eq(sprung_ticks, [60] as Array[int], "sprang exactly when the trigger fired, once")
	assert_eq(order_ticks.slice(0, 1), [60] as Array[int], "and hunted on that very tick")
	var group: AiGroup = world.ai.groups[0]
	assert_eq(group.behavior, AiGroupSpec.Behavior.HUNT)
	for unit: Unit in group.living(world):
		assert_true(unit.surfaced)
	assert_eq(group.ordered_target[0], walker.id, "after the one enemy there is")


func test_springing_reports_once_and_surfacing_is_for_good() -> void:
	var world: World = _world()
	var group: AiGroup = world.ai.spawn_group(world, _spec(), 0, 0)
	world.step()
	world.ai_events.clear()
	world.ai.set_behavior(world, group, AiGroupSpec.Behavior.IDLE)
	var sprung: Array[AiEvent] = _sprung(world)
	assert_eq(sprung.size(), 1)
	if sprung.size() == 1:
		assert_eq(sprung[0].value, 3)
	assert_eq(world.ai_events.size(), 2, "the spring and the behavior change")
	if world.ai_events.size() == 2:
		assert_eq(world.ai_events[0].kind, AiEvent.Kind.AMBUSH_SPRUNG, "the spring comes before the behavior change")
		assert_eq(world.ai_events[1].kind, AiEvent.Kind.BEHAVIOR)
	world.ai_events.clear()
	world.ai.set_behavior(world, group, AiGroupSpec.Behavior.GUARD)
	assert_eq(_sprung(world).size(), 0, "a group that wasn't lurking doesn't spring again")
	world.ai.set_behavior(world, group, AiGroupSpec.Behavior.AMBUSH)
	for unit: Unit in group.living(world):
		assert_true(unit.surfaced, "back to ambush, still surfaced")
		assert_false(Visibility.is_submerged(world.terrain, unit))


# --- determinism ------------------------------------------------------------


func test_two_worlds_stay_identical_through_a_spring() -> void:
	var a: World = _walk_world(7, 2, 5, 38, 5)
	var b: World = _walk_world(7, 2, 5, 38, 5)
	var sang: bool = false
	for _t: int in 400:
		a.step()
		b.step()
		assert_eq(a.ai_events.size(), b.ai_events.size())
		for i: int in mini(a.ai_events.size(), b.ai_events.size()):
			assert_eq(a.ai_events[i].to_array(), b.ai_events[i].to_array())
		if not _sprung(a).is_empty():
			sang = true
	assert_true(sang, "the ambush sprang inside the run")
	assert_eq(a.state_hash(), b.state_hash())
	var c: World = _walk_world(7, 2, 5, 38, 5)
	for _t: int in 400:
		c.step()
	assert_eq(a.state_hash(), c.state_hash(), "and the run is repeatable")


func test_surfacing_is_part_of_the_state_hash() -> void:
	var a: World = _world()
	var b: World = _world()
	a.ai.spawn_group(a, _spec(), 0, 0)
	b.ai.spawn_group(b, _spec(), 0, 0)
	assert_eq(a.state_hash(), b.state_hash())
	a.get_unit(a.ai.groups[0].members[0]).surfaced = true
	assert_ne(a.state_hash(), b.state_hash())
