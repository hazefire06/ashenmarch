extends GutTest
## Per-type AI tactics (UnitType.ai_tactic). A Blightbag (CLUSTER) walks past
## a lone decoy into the thickest knot of enemies and bursts there. A
## Stormcaller (STANDOFF) holds at 90 % of its range where its line is clear,
## steps out of its dead zone when a walker closes and keeps casting, moves
## round a friend standing in its line, and only falls back to attack-moving
## when no spot will do; the melee members of its group go for whatever
## threatens it (the bodyguard rule). Also the march's standoff offset, and
## the order kind every member's order record keeps (ordered_attack). Groups
## are spawned straight from specs (AiDirector.spawn_group), no mission.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

## Catalog indices of the synthetic types.
const CASTER: int = 0
const GRUNT: int = 1
const DUMMY: int = 2
const BOMB: int = 3
const WALKER: int = 4
const TARGET: int = 5
const BOWMAN: int = 6

var _catalog: UnitCatalog
var _bolt: ProjectileType


func before_all() -> void:
	var types: Array[UnitType] = [
		TestUnits.caster(&"caster", {"ai_tactic": UnitType.AiTactic.STANDOFF, "ai_standoff_permille": 900}),
		TestUnits.melee(&"grunt"),
		TestUnits.dummy(&"dummy"),
		TestUnits.bomb(&"bomb", {"ai_tactic": UnitType.AiTactic.CLUSTER}),
		TestUnits.melee(&"walker", {"move_speed": 1000}),
		# Stands still and dies to three bolts.
		TestUnits.dummy(&"target", {"max_hp": 100}),
		# Arrows out to 50 m, a 4 m dead zone: a STANDOFF unit an enemy can stand
		# near without driving it off.
		TestUnits.ranged(&"bowman", {"ai_tactic": UnitType.AiTactic.STANDOFF, "ai_standoff_permille": 800}),
	]
	_catalog = TestUnits.catalog(types)
	_bolt = _catalog.find_projectile(&"lightning")


# --- fixtures ---------------------------------------------------------------


func _world(terrain: Terrain) -> World:
	return World.new(1, terrain, _catalog)


## A DARK group spawned as spec 0 at (x, z) m: entries are [type id, count]
## pairs, spawned in that order.
func _group(
	world: World, entries: Array, x: int, z: int, behavior: AiGroupSpec.Behavior, guard_radius: int = 0
) -> AiGroup:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = &"pack"
	for pair: Array in entries:
		var e: AiUnitEntry = AiUnitEntry.new()
		e.type_id = pair[0]
		e.counts = PackedInt32Array([pair[1]])
		g.units.append(e)
	g.spawns = PackedInt32Array([x * M, z * M])
	g.behavior = behavior
	g.guard_radius = guard_radius
	if behavior == AiGroupSpec.Behavior.PATROL:
		g.waypoints = PackedInt32Array([40 * M, z * M, x * M, z * M])
	assert_eq(g.validate(_catalog), PackedStringArray(), "the spec is valid")
	return world.ai.spawn_group(world, g, 0, 0)


## Puts unit at (x, z) milli-units, standing and holding there.
func _place(unit: Unit, x: int, z: int) -> void:
	unit.x = x
	unit.z = z
	unit.goal_x = x
	unit.goal_z = z
	UnitOrders.hold(unit)


func _distance(a: Unit, b: Unit) -> int:
	return FixedMath.length(a.x - b.x, a.z - b.z)


func _events(world: World, kind: AiEvent.Kind) -> Array[AiEvent]:
	var out: Array[AiEvent] = []
	for e: AiEvent in world.ai_events:
		if e.kind == kind:
			out.append(e)
	return out


func _cast_by(world: World, unit: Unit) -> bool:
	for e: ProjectileEvent in world.projectile_events:
		if e.kind == ProjectileEvent.Kind.BOLT and e.unit_id == unit.id:
			return true
	return false


## Lightning.is_clear for caster at target from where it stands, careful,
## with the spread and reach RangedCombat aims a bolt with.
func _clear_line(world: World, caster: Unit, target: Unit) -> bool:
	var from_y: int = caster.y + caster.type.ranged_launch_height
	var ground: int = world.terrain.height_at(target.x, target.z)
	var y: int = RangedCombat.chest_height(target, ground)
	var dist: int = _distance(caster, target)
	var spread: int = RangedCombat.spread_for(caster, y - from_y, dist)
	var reach: int = RangedCombat.effective_max_range(caster, ground - from_y, dist)
	return Lightning.is_clear(
		world, caster, _bolt, target.x, y, target.z, true, RangedCombat.PATH_MARGIN, spread, reach
	)


## Flat 80 x 12 m with a wall at x = 10 m, so a unit west of it is penned in
## a pocket no standoff spot 36 m out can be in.
func _pocket() -> Terrain:
	var rows: Array[String] = []
	for j: int in 12:
		rows.append(".".repeat(10) + "#" + ".".repeat(69))
	return TestTerrains.from_ascii(rows)


