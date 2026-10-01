extends GutTest
## GUARD and HUNT: a guard chases what enters its radius, ignores what stays
## out, comes back afterwards, and is called back when a chase drags a member
## past the leash; a hunt runs enemies down one after another, prefers the
## roles its type prefers, leaves a member mid-swing alone, and re-orders
## only when its plan changes (the ORDER count pins that). Also when the
## director lets a group think. Groups are spawned straight from specs
## (AiDirector.spawn_group) on flat ground, no mission.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

## Catalog indices of the synthetic types.
const GRUNT: int = 0
const TARGET: int = 1
const POST: int = 2
const RAIDER: int = 3
const ARCHER: int = 4

## Most ORDER events a 4-grunt hunt of two standing targets may emit in its
## first 600 ticks. Re-ordering at every think would be 40.
const HUNT_ORDER_BOUND: int = 6

var _catalog: UnitCatalog


func before_all() -> void:
	var types: Array[UnitType] = [
		TestUnits.melee(&"grunt"),
		# Dies to six blows, so a hunt doesn't wait on it.
		TestUnits.dummy(&"target", {"max_hp": 60}),
		TestUnits.dummy(&"post"),
		TestUnits.scavenger(&"raider"),
		TestUnits.ranged(&"archer"),
	]
	_catalog = TestUnits.catalog(types)


# --- fixtures ---------------------------------------------------------------


func _world() -> World:
	return World.new(1, TestTerrains.flat(60, 60), _catalog)


## A DARK group of count units of type_id at (x, z) m, spawned as spec 0.
func _group(
	world: World, type_id: StringName, count: int, x: int, z: int,
	behavior: AiGroupSpec.Behavior, guard_radius: int = 0
) -> AiGroup:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = &"pack"
	var e: AiUnitEntry = AiUnitEntry.new()
	e.type_id = type_id
	e.counts = PackedInt32Array([count])
	g.units.append(e)
	g.spawns = PackedInt32Array([x * M, z * M])
	g.behavior = behavior
	g.guard_radius = guard_radius
	assert_eq(g.validate(_catalog), PackedStringArray(), "the spec is valid")
	return world.ai.spawn_group(world, g, 0, 0)


func _distance(unit: Unit, x: int, z: int) -> int:
	return FixedMath.length(unit.x - x, unit.z - z)


func _order_count(world: World) -> int:
	var n: int = 0
	for e: AiEvent in world.ai_events:
		if e.kind == AiEvent.Kind.ORDER:
			n += 1
	return n


## Steps the world until the group emits an ORDER, and returns it (null if
## none comes within 60 ticks).
func _first_order(world: World, group: AiGroup) -> AiEvent:
	for _t: int in 60:
		world.step()
		for e: AiEvent in world.ai_events:
			if e.kind == AiEvent.Kind.ORDER and e.group_id == group.id:
				return e
	return null


# --- GUARD ------------------------------------------------------------------


func test_guard_engages_an_intruder_ignores_a_bystander_and_comes_back() -> void:
	var world: World = _world()
	var radius: int = 15 * M
	var group: AiGroup = _group(world, &"grunt", 4, 20, 30, AiGroupSpec.Behavior.GUARD, radius)
	var anchor: Vector2i = Vector2i(group.anchor_x, group.anchor_z)
	var bystander: Unit = world.spawn_unit(POST, LIGHT, 45 * M, 30 * M, -1, 0)
	var intruder: Unit = world.spawn_unit(GRUNT, LIGHT, 20 * M, 5 * M, 0, 1)
	world.enqueue(MoveUnitsCommand.new(
		60, PackedInt32Array([intruder.id]), 20 * M, 16 * M, Formations.Kind.BOX
	))
	var entered: int = -1
	var engaged: int = -1
	var died: int = -1
	while world.tick < 1500 and died < 0:
		world.step()
		for e: AiEvent in world.ai_events:
			if e.kind != AiEvent.Kind.ORDER:
				continue
			assert_gt(FixedMath.length(e.x - bystander.x, e.z - bystander.z), 5 * M, "never sent at the bystander")
			if engaged < 0:
				engaged = world.tick
				assert_lte(FixedMath.length(e.x - intruder.x, e.z - intruder.z), M, "sent at the intruder")
				for i: int in group.members.size():
					assert_eq(group.ordered_target[i], intruder.id)
		if entered < 0 and _distance(intruder, anchor.x, anchor.y) <= radius:
			entered = world.tick
		if not intruder.is_alive():
			died = world.tick
	assert_gt(entered, 60, "the intruder walked in after its order")
	assert_between(engaged - entered, 1, AiDirector.THINK_TICKS, "engaged at the first think after it came in")
	assert_gt(died, 0, "the guard killed it")
	assert_eq(bystander.hp, bystander.type.max_hp, "the bystander 25 m out was left alone")
	for _t: int in 450:
		world.step()
	for unit: Unit in group.living(world):
		assert_lte(_distance(unit, anchor.x, anchor.y), radius, "unit %d is back inside the radius" % unit.id)


