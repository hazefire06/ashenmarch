extends GutTest
## Melee rules one at a time, on synthetic unit types so each test pins the
## stats it depends on: swing timing, committed wind-ups, damage variance,
## front/flank/rear, shields, the one-target lock, when units do and don't
## fight, attack-move, death and bodies, kill credit, and who can't be
## picked (hidden or unreachable enemies).

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const NORTH: Vector2i = Vector2i(0, -FixedMath.DIR_ONE)
const SOUTH: Vector2i = Vector2i(0, FixedMath.DIR_ONE)

## Catalog indices of the synthetic types.
const BRAWLER: int = 0
const DUMMY: int = 1
const SHIELDED: int = 2
const FRAGILE: int = 3
const LURKER: int = 4
const WADER: int = 5

var _catalog: UnitCatalog


func before_all() -> void:
	var undead_water: PackedInt32Array = PackedInt32Array([1000, 1000, 1000, 1000, 1000])
	var types: Array[UnitType] = [
		TestUnits.melee(&"brawler"),
		TestUnits.dummy(&"dummy"),
		TestUnits.dummy(&"shielded", {"shield_block_permille": 1000}),
		TestUnits.dummy(&"fragile", {"max_hp": 3}),
		TestUnits.dummy(&"lurker", {
			"nature": UnitType.Nature.UNDEAD, "mobility": Terrain.Mobility.UNDEAD,
			"water_speed_permille": undead_water, "hidden_in_deep_water": true,
		}),
		TestUnits.dummy(&"wader", {
			"nature": UnitType.Nature.UNDEAD, "mobility": Terrain.Mobility.UNDEAD,
			"water_speed_permille": undead_water,
		}),
	]
	_catalog = TestUnits.catalog(types)


func test_blow_lands_after_windup_and_repeats_every_windup_plus_cooldown() -> void:
	var world: World = _flat_world()
	var a: Unit = world.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 0, 1)
	var b: Unit = world.spawn_unit(DUMMY, DARK, 20 * M, 20_900, 0, -1)
	var record: Array[Array] = _run(world, 40)
	assert_eq(_ticks(record, CombatEvent.Kind.SWING, a), [0, 15, 30], "swing starts")
	assert_eq(_ticks(record, CombatEvent.Kind.HIT, a), [5, 20, 35], "blows land windup later")
	assert_eq(a.state, Unit.State.ATTACKING)
	assert_eq(a.target_id, b.id)


func test_target_that_steps_away_mid_windup_is_missed() -> void:
	var world: World = _flat_world()
	var a: Unit = world.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 0, 1)
	var b: Unit = world.spawn_unit(DUMMY, DARK, 20 * M, 20_900, 0, -1)
	_run(world, 2)
	assert_eq(a.windup_left, 4, "mid-swing")
	b.z += 2000
	var record: Array[Array] = _run(world, 4)
	assert_eq(_ticks(record, CombatEvent.Kind.MISS, a), [5], "the committed blow whiffs")
	assert_eq(b.hp, b.type.max_hp)


func test_damage_varies_within_ten_percent_and_is_seeded() -> void:
	var first: Array[int] = _dummy_damage(5)
	assert_eq(first.size(), 60)
	for d: int in first:
		assert_between(d, 9, 11)
	var distinct: Dictionary[int, bool] = {}
	for d: int in first:
		distinct[d] = true
	assert_gt(distinct.size(), 1, "damage varies")
	assert_eq(_dummy_damage(5), first, "same seed, same rolls")
	assert_ne(_dummy_damage(6), first, "different seed, different rolls")


func test_aspect_arcs() -> void:
	var t: UnitType = _catalog.types[DUMMY]
	var north_facing: Unit = Unit.new(1, 0, 0, 0, t, DUMMY, LIGHT)
	var cases: Array[Array] = [
		[Vector2i(0, -5000), MeleeCombat.Aspect.FRONT],
		[Vector2i(3000, -3000), MeleeCombat.Aspect.FRONT],
		[Vector2i(5000, -3000), MeleeCombat.Aspect.FRONT],  # 59 degrees off facing
		[Vector2i(5000, -2800), MeleeCombat.Aspect.FLANK],  # 61 degrees
		[Vector2i(-5000, 0), MeleeCombat.Aspect.FLANK],
		[Vector2i(5000, 2800), MeleeCombat.Aspect.FLANK],  # 119 degrees
		[Vector2i(5000, 3000), MeleeCombat.Aspect.REAR],  # 121 degrees
		[Vector2i(0, 5000), MeleeCombat.Aspect.REAR],
	]
	for c: Array in cases:
		var at: Vector2i = c[0]
		assert_eq(MeleeCombat.aspect_of(north_facing, at.x, at.y), c[1], "from %s" % at)
	var east_facing: Unit = Unit.new(2, 0, 0, 0, t, DUMMY, LIGHT)
	east_facing.facing_x = FixedMath.DIR_ONE
	east_facing.facing_z = 0
	assert_eq(MeleeCombat.aspect_of(east_facing, -5000, 0), MeleeCombat.Aspect.REAR)
	assert_eq(MeleeCombat.aspect_of(east_facing, 5000, 100), MeleeCombat.Aspect.FRONT)


