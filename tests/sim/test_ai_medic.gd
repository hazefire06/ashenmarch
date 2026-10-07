extends GutTest
## MEDIC (a Warden under the AI): it heals the most wounded friend near it
## below 60% health, between fights too; kills an undead enemy that comes
## close with a herb; doesn't send two medics to one patient; stands behind
## the group in a fight; and once out of herbs fights like anyone. Groups are
## spawned from specs in ADVANCE on flat ground, the way a skirmish
## commander's are.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

## Catalog indices of the synthetic types.
const GRUNT: int = 0
const HEALER: int = 1
const GHOUL: int = 2
const TARGET: int = 3

var _catalog: UnitCatalog


func before_all() -> void:
	_catalog = TestUnits.catalog([
		TestUnits.melee(&"grunt"),
		TestUnits.healer(&"healer", {"ai_tactic": UnitType.AiTactic.MEDIC}),
		TestUnits.undead(&"ghoul"),
		TestUnits.dummy(&"target"),
	])


func _world() -> World:
	return World.new(1, TestTerrains.flat(80, 80), _catalog)


func _group(world: World, grunts: int, healers: int, x: int = 40, z: int = 40) -> AiGroup:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = &"army"
	for pair: Array in [[&"grunt", grunts], [&"healer", healers]]:
		if pair[1] == 0:
			continue
		var e: AiUnitEntry = AiUnitEntry.new()
		e.type_id = pair[0]
		e.counts = PackedInt32Array([pair[1]])
		g.units.append(e)
	g.spawns = PackedInt32Array([x * M, z * M])
	g.behavior = AiGroupSpec.Behavior.ADVANCE
	g.guard_radius = 20 * M
	g.ranged_behind = true
	assert_eq(g.validate(_catalog), PackedStringArray())
	return world.ai.spawn_group(world, g, 0, 0)


func _of(world: World, group: AiGroup, type_index: int) -> Array[Unit]:
	var out: Array[Unit] = []
	for unit: Unit in group.living(world):
		if unit.type_index == type_index:
			out.append(unit)
	return out


func _run(world: World, ticks: int) -> Array[AiEvent]:
	var events: Array[AiEvent] = []
	for _t: int in ticks:
		world.step()
		events.append_array(world.ai_events)
	return events


func _heals(events: Array[AiEvent]) -> Array[AiEvent]:
	return events.filter(func(e: AiEvent) -> bool: return e.kind == AiEvent.Kind.HEAL)


func test_it_heals_the_most_wounded_friend_below_the_line() -> void:
	var w: World = _world()
	var g: AiGroup = _group(w, 3, 1)
	var grunts: Array[Unit] = _of(w, g, GRUNT)
	grunts[0].hp = 50
	grunts[1].hp = 30
	grunts[2].hp = 70
	var healer: Unit = _of(w, g, HEALER)[0]
	var first: Array[AiEvent] = _heals(_run(w, 20))
	assert_eq(first.size(), 1)
	assert_eq(first[0].value, grunts[1].id, "the one at 30% first")
	assert_eq(first[0].unit_id, healer.id)
	var rest: Array[AiEvent] = _heals(_run(w, 600))
	assert_eq(rest.size(), 1, "then one more")
	assert_eq(rest[0].value, grunts[0].id, "the one at 50%")
	assert_gt(grunts[1].hp, 30, "healed")
	assert_gt(grunts[0].hp, 50, "healed")
	assert_eq(grunts[2].hp, 70, "70% isn't worth a herb")
	assert_eq(healer.special_left, 4, "two herbs spent")


func test_two_medics_dont_go_to_one_patient() -> void:
	var w: World = _world()
	var g: AiGroup = _group(w, 2, 2)
	var grunts: Array[Unit] = _of(w, g, GRUNT)
	grunts[0].hp = 20
	grunts[1].hp = 40
	var heals: Array[AiEvent] = _heals(_run(w, 20))
	assert_eq(heals.size(), 2)
	assert_ne(heals[0].value, heals[1].value)


func test_it_kills_an_undead_enemy_that_comes_close() -> void:
	var w: World = _world()
	var g: AiGroup = _group(w, 0, 1)
	var healer: Unit = _of(w, g, HEALER)[0]
	var ghoul: Unit = w.spawn_unit(GHOUL, LIGHT, healer.x + 5 * M, healer.z, -1, 0)
	var far: Unit = w.spawn_unit(GHOUL, LIGHT, healer.x + 30 * M, healer.z, -1, 0)
	var heals: Array[AiEvent] = _heals(_run(w, 20))
	assert_eq(heals.size(), 1)
	assert_eq(heals[0].value, ghoul.id)
	_run(w, 120)
	assert_false(ghoul.is_alive(), "a herb kills the undead")
	assert_true(far.is_alive(), "30 m off is out of its reach")


func test_it_stands_behind_the_fight() -> void:
	var w: World = _world()
	var g: AiGroup = _group(w, 4, 1, 40, 40)
	var foe: Unit = w.spawn_unit(TARGET, LIGHT, 40 * M, 52 * M, 0, -1)
	_run(w, 300)
	var healer: Unit = _of(w, g, HEALER)[0]
	assert_eq(healer.target_id, 0, "it doesn't fight")
	var nearest_grunt: int = 1 << 40
	for unit: Unit in _of(w, g, GRUNT):
		nearest_grunt = mini(nearest_grunt, FixedMath.length(unit.x - foe.x, unit.z - foe.z))
	assert_gt(FixedMath.length(healer.x - foe.x, healer.z - foe.z), nearest_grunt, "behind the melee")


func test_out_of_herbs_it_fights() -> void:
	var w: World = _world()
	var g: AiGroup = _group(w, 0, 1)
	var healer: Unit = _of(w, g, HEALER)[0]
	healer.special_left = 0
	var foe: Unit = w.spawn_unit(TARGET, LIGHT, healer.x + 10 * M, healer.z, -1, 0)
	_run(w, 40)
	assert_eq(g.ordered_target[g.member_index(healer.id)], foe.id, "sent after the enemy like any fighter")


func test_a_medic_in_a_mission_group_still_heals() -> void:
	# A Phase 7 group (ranged_behind off, here a HUNT): the errand works there
	# too through engage, and the healer isn't kept back.
	var w: World = _world()
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = &"pack"
	var e: AiUnitEntry = AiUnitEntry.new()
	e.type_id = &"healer"
	e.counts = PackedInt32Array([1])
	g.units.append(e)
	var e2: AiUnitEntry = AiUnitEntry.new()
	e2.type_id = &"grunt"
	e2.counts = PackedInt32Array([1])
	g.units.append(e2)
	g.spawns = PackedInt32Array([40 * M, 40 * M])
	g.behavior = AiGroupSpec.Behavior.HUNT
	var group: AiGroup = w.ai.spawn_group(w, g, 0, 0)
	var grunt: Unit = _of(w, group, GRUNT)[0]
	grunt.hp = 10
	w.spawn_unit(TARGET, LIGHT, 40 * M, 70 * M, 0, -1)
	assert_false(AiTactics.is_back(group, _of(w, group, HEALER)[0]))
	assert_eq(_heals(_run(w, 20)).size(), 1)
