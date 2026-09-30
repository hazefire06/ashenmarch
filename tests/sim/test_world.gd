extends GutTest
## Determinism contract for World: the same seed and the same command stream
## must give identical state; a different seed or stream must not.

const TICKS: int = 1000
const WORLD_SEED: int = 12345
const STREAM_SEED: int = 20260929
const INITIAL_ENTITIES: int = 20
const SPREAD: int = 50 * World.UNITS_PER_METER


func test_tick_rate_is_30() -> void:
	assert_eq(World.TICK_RATE, 30)


func test_same_seed_and_stream_identical_after_1000_ticks() -> void:
	var a: World = _run(WORLD_SEED, _build_stream(STREAM_SEED))
	var b: World = _run(WORLD_SEED, _build_stream(STREAM_SEED))

	assert_eq(a.tick, TICKS)
	assert_eq(b.tick, TICKS)
	assert_gt(a.entities.size(), 0, "stream should leave entities alive")
	assert_eq(_snapshot(a), _snapshot(b), "entity state")
	assert_eq(a.rng.state, b.rng.state, "rng state")
	assert_eq(a.state_hash(), b.state_hash(), "state hash")


func test_different_seed_diverges() -> void:
	var a: World = _run(WORLD_SEED, _build_stream(STREAM_SEED))
	var b: World = _run(WORLD_SEED + 1, _build_stream(STREAM_SEED))
	assert_ne(_snapshot(a), _snapshot(b), "seeded rng must affect entity state")
	assert_ne(a.state_hash(), b.state_hash())


func test_different_stream_diverges() -> void:
	var a: World = _run(WORLD_SEED, _build_stream(STREAM_SEED))
	var b: World = _run(WORLD_SEED, _build_stream(STREAM_SEED + 1))
	assert_ne(a.state_hash(), b.state_hash())


func test_command_applies_at_start_of_its_tick() -> void:
	var world: World = World.new(WORLD_SEED)
	world.enqueue(SpawnEntityCommand.new(0, 0, 0, 0))
	world.enqueue(SetVelocityCommand.new(5, 1, 10, 0, 0))
	for i: int in 5:
		world.step()
	assert_eq(world.get_entity(1).x, 0, "not applied before tick 5")
	world.step()
	assert_eq(world.get_entity(1).x, 10, "applied at start of tick 5, then integrated in it")


func test_same_tick_commands_apply_in_enqueue_order() -> void:
	var world: World = World.new(WORLD_SEED)
	# Velocity before spawn: entity 1 doesn't exist yet, so this is a no-op.
	world.enqueue(SetVelocityCommand.new(0, 1, 99, 0, 0))
	world.enqueue(SpawnEntityCommand.new(0, 0, 0, 0))
	world.enqueue(SetVelocityCommand.new(1, 1, 5, 0, 0))
	world.enqueue(SetVelocityCommand.new(1, 1, 7, 0, 0))
	world.step()
	assert_eq(world.get_entity(1).vx, 0)
	world.step()
	assert_eq(world.get_entity(1).vx, 7)


func test_enqueue_rejects_past_ticks() -> void:
	var world: World = World.new(WORLD_SEED)
	world.step()
	world.step()
	assert_false(world.enqueue(SpawnEntityCommand.new(1, 0, 0, 0)))
	assert_true(world.enqueue(SpawnEntityCommand.new(2, 0, 0, 0)))


func test_entity_ids_are_not_reused() -> void:
	var world: World = World.new(WORLD_SEED)
	var first: SimEntity = world.spawn_entity(0, 0, 0)
	world.despawn_entity(first.id)
	var second: SimEntity = world.spawn_entity(0, 0, 0)
	assert_ne(second.id, first.id)


func _run(world_seed: int, stream: Array[SimCommand]) -> World:
	var world: World = World.new(world_seed)
	for command: SimCommand in stream:
		assert_true(world.enqueue(command), "enqueue tick %d" % command.tick)
	for i: int in TICKS:
		world.step()
	return world