func test_flank_and_rear_blows_hit_harder() -> void:
	# Three north-facing dummies, struck from the front, the east flank, and behind.
	var world: World = _flat_world()
	var front: Unit = world.spawn_unit(BRAWLER, LIGHT, 10 * M, 19_100, 0, 1)
	var flank: Unit = world.spawn_unit(BRAWLER, LIGHT, 20_900, 20 * M, -1, 0)
	var rear: Unit = world.spawn_unit(BRAWLER, LIGHT, 30 * M, 20_900, 0, -1)
	for x: int in [10, 20, 30]:
		world.spawn_unit(DUMMY, DARK, x * M, 20 * M, NORTH.x, NORTH.y)
	var record: Array[Array] = _run(world, 300)
	var expect: Array[Array] = [
		[front, MeleeCombat.Aspect.FRONT, 9, 11],
		[flank, MeleeCombat.Aspect.FLANK, 11, 13],
		[rear, MeleeCombat.Aspect.REAR, 13, 15],
	]
	for e: Array in expect:
		var hits: Array[CombatEvent] = _events(record, CombatEvent.Kind.HIT, e[0])
		assert_eq(hits.size(), 20, "every blow lands at 100% accuracy")
		for hit: CombatEvent in hits:
			assert_eq(hit.aspect, e[1])
			assert_between(hit.damage, e[2], e[3])


func test_shield_blocks_frontal_blows_only() -> void:
	var world: World = _flat_world()
	var front: Unit = world.spawn_unit(BRAWLER, LIGHT, 10 * M, 19_100, 0, 1)
	var flank: Unit = world.spawn_unit(BRAWLER, LIGHT, 20_900, 20 * M, -1, 0)
	var rear: Unit = world.spawn_unit(BRAWLER, LIGHT, 30 * M, 20_900, 0, -1)
	var shields: Array[Unit] = []
	for x: int in [10, 20, 30]:
		shields.append(world.spawn_unit(SHIELDED, DARK, x * M, 20 * M, NORTH.x, NORTH.y))
	var record: Array[Array] = _run(world, 100)
	assert_eq(_events(record, CombatEvent.Kind.BLOCK, front).size(), 7)
	assert_eq(_events(record, CombatEvent.Kind.HIT, front).size(), 0)
	assert_eq(shields[0].hp, shields[0].type.max_hp, "untouched behind its shield")
	for attacker: Unit in [flank, rear]:
		assert_eq(_events(record, CombatEvent.Kind.BLOCK, attacker).size(), 0)
		assert_eq(_events(record, CombatEvent.Kind.HIT, attacker).size(), 7)


func test_engaged_unit_keeps_its_target_while_struck_from_behind() -> void:
	var world: World = _flat_world()
	var a: Unit = world.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 0, 1)
	var b: Unit = world.spawn_unit(DUMMY, DARK, 20 * M, 20_900, 0, -1)
	_run(world, 3)
	assert_eq(a.target_id, b.id)
	var c: Unit = world.spawn_unit(BRAWLER, DARK, 20 * M, 19_100, 0, 1)
	var record: Array[Array] = []
	while a.is_alive() and world.tick < 400:
		assert_eq(a.target_id, b.id, "tick %d: still fighting the one in front" % world.tick)
		assert_eq([a.facing_x, a.facing_z], [SOUTH.x, SOUTH.y], "never turns around")
		record.append_array(_run(world, 1))
	assert_false(a.is_alive(), "the unanswered attacker behind kills it")
	var blows: Array[CombatEvent] = _events(record, CombatEvent.Kind.HIT, c)
	blows.append_array(_events(record, CombatEvent.Kind.KILL, c))
	assert_gt(blows.size(), 0)
	for blow: CombatEvent in blows:
		assert_eq(blow.aspect, MeleeCombat.Aspect.REAR)