# --- CLUSTER ----------------------------------------------------------------


func test_a_blightbag_walks_past_a_decoy_and_bursts_in_the_densest_knot() -> void:
	var world: World = _world(TestTerrains.flat(80, 60))
	var group: AiGroup = _group(world, [[&"bomb", 1]], 30, 30, AiGroupSpec.Behavior.HUNT)
	var bomb: Unit = group.living(world)[0]
	var knot: Array[Unit] = []
	for p: Vector2i in [Vector2i(60_000, 15_000), Vector2i(61_500, 15_000), Vector2i(58_500, 15_000),
			Vector2i(60_000, 16_500), Vector2i(60_000, 13_500)]:
		knot.append(world.spawn_unit(DUMMY, LIGHT, p.x, p.y, -1, 0))
	var decoy: Unit = world.spawn_unit(DUMMY, LIGHT, 30 * M, 44 * M, 0, -1)
	var center: Vector2i = AiOrders.centroid(knot)
	var burst_index: int = _catalog.projectile_index_of(&"blight_burst")
	var orders: Array[AiEvent] = []
	var burst: ProjectileEvent = null
	while world.tick < 1500 and burst == null:
		world.step()
		orders.append_array(_events(world, AiEvent.Kind.ORDER))
		for e: ProjectileEvent in world.projectile_events:
			if e.kind == ProjectileEvent.Kind.EXPLODE and e.type_index == burst_index:
				burst = e
	assert_not_null(burst, "it burst within 1500 ticks")
	if burst == null:
		return
	var off: int = FixedMath.length(burst.x - center.x, burst.z - center.y)
	gut.p("blightbag burst at tick %d, %d mm from the knot's centroid, %d orders"
		% [world.tick, off, orders.size()])
	assert_false(bomb.is_alive())
	assert_lte(off, 4 * M, "in the knot")
	assert_eq(decoy.hp, decoy.type.max_hp, "the decoy it passed is untouched")
	assert_gt(orders.size(), 0)
	if orders.is_empty():
		return
	assert_eq(orders[0].value, 0, "a plain move first, so nothing on the way distracts it")
	assert_eq(Vector2i(orders[0].x, orders[0].z), center)
	assert_eq(orders[orders.size() - 1].value, 1, "an attack-move once it is close")
	assert_lte(orders.size(), 3, "not re-sent at every think")


func test_a_cluster_member_is_sent_at_a_knot_once_per_kind() -> void:
	var world: World = _world(TestTerrains.flat(80, 60))
	var group: AiGroup = _group(world, [[&"bomb", 1]], 30, 30, AiGroupSpec.Behavior.HUNT)
	var bomb: Unit = group.living(world)[0]
	var a: Unit = world.spawn_unit(DUMMY, LIGHT, 60 * M, 30 * M, -1, 0)
	var b: Unit = world.spawn_unit(DUMMY, LIGHT, 62 * M, 30 * M, -1, 0)
	var enemies: Array[Unit] = [a, b]
	AiOrders.engage(world, group, group.living(world), enemies)
	assert_eq(_events(world, AiEvent.Kind.ORDER).size(), 1)
	assert_eq(bomb.order, Unit.Order.MOVE, "31 m off: a plain move")
	assert_eq(group.ordered_attack[0], 0)
	assert_true(AiOrders.is_free(world, bomb), "on flat ground it walks straight: no path to wait for")
	world.ai_events.clear()
	b.x += 2 * M
	AiOrders.engage(world, group, group.living(world), enemies)
	assert_true(_events(world, AiEvent.Kind.ORDER).is_empty(), "the knot moved 1 m: not re-sent")
	a.x += 4 * M
	b.x += 2 * M
	AiOrders.engage(world, group, group.living(world), enemies)
	assert_eq(_events(world, AiEvent.Kind.ORDER).size(), 1, "it is 4 m from where it was sent: re-sent")
	assert_eq(Vector2i(group.ordered_x[0], group.ordered_z[0]), Vector2i(65 * M, 30 * M))
	world.ai_events.clear()
	_place(bomb, 58 * M, 30 * M)
	AiOrders.engage(world, group, group.living(world), enemies)
	assert_eq(_events(world, AiEvent.Kind.ORDER).size(), 1, "within its acquire radius")
	assert_eq(bomb.order, Unit.Order.ATTACK_MOVE)
	assert_eq(group.ordered_attack[0], 1)
	world.ai_events.clear()
	AiOrders.engage(world, group, group.living(world), enemies)
	assert_true(_events(world, AiEvent.Kind.ORDER).is_empty(), "attack-moved there once")


# --- STANDOFF ---------------------------------------------------------------


