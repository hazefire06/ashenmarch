extends GutTest
## Whole fights with the shipped unit data, each on several seeds so a result
## can't pass on one lucky roll:
## - 10 Shieldmen holding a line beat 10 Husks attacking it.
## - 10 Husks surrounding 5 Shieldmen kill them all.
## - Control: the same 5 Shieldmen holding a gap against the same 10 Husks
##   win. Same units, same numbers; only the geometry changed. Numbers alone
##   would predict the Husks win both, so this is what shows flanking matters.
## - The same seed and orders give the same fight, tick for tick.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const SEEDS: Array[int] = [1, 2, 3, 4, 5]
const MAX_TICKS: int = 90 * World.TICK_RATE

var _catalog: UnitCatalog
var _shieldman: int
var _husk: int


func before_all() -> void:
	_catalog = TestTerrains.catalog()
	_shieldman = _catalog.index_of(&"shieldman")
	_husk = _catalog.index_of(&"husk")


func test_shieldman_line_beats_as_many_husks() -> void:
	for s: int in SEEDS:
		var world: World = _line(s)
		var ticks: int = _fight(world)
		gut.p(_report("line", s, world, ticks))
		assert_eq(_alive(world, DARK), 0, "seed %d: every Husk dead" % s)
		assert_gt(_alive(world, LIGHT), 5, "seed %d: the line holds" % s)


func test_husks_surrounding_half_as_many_shieldmen_win() -> void:
	for s: int in SEEDS:
		var world: World = _surround(s)
		var ticks: int = _fight(world)
		gut.p(_report("surround", s, world, ticks))
		assert_eq(_alive(world, LIGHT), 0, "seed %d: every Shieldman dead" % s)
		assert_gt(_alive(world, DARK), 0, "seed %d" % s)


func test_same_shieldmen_holding_a_gap_beat_the_same_husks() -> void:
	for s: int in SEEDS:
		var world: World = _gap(s)
		var ticks: int = _fight(world)
		gut.p(_report("gap", s, world, ticks))
		assert_eq(_alive(world, DARK), 0, "seed %d: every Husk dead" % s)
		assert_gt(_alive(world, LIGHT), 0, "seed %d" % s)


func test_surround_needs_flank_blows() -> void:
	# In the surround most blows on Shieldmen come from the side or behind;
	# in the line almost all come from the front.
	var line_share: int = _off_front_permille(_line(1), LIGHT)
	var surround_share: int = _off_front_permille(_surround(1), LIGHT)
	gut.p("blows on Shieldmen from flank or rear: line %d permille, surround %d permille" % [line_share, surround_share])
	assert_lt(line_share, 250)
	assert_gt(surround_share, 400)


func test_same_seed_same_fight() -> void:
	var a: World = _surround(3)
	var b: World = _surround(3)
	var mismatches: Array[int] = []
	for t: int in 30 * World.TICK_RATE:
		a.step()
		b.step()
		if (t + 1) % 100 == 0 and a.state_hash() != b.state_hash():
			mismatches.append(t + 1)
	assert_eq(mismatches.size(), 0, "hashes differ at ticks %s" % [mismatches])
	assert_eq(_alive(a, LIGHT) + _alive(a, DARK), _alive(b, LIGHT) + _alive(b, DARK))
	var c: World = _surround(4)
	for t: int in 30 * World.TICK_RATE:
		c.step()
	assert_ne(a.state_hash(), c.state_hash(), "a different seed rolls a different fight")


func test_riverside_melee_stream_is_lockstep_safe() -> void:
	# Both sides attack-move across the ford at each other: A* chases, water,
	# slopes, and deaths, all under the lockstep contract.
	var terrain: Terrain = TestTerrains.riverside()
	var worlds: Array[World] = [World.new(9, terrain, _catalog), World.new(9, terrain, _catalog)]
	for world: World in worlds:
		var light: PackedInt32Array = PackedInt32Array()
		var dark: PackedInt32Array = PackedInt32Array()
		for i: int in 20:
			var type_id: StringName = &"shieldman" if i < 15 else &"reaver"
			world.enqueue(SpawnUnitCommand.new(0, type_id, LIGHT, (290 + (i % 5) * 2) * M, (185 + (i / 5) * 2) * M))
			light.append(i + 1)
		for i: int in 20:
			var type_id: StringName = &"husk" if i < 15 else &"ripper"
			world.enqueue(SpawnUnitCommand.new(0, type_id, DARK, (250 + (i % 5) * 2) * M, (275 + (i / 5) * 2) * M))
			dark.append(i + 21)
		world.enqueue(AttackMoveCommand.new(1, light, 255 * M, 280 * M, Formations.Kind.SHORT_LINE))
		world.enqueue(AttackMoveCommand.new(1, dark, 295 * M, 190 * M, Formations.Kind.RABBLE))
	var started: int = Time.get_ticks_usec()
	var mismatches: Array[int] = []
	for t: int in 60 * World.TICK_RATE:
		worlds[0].step()
		worlds[1].step()
		if (t + 1) % 150 == 0 and worlds[0].state_hash() != worlds[1].state_hash():
			mismatches.append(t + 1)
	var dead: int = 40 - _alive(worlds[0], LIGHT) - _alive(worlds[0], DARK)
	gut.p("riverside: %d dead after 60 s; %.2f ms/tick per world" % [
		dead, (Time.get_ticks_usec() - started) / 1000.0 / (2 * 60 * World.TICK_RATE)
	])
	assert_eq(mismatches.size(), 0, "hashes differ at ticks %s" % [mismatches])
	assert_gt(dead, 0, "the armies actually met and fought")