func test_guard_calls_back_a_member_that_chases_past_the_leash() -> void:
	var world: World = _world()
	var radius: int = 10 * M
	var leash: int = radius * AiBehaviors.GUARD_LEASH_PERMILLE / 1000
	var group: AiGroup = _group(world, &"grunt", 4, 30, 40, AiGroupSpec.Behavior.GUARD, radius)
	var anchor: Vector2i = Vector2i(group.anchor_x, group.anchor_z)
	# A tough runner inside the radius walks off south at the guards' own
	# pace, so the chase never closes and never ends by itself.
	var runner: Unit = world.spawn_unit(POST, LIGHT, 30 * M, 32 * M, 0, -1)
	world.enqueue(MoveUnitsCommand.new(
		20, PackedInt32Array([runner.id]), 30 * M, 2 * M, Formations.Kind.BOX
	))
	var recalled: int = -1
	var farthest: int = 0
	while world.tick < 900:
		world.step()
		for unit: Unit in group.living(world):
			farthest = maxi(farthest, _distance(unit, anchor.x, anchor.y))
		for e: AiEvent in world.ai_events:
			if e.kind != AiEvent.Kind.ORDER or e.value != 0:
				continue
			assert_eq(Vector2i(e.x, e.z), anchor, "a plain move home")
			if recalled < 0:
				recalled = world.tick
				var unit: Unit = world.get_unit(e.unit_id)
				assert_gt(_distance(unit, anchor.x, anchor.y), leash - 200, "recalled once past the leash")
				assert_eq(unit.order, Unit.Order.MOVE)
				assert_eq(unit.target_id, 0, "its chase is dropped")
	assert_gt(recalled, 0, "a member was called back")
	assert_gt(farthest, leash, "the chase did drag members past the leash")
	assert_lt(farthest, leash + 1500, "but not past it by more than a think's walk")
	for unit: Unit in group.living(world):
		assert_lte(_distance(unit, anchor.x, anchor.y), radius, "unit %d is home" % unit.id)


func test_guard_members_out_of_the_radius_attack_move_back_to_the_post() -> void:
	var world: World = _world()
	var radius: int = 5 * M
	var group: AiGroup = _group(world, &"grunt", 4, 10, 30, AiGroupSpec.Behavior.GUARD, radius)
	# A post somewhere else, as when a group is told to hold a new spot.
	group.anchor_x = 40 * M
	group.anchor_z = 30 * M
	var order: AiEvent = _first_order(world, group)
	assert_not_null(order)
	if order == null:
		return
	assert_eq(Vector2i(order.x, order.z), Vector2i(40 * M, 30 * M))
	assert_eq(order.value, 1, "an attack-move, so it fights its way back")
	for _t: int in 600:
		world.step()
	for unit: Unit in group.living(world):
		assert_lte(_distance(unit, 40 * M, 30 * M), radius, "unit %d is at the post" % unit.id)


# --- HUNT -------------------------------------------------------------------