func test_a_stormcaller_holds_at_its_standoff_range_and_casts() -> void:
	var world: World = _world(TestTerrains.flat(80, 40))
	var group: AiGroup = _group(world, [[&"caster", 1]], 10, 20, AiGroupSpec.Behavior.HUNT)
	var caster: Unit = group.living(world)[0]
	var dummy: Unit = world.spawn_unit(DUMMY, LIGHT, 60 * M, 20 * M, -1, 0)
	var bolts: int = 0
	var first_bolt: int = -1
	var standoffs: Array[AiEvent] = []
	var orders: int = 0
	while world.tick < 900:
		world.step()
		standoffs.append_array(_events(world, AiEvent.Kind.STANDOFF))
		orders += _events(world, AiEvent.Kind.ORDER).size()
		if _cast_by(world, caster):
			bolts += 1
			if first_bolt < 0:
				first_bolt = world.tick
	var dist: int = _distance(caster, dummy)
	gut.p("stormcaller: holds %d mm from the dummy, first bolt tick %d, %d bolts by 900"
		% [dist, first_bolt, bolts])
	assert_eq(caster.order, Unit.Order.NONE, "holding")
	assert_between(dist, 34 * M, 40 * M, "at about 90 % of its 40 m")
	assert_gt(bolts, 0, "and casting")
	assert_eq(standoffs.size(), 1, "sent to its spot once, then left to hold")
	assert_eq(orders, 0, "never attack-moved")
	if standoffs.size() == 1:
		assert_eq(standoffs[0].unit_id, caster.id)
		assert_eq(Vector2i(standoffs[0].x, standoffs[0].z), Vector2i(24 * M, 20 * M))


func test_a_stormcaller_steps_out_of_its_dead_zone_and_keeps_casting() -> void:
	var world: World = _world(TestTerrains.flat(80, 40))
	var group: AiGroup = _group(world, [[&"caster", 1]], 40, 20, AiGroupSpec.Behavior.HUNT)
	var caster: Unit = group.living(world)[0]
	var walker: Unit = world.spawn_unit(WALKER, LIGHT, 52 * M, 20 * M, -1, 0)
	var dead_zone: int = caster.type.ranged_min_range + StandoffSpot.DEAD_ZONE_MARGIN
	var close_run: int = 0
	var longest: int = 0
	var nearest: int = _distance(caster, walker)
	var escapes: int = 0
	while world.tick < 1800 and walker.is_alive():
		if world.tick % 30 == 0:
			# It keeps coming at wherever the caster is now.
			world.enqueue(AttackMoveCommand.new(
				world.tick, PackedInt32Array([walker.id]), caster.x, caster.z, Formations.Kind.BOX
			))
		var before: int = _distance(caster, walker)
		world.step()
		for e: AiEvent in _events(world, AiEvent.Kind.STANDOFF):
			if before <= dead_zone + M:
				escapes += 1
		var d: int = _distance(caster, walker)
		nearest = mini(nearest, d)
		close_run = close_run + 1 if d < 8 * M else 0
		longest = maxi(longest, close_run)
	gut.p("dead zone: nearest %d mm, longest run inside 8 m %d ticks, %d escapes, walker dead at tick %d"
		% [nearest, longest, escapes, world.tick])
	assert_true(caster.is_alive())
	assert_lte(longest, 45, "never inside 8 m for more than 45 ticks")
	assert_gt(escapes, 0, "it had to step out")
	assert_false(walker.is_alive(), "it kept casting between escapes and killed the walker")


func test_a_stormcaller_moves_round_a_friend_in_its_line() -> void:
	var world: World = _world(TestTerrains.flat(80, 40))
	var group: AiGroup = _group(world, [[&"caster", 1]], 10, 20, AiGroupSpec.Behavior.HUNT)
	var caster: Unit = group.living(world)[0]
	var dummy: Unit = world.spawn_unit(DUMMY, LIGHT, 60 * M, 20 * M, -1, 0)
	var friend: Unit = world.spawn_unit(DUMMY, DARK, 40 * M, 20 * M, -1, 0)
	var bolts: int = 0
	var standoffs: int = 0
	while world.tick < 900:
		world.step()
		standoffs += _events(world, AiEvent.Kind.STANDOFF).size()
		if not _cast_by(world, caster):
			continue
		bolts += 1
		if bolts == 1:
			gut.p("clear line: first bolt at tick %d from (%d, %d), %d mm out, after %d STANDOFF moves"
				% [world.tick, caster.x, caster.z, _distance(caster, dummy), standoffs])
			assert_true(_clear_line(world, caster, dummy), "cast from where the line is clear")
			assert_between(_distance(caster, dummy), 34 * M, 40 * M, "from its standoff range")
	assert_gt(bolts, 0, "it cast")
	assert_eq(friend.hp, friend.type.max_hp, "the friend in the way was never struck")


