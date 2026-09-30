extends GutTest
## Ranged units: who they shoot and when they refuse, standing to shoot and
## marching on, the dagger when an enemy comes close, ground attacks, ammo,
## friendly fire, and the Drifter's floating.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK


func test_a_holding_archer_shoots_an_enemy_in_range_until_it_dies() -> void:
	var world: World = _world(TestTerrains.flat(80, 40), [TestUnits.ranged(&"archer"), _target(60)])
	var archer: Unit = world.spawn_unit(0, LIGHT, 10 * M, 20 * M, 1, 0)
	var enemy: Unit = world.spawn_unit(1, DARK, 40 * M, 20 * M, -1, 0)
	var launches: int = _run(world, 20 * World.TICK_RATE, ProjectileEvent.Kind.LAUNCH)
	assert_false(enemy.is_alive())
	assert_eq(archer.kills, 1, "an arrow kill counts toward veterancy")
	assert_between(launches, 4, 6, "60 hp at 18 an arrow, no misses at zero spread")


func test_an_archer_ignores_enemies_beyond_range() -> void:
	var world: World = _world(TestTerrains.flat(80, 40), [TestUnits.ranged(&"archer"), _target(60)])
	world.spawn_unit(0, LIGHT, 10 * M, 20 * M, 1, 0)
	world.spawn_unit(1, DARK, 62 * M, 20 * M, -1, 0)
	assert_eq(_run(world, 5 * World.TICK_RATE, ProjectileEvent.Kind.LAUNCH), 0)


func test_uphill_shortens_an_archers_range() -> void:
	# 45 m out: in range on the flat, not 20 m up a slope (grade 450, which
	# with uphill_range 400 cuts 50 m to about 42).
	var archer: UnitType = TestUnits.ranged(&"archer", {"uphill_range_permille": 400})
	var flat: World = _world(TestTerrains.flat(80, 40), [archer, _target(60)])
	flat.spawn_unit(0, LIGHT, 5 * M, 20 * M, 1, 0)
	flat.spawn_unit(1, DARK, 50 * M, 20 * M, -1, 0)
	assert_gt(_run(flat, 5 * World.TICK_RATE, ProjectileEvent.Kind.LAUNCH), 0, "level: in range")
	var hill: World = _world(TestTerrains.ramp_x(80, 40, 450), [archer, _target(60)])
	hill.spawn_unit(0, LIGHT, 5 * M, 20 * M, 1, 0)
	hill.spawn_unit(1, DARK, 50 * M, 20 * M, -1, 0)
	assert_eq(_run(hill, 5 * World.TICK_RATE, ProjectileEvent.Kind.LAUNCH), 0, "uphill: out of range")


func test_a_thrower_wont_throw_at_what_it_cant_reach() -> void:
	# A plateau 15 m up, 20 m out: beyond a 17.5 m/s arm by any arc.
	var world: World = _world(_plateau(80, 40, 25, 15_000), [TestUnits.thrower(&"sapper"), _target(60)])
	world.spawn_unit(0, LIGHT, 10 * M, 20 * M, 1, 0)
	world.spawn_unit(1, DARK, 30 * M, 20 * M, -1, 0)
	assert_eq(_run(world, 5 * World.TICK_RATE, ProjectileEvent.Kind.LAUNCH), 0)


func test_the_dagger_takes_over_when_an_enemy_is_adjacent() -> void:
	# No minimum range, so only the adjacency rule keeps the bow down.
	var archer: UnitType = TestUnits.ranged(&"archer", {"ranged_min_range": 0})
	var world: World = _world(TestTerrains.flat(40, 40), [archer, _target(1000)])
	var unit: Unit = world.spawn_unit(0, LIGHT, 20 * M, 20 * M, 1, 0)
	world.spawn_unit(1, DARK, 21 * M, 20 * M, -1, 0)
	var swings: int = 0
	var launches: int = 0
	for _t: int in 3 * World.TICK_RATE:
		world.step()
		for e: CombatEvent in world.combat_events:
			swings += 1 if e.kind == CombatEvent.Kind.SWING and e.attacker_id == unit.id else 0
		launches += _count(world, ProjectileEvent.Kind.LAUNCH)
	assert_gt(swings, 0, "it fights with the dagger")
	assert_eq(launches, 0, "and doesn't shoot point-blank")