func test_hunt_runs_down_two_enemies_far_apart_without_order_spam() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, &"grunt", 4, 10, 30, AiGroupSpec.Behavior.HUNT)
	var near: Unit = world.spawn_unit(TARGET, LIGHT, 30 * M, 20 * M, -1, 0)
	var far: Unit = world.spawn_unit(TARGET, LIGHT, 50 * M, 50 * M, -1, 0)
	var orders: int = 0
	var killed: Array[int] = []
	while world.tick < 2000 and (near.is_alive() or far.is_alive()):
		world.step()
		for e: AiEvent in world.ai_events:
			if e.kind == AiEvent.Kind.ORDER and world.tick <= 600:
				orders += 1
		for e: CombatEvent in world.combat_events:
			if e.kind == CombatEvent.Kind.KILL and group.spawned_ids.has(e.attacker_id):
				killed.append(e.target_id)
	assert_eq(killed, [near.id, far.id], "the nearer one first, then the other")
	gut.p("hunt: %d ORDER events in the first 600 ticks" % orders)
	assert_lt(orders, HUNT_ORDER_BOUND, "orders only when the plan changes")


func test_hunt_reorders_a_walking_quarry_only_once_it_has_drifted() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, &"grunt", 4, 10, 10, AiGroupSpec.Behavior.HUNT)
	# As fast as the hunters and never killed, so the chase lasts the test.
	var quarry: Unit = world.spawn_unit(POST, LIGHT, 40 * M, 10 * M, 0, 1)
	world.enqueue(MoveUnitsCommand.new(
		0, PackedInt32Array([quarry.id]), 40 * M, 58 * M, Formations.Kind.BOX
	))
	var goals: Array[Vector2i] = []
	var targets: Array[int] = []
	for i: int in group.members.size():
		goals.append(Vector2i(group.ordered_x[i], group.ordered_z[i]))
		targets.append(group.ordered_target[i])
	var reorders: int = 0
	var orders: int = 0
	while world.tick < 600:
		world.step()
		for e: AiEvent in world.ai_events:
			if e.kind == AiEvent.Kind.ORDER:
				orders += 1
		for i: int in group.members.size():
			var goal: Vector2i = Vector2i(group.ordered_x[i], group.ordered_z[i])
			if targets[i] == quarry.id and group.ordered_target[i] == quarry.id and goal != goals[i]:
				reorders += 1
				assert_gt(
					FixedMath.length(goal.x - goals[i].x, goal.y - goals[i].y), AiOrders.REORDER_MIN,
					"a member is re-sent after the same quarry only once it has drifted"
				)
			goals[i] = goal
			targets[i] = group.ordered_target[i]
	gut.p("walking quarry: %d ORDER events, %d member re-orders in 600 ticks" % [orders, reorders])
	assert_gt(reorders, 0, "the hunters do follow it")
	assert_lt(orders, 20, "far fewer than one per think (40)")


func test_a_raider_hunt_goes_for_the_archer_past_a_nearer_swordsman() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, &"raider", 3, 10, 30, AiGroupSpec.Behavior.HUNT)
	world.spawn_unit(GRUNT, LIGHT, 20 * M, 30 * M, -1, 0)
	var archer: Unit = world.spawn_unit(ARCHER, LIGHT, 40 * M, 30 * M, -1, 0)
	var order: AiEvent = _first_order(world, group)
	assert_not_null(order)
	if order == null:
		return
	assert_eq(Vector2i(order.x, order.z), Vector2i(archer.x, archer.z))
	for i: int in group.members.size():
		assert_eq(group.ordered_target[i], archer.id)


func test_a_plain_melee_hunt_goes_for_the_nearest() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, &"grunt", 3, 10, 30, AiGroupSpec.Behavior.HUNT)
	var swordsman: Unit = world.spawn_unit(GRUNT, LIGHT, 20 * M, 30 * M, -1, 0)
	world.spawn_unit(ARCHER, LIGHT, 40 * M, 30 * M, -1, 0)
	var order: AiEvent = _first_order(world, group)
	assert_not_null(order)
	if order == null:
		return
	assert_eq(Vector2i(order.x, order.z), Vector2i(swordsman.x, swordsman.z))
	for i: int in group.members.size():
		assert_eq(group.ordered_target[i], swordsman.id)


