extends GutTest
## AiOrders: who the AI may re-order (is_free), who has finished its order
## (is_done), the enemies a group can see, and how march and engage split
## members by type, pick an objective, record, report, and hold back from
## re-ordering (the hysteresis). Pure calls on small worlds; no stepping
## unless a rule needs it.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

## Catalog indices of the synthetic types.
const GRUNT: int = 0
const PLODDER: int = 1
const POST: int = 2
const LURKER: int = 3

var _catalog: UnitCatalog


func before_all() -> void:
	var types: Array[UnitType] = [
		TestUnits.melee(&"grunt"),
		TestUnits.melee(&"plodder", {"move_speed": 1000}),
		TestUnits.dummy(&"post"),
		TestUnits.undead(&"lurker", {"hidden_in_deep_water": true}),
	]
	_catalog = TestUnits.catalog(types)


# --- fixtures ---------------------------------------------------------------


func _world(terrain: Terrain = null) -> World:
	return World.new(1, terrain if terrain != null else TestTerrains.flat(60, 60), _catalog)


## A DARK HUNT group at (x, z) m: `grunts` grunts, then `plodders` plodders.
func _group(world: World, grunts: int, plodders: int = 0, x: int = 10, z: int = 30) -> AiGroup:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = &"pack"
	g.behavior = AiGroupSpec.Behavior.HUNT
	for pair: Array in [[&"grunt", grunts], [&"plodder", plodders]]:
		if pair[1] == 0:
			continue
		var e: AiUnitEntry = AiUnitEntry.new()
		e.type_id = pair[0]
		e.counts = PackedInt32Array([pair[1]])
		g.units.append(e)
	g.spawns = PackedInt32Array([x * M, z * M])
	return world.ai.spawn_group(world, g, 0, 0)


func _orders(world: World) -> Array[AiEvent]:
	var out: Array[AiEvent] = []
	for e: AiEvent in world.ai_events:
		if e.kind == AiEvent.Kind.ORDER:
			out.append(e)
	return out


# --- is_free / is_done ------------------------------------------------------


func test_a_fresh_unit_is_free_and_done() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(GRUNT, DARK, 10 * M, 10 * M, 0, 1)
	assert_true(AiOrders.is_free(world, unit))
	assert_true(AiOrders.is_done(unit))


func test_anything_the_unit_is_in_the_middle_of_makes_it_not_free() -> void:
	var busy: Dictionary[String, Callable] = {
		"dead": func(_w: World, u: Unit) -> void: u.kill(),
		"confused": func(w: World, u: Unit) -> void: StatusEffects.apply(w, u, StatusEffects.Kind.CONFUSION, 30, 0),
		"on an errand": func(_w: World, u: Unit) -> void: u.order = Unit.Order.INTERACT,
		"fighting or chasing": func(_w: World, u: Unit) -> void: u.target_id = 99,
		"attacking": func(_w: World, u: Unit) -> void: u.transition_to(Unit.State.ATTACKING),
		"shooting": func(_w: World, u: Unit) -> void: u.transition_to(Unit.State.SHOOTING),
		"drawing": func(_w: World, u: Unit) -> void: u.aim_left = 3,
		"swinging": func(_w: World, u: Unit) -> void: u.windup_left = 3,
		"acting": func(_w: World, u: Unit) -> void: u.act_left = 3,
		"waiting for a path": func(_w: World, u: Unit) -> void: u.path_pending = true,
	}
	for what: String in busy:
		var world: World = _world()
		var unit: Unit = world.spawn_unit(GRUNT, DARK, 10 * M, 10 * M, 0, 1)
		busy[what].call(world, unit)
		assert_false(AiOrders.is_free(world, unit), what)


func test_is_done_once_the_order_has_run_out() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(GRUNT, DARK, 10 * M, 10 * M, 0, 1)
	UnitOrders.move(world, PackedInt32Array([unit.id]), 30 * M, 10 * M, Formations.Kind.BOX)
	assert_eq(unit.order, Unit.Order.MOVE)
	assert_false(AiOrders.is_done(unit), "still walking")
	world.movement.order_stop(unit)
	assert_true(AiOrders.is_done(unit), "MOVE but stopped: arrived or gave up")
	UnitOrders.move(world, PackedInt32Array([unit.id]), 30 * M, 10 * M, Formations.Kind.BOX, true)
	assert_false(AiOrders.is_done(unit), "attack-moving")
	world.movement.order_stop(unit)
	assert_true(AiOrders.is_done(unit), "ATTACK_MOVE but stopped")
	unit.order = Unit.Order.GROUND_ATTACK
	assert_false(AiOrders.is_done(unit), "a ground attack lasts until another order")
	unit.order = Unit.Order.INTERACT
	assert_false(AiOrders.is_done(unit), "an errand ends by itself")
	UnitOrders.hold(unit)
	assert_true(AiOrders.is_done(unit), "holding")