func test_a_thrower_keeps_its_minimum_range_and_its_friends_out_of_the_blast() -> void:
	var types: Array[UnitType] = [TestUnits.thrower(&"sapper"), _target(1000), TestUnits.dummy(&"friend")]
	var close: World = _world(TestTerrains.flat(60, 40), types)
	close.spawn_unit(0, LIGHT, 10 * M, 20 * M, 1, 0)
	close.spawn_unit(1, DARK, 14 * M, 20 * M, -1, 0)
	assert_eq(_run(close, 5 * World.TICK_RATE, ProjectileEvent.Kind.LAUNCH), 0, "inside 5 m")
	var crowded: World = _world(TestTerrains.flat(60, 40), types)
	crowded.spawn_unit(0, LIGHT, 10 * M, 20 * M, 1, 0)
	crowded.spawn_unit(1, DARK, 22 * M, 20 * M, -1, 0)
	crowded.spawn_unit(2, LIGHT, 23 * M, 20 * M, -1, 0)
	assert_eq(_run(crowded, 5 * World.TICK_RATE, ProjectileEvent.Kind.LAUNCH), 0, "a friend next to it")
	var clear: World = _world(TestTerrains.flat(60, 40), types)
	clear.spawn_unit(0, LIGHT, 10 * M, 20 * M, 1, 0)
	clear.spawn_unit(1, DARK, 22 * M, 20 * M, -1, 0)
	assert_gt(_run(clear, 5 * World.TICK_RATE, ProjectileEvent.Kind.LAUNCH), 0, "alone: throw")


func test_archers_behind_a_friendly_line_shoot_over_it() -> void:
	# Five archers 3 m behind a line of five friends; enemies 25 m out. The
	# flat shot would go through the line, so they lob over it.
	var types: Array[UnitType] = [TestUnits.ranged(&"archer"), TestUnits.dummy(&"friend"), _target(1000)]
	var world: World = _world(TestTerrains.flat(80, 40), types)
	var friends: Array[Unit] = []
	var enemies: Array[Unit] = []
	for k: int in 5:
		var z: int = (16 + 2 * k) * M
		world.spawn_unit(0, LIGHT, 10 * M, z, 1, 0)
		friends.append(world.spawn_unit(1, LIGHT, 13 * M, z, 1, 0))
		enemies.append(world.spawn_unit(2, DARK, 35 * M, z, -1, 0))
	var launches: int = _run(world, 10 * World.TICK_RATE, ProjectileEvent.Kind.LAUNCH)
	var enemy_loss: int = 0
	for e: Unit in enemies:
		enemy_loss += e.type.max_hp - e.hp
	assert_gt(launches, 10)
	assert_gt(enemy_loss, 0, "the arrows reach the enemy")
	for f: Unit in friends:
		assert_eq(f.hp, f.type.max_hp, "and never the line in front")


func test_an_attack_mover_halts_to_shoot_and_marches_on() -> void:
	var world: World = _world(TestTerrains.flat(90, 40), [TestUnits.ranged(&"archer"), _target(36)])
	var archer: Unit = world.spawn_unit(0, LIGHT, 10 * M, 20 * M, 1, 0)
	var enemy: Unit = world.spawn_unit(1, DARK, 40 * M, 25 * M, -1, 0)
	world.enqueue(AttackMoveCommand.new(0, PackedInt32Array([archer.id]), 70 * M, 20 * M, Formations.Kind.SHORT_LINE))
	var stood_to_shoot: bool = false
	for _t: int in 40 * World.TICK_RATE:
		world.step()
		stood_to_shoot = stood_to_shoot or archer.state == Unit.State.SHOOTING
	assert_true(stood_to_shoot)
	assert_false(enemy.is_alive())
	assert_almost_eq(archer.x, 70 * M, 1500, "then reached the end of the march")
	assert_eq(archer.order, Unit.Order.NONE)


func test_a_ground_attack_in_reach_keeps_hitting_the_spot() -> void:
	var world: World = _world(TestTerrains.flat(60, 40), [TestUnits.ranged(&"archer")])
	var archer: Unit = world.spawn_unit(0, LIGHT, 10 * M, 20 * M, 1, 0)
	world.enqueue(GroundAttackCommand.new(0, PackedInt32Array([archer.id]), 30 * M, 22 * M))
	var stuck: Array[ProjectileEvent] = _collect(world, 6 * World.TICK_RATE, ProjectileEvent.Kind.STICK)
	assert_gte(stuck.size(), 3, "again and again")
	for e: ProjectileEvent in stuck:
		assert_almost_eq(e.x, 30 * M, 1000)
		assert_almost_eq(e.z, 22 * M, 1000)
	assert_eq(archer.order, Unit.Order.GROUND_ATTACK, "until told otherwise")