func test_idle_unit_ignores_enemies_beyond_adjacent() -> void:
	var world: World = _flat_world()
	var a: Unit = world.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 0, 1)
	world.spawn_unit(DUMMY, DARK, 20 * M, 26 * M, 0, -1)
	var record: Array[Array] = _run(world, 60)
	assert_eq(_events(record, CombatEvent.Kind.SWING, a).size(), 0)
	assert_eq(a.state, Unit.State.IDLE)
	assert_eq([a.x, a.z], [20 * M, 20 * M], "stays put")


func test_idle_unit_steps_in_to_fight_an_enemy_just_out_of_reach() -> void:
	var world: World = _flat_world()
	var a: Unit = world.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 0, 1)
	# Edge distance 1.1 m: beyond the 0.5 m reach, within reach + slack.
	var b: Unit = world.spawn_unit(DUMMY, DARK, 20 * M, 21_900, 0, -1)
	var record: Array[Array] = _run(world, 60)
	assert_gt(_events(record, CombatEvent.Kind.HIT, a).size(), 0)
	assert_eq(a.target_id, b.id)
	assert_gt(a.z, 20 * M, "stepped toward it")
	assert_lt(a.z, 21 * M, "but only as far as needed")


func test_plain_move_ignores_enemies_then_holds() -> void:
	var world: World = _flat_world()
	var a: Unit = world.spawn_unit(BRAWLER, LIGHT, 5 * M, 20 * M, 1, 0)
	world.spawn_unit(DUMMY, DARK, 20 * M, 20_950, 0, -1)
	world.enqueue(MoveUnitsCommand.new(0, PackedInt32Array([a.id]), 35 * M, 20 * M, Formations.Kind.SHORT_LINE))
	var record: Array[Array] = []
	while world.tick < 30 * 30 and (world.tick == 0 or a.state != Unit.State.IDLE):
		record.append_array(_run(world, 1))
	assert_eq(a.state, Unit.State.IDLE, "arrived")
	assert_eq(_events(record, CombatEvent.Kind.SWING, a).size(), 0, "walked past without fighting")
	_run(world, 1)
	assert_eq(a.order, Unit.Order.NONE, "holds on arrival")
	assert_almost_eq(a.x, 35 * M, 300)


func test_attack_move_fights_on_the_way_then_resumes() -> void:
	var world: World = _flat_world()
	var a: Unit = world.spawn_unit(BRAWLER, LIGHT, 5 * M, 20 * M, 1, 0)
	var victim: Unit = world.spawn_unit(FRAGILE, DARK, 15 * M, 25 * M, 0, -1)
	world.enqueue(AttackMoveCommand.new(0, PackedInt32Array([a.id]), 35 * M, 20 * M, Formations.Kind.SHORT_LINE))
	var record: Array[Array] = _run(world, 40 * 30)
	assert_eq(_events(record, CombatEvent.Kind.KILL, a).size(), 1, "turned aside to kill it")
	assert_false(victim.is_alive())
	assert_eq(a.kills, 1)
	assert_eq(a.state, Unit.State.IDLE)
	assert_eq(a.order, Unit.Order.NONE, "the march finished")
	assert_almost_eq(a.x, 35 * M, 300)
	assert_almost_eq(a.z, 20 * M, 300)


func test_dead_body_stays_but_is_not_fought_and_does_not_block() -> void:
	var world: World = _flat_world()
	var a: Unit = world.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 0, 1)
	var body: Unit = world.spawn_unit(FRAGILE, DARK, 20 * M, 20_900, 0, -1)
	var record: Array[Array] = _run(world, 60)
	assert_eq(_events(record, CombatEvent.Kind.KILL, a).size(), 1)
	assert_eq(_events(record, CombatEvent.Kind.SWING, a).size(), 1, "no swings at the body")
	assert_eq(body.state, Unit.State.DEAD)
	assert_eq(body.hp, 0)
	assert_true(world.units.has(body), "bodies persist")
	assert_eq(world.get_unit(body.id), body)
	assert_eq([body.vx, body.vy, body.vz], [0, 0, 0])
	assert_eq(a.target_id, 0)
	# Walk to where the body lies: it doesn't push back.
	world.enqueue(MoveUnitsCommand.new(world.tick, PackedInt32Array([a.id]), body.x, body.z, 0))
	_run(world, 90)
	assert_lt(FixedMath.length(a.x - body.x, a.z - body.z), UnitMovement.ARRIVE_RADIUS + 1)