func test_a_member_mid_swing_is_not_reordered() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, &"grunt", 2, 20, 30, AiGroupSpec.Behavior.IDLE)
	var a: Unit = world.get_unit(group.members[0])
	var b: Unit = world.get_unit(group.members[1])
	# A post 1 m beyond a, on the side away from b: in a's reach, out of b's.
	var away: Vector2i = FixedMath.normalize(a.x - b.x, a.z - b.z, M)
	var post: Unit = world.spawn_unit(POST, LIGHT, a.x + away.x, a.z + away.y, 0, -1)
	world.step()
	assert_gt(a.windup_left, 0, "a is swinging at the post")
	assert_eq(a.target_id, post.id)
	assert_eq(b.target_id, 0, "b stands out of reach")
	world.ai.set_behavior(world, group, AiGroupSpec.Behavior.HUNT)
	world.ai_events.clear()
	var windup: int = a.windup_left
	AiBehaviors.think(world, group)
	assert_eq(a.target_id, post.id, "the swing survives the think")
	assert_eq(a.windup_left, windup)
	assert_eq(a.order, Unit.Order.NONE)
	assert_eq(group.ordered_target[0], 0, "a was not re-ordered")
	assert_eq(group.ordered_target[1], post.id, "b, free, was")
	assert_eq(world.ai_events.size(), 1)
	if world.ai_events.size() != 1:
		return
	assert_eq(world.ai_events[0].kind, AiEvent.Kind.ORDER)
	assert_eq(world.ai_events[0].unit_id, b.id)


# --- when a group thinks ----------------------------------------------------


func test_groups_first_plan_on_their_staggered_ticks() -> void:
	var world: World = _world()
	var first: AiGroup = _group(world, &"grunt", 2, 10, 20, AiGroupSpec.Behavior.HUNT)
	var second: AiGroup = _group(world, &"grunt", 2, 10, 40, AiGroupSpec.Behavior.HUNT)
	world.spawn_unit(POST, LIGHT, 50 * M, 30 * M, -1, 0)
	var planned: Dictionary[int, int] = {}
	while world.tick < 30:
		var tick: int = world.tick
		world.step()
		for e: AiEvent in world.ai_events:
			if e.kind == AiEvent.Kind.ORDER and not planned.has(e.group_id):
				planned[e.group_id] = tick
	assert_eq(planned.get(first.id, -1), 14, "group 1: (14 + 1) % THINK_TICKS == 0")
	assert_eq(planned.get(second.id, -1), 13, "group 2: (13 + 2) % THINK_TICKS == 0")


func test_think_now_plans_at_the_next_update_once_then_the_group_waits_its_turn() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, &"grunt", 2, 10, 30, AiGroupSpec.Behavior.IDLE)
	world.spawn_unit(POST, LIGHT, 40 * M, 30 * M, -1, 0)
	world.step()
	world.ai.set_behavior(world, group, AiGroupSpec.Behavior.HUNT)
	world.step()
	assert_eq(_order_count(world), 1, "planned at the very next update")
	assert_false(group.think_now, "and the request is spent")
	# last_hp only changes when the group thinks: a quiet way to watch it.
	world.get_unit(group.members[0]).hp -= 10
	var noted: int = group.last_hp
	while world.tick < 14:
		world.step()
		assert_eq(group.last_hp, noted, "no plan on tick %d" % (world.tick - 1))
	world.step()
	assert_eq(group.last_hp, noted - 10, "planned on its turn, tick 14")


func test_a_group_with_no_members_left_does_not_think() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, &"grunt", 2, 10, 30, AiGroupSpec.Behavior.HUNT)
	world.spawn_unit(POST, LIGHT, 40 * M, 30 * M, -1, 0)
	for unit: Unit in group.living(world):
		unit.kill()
	group.think_now = true
	for _t: int in 30:
		world.step()
		assert_eq(_order_count(world), 0)
	assert_true(group.members.is_empty())
	assert_true(group.think_now, "nothing to plan for, so the request stands")