func test_a_ground_attack_out_of_reach_walks_into_range_first() -> void:
	var world: World = _world(TestTerrains.flat(120, 40), [TestUnits.ranged(&"archer")])
	var archer: Unit = world.spawn_unit(0, LIGHT, 10 * M, 20 * M, 1, 0)
	world.enqueue(GroundAttackCommand.new(0, PackedInt32Array([archer.id]), 90 * M, 20 * M))
	var first_from: int = -1
	for _t: int in 30 * World.TICK_RATE:
		world.step()
		if first_from < 0 and _count(world, ProjectileEvent.Kind.LAUNCH) > 0:
			first_from = archer.x
	assert_gt(first_from, 10 * M, "it walked")
	assert_gte(first_from, 90 * M - archer.type.ranged_max_range, "until in range")


func test_a_ground_attack_it_can_never_reach_is_given_up() -> void:
	# Up a 30 m cliff no one can climb: the thrower walks to the foot, still
	# can't reach, and says so.
	var world: World = _world(_plateau(80, 40, 30, 30_000), [TestUnits.thrower(&"sapper")])
	var sapper: Unit = world.spawn_unit(0, LIGHT, 10 * M, 20 * M, 1, 0)
	world.enqueue(GroundAttackCommand.new(0, PackedInt32Array([sapper.id]), 40 * M, 20 * M))
	var refused: Array[ProjectileEvent] = _collect(world, 30 * World.TICK_RATE, ProjectileEvent.Kind.CANT_REACH)
	assert_eq(refused.size(), 1)
	assert_eq(refused[0].unit_id, sapper.id)
	assert_eq(sapper.order, Unit.Order.NONE, "it holds instead")
	var inside: World = _world(TestTerrains.flat(40, 40), [TestUnits.thrower(&"sapper")])
	var s: Unit = inside.spawn_unit(0, LIGHT, 10 * M, 20 * M, 1, 0)
	inside.enqueue(GroundAttackCommand.new(0, PackedInt32Array([s.id]), 13 * M, 20 * M))
	assert_eq(_collect(inside, 3, ProjectileEvent.Kind.CANT_REACH).size(), 1, "inside its minimum range")


func test_a_ground_attack_hurts_whoever_is_there() -> void:
	var types: Array[UnitType] = [TestUnits.thrower(&"sapper", {"ranged_ammo": 1}), TestUnits.dummy(&"friend")]
	var world: World = _world(TestTerrains.flat(60, 40), types)
	var sapper: Unit = world.spawn_unit(0, LIGHT, 10 * M, 20 * M, 1, 0)
	var friend: Unit = world.spawn_unit(1, LIGHT, 20 * M, 20 * M, -1, 0)
	world.enqueue(GroundAttackCommand.new(0, PackedInt32Array([sapper.id]), 20 * M, 20 * M))
	_run(world, 8 * World.TICK_RATE, ProjectileEvent.Kind.EXPLODE)
	assert_lt(friend.hp, friend.type.max_hp, "friendly fire: the player chose the spot")


func test_a_blast_kill_is_credited_to_the_thrower() -> void:
	var types: Array[UnitType] = [TestUnits.thrower(&"sapper"), _target(20)]
	var world: World = _world(TestTerrains.flat(60, 40), types)
	var sapper: Unit = world.spawn_unit(0, LIGHT, 10 * M, 20 * M, 1, 0)
	var enemy: Unit = world.spawn_unit(1, DARK, 20 * M, 20 * M, -1, 0)
	_run(world, 10 * World.TICK_RATE, ProjectileEvent.Kind.EXPLODE)
	assert_false(enemy.is_alive())
	assert_eq(sapper.kills, 1)


func test_ammo_runs_out() -> void:
	var world: World = _world(TestTerrains.flat(60, 40), [TestUnits.ranged(&"archer", {"ranged_ammo": 3}), _target(100_000)])
	var archer: Unit = world.spawn_unit(0, LIGHT, 10 * M, 20 * M, 1, 0)
	world.spawn_unit(1, DARK, 30 * M, 20 * M, -1, 0)
	assert_eq(_run(world, 10 * World.TICK_RATE, ProjectileEvent.Kind.LAUNCH), 3)
	assert_eq(archer.ammo_left, 0)
	assert_ne(archer.state, Unit.State.SHOOTING, "it stops drawing an empty bow")