## Builds a fresh stream each call so the two worlds share no command
## instances. Mixes spawns, despawns, velocity changes, and world-RNG impulses,
## with several ticks carrying more than one command. Some commands target
## despawned ids, which exercises the no-op path.
func _build_stream(stream_seed: int) -> Array[SimCommand]:
	var gen: RandomNumberGenerator = RandomNumberGenerator.new()
	gen.seed = stream_seed
	var stream: Array[SimCommand] = []
	for i: int in INITIAL_ENTITIES:
		stream.append(_random_spawn(gen, 0))
	var last_id: int = INITIAL_ENTITIES
	for t: int in range(1, TICKS):
		if t % 10 == 0:
			var vx: int = gen.randi_range(-200, 200)
			var vz: int = gen.randi_range(-200, 200)
			stream.append(SetVelocityCommand.new(t, gen.randi_range(1, last_id), vx, 0, vz))
		if t % 7 == 0:
			stream.append(RandomImpulseCommand.new(t, gen.randi_range(1, last_id), 50))
		if t % 100 == 0:
			stream.append(_random_spawn(gen, t))
			last_id += 1
		if t % 150 == 0:
			stream.append(DespawnEntityCommand.new(t, gen.randi_range(1, last_id)))
	return stream


func _random_spawn(gen: RandomNumberGenerator, t: int) -> SpawnEntityCommand:
	var x: int = gen.randi_range(-SPREAD, SPREAD)
	var z: int = gen.randi_range(-SPREAD, SPREAD)
	return SpawnEntityCommand.new(t, x, 0, z)


func _snapshot(world: World) -> Array[PackedInt64Array]:
	var rows: Array[PackedInt64Array] = []
	for e: SimEntity in world.entities.values():
		rows.append(PackedInt64Array([e.id, e.x, e.y, e.z, e.vx, e.vy, e.vz]))
	return rows


func test_state_hash_covers_unit_fields() -> void:
	var world: World = World.new(WORLD_SEED, TestTerrains.flat(20, 20), TestTerrains.catalog())
	var unit: Unit = world.spawn_unit(0, UnitType.Faction.LIGHT, 5000, 5000, 0, -1)
	var before: String = world.state_hash()
	unit.hp -= 1
	assert_ne(world.state_hash(), before, "hp")
	unit.hp += 1
	assert_eq(world.state_hash(), before)
	unit.facing_x = 600
	assert_ne(world.state_hash(), before, "facing")


func test_despawn_removes_units_from_the_unit_list() -> void:
	var world: World = World.new(WORLD_SEED, TestTerrains.flat(20, 20), TestTerrains.catalog())
	var a: Unit = world.spawn_unit(0, UnitType.Faction.LIGHT, 5000, 5000, 0, -1)
	var b: Unit = world.spawn_unit(0, UnitType.Faction.LIGHT, 8000, 5000, 0, -1)
	world.despawn_entity(a.id)
	assert_eq(world.units, [b])
	assert_null(world.get_unit(a.id))


func test_units_spawn_on_ground_they_can_stand_on() -> void:
	var rows: Array[String] = ["..333..", "..333..", "..333.."]
	var world: World = World.new(WORLD_SEED, TestTerrains.from_ascii(rows), TestTerrains.catalog())
	var living: Unit = world.spawn_unit(0, UnitType.Faction.LIGHT, 3000, 1000, 0, -1)
	assert_true(world.terrain.is_passable(living.x, living.z, Terrain.Mobility.LIVING))
	var undead: Unit = world.spawn_unit(1, UnitType.Faction.DARK, 3000, 1000, 0, -1)
	assert_eq([undead.x, undead.z], [3000, 1000], "undead may stand in deep water")
	assert_null(world.spawn_unit(99, UnitType.Faction.LIGHT, 0, 0, 0, -1), "bad type index")