func test_kill_reports_overkill_and_credits_the_killer() -> void:
	var world: World = _flat_world()
	var a: Unit = world.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 0, 1)
	var victim: Unit = world.spawn_unit(FRAGILE, DARK, 20 * M, 20_900, 0, -1)
	var kills: Array[CombatEvent] = _events(_run(world, 10), CombatEvent.Kind.KILL, a)
	assert_eq(kills.size(), 1)
	assert_eq(kills[0].target_id, victim.id)
	assert_between(kills[0].damage, 9, 11)
	assert_eq(kills[0].overkill, kills[0].damage - 3, "3 hp left, the rest is overkill")
	assert_eq(a.kills, 1)


func test_killing_a_friend_earns_nothing() -> void:
	# Melee never picks a friend today; this pins the rule for Confusion later.
	var world: World = _flat_world()
	var a: Unit = world.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 0, 1)
	var friend: Unit = world.spawn_unit(FRAGILE, LIGHT, 20 * M, 20_900, 0, -1)
	a.target_id = friend.id
	a.windup_left = 1
	_run(world, 1)
	assert_false(friend.is_alive())
	assert_eq(a.kills, 0)


func test_enemy_hidden_in_deep_water_is_not_picked() -> void:
	var world: World = World.new(1, _bank_terrain(), _catalog)
	var a: Unit = world.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 1, 0)
	world.spawn_unit(LURKER, DARK, 21 * M, 20 * M, -1, 0)
	assert_eq(_events(_run(world, 60), CombatEvent.Kind.SWING, a).size(), 0, "can't see it")
	var seen: World = World.new(1, _bank_terrain(), _catalog)
	var b: Unit = seen.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 1, 0)
	seen.spawn_unit(WADER, DARK, 21 * M, 20 * M, -1, 0)
	assert_gt(_events(_run(seen, 60), CombatEvent.Kind.HIT, b).size(), 0, "a visible one in reach is fair game")


func test_attack_move_does_not_chase_into_water_it_cannot_enter() -> void:
	var rows: Array[String] = []
	for j: int in 40:
		rows.append(("." if j < 24 else "3").repeat(40))
	var world: World = World.new(1, TestTerrains.from_ascii(rows), _catalog)
	var a: Unit = world.spawn_unit(BRAWLER, LIGHT, 5 * M, 20 * M, 1, 0)
	var wader: Unit = world.spawn_unit(WADER, DARK, 20 * M, 27 * M, 0, -1)
	world.enqueue(AttackMoveCommand.new(0, PackedInt32Array([a.id]), 35 * M, 20 * M, Formations.Kind.SHORT_LINE))
	for t: int in 25 * 30:
		world.step()
		assert_ne(a.target_id, wader.id, "tick %d" % world.tick)
	assert_almost_eq(a.x, 35 * M, 300, "kept marching")


# --- helpers ---


func _flat_world(world_seed: int = 1) -> World:
	return World.new(world_seed, TestTerrains.flat(40, 40), _catalog)


# Dry ground for x < 21 m, depth-3 water from x = 21 m.
func _bank_terrain() -> Terrain:
	var rows: Array[String] = []
	for j: int in 40:
		rows.append(".".repeat(21) + "3".repeat(19))
	return TestTerrains.from_ascii(rows)


# Damage of every blow a brawler lands on a dummy in 30 s, for one seed.
func _dummy_damage(world_seed: int) -> Array[int]:
	var world: World = _flat_world(world_seed)
	var a: Unit = world.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 0, 1)
	world.spawn_unit(DUMMY, DARK, 20 * M, 20_900, 0, -1)
	var out: Array[int] = []
	for hit: CombatEvent in _events(_run(world, 30 * 30), CombatEvent.Kind.HIT, a):
		out.append(hit.damage)
	return out


# Steps the world, returning [tick, CombatEvent] for every event.
func _run(world: World, ticks: int) -> Array[Array]:
	var record: Array[Array] = []
	for t: int in ticks:
		var at: int = world.tick
		world.step()
		for event: CombatEvent in world.combat_events:
			record.append([at, event])
	return record


func _events(record: Array[Array], kind: CombatEvent.Kind, attacker: Unit) -> Array[CombatEvent]:
	var out: Array[CombatEvent] = []
	for entry: Array in record:
		var event: CombatEvent = entry[1]
		if event.kind == kind and event.attacker_id == attacker.id:
			out.append(event)
	return out


func _ticks(record: Array[Array], kind: CombatEvent.Kind, attacker: Unit) -> Array[int]:
	var out: Array[int] = []
	for entry: Array in record:
		var event: CombatEvent = entry[1]
		if event.kind == kind and event.attacker_id == attacker.id:
			out.append(entry[0])
	return out
