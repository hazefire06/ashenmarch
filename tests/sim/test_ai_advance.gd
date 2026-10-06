extends GutTest
## ADVANCE, the behavior a skirmish commander drives (AiDirector.advance): a
## group marches to its anchor and holds it, fights visible enemies within
## its engage radius, never pulls a member out of a fight, starts a new march
## only for a move that matters, and walks back when nobody is left inside the
## hold radius. And ranged_behind: a commander's group keeps its ranged and
## support behind its melee, while a mission's group (the flag off) acts as
## it always has. Groups are spawned straight from specs on flat ground.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const ADVANCE: AiGroupSpec.Behavior = AiGroupSpec.Behavior.ADVANCE

## Catalog indices of the synthetic types.
const GRUNT: int = 0
const TARGET: int = 1
const ARCHER: int = 2
const CASTER: int = 3

## Most ORDER events a group may emit over 900 ticks while its anchor is
## nudged by under REORDER_MIN every second.
const JITTER_ORDER_BOUND: int = 6

var _catalog: UnitCatalog


func before_all() -> void:
	_catalog = TestUnits.catalog([
		TestUnits.melee(&"grunt"),
		TestUnits.dummy(&"target"),
		TestUnits.ranged(&"archer"),
		TestUnits.caster(&"caster", {"ai_tactic": UnitType.AiTactic.STANDOFF, "ai_standoff_permille": 900}),
	])


func _world() -> World:
	return World.new(1, TestTerrains.flat(100, 100), _catalog)


## A DARK group of [[type_id, count], ...] at (x, z) m facing south, in
## ADVANCE with engage radius `radius` m.
func _group(world: World, entries: Array, x: int, z: int, ranged_behind: bool = true, radius: int = 20) -> AiGroup:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = &"army"
	for pair: Array in entries:
		var e: AiUnitEntry = AiUnitEntry.new()
		e.type_id = pair[0]
		e.counts = PackedInt32Array([pair[1]])
		g.units.append(e)
	g.spawns = PackedInt32Array([x * M, z * M])
	g.facing_z = 1
	g.behavior = ADVANCE
	g.guard_radius = radius * M
	g.ranged_behind = ranged_behind
	assert_eq(g.validate(_catalog), PackedStringArray(), "the spec is valid")
	return world.ai.spawn_group(world, g, 0, 0)


func _run(world: World, ticks: int) -> Array[AiEvent]:
	var events: Array[AiEvent] = []
	for _t: int in ticks:
		world.step()
		events.append_array(world.ai_events)
	return events


func _orders(events: Array[AiEvent]) -> Array[AiEvent]:
	return events.filter(func(e: AiEvent) -> bool: return e.kind == AiEvent.Kind.ORDER)


func _distance(unit: Unit, x: int, z: int) -> int:
	return FixedMath.length(unit.x - x * M, unit.z - z * M)


func test_it_marches_to_its_anchor_and_holds_it() -> void:
	var w: World = _world()
	var g: AiGroup = _group(w, [[&"grunt", 6]], 20, 20)
	assert_eq(g.engage_radius, 20 * M, "the spec's guard_radius")
	assert_true(w.ai.advance(w, g, 60 * M, 50 * M, 20 * M, 0, true))
	assert_eq(g.behavior, ADVANCE)
	assert_eq(g.phase, 0)
	_run(w, 900)
	var c: Vector2i = AiOrders.centroid(g.living(w))
	assert_lt(FixedMath.length(c.x - 60 * M, c.y - 50 * M), AiBehaviors.LEG_ARRIVE_RADIUS)
	assert_eq(g.phase, 1, "holding")
	assert_eq(Vector2i(g.anchor_x, g.anchor_z), Vector2i(60 * M, 50 * M))


func test_a_new_march_only_for_a_move_that_matters() -> void:
	var w: World = _world()
	var g: AiGroup = _group(w, [[&"grunt", 4]], 20, 20)
	w.ai.advance(w, g, 60 * M, 20 * M, 20 * M, 0, true)
	_run(w, 1200)
	assert_eq(g.phase, 1)
	assert_false(w.ai.advance(w, g, 62 * M, 20 * M, 25 * M, 7 * M, true), "2 m is under REORDER_MIN")
	assert_eq(g.anchor_x, 60 * M, "the anchor stays")
	assert_eq(g.engage_radius, 25 * M, "the radii change anyway")
	assert_eq(g.hold_radius, 7 * M)
	assert_eq(g.phase, 1)
	assert_true(w.ai.advance(w, g, 70 * M, 20 * M, 25 * M, 7 * M, true))
	assert_eq(g.phase, 0, "a new march")
	assert_true(g.think_now)
	assert_true(w.ai.advance(w, g, 70 * M, 20 * M, 25 * M, 7 * M, false), "switching to a plain move matters")
	assert_false(g.march_attack)


