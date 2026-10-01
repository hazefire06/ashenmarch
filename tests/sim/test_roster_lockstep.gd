extends GutTest
## Lockstep with the whole v1 roster at the Riverside ford: two worlds fed
## the same seed and the same commands stay hash-identical through status
## effects, errands, herbs and herb plants, gas, lightning, and Rippers
## scavenging and throwing; a different seed fights differently. Also the
## cost per tick, for docs/architecture.md.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const TICKS: int = 1500

var _terrain: Terrain
var _catalog: UnitCatalog


func before_all() -> void:
	_terrain = TestTerrains.riverside()
	_catalog = TestTerrains.catalog()


func test_the_whole_roster_stays_in_lockstep() -> void:
	var a: World = _battle(21)
	var b: World = _battle(21)
	var seen: Dictionary[String, int] = {}
	var mismatches: Array[int] = []
	var started: int = Time.get_ticks_usec()
	var worst_us: int = 0
	for t: int in TICKS:
		var tick_started: int = Time.get_ticks_usec()
		a.step()
		if t > 0:
			# Tick 0 builds the pathing layers for three mobilities.
			worst_us = maxi(worst_us, Time.get_ticks_usec() - tick_started)
		b.step()
		_tally(a, seen)
		if (t + 1) % 150 == 0 and a.state_hash() != b.state_hash():
			mismatches.append(t + 1)
	var alive: Array[int] = [0, 0]
	for unit: Unit in a.units:
		if unit.is_alive():
			alive[unit.faction] += 1
	gut.p("%s; light %d / dark %d alive; %.2f ms/tick per world, worst %.1f ms" % [
		seen, alive[0], alive[1], (Time.get_ticks_usec() - started) / 1000.0 / (2 * TICKS), worst_us / 1000.0,
	])
	assert_eq(mismatches.size(), 0, "hashes differ at ticks %s" % [mismatches])
	assert_eq(a.state_hash(), b.state_hash())
	for what: String in ["bolt", "blight burst", "cloud", "pick-up", "heal", "paralyzed", "plant struck"]:
		assert_gt(seen.get(what, 0), 0, "the battle had a %s" % what)


func test_a_different_seed_fights_differently() -> void:
	var a: World = _battle(21)
	var c: World = _battle(22)
	for _t: int in 600:
		a.step()
		c.step()
	assert_ne(a.state_hash(), c.state_hash())


# Light holds the north bank by the ford: Shieldmen and Reavers in front,
# Longbows, Sappers (who mine the bank), and Wardens behind, a herb plant
# beside them. Dark comes across: Husks, Rippers, and Blightbags
# attack-move over the ford, Drifters behind them, and the Stormcallers off
# to the west flank, where their lines to the Light bank aren't through
# their own side (they won't cast through friends). The Wardens
# strike the plant, heal the wounded in the line, and two Shieldmen are
# confused for a while.
func _battle(world_seed: int) -> World:
	var world: World = World.new(world_seed, _terrain, _catalog)
	var ids: Dictionary[StringName, PackedInt32Array] = {}
	var next_id: Array[int] = [1]
	var spawn: Callable = func(type_id: StringName, side: UnitType.Faction, x: int, z: int) -> void:
		world.enqueue(SpawnUnitCommand.new(0, type_id, side, x * M, z * M))
		if not ids.has(type_id):
			ids[type_id] = PackedInt32Array()
		ids[type_id].append(next_id[0])
		next_id[0] += 1
	for i: int in 10:
		spawn.call(&"shieldman", LIGHT, 290 + (i % 5) * 2, 196 + (i / 5) * 2)
	for i: int in 3:
		spawn.call(&"reaver", LIGHT, 292 + i * 2, 194)
	for i: int in 4:
		spawn.call(&"longbow", LIGHT, 290 + i * 2, 189)
	for i: int in 2:
		spawn.call(&"sapper", LIGHT, 293 + i * 3, 186)
	for i: int in 3:
		spawn.call(&"warden", LIGHT, 291 + i * 3, 191)
	for i: int in 8:
		spawn.call(&"husk", DARK, 286 + (i % 4) * 3, 240 + (i / 4) * 3)
	for i: int in 4:
		spawn.call(&"ripper", DARK, 287 + i * 3, 248)
	for i: int in 3:
		spawn.call(&"blightbag", DARK, 290 + i * 3, 232)
	for i: int in 3:
		spawn.call(&"drifter", DARK, 286 + i * 4, 252)
	for i: int in 2:
		spawn.call(&"stormcaller", DARK, 268 + i * 5, 236)
	# The plant's id comes after every unit's.
	world.enqueue(SpawnHerbPlantCommand.new(0, 302 * M, 190 * M))
	var plant_id: int = next_id[0]
	var line: PackedInt32Array = ids[&"shieldman"].duplicate()
	line.append_array(ids[&"reaver"])
	var dark: PackedInt32Array = ids[&"husk"].duplicate()
	dark.append_array(ids[&"ripper"])
	dark.append_array(ids[&"blightbag"])
	world.enqueue(UseSpecialCommand.new(1, ids[&"sapper"]))
	world.enqueue(InteractCommand.new(2, ids[&"warden"], plant_id))
	world.enqueue(AttackMoveCommand.new(1, dark, 295 * M, 200 * M, Formations.Kind.RABBLE))
	world.enqueue(AttackMoveCommand.new(1, ids[&"drifter"], 295 * M, 215 * M, Formations.Kind.LOOSE_LINE))
	world.enqueue(AttackMoveCommand.new(1, ids[&"stormcaller"], 272 * M, 222 * M, Formations.Kind.LOOSE_LINE))
	world.enqueue(GroundAttackCommand.new(60, ids[&"sapper"], 296 * M, 225 * M))
	world.enqueue(ApplyStatusCommand.new(
		300, PackedInt32Array([line[0], line[1]]), StatusEffects.Kind.CONFUSION, 150
	))
	# Every few seconds the Wardens heal one of the line in turn (refused if
	# it is unhurt or dead).
	for k: int in 12:
		world.enqueue(HealCommand.new(360 + k * 90, ids[&"warden"], line[k % line.size()]))
	return world


func _tally(world: World, seen: Dictionary[String, int]) -> void:
	var burst: int = world.catalog.projectile_index_of(&"blight_burst")
	for e: ProjectileEvent in world.projectile_events:
		match e.kind:
			ProjectileEvent.Kind.BOLT:
				_add(seen, "bolt")
			ProjectileEvent.Kind.PICK_UP:
				_add(seen, "pick-up")
			ProjectileEvent.Kind.EXPLODE:
				if e.type_index == burst:
					_add(seen, "blight burst")
	for e: CombatEvent in world.combat_events:
		if e.kind == CombatEvent.Kind.HEAL:
			_add(seen, "heal")
	if not world.clouds.is_empty():
		_add(seen, "cloud")
	for unit: Unit in world.units:
		if StatusEffects.paralyzed(world, unit):
			_add(seen, "paralyzed")
			break
	for plant: HerbPlant in world.herb_plants:
		if plant.spent and not seen.has("plant struck"):
			_add(seen, "plant struck")


func _add(seen: Dictionary[String, int], what: String) -> void:
	seen[what] = seen.get(what, 0) + 1
