extends GutTest
## Lockstep with projectiles in the air: two worlds fed the same seed and the
## same commands land every arrow and grenade in the same place and end in
## the same state; a different seed lands them differently. Riverside, the
## shipped units, archers and throwers with their real spread, ground
## attacks, satchels, fuses, fizzles, blasts, and craters.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const TICKS: int = 900

var _terrain: Terrain
var _catalog: UnitCatalog


func before_all() -> void:
	_terrain = TestTerrains.riverside()
	_catalog = TestTerrains.catalog()


func test_same_seed_same_landings_and_state() -> void:
	var a: World = _battle(11)
	var b: World = _battle(11)
	var landings_a: PackedInt64Array = PackedInt64Array()
	var landings_b: PackedInt64Array = PackedInt64Array()
	var mismatches: Array[int] = []
	var started: int = Time.get_ticks_usec()
	for t: int in TICKS:
		a.step()
		b.step()
		_record(a, landings_a)
		_record(b, landings_b)
		if (t + 1) % 150 == 0 and a.state_hash() != b.state_hash():
			mismatches.append(t + 1)
	gut.p("%d landings, %d fire marks, %d scarred samples; %.2f ms/tick per world" % [
		landings_a.size() / 4, a.fire_marks.size() / 3, a.terrain.scars.size(),
		(Time.get_ticks_usec() - started) / 1000.0 / (2 * TICKS),
	])
	assert_gt(landings_a.size() / 4, 50, "plenty landed")
	assert_gt(a.terrain.scars.size(), 0, "and dug craters")
	assert_eq(landings_a, landings_b, "every landing in the same place")
	assert_eq(mismatches.size(), 0, "hashes differ at ticks %s" % [mismatches])


func test_a_different_seed_lands_differently() -> void:
	var a: World = _battle(11)
	var c: World = _battle(12)
	var landings_a: PackedInt64Array = PackedInt64Array()
	var landings_c: PackedInt64Array = PackedInt64Array()
	for _t: int in TICKS:
		a.step()
		c.step()
		_record(a, landings_a)
		_record(c, landings_c)
	assert_false(landings_a.is_empty())
	assert_ne(landings_a, landings_c)
	assert_ne(a.state_hash(), c.state_hash())


# The Phase 3 ford battle with ranged units on both sides: Longbows and
# Sappers behind the Shieldmen, Drifters behind the Husks. Sappers mine the
# ford and bombard it; everyone else attack-moves.
func _battle(world_seed: int) -> World:
	var world: World = World.new(world_seed, _terrain, _catalog)
	var light: PackedInt32Array = PackedInt32Array()
	var archers: PackedInt32Array = PackedInt32Array()
	var sappers: PackedInt32Array = PackedInt32Array()
	var dark: PackedInt32Array = PackedInt32Array()
	var id: int = 1
	for i: int in 10:
		world.enqueue(SpawnUnitCommand.new(0, &"shieldman", LIGHT, (290 + (i % 5) * 2) * M, (190 + (i / 5) * 2) * M))
		light.append(id)
		id += 1
	for i: int in 6:
		world.enqueue(SpawnUnitCommand.new(0, &"longbow", LIGHT, (289 + i * 2) * M, 184 * M))
		archers.append(id)
		id += 1
	for i: int in 3:
		world.enqueue(SpawnUnitCommand.new(0, &"sapper", LIGHT, (292 + i * 3) * M, 181 * M))
		sappers.append(id)
		id += 1
	for i: int in 15:
		var type_id: StringName = &"husk" if i < 10 else &"drifter"
		world.enqueue(SpawnUnitCommand.new(0, type_id, DARK, (285 + (i % 5) * 3) * M, (262 + (i / 5) * 3) * M))
		dark.append(id)
		id += 1
	world.enqueue(UseSpecialCommand.new(1, sappers))
	world.enqueue(AttackMoveCommand.new(1, dark, 295 * M, 195 * M, Formations.Kind.RABBLE))
	world.enqueue(AttackMoveCommand.new(90, light, 295 * M, 215 * M, Formations.Kind.SHORT_LINE))
	world.enqueue(GroundAttackCommand.new(60, sappers, 297 * M, 225 * M))
	world.enqueue(UseSpecialCommand.new(120, archers))
	return world


# Appends every landing this tick: where arrows stuck, grenades first
# touched down, and blasts went off, with the tick.
func _record(world: World, out: PackedInt64Array) -> void:
	for e: ProjectileEvent in world.projectile_events:
		if e.kind == ProjectileEvent.Kind.STICK or e.kind == ProjectileEvent.Kind.EXPLODE or e.kind == ProjectileEvent.Kind.BOUNCE:
			out.append_array(PackedInt64Array([world.tick, e.x, e.y, e.z]))
