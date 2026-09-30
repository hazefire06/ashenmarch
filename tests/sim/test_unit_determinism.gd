extends GutTest
## Lockstep contract for units: two Riverside worlds fed the same spawns and
## the same stream of move orders (random groups, targets, and formations,
## including creek crossings that need A*) stay hash-identical every tick
## checked, and a different stream diverges.

const TICKS: int = 600
const CHECK_EVERY: int = 100
const ORDER_EVERY: int = 20
const STREAM_SEED: int = 777
const M: int = 1000

var _terrain: Terrain
var _catalog: UnitCatalog


func before_all() -> void:
	_terrain = TestTerrains.riverside()
	_catalog = TestTerrains.catalog()


func test_same_stream_gives_identical_hashes() -> void:
	var a: World = _world(_stream(STREAM_SEED))
	var b: World = _world(_stream(STREAM_SEED))
	var started: int = Time.get_ticks_usec()
	var mismatches: Array[int] = []
	for t: int in TICKS:
		a.step()
		b.step()
		if (t + 1) % CHECK_EVERY == 0 and a.state_hash() != b.state_hash():
			mismatches.append(t + 1)
	gut.p("%d ticks x 2 worlds, 40 units: %d ms" % [TICKS, (Time.get_ticks_usec() - started) / 1000])
	assert_eq(a.units.size(), 40)
	assert_eq(mismatches.size(), 0, "hashes differ at ticks %s" % [mismatches])
	var moved: int = 0
	for u: Unit in a.units:
		if u.state == Unit.State.MOVING or u.goal_x != 0:
			moved += 1
	assert_gt(moved, 20, "the stream must actually move units")


func test_different_stream_diverges() -> void:
	var a: World = _world(_stream(STREAM_SEED))
	var b: World = _world(_stream(STREAM_SEED + 1))
	for t: int in 200:
		a.step()
		b.step()
	assert_ne(a.state_hash(), b.state_hash())


func _world(stream: Array[SimCommand]) -> World:
	var world: World = World.new(1, _terrain, _catalog)
	for command: SimCommand in stream:
		assert_true(world.enqueue(command))
	return world


## 20 Shieldmen north of the creek near the ford, 20 Husks south of it, then
## a move order every ORDER_EVERY ticks for a random subset of one side to a
## random point within 80 m of the ford, in a random formation.
func _stream(stream_seed: int) -> Array[SimCommand]:
	var gen: RandomNumberGenerator = RandomNumberGenerator.new()
	gen.seed = stream_seed
	var stream: Array[SimCommand] = []
	for i: int in 20:
		stream.append(SpawnUnitCommand.new(
			0, &"shieldman", UnitType.Faction.LIGHT, (290 + (i % 5) * 2) * M, (185 + (i / 5) * 2) * M
		))
	for i: int in 20:
		stream.append(SpawnUnitCommand.new(
			0, &"husk", UnitType.Faction.DARK, (250 + (i % 5) * 2) * M, (275 + (i / 5) * 2) * M
		))
	for t: int in range(ORDER_EVERY, TICKS, ORDER_EVERY):
		var first: int = 1 if gen.randi_range(0, 1) == 0 else 21
		var ids: PackedInt32Array = PackedInt32Array()
		for k: int in 20:
			if gen.randi_range(0, 2) > 0:
				ids.append(first + k)
		var x: int = gen.randi_range(220, 380) * M
		var z: int = gen.randi_range(150, 310) * M
		stream.append(MoveUnitsCommand.new(t, ids, x, z, gen.randi_range(0, Formations.Kind.size() - 1)))
	return stream