# --- enemies, hp_sum, centroid ----------------------------------------------


func test_enemies_are_the_living_visible_other_side_in_id_order() -> void:
	var rows: Array[String] = []
	for j: int in 20:
		rows.append(".".repeat(10) + "3333" + ".".repeat(6))
	var world: World = _world(TestTerrains.from_ascii(rows))
	var a: Unit = world.spawn_unit(GRUNT, LIGHT, 2 * M, 2 * M, 0, 1)
	var dead: Unit = world.spawn_unit(GRUNT, LIGHT, 3 * M, 2 * M, 0, 1)
	dead.kill()
	world.spawn_unit(GRUNT, DARK, 4 * M, 2 * M, 0, 1)
	var lurker: Unit = world.spawn_unit(LURKER, LIGHT, 12 * M, 5 * M, 0, 1)
	var b: Unit = world.spawn_unit(POST, LIGHT, 5 * M, 8 * M, 0, 1)
	assert_true(Visibility.is_submerged(world.terrain, lurker))
	assert_eq(AiOrders.enemies(world, DARK), [a, b])
	assert_eq(AiOrders.enemies(world, LIGHT).size(), 1, "the other way round")


func test_hp_sum_and_centroid() -> void:
	var world: World = _world()
	var units: Array[Unit] = [
		world.spawn_unit(GRUNT, DARK, 10 * M, 10 * M, 0, 1),
		world.spawn_unit(GRUNT, DARK, 11 * M, 10 * M, 0, 1),
		world.spawn_unit(POST, DARK, 11 * M, 13 * M, 0, 1),
	]
	units[0].hp = 40
	assert_eq(AiOrders.hp_sum(units), 40 + 100 + 100_000)
	# x: 32000 / 3 = 10666.7 rounds up; z: 33000 / 3 = 11000.
	assert_eq(AiOrders.centroid(units), Vector2i(10_667, 11_000))
	var none: Array[Unit] = []
	assert_eq(AiOrders.hp_sum(none), 0)
	assert_eq(AiOrders.centroid(none), Vector2i.ZERO)


# --- march ------------------------------------------------------------------


func test_march_orders_each_type_on_its_own_at_its_own_pace() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, 2, 2)
	var units: Array[Unit] = group.living(world)
	AiOrders.march(world, group, units, 40 * M, 30 * M, true)
	var orders: Array[AiEvent] = _orders(world)
	assert_eq(orders.size(), 2, "one order per type")
	if orders.size() != 2:
		return
	assert_eq(orders[0].unit_id, units[0].id, "grunts first: the lower type index")
	assert_eq(orders[1].unit_id, units[2].id)
	for e: AiEvent in orders:
		assert_eq(Vector2i(e.x, e.z), Vector2i(40 * M, 30 * M))
		assert_eq(e.value, 1, "an attack-move")
	assert_eq(units[0].order_speed_cap, 2000, "grunts aren't held to the plodders' pace")
	assert_eq(units[2].order_speed_cap, 1000)
	for i: int in 4:
		assert_eq(units[i].order, Unit.Order.ATTACK_MOVE)
		assert_eq(Vector2i(group.ordered_x[i], group.ordered_z[i]), Vector2i(40 * M, 30 * M))
		assert_eq(group.ordered_target[i], 0)


func test_march_skips_members_already_sent_there_and_busy_ones_unless_forced() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, 3)
	var units: Array[Unit] = group.living(world)
	AiOrders.march(world, group, units, 40 * M, 30 * M, false)
	world.ai_events.clear()
	AiOrders.march(world, group, units, 40 * M, 30 * M, false)
	assert_true(_orders(world).is_empty(), "already on their way")
	units[1].target_id = 99
	group.record_order(units[1].id, 1, 1, 0)
	group.record_order(units[2].id, 1, 1, 0)
	AiOrders.march(world, group, units, 40 * M, 30 * M, false)
	var orders: Array[AiEvent] = _orders(world)
	assert_eq(orders.size(), 1)
	if orders.size() != 1:
		return
	assert_eq(orders[0].unit_id, units[2].id, "only the free member sent elsewhere")
	assert_eq(units[1].target_id, 99, "the busy one keeps its fight")
	assert_eq(group.ordered_x[1], 1)
	world.ai_events.clear()
	AiOrders.march(world, group, units, 40 * M, 30 * M, false, true)
	orders = _orders(world)
	assert_eq(orders.size(), 1)
	if orders.size() != 1:
		return
	assert_eq(orders[0].unit_id, units[0].id, "forced: every member, in one bucket")
	assert_eq(units[1].target_id, 0, "the fight is dropped")
	assert_eq(units[1].order, Unit.Order.MOVE)