func test_a_drawing_standoff_unit_is_only_moved_to_escape_its_dead_zone() -> void:
	var world: World = _world(TestTerrains.flat(80, 40))
	var group: AiGroup = _group(world, [[&"caster", 1]], 10, 20, AiGroupSpec.Behavior.HUNT)
	var caster: Unit = group.living(world)[0]
	var dummy: Unit = world.spawn_unit(DUMMY, LIGHT, 60 * M, 20 * M, -1, 0)
	caster.aim_left = 5
	AiOrders.engage(world, group, group.living(world), AiOrders.enemies(world, DARK))
	assert_true(_events(world, AiEvent.Kind.STANDOFF).is_empty(), "mid-draw: left alone though out of range")
	assert_eq(caster.order, Unit.Order.NONE)
	# 9 m west of it: the way out is east, onto the map.
	_place(dummy, caster.x - 9 * M, caster.z)
	caster.aim_left = 5
	AiOrders.engage(world, group, group.living(world), AiOrders.enemies(world, DARK))
	assert_eq(_events(world, AiEvent.Kind.STANDOFF).size(), 1, "inside its dead zone: it goes, draw or not")
	assert_eq(caster.order, Unit.Order.MOVE)
	assert_eq(caster.aim_left, 0, "the draw is dropped")
	assert_gt(FixedMath.length(caster.order_x - dummy.x, caster.order_z - dummy.z), 30 * M, "away from it")


func test_a_standoff_unit_beside_a_spot_it_doesnt_hold_is_still_sent_there() -> void:
	var world: World = _world(TestTerrains.flat(80, 40))
	var group: AiGroup = _group(world, [[&"caster", 1]], 25, 20, AiGroupSpec.Behavior.HUNT)
	var caster: Unit = group.living(world)[0]
	_place(caster, 25_500, 20 * M)
	var dummy: Unit = world.spawn_unit(DUMMY, LIGHT, 60 * M, 20 * M, -1, 0)
	# Past the target, where the caster's line runs on to its 40 m reach from
	# 34.5 m out (to x = 65.5 m), but not from the spot 36 m out (to 64 m).
	world.spawn_unit(DUMMY, DARK, 65_200, 20 * M, -1, 0)
	assert_false(StandoffSpot.holds(world, caster, dummy), "its line is blocked from where it stands")
	assert_eq(StandoffSpot.find(world, caster, dummy), PackedInt64Array([24 * M, 20 * M]), "1.5 m back is clear")
	AiOrders.engage(world, group, group.living(world), AiOrders.enemies(world, DARK))
	assert_eq(_events(world, AiEvent.Kind.STANDOFF).size(), 1, "sent there though it is close")
	assert_eq(caster.order, Unit.Order.MOVE)
	assert_eq(Vector2i(caster.order_x, caster.order_z), Vector2i(24 * M, 20 * M))


func test_with_no_spot_it_attack_moves_unless_it_already_has_a_shot() -> void:
	var world: World = _world(_pocket())
	var group: AiGroup = _group(world, [[&"caster", 1]], 5, 6, AiGroupSpec.Behavior.HUNT)
	var caster: Unit = group.living(world)[0]
	var far: Unit = world.spawn_unit(DUMMY, LIGHT, 60 * M, 6 * M, -1, 0)
	var enemies: Array[Unit] = [far]
	assert_eq(StandoffSpot.find(world, caster, far), PackedInt64Array(), "penned in: no spot")
	AiOrders.engage(world, group, group.living(world), enemies)
	var orders: Array[AiEvent] = _events(world, AiEvent.Kind.ORDER)
	assert_eq(orders.size(), 1)
	if orders.size() == 1:
		assert_eq(Vector2i(orders[0].x, orders[0].z), Vector2i(far.x, far.z), "toward the objective")
		assert_eq(orders[0].value, 1, "attack-moving, so RangedCombat halts it in range")
	assert_eq(group.ordered_target[0], far.id)
	world.ai_events.clear()
	AiOrders.engage(world, group, group.living(world), enemies)
	assert_true(_events(world, AiEvent.Kind.ORDER).is_empty(), "not re-sent while on its way")
	# It walks to the wall and stops there, still out of range; the group
	# thinks on, and must not send it at the wall again every time.
	var resent: int = 0
	for _t: int in 300:
		world.step()
		resent += _events(world, AiEvent.Kind.ORDER).size()
	assert_lt(caster.x, 10 * M, "penned at the wall")
	assert_eq(caster.order, Unit.Order.NONE, "it stopped there")
	assert_eq(resent, 0, "and is left there")
	# In range now, but a friend stands in the line and no spot will do: it
	# holds, and RangedCombat shoots when the friend moves.
	var near_world: World = _world(_pocket())
	group = _group(near_world, [[&"caster", 1]], 5, 6, AiGroupSpec.Behavior.HUNT)
	caster = group.living(near_world)[0]
	var near: Unit = near_world.spawn_unit(DUMMY, LIGHT, 30 * M, 6 * M, -1, 0)
	near_world.spawn_unit(DUMMY, DARK, 20 * M, 6 * M, -1, 0)
	assert_false(StandoffSpot.holds(near_world, caster, near))
	AiOrders.engage(near_world, group, group.living(near_world), AiOrders.enemies(near_world, DARK))
	assert_true(_events(near_world, AiEvent.Kind.ORDER).is_empty(), "holding with a shot in range: left alone")
	assert_eq(caster.order, Unit.Order.NONE)