func test_switching_into_advance_reports_the_behavior_once() -> void:
	var w: World = _world()
	var g: AiGroup = _group(w, [[&"grunt", 2]], 20, 20)
	w.ai.set_behavior(w, g, AiGroupSpec.Behavior.HUNT)
	w.ai_events.clear()
	w.ai.advance(w, g, 50 * M, 50 * M, 20 * M, 0, true)
	var behaviors: Array = w.ai_events.filter(func(e: AiEvent) -> bool: return e.kind == AiEvent.Kind.BEHAVIOR)
	assert_eq(behaviors.size(), 1)
	assert_eq(behaviors[0].value, ADVANCE)
	w.ai_events.clear()
	w.ai.advance(w, g, 80 * M, 50 * M, 20 * M, 0, true)
	assert_eq(w.ai_events.size(), 0, "re-anchoring reports nothing itself")


func test_it_fights_what_comes_within_its_engage_radius_only() -> void:
	var w: World = _world()
	var g: AiGroup = _group(w, [[&"grunt", 4]], 20, 20)
	var near: Unit = w.spawn_unit(TARGET, LIGHT, 20 * M, 35 * M, 0, -1)
	var far: Unit = w.spawn_unit(TARGET, LIGHT, 80 * M, 80 * M, 0, -1)
	w.ai.advance(w, g, 20 * M, 20 * M, 20 * M, 0, true)
	_run(w, 40)
	var after: Array[int] = []
	for i: int in g.members.size():
		after.append(g.ordered_target[i])
	assert_true(after.has(near.id), "the enemy 15 m off is fought")
	assert_false(after.has(far.id), "the one 85 m off isn't")


func test_a_plain_advance_doesnt_stop_to_fight() -> void:
	var w: World = _world()
	var g: AiGroup = _group(w, [[&"grunt", 4]], 20, 20)
	w.spawn_unit(TARGET, LIGHT, 22 * M, 30 * M, 0, -1)
	w.ai.advance(w, g, 20 * M, 80 * M, 20 * M, 0, false)
	_run(w, 40)
	for i: int in g.members.size():
		assert_eq(g.ordered_target[i], 0, "no objective")
		assert_eq(g.ordered_attack[i], 0, "a plain move")


func test_it_never_pulls_a_member_out_of_a_fight() -> void:
	var w: World = _world()
	var g: AiGroup = _group(w, [[&"grunt", 3]], 20, 20, true, 1)
	var fighter: Unit = g.living(w)[0]
	# The other two stand well out of reach of the dummy, so only one fights.
	g.living(w)[1].x = 50 * M
	g.living(w)[2].x = 52 * M
	var foe: Unit = w.spawn_unit(TARGET, LIGHT, fighter.x + 900, fighter.z, -1, 0)
	_run(w, 15)
	assert_eq(fighter.target_id, foe.id, "it took on the dummy beside it")
	w.ai.advance(w, g, 80 * M, 80 * M, 1 * M, 0, true)
	_run(w, 20)
	assert_eq(fighter.target_id, foe.id, "it is still at it")
	var i: int = g.member_index(fighter.id)
	assert_ne(Vector2i(g.ordered_x[i], g.ordered_z[i]), Vector2i(80 * M, 80 * M), "never sent away")
	var others: int = 0
	for unit: Unit in g.living(w):
		if unit != fighter and g.ordered_x[g.member_index(unit.id)] == 80 * M:
			others += 1
	assert_eq(others, 2, "the free members march")


func test_holding_walks_back_when_nobody_is_inside() -> void:
	var w: World = _world()
	var g: AiGroup = _group(w, [[&"grunt", 4]], 50, 50)
	w.ai.advance(w, g, 50 * M, 50 * M, 30 * M, 5 * M, true)
	_run(w, 120)
	assert_eq(g.phase, 1)
	# A chase ended 12 m east of the flag: nobody within the 5 m hold radius,
	# everyone still within the 30 m engage radius.
	var k: int = 0
	for unit: Unit in g.living(w):
		unit.x = 62 * M + k * 1500
		unit.z = 50 * M
		UnitOrders.hold(unit)
		k += 1
	_run(w, 300)
	var inside: int = 0
	for unit: Unit in g.living(w):
		if _distance(unit, 50, 50) <= 5 * M:
			inside += 1
	assert_gt(inside, 0, "someone is back on the flag")