# 10 Shieldmen hold a line; 10 Husks 12 m away attack-move through it.
func _line(world_seed: int) -> World:
	var world: World = World.new(world_seed, TestTerrains.flat(80, 80), _catalog)
	var husks: PackedInt32Array = PackedInt32Array()
	for i: int in 10:
		world.spawn_unit(_shieldman, LIGHT, 33 * M + i * 1400, 30 * M, 0, 1)
		husks.append(world.spawn_unit(_husk, DARK, 33 * M + i * 1400, 42 * M, 0, -1).id)
	world.enqueue(AttackMoveCommand.new(0, husks, 39_300, 26 * M, Formations.Kind.SHORT_LINE))
	return world


# 5 Shieldmen in a cross, facing out; 10 Husks on a 9 m ring close in.
func _surround(world_seed: int) -> World:
	var world: World = World.new(world_seed, TestTerrains.flat(80, 80), _catalog)
	var offsets: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(1400, 0), Vector2i(-1400, 0), Vector2i(0, 1400), Vector2i(0, -1400),
	]
	for o: Vector2i in offsets:
		var face: Vector2i = o if o != Vector2i.ZERO else Vector2i(0, 1)
		world.spawn_unit(_shieldman, LIGHT, 40 * M + o.x, 40 * M + o.y, face.x, face.y)
	var husks: PackedInt32Array = PackedInt32Array()
	for i: int in 10:
		var angle: int = i * FixedMath.ANGLE_FULL / 10
		var x: int = 40 * M + FixedMath.cos_b(angle) * 9000 / FixedMath.TRIG_ONE
		var z: int = 40 * M + FixedMath.sin_b(angle) * 9000 / FixedMath.TRIG_ONE
		husks.append(world.spawn_unit(_husk, DARK, x, z, 40 * M - x, 40 * M - z).id)
	world.enqueue(AttackMoveCommand.new(0, husks, 40 * M, 40 * M, Formations.Kind.CIRCLE))
	return world


# A 4 m thick wall across the map with a 7 m gap. 5 Shieldmen fill the gap;
# 10 Husks attack-move through it from the south.
func _gap(world_seed: int) -> World:
	var rows: Array[String] = []
	for j: int in 60:
		if j >= 27 and j <= 30:
			rows.append("#".repeat(27) + ".".repeat(7) + "#".repeat(26))
		else:
			rows.append(".".repeat(60))
	var world: World = World.new(world_seed, TestTerrains.from_ascii(rows), _catalog)
	var husks: PackedInt32Array = PackedInt32Array()
	for i: int in 5:
		world.spawn_unit(_shieldman, LIGHT, 27_200 + i * 1400, 29_500, 0, 1)
	for i: int in 10:
		husks.append(world.spawn_unit(_husk, DARK, 25 * M + (i % 5) * 2 * M, 42 * M + (i / 5) * 2 * M, 0, -1).id)
	world.enqueue(AttackMoveCommand.new(0, husks, 30 * M, 15 * M, Formations.Kind.BOX))
	return world


# Runs until one side is wiped out or MAX_TICKS; returns ticks run.
func _fight(world: World) -> int:
	var t: int = 0
	while t < MAX_TICKS and _alive(world, LIGHT) > 0 and _alive(world, DARK) > 0:
		world.step()
		t += 1
	return t


# Permille of blows landing on side that came from the flank or rear.
func _off_front_permille(world: World, side: UnitType.Faction) -> int:
	var total: int = 0
	var off_front: int = 0
	while world.tick < MAX_TICKS and _alive(world, LIGHT) > 0 and _alive(world, DARK) > 0:
		world.step()
		for event: CombatEvent in world.combat_events:
			if event.kind != CombatEvent.Kind.HIT and event.kind != CombatEvent.Kind.KILL:
				continue
			if world.get_unit(event.target_id).faction != side:
				continue
			total += 1
			if event.aspect != MeleeCombat.Aspect.FRONT:
				off_front += 1
	return off_front * 1000 / maxi(total, 1)


func _alive(world: World, side: UnitType.Faction) -> int:
	var n: int = 0
	for u: Unit in world.units:
		if u.is_alive() and u.faction == side:
			n += 1
	return n


func _report(scenario: String, world_seed: int, world: World, ticks: int) -> String:
	return "%s seed %d: %d Light, %d Dark left after %.1f s" % [
		scenario, world_seed, _alive(world, LIGHT), _alive(world, DARK), float(ticks) / World.TICK_RATE
	]