func test_a_bowman_under_a_cliff_lip_backs_off_until_its_arrows_clear_it() -> void:
	# A plain at 0 m, a cliff rising 2 m per m from x = 50 m to a plateau 6 m
	# up from x = 53 m. The bowman spawns 2 m short of the foot with the target
	# 32 m off on the plateau: in range, but every arrow from there meets the
	# cliff. It used to hold there for ever without a shot (Old Mill's west
	# cliff); now it walks back to where its arrows clear the lip, and shoots.
	var size_x: int = 100
	var heights: PackedInt32Array = PackedInt32Array()
	var water: PackedByteArray = PackedByteArray()
	var blocked: PackedByteArray = PackedByteArray()
	heights.resize(size_x * 40)
	water.resize(size_x * 40)
	blocked.resize(size_x * 40)
	for j: int in 40:
		for i: int in size_x:
			heights[j * size_x + i] = clampi((i - 50) * 2 * M, 0, 6 * M)
	var world: World = _world(Terrain.new(
		size_x, 40, TestTerrains.CELL, heights, water, blocked, TestTerrains.WALKABLE_SLOPE
	))
	var group: AiGroup = _group(world, [[&"bowman", 1]], 48, 20, AiGroupSpec.Behavior.HUNT)
	var bowman: Unit = group.living(world)[0]
	var dummy: Unit = world.spawn_unit(DUMMY, LIGHT, 80 * M, 20 * M, -1, 0)
	var shots: int = 0
	var first_shot_x: int = -1
	while world.tick < 600:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			if e.kind == ProjectileEvent.Kind.LAUNCH and e.unit_id == bowman.id:
				shots += 1
				if first_shot_x < 0:
					first_shot_x = bowman.x
	gut.p("bowman under a cliff: %d arrows by tick 600, the first from x = %d mm" % [shots, first_shot_x])
	assert_gt(shots, 0, "it gets a shot")
	assert_lt(first_shot_x, 47 * M, "from back on the plain, not the foot")
	assert_lt(dummy.hp, dummy.type.max_hp, "and the arrows land")


# --- bodyguards -------------------------------------------------------------


func test_melee_members_go_for_what_threatens_their_standoff_unit() -> void:
	var world: World = _world(TestTerrains.flat(60, 60))
	var group: AiGroup = _group(world, [[&"grunt", 4], [&"caster", 1]], 20, 30, AiGroupSpec.Behavior.HUNT)
	var units: Array[Unit] = group.living(world)
	var caster: Unit = units[4]
	assert_eq(caster.type_index, CASTER)
	for i: int in 4:
		_place(units[i], 24 * M, (27 + 2 * i) * M)
	_place(caster, 14 * M, 30 * M)
	# Beyond the grunts' 8 m acquire radius, but the nearest enemy to them.
	var dummy: Unit = world.spawn_unit(DUMMY, LIGHT, 34 * M, 30 * M, -1, 0)
	# Comes at the caster from the side, already inside PROTECT_RADIUS of it.
	var raider: Unit = world.spawn_unit(GRUNT, LIGHT, 14 * M, 39 * M, 0, -1)
	world.enqueue(AttackMoveCommand.new(
		0, PackedInt32Array([raider.id]), caster.x, caster.z, Formations.Kind.BOX
	))
	var order: AiEvent = null
	while world.tick < 60 and order == null:
		world.step()
		for e: AiEvent in _events(world, AiEvent.Kind.ORDER):
			if order == null and world.get_unit(e.unit_id).type_index == GRUNT:
				order = e
	assert_not_null(order, "the grunts were given an order")
	if order == null:
		return
	var lead: Unit = units[0]
	assert_lt(_distance(lead, dummy), _distance(lead, raider), "the dummy was nearer the grunts")
	assert_lte(_distance(caster, raider), AiTactics.PROTECT_RADIUS, "the raider was on the caster")
	assert_lte(FixedMath.length(order.x - raider.x, order.z - raider.z), 1500, "sent at the raider")
	for i: int in 4:
		assert_eq(group.ordered_target[i], raider.id, "grunt %d after the raider" % i)