# --- engage -----------------------------------------------------------------


func test_engage_skips_an_enemy_it_cannot_walk_to() -> void:
	var rows: Array[String] = []
	for j: int in 60:
		rows.append("#".repeat(60) if j == 35 else ".".repeat(60))
	var world: World = _world(TestTerrains.from_ascii(rows))
	var group: AiGroup = _group(world, 2, 0, 20, 30)
	world.spawn_unit(POST, LIGHT, 20 * M, 40 * M, 0, -1)
	var reachable: Unit = world.spawn_unit(POST, LIGHT, 45 * M, 30 * M, -1, 0)
	AiOrders.engage(world, group, group.living(world), AiOrders.enemies(world, DARK))
	var orders: Array[AiEvent] = _orders(world)
	assert_eq(orders.size(), 1)
	if orders.size() != 1:
		return
	assert_eq(Vector2i(orders[0].x, orders[0].z), Vector2i(reachable.x, reachable.z), "not the nearer one over the wall")
	assert_eq(group.ordered_target[0], reachable.id)


func test_engage_reorders_only_when_the_objective_changes_drifts_or_got_away() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, 1, 0, 10, 30)
	var member: Unit = group.living(world)[0]
	var post: Unit = world.spawn_unit(POST, LIGHT, 40 * M, 30 * M, -1, 0)
	var enemies: Array[Unit] = [post]
	AiOrders.engage(world, group, group.living(world), enemies)
	assert_eq(_orders(world).size(), 1, "a new objective")
	assert_eq(member.order, Unit.Order.ATTACK_MOVE)
	assert_eq(group.ordered_target[0], post.id)
	world.ai_events.clear()
	AiOrders.engage(world, group, group.living(world), enemies)
	assert_true(_orders(world).is_empty(), "same objective, on its way")
	# 30 m off, the slack is a quarter of the distance: about 7.6 m.
	post.z += 7 * M
	AiOrders.engage(world, group, group.living(world), enemies)
	assert_true(_orders(world).is_empty(), "7 m of drift at 30 m")
	post.z += 2 * M
	AiOrders.engage(world, group, group.living(world), enemies)
	assert_eq(_orders(world).size(), 1, "9 m of drift at 30 m")
	assert_eq(Vector2i(group.ordered_x[0], group.ordered_z[0]), Vector2i(40 * M, 39 * M))
	# 12 m off, a quarter is 3 m and REORDER_MIN (4 m) is the slack instead.
	world.ai_events.clear()
	member.x = post.x - 12 * M
	member.z = post.z
	post.z += 3500
	AiOrders.engage(world, group, group.living(world), enemies)
	assert_true(_orders(world).is_empty(), "3.5 m of drift at 12 m")
	post.z += 1000
	AiOrders.engage(world, group, group.living(world), enemies)
	assert_eq(_orders(world).size(), 1, "4.5 m of drift at 12 m")
	world.ai_events.clear()
	UnitOrders.hold(member)
	AiOrders.engage(world, group, group.living(world), enemies)
	assert_eq(_orders(world).size(), 1, "it stopped beyond its acquire radius: sent again")
	world.ai_events.clear()
	UnitOrders.hold(member)
	post.x = member.x + 5 * M
	post.z = member.z
	group.record_order(member.id, post.x, post.z, post.id)
	AiOrders.engage(world, group, group.living(world), enemies)
	assert_true(_orders(world).is_empty(), "stopped within its acquire radius: melee takes it from there")


func test_engage_with_no_candidates_does_nothing() -> void:
	var world: World = _world()
	var group: AiGroup = _group(world, 3)
	var before: PackedInt64Array = group.hash_fields()
	var none: Array[Unit] = []
	AiOrders.engage(world, group, group.living(world), none)
	assert_true(_orders(world).is_empty())
	assert_eq(group.hash_fields(), before)