func test_members_that_chased_past_the_engage_radius_come_back() -> void:
	var w: World = _world()
	var g: AiGroup = _group(w, [[&"grunt", 3]], 50, 50)
	w.ai.advance(w, g, 50 * M, 50 * M, 10 * M, 20 * M, true)
	_run(w, 120)
	var stray: Unit = g.living(w)[0]
	stray.x = 90 * M
	stray.z = 90 * M
	UnitOrders.hold(stray)
	_run(w, 900)
	assert_lt(_distance(stray, 50, 50), 10 * M, "it walked back")


func test_nudging_the_anchor_doesnt_flood_orders() -> void:
	var w: World = _world()
	var g: AiGroup = _group(w, [[&"grunt", 6], [&"archer", 3]], 30, 30)
	var events: Array[AiEvent] = []
	for k: int in 30:
		w.ai.advance(w, g, 60 * M + (k % 2) * 2 * M, 40 * M, 20 * M, 0, true)
		events.append_array(_run(w, 30))
	assert_lte(_orders(events).size(), JITTER_ORDER_BOUND)


func test_ranged_behind_keeps_archers_short_of_an_attack_march() -> void:
	for behind: bool in [true, false]:
		var w: World = _world()
		var g: AiGroup = _group(w, [[&"grunt", 4], [&"archer", 2]], 20, 20, behind)
		w.ai.advance(w, g, 20 * M, 80 * M, 20 * M, 0, true)
		var events: Array[AiEvent] = _orders(_run(w, 20))
		var archer_goal: Vector2i = Vector2i(-1, -1)
		var grunt_goal: Vector2i = Vector2i(-1, -1)
		for e: AiEvent in events:
			var unit: Unit = w.get_unit(e.unit_id)
			if unit.type_index == ARCHER:
				archer_goal = Vector2i(e.x, e.z)
			else:
				grunt_goal = Vector2i(e.x, e.z)
		assert_eq(grunt_goal, Vector2i(20 * M, 80 * M), "the melee goes to the goal")
		if behind:
			assert_lt(archer_goal.y, 80 * M - AiTactics.STANDOFF_BEHIND + 500, "the archers stop behind")
		else:
			assert_eq(archer_goal, Vector2i(20 * M, 80 * M), "without the flag, as before")


func test_ranged_behind_says_who_keeps_back() -> void:
	var w: World = _world()
	var with_flag: AiGroup = _group(w, [[&"grunt", 2], [&"archer", 2], [&"caster", 1]], 20, 20, true)
	var units: Array[Unit] = with_flag.living(w)
	for unit: Unit in units:
		var expected: bool = unit.type_index != GRUNT
		assert_eq(AiTactics.is_back(with_flag, unit), expected, "type %d" % unit.type_index)
	assert_eq(AiTactics.front(units, with_flag).size(), 2, "the grunts")
	var w2: World = _world()
	var without: AiGroup = _group(w2, [[&"grunt", 2], [&"archer", 2], [&"caster", 1]], 20, 20, false)
	for unit: Unit in without.living(w2):
		assert_eq(AiTactics.is_back(without, unit), unit.type_index == CASTER, "only STANDOFF, as in Phase 7")
	assert_eq(AiTactics.front(without.living(w2), without).size(), 4)
	assert_eq(AiTactics.front(without.living(w2)).size(), 4, "no group: STANDOFF only")


func test_the_melee_guards_its_archers() -> void:
	var w: World = _world()
	var g: AiGroup = _group(w, [[&"grunt", 3], [&"archer", 1]], 50, 50, true)
	var archer: Unit = g.living(w)[3]
	var threat: Unit = w.spawn_unit(TARGET, LIGHT, archer.x + 6 * M, archer.z, -1, 0)
	assert_eq(AiTactics.threats(w, g), [threat] as Array[Unit])
	var w2: World = _world()
	var plain: AiGroup = _group(w2, [[&"grunt", 3], [&"archer", 1]], 50, 50, false)
	var archer2: Unit = plain.living(w2)[3]
	w2.spawn_unit(TARGET, LIGHT, archer2.x + 6 * M, archer2.z, -1, 0)
	assert_eq(AiTactics.threats(w2, plain).size(), 0, "a mission's group guards STANDOFF members only")


func test_advance_needs_an_engage_radius() -> void:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = &"army"
	var e: AiUnitEntry = AiUnitEntry.new()
	e.type_id = &"grunt"
	e.counts = PackedInt32Array([1])
	g.units.append(e)
	g.spawns = PackedInt32Array([0, 0])
	g.behavior = ADVANCE
	assert_string_contains("\n".join(g.validate(_catalog)), "ADVANCE needs guard_radius > 0")