func test_bodyguards_fall_back_to_the_candidates_when_they_cant_reach_the_threat() -> void:
	# Deep water at x = 30-31 m, impassable to the living, splits the map.
	var rows: Array[String] = []
	for j: int in 40:
		rows.append(".".repeat(30) + "33" + ".".repeat(48))
	var world: World = _world(TestTerrains.from_ascii(rows))
	var group: AiGroup = _group(world, [[&"grunt", 2], [&"caster", 1]], 20, 20, AiGroupSpec.Behavior.HUNT)
	var units: Array[Unit] = group.living(world)
	_place(units[0], 20 * M, 19 * M)
	_place(units[1], 20 * M, 21 * M)
	_place(units[2], 26 * M, 20 * M)
	# On the caster across the water, and the nearest enemy to the grunts.
	var threat: Unit = world.spawn_unit(DUMMY, LIGHT, 34 * M, 20 * M, -1, 0)
	var dummy: Unit = world.spawn_unit(DUMMY, LIGHT, 5 * M, 20 * M, 1, 0)
	assert_eq(AiTactics.threats(world, group), [threat])
	AiOrders.engage(world, group, units, AiOrders.enemies(world, DARK))
	var orders: Array[AiEvent] = _events(world, AiEvent.Kind.ORDER)
	assert_eq(orders.size(), 1, "the grunts' order")
	if orders.size() == 1:
		assert_eq(orders[0].unit_id, units[0].id)
		assert_eq(Vector2i(orders[0].x, orders[0].z), Vector2i(dummy.x, dummy.z), "after what they can reach")
	assert_eq(group.ordered_target[0], dummy.id)
	assert_eq(group.ordered_target[1], dummy.id)


# --- GUARD ------------------------------------------------------------------


func test_guard_bodyguards_leave_a_threat_past_the_leash_alone() -> void:
	# The bowman shoots from past the leash at an enemy standing by it;
	# another enemy is inside the radius. Sent at the one by the bowman, the
	# grunts would be dragged past the leash, called back, and sent again.
	var world: World = _world(TestTerrains.flat(80, 40))
	var radius: int = 10 * M
	var leash: int = radius * AiBehaviors.GUARD_LEASH_PERMILLE / 1000
	var group: AiGroup = _group(world, [[&"grunt", 3], [&"bowman", 1]], 40, 20, AiGroupSpec.Behavior.GUARD, radius)
	var units: Array[Unit] = group.living(world)
	var anchor: Vector2i = Vector2i(group.anchor_x, group.anchor_z)
	for i: int in 3:
		_place(units[i], 40 * M, (19 + i) * M)
	var bowman: Unit = units[3]
	_place(bowman, 12 * M, 20 * M)
	# Inside the radius, but past the grunts' 8 m acquire radius, so a walk
	# toward the stray doesn't pick it up on the way.
	var intruder: Unit = world.spawn_unit(DUMMY, LIGHT, 49 * M, 20 * M, -1, 0)
	var stray: Unit = world.spawn_unit(DUMMY, LIGHT, 12 * M, 27 * M, 0, -1)
	assert_lte(_distance(bowman, stray), AiTactics.PROTECT_RADIUS, "the stray threatens the bowman")
	assert_gt(FixedMath.length(stray.x - anchor.x, stray.z - anchor.y), leash, "from past the leash")
	var orders: int = 0
	var recalls: int = 0
	var farthest: int = 0
	while world.tick < 900:
		world.step()
		for e: AiEvent in _events(world, AiEvent.Kind.ORDER):
			if world.get_unit(e.unit_id).type_index != GRUNT:
				continue
			orders += 1
			if e.value == 0 and Vector2i(e.x, e.z) == anchor:
				recalls += 1
		for i: int in 3:
			farthest = maxi(farthest, FixedMath.length(units[i].x - anchor.x, units[i].z - anchor.y))
	gut.p("guard bodyguards: %d grunt orders, %d recalls, farthest %d mm from the post" % [orders, recalls, farthest])
	assert_eq(recalls, 0, "never called back")
	assert_lte(orders, 2, "no shuttling")
	assert_lte(farthest, leash, "never dragged past the leash")
	for i: int in 3:
		assert_eq(group.ordered_target[i], intruder.id, "grunt %d after the intruder" % i)


func test_a_guarding_caster_isnt_called_back_from_its_spot_while_intruders_live() -> void:
	var world: World = _world(TestTerrains.flat(80, 40))
	var radius: int = 10 * M
	var leash: int = radius * AiBehaviors.GUARD_LEASH_PERMILLE / 1000
	var group: AiGroup = _group(world, [[&"caster", 1]], 40, 20, AiGroupSpec.Behavior.GUARD, radius)
	var caster: Unit = group.living(world)[0]
	var anchor: Vector2i = Vector2i(group.anchor_x, group.anchor_z)
	# 8 m from the post: inside the guard radius and inside the caster's dead
	# zone, so it backs off to a spot 36 m from the intruder, 28 m from the
	# post and well past the 15 m leash, and casts from there.
	var intruder: Unit = world.spawn_unit(TARGET, LIGHT, 48 * M, 20 * M, -1, 0)
	var orders: int = 0
	var recalls: int = 0
	var farthest: int = 0
	var died: int = -1
	while world.tick < 2400:
		world.step()
		for e: AiEvent in _events(world, AiEvent.Kind.ORDER):
			if e.unit_id != caster.id or died >= 0:
				continue
			orders += 1
			if e.value == 0 and Vector2i(e.x, e.z) == anchor:
				recalls += 1
		if died < 0:
			farthest = maxi(farthest, FixedMath.length(caster.x - anchor.x, caster.z - anchor.y))
			if not intruder.is_alive():
				died = world.tick
	var home: int = FixedMath.length(caster.x - anchor.x, caster.z - anchor.y)
	gut.p("guard: farthest %d mm out while the intruder lived, %d orders, %d recalls, it died at tick %d, "
		% [farthest, orders, recalls, died] + "%d mm from the post at the end" % home)
	assert_gt(farthest, leash, "its spot was past the leash")
	assert_eq(recalls, 0, "never called back while the intruder lived")
	assert_eq(orders, 0, "nor sent anywhere but its spot")
	assert_gt(died, 0, "so it kept casting and killed the intruder")
	assert_lte(home, radius, "then the stray return brought it home")