func test_veterans_shoot_tighter() -> void:
	var archer: UnitType = TestUnits.ranged(&"archer", {
		"ranged_spread_permille": 40, "veterancy_accuracy_permille": 300, "uphill_spread_permille": 800,
	})
	var world: World = _world(TestTerrains.flat(20, 20), [archer])
	var unit: Unit = world.spawn_unit(0, LIGHT, 10 * M, 10 * M, 1, 0)
	var green: int = Veterancy.ranged_spread(unit)
	unit.kills = 4
	assert_eq(green, 40)
	assert_eq(Veterancy.ranged_spread(unit), 40 * (1000 - 150) / 1000, "half the cap after four kills")
	assert_gt(RangedCombat.spread_for(unit, 10 * M, 20 * M), Veterancy.ranged_spread(unit), "wider uphill")


func test_every_live_state_can_die() -> void:
	var world: World = _world(TestTerrains.flat(20, 20), [TestUnits.ranged(&"archer")])
	for state: Unit.State in [Unit.State.IDLE, Unit.State.MOVING, Unit.State.ATTACKING, Unit.State.SHOOTING]:
		var unit: Unit = world.spawn_unit(0, LIGHT, 10 * M, 10 * M, 1, 0)
		if state != Unit.State.IDLE:
			assert_true(unit.transition_to(state))
		unit.kill()
		assert_eq(unit.state, Unit.State.DEAD, "from %s" % Unit.State.keys()[state])


func test_a_drifter_floats_over_deep_water_and_steep_slopes() -> void:
	var catalog: UnitCatalog = TestTerrains.catalog()
	var drifter: int = catalog.index_of(&"drifter")
	var heights: PackedInt32Array = PackedInt32Array()
	var water: PackedByteArray = PackedByteArray()
	var blocked: PackedByteArray = PackedByteArray()
	var n: int = 60 * 20
	heights.resize(n)
	water.resize(n)
	blocked.resize(n)
	for j: int in 20:
		for i: int in 60:
			var k: int = j * 60 + i
			if i >= 15 and i < 25:
				water[k] = 4
			# A 63 degree wall, 8 m high, from x = 35 to 39.
			heights[k] = clampi((i - 35) * 2000, 0, 8000)
	var terrain: Terrain = Terrain.new(60, 20, 1000, heights, water, blocked, 1000)
	var world: World = World.new(1, terrain, catalog)
	var unit: Unit = world.spawn_unit(drifter, DARK, 5 * M, 10 * M, 1, 0)
	assert_eq(unit.y - terrain.height_at(unit.x, unit.z), 600, "it hovers")
	world.enqueue(MoveUnitsCommand.new(0, PackedInt32Array([unit.id]), 50 * M, 10 * M, Formations.Kind.SHORT_LINE))
	for _t: int in 40 * World.TICK_RATE:
		world.step()
	assert_almost_eq(unit.x, 50 * M, 500, "across the deep water and up the wall")
	assert_eq(unit.y - terrain.height_at(unit.x, unit.z), 600, "still hovering")
	unit.kill()
	world.step()
	assert_eq(unit.y, terrain.height_at(unit.x, unit.z), "its body falls to the ground")


# --- helpers

func _world(terrain: Terrain, types: Array[UnitType]) -> World:
	return World.new(1, terrain, TestUnits.catalog(types))


# A target that stands still and never fights back, with this many hp.
func _target(hp: int) -> UnitType:
	return TestUnits.dummy(&"target_%d" % hp, {"max_hp": hp})


func _run(world: World, ticks: int, kind: ProjectileEvent.Kind) -> int:
	var n: int = 0
	for _t: int in ticks:
		world.step()
		n += _count(world, kind)
	return n


func _collect(world: World, ticks: int, kind: ProjectileEvent.Kind) -> Array[ProjectileEvent]:
	var out: Array[ProjectileEvent] = []
	for _t: int in ticks:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			if e.kind == kind:
				out.append(e)
	return out


func _count(world: World, kind: ProjectileEvent.Kind) -> int:
	var n: int = 0
	for e: ProjectileEvent in world.projectile_events:
		n += 1 if e.kind == kind else 0
	return n


# Flat ground at 0 up to x = edge_i m, then a plateau height mm high behind
# a one-cell cliff no one can climb.
func _plateau(size_x: int, size_z: int, edge_i: int, height: int) -> Terrain:
	var heights: PackedInt32Array = PackedInt32Array()
	var water: PackedByteArray = PackedByteArray()
	var blocked: PackedByteArray = PackedByteArray()
	heights.resize(size_x * size_z)
	water.resize(size_x * size_z)
	blocked.resize(size_x * size_z)
	for j: int in size_z:
		for i: int in range(edge_i, size_x):
			heights[j * size_x + i] = height
	return Terrain.new(size_x, size_z, TestTerrains.CELL, heights, water, blocked, TestTerrains.WALKABLE_SLOPE)