# --- march ------------------------------------------------------------------


func test_march_sends_standoff_members_behind_the_goal_and_records_the_goal() -> void:
	var world: World = _world(TestTerrains.flat(60, 60))
	var group: AiGroup = _group(world, [[&"grunt", 2], [&"caster", 1]], 10, 30, AiGroupSpec.Behavior.HUNT)
	var units: Array[Unit] = group.living(world)
	var goal: Vector2i = Vector2i(40 * M, 30 * M)
	AiOrders.march(world, group, units, goal.x, goal.y, true)
	var orders: Array[AiEvent] = _events(world, AiEvent.Kind.ORDER)
	assert_eq(orders.size(), 2, "one per bucket")
	if orders.size() != 2:
		return
	assert_eq(orders[0].unit_id, units[0].id, "the grunts first")
	assert_eq(Vector2i(orders[0].x, orders[0].z), goal)
	assert_eq(orders[1].unit_id, units[2].id)
	assert_almost_eq(FixedMath.length(orders[1].x - goal.x, orders[1].z - goal.y), AiTactics.STANDOFF_BEHIND, 2)
	assert_lt(orders[1].x, goal.x - 5900, "behind, on the side it comes from")
	assert_eq(Vector2i(units[2].order_x, units[2].order_z), Vector2i(orders[1].x, orders[1].z))
	for i: int in 3:
		assert_eq(Vector2i(group.ordered_x[i], group.ordered_z[i]), goal, "the group goal is recorded")
		assert_eq(group.ordered_attack[i], 1)
	world.ai_events.clear()
	AiOrders.march(world, group, units, goal.x, goal.y, true)
	assert_true(_events(world, AiEvent.Kind.ORDER).is_empty(), "already on their way")


func test_a_plain_march_sends_standoff_members_to_the_goal_itself() -> void:
	# A retreat, a recall, or a flank's approach: nobody is fighting at the
	# goal, so there is no front to stand behind.
	var world: World = _world(TestTerrains.flat(60, 60))
	var group: AiGroup = _group(world, [[&"grunt", 2], [&"caster", 1]], 10, 30, AiGroupSpec.Behavior.HUNT)
	var goal: Vector2i = Vector2i(40 * M, 30 * M)
	AiOrders.march(world, group, group.living(world), goal.x, goal.y, false)
	var orders: Array[AiEvent] = _events(world, AiEvent.Kind.ORDER)
	assert_eq(orders.size(), 2, "one per bucket")
	for order: AiEvent in orders:
		assert_eq(Vector2i(order.x, order.z), goal, "unit %d is sent to the goal itself" % order.unit_id)
		assert_eq(order.value, 0, "a plain move")


func test_an_attack_march_of_some_members_offsets_from_their_own_centroid() -> void:
	# The grunts stand 30 m west of the goal, the caster 10 m east of it. A
	# march of the caster alone stops it short on its own side; measured from
	# the whole group's centroid (west of the goal) it would be sent through
	# the goal to the far side.
	var world: World = _world(TestTerrains.flat(60, 60))
	var group: AiGroup = _group(world, [[&"grunt", 3], [&"caster", 1]], 10, 30, AiGroupSpec.Behavior.HUNT)
	var units: Array[Unit] = group.living(world)
	for i: int in 3:
		_place(units[i], 10 * M, (29 + i) * M)
	var caster: Unit = units[3]
	_place(caster, 50 * M, 30 * M)
	var goal: Vector2i = Vector2i(40 * M, 30 * M)
	var marched: Array[Unit] = [caster]
	AiOrders.march(world, group, marched, goal.x, goal.y, true)
	var orders: Array[AiEvent] = _events(world, AiEvent.Kind.ORDER)
	assert_eq(orders.size(), 1)
	if orders.size() != 1:
		return
	assert_eq(Vector2i(orders[0].x, orders[0].z), Vector2i(goal.x + AiTactics.STANDOFF_BEHIND, goal.y), "6 m short, east")
	assert_eq(Vector2i(group.ordered_x[3], group.ordered_z[3]), goal, "the goal is recorded")


func test_a_group_of_standoff_units_alone_marches_to_the_goal_itself() -> void:
	var world: World = _world(TestTerrains.flat(60, 60))
	var group: AiGroup = _group(world, [[&"caster", 2]], 10, 30, AiGroupSpec.Behavior.HUNT)
	AiOrders.march(world, group, group.living(world), 40 * M, 30 * M, true)
	var orders: Array[AiEvent] = _events(world, AiEvent.Kind.ORDER)
	assert_eq(orders.size(), 1)
	if orders.size() == 1:
		assert_eq(Vector2i(orders[0].x, orders[0].z), Vector2i(40 * M, 30 * M), "nobody to stand behind")


func test_a_mixed_patrol_leg_arrives_on_its_non_standoff_members() -> void:
	# Three casters stopping 6 m short would drag the centroid of all four
	# 4.5 m off the waypoint, past LEG_ARRIVE_RADIUS. The grunt leads, as a
	# front line does: one starting behind the casters would have to squeeze
	# past them where they stop, on its line to the goal.
	var world: World = _world(TestTerrains.flat(60, 60))
	var group: AiGroup = _group(world, [[&"grunt", 1], [&"caster", 3]], 10, 30, AiGroupSpec.Behavior.PATROL)
	var units: Array[Unit] = group.living(world)
	_place(units[0], 16 * M, 30 * M)
	for i: int in 3:
		_place(units[i + 1], 10 * M, (28 + 2 * i) * M)
	var result: AiEvent = null
	while world.tick < 1200 and result == null:
		world.step()
		for e: AiEvent in world.ai_events:
			if e.kind == AiEvent.Kind.WAYPOINT_REACHED or e.kind == AiEvent.Kind.WAYPOINT_FAILED:
				result = e
	assert_not_null(result)
	if result == null:
		return
	assert_eq(result.kind, AiEvent.Kind.WAYPOINT_REACHED)
	assert_eq(result.value, 0)
	var casters: Array[Unit] = group.living(world).slice(1)
	var c: Vector2i = AiOrders.centroid(casters)
	assert_lt(c.x, 40 * M - 4 * M, "the casters stopped short, behind the grunt")


# --- ordered_attack ---------------------------------------------------------


func test_the_order_kind_is_kept_per_member_pruned_and_hashed() -> void:
	var world: World = _world(TestTerrains.flat(60, 60))
	var group: AiGroup = _group(world, [[&"grunt", 3]], 10, 30, AiGroupSpec.Behavior.IDLE)
	assert_eq(group.ordered_attack, PackedByteArray([0, 0, 0]), "spawned with no attack recorded")
	var before: PackedInt64Array = group.hash_fields()
	group.record_order(group.members[1], 5, 6, 0, true)
	assert_eq(group.ordered_attack, PackedByteArray([0, 1, 0]))
	assert_ne(group.hash_fields(), before, "hashed")
	group.record_order(group.members[2], 5, 6, 0)
	assert_eq(group.ordered_attack[2], 0, "a plain order by default")
	world.get_unit(group.members[0]).kill()
	group.prune(world)
	assert_eq(group.ordered_attack, PackedByteArray([1, 0]), "pruned with its member")


# --- determinism ------------------------------------------------------------


func test_two_runs_of_every_tactic_agree_event_for_event() -> void:
	var a: World = _tactics_battle()
	var b: World = _tactics_battle()
	var standoffs: int = 0
	var bursts: int = 0
	for _t: int in 900:
		a.step()
		b.step()
		if _log(a) != _log(b):
			assert_eq(_log(a), _log(b), "tick %d" % a.tick)
			return
		standoffs += _events(a, AiEvent.Kind.STANDOFF).size()
		for e: ProjectileEvent in a.projectile_events:
			if e.kind == ProjectileEvent.Kind.EXPLODE:
				bursts += 1
	assert_gt(standoffs, 0, "the casters stood off")
	assert_gt(bursts, 0, "the Blightbag burst")
	assert_eq(a.state_hash(), b.state_hash())


## A caster, its grunts and a Blightbag hunting a Light line that walks at
## them: every tactic at once.
func _tactics_battle() -> World:
	var world: World = _world(TestTerrains.flat(80, 60))
	_group(world, [[&"grunt", 3], [&"caster", 2], [&"bomb", 1]], 15, 30, AiGroupSpec.Behavior.HUNT)
	var line: PackedInt32Array = PackedInt32Array()
	for i: int in 5:
		line.append(world.spawn_unit(WALKER, LIGHT, 50 * M, (24 + 3 * i) * M, -1, 0).id)
	world.enqueue(AttackMoveCommand.new(0, line, 15 * M, 30 * M, Formations.Kind.SHORT_LINE))
	return world


func _log(world: World) -> Array[PackedInt64Array]:
	var out: Array[PackedInt64Array] = []
	for e: AiEvent in world.ai_events:
		out.append(e.to_array())
	return out
