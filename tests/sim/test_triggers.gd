extends GutTest
## Mission triggers running inside World.step(): groups spawning from the
## script, every trigger condition, the `after` gate, every action, and how a
## mission ends. Scripts are built in code on flat terrain with target-dummy
## types, so each test pins only what it depends on.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

## Catalog indices of the synthetic types.
const HUSK: int = 0
const BRUTE: int = 1
const WALKER: int = 2

var _catalog: UnitCatalog


func before_all() -> void:
	var types: Array[UnitType] = [
		TestUnits.dummy(&"husk"),
		TestUnits.dummy(&"brute", {"body_radius": 600, "max_hp": 40_000}),
		TestUnits.dummy(&"walker"),
	]
	_catalog = TestUnits.catalog(types)


# --- fixtures ---------------------------------------------------------------


func _entry(type_id: StringName, counts: PackedInt32Array) -> AiUnitEntry:
	var e: AiUnitEntry = AiUnitEntry.new()
	e.type_id = type_id
	e.counts = counts
	return e


## A group of husks spawning at (x, z) metres; at_start false waits for a
## SPAWN_GROUP action.
func _group(
	group_name: StringName, counts: PackedInt32Array, x: int = 10, z: int = 10, at_start: bool = true
) -> AiGroupSpec:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = group_name
	g.units.append(_entry(&"husk", counts))
	g.spawns = PackedInt32Array([x * M, z * M])
	g.spawn_at_start = at_start
	return g


## Husks 2..6 by tier; tier 4 spawns at the second point, the rest at the first.
func _squad() -> AiGroupSpec:
	var g: AiGroupSpec = _group(&"squad", PackedInt32Array([2, 3, 4, 5, 6]))
	g.spawns = PackedInt32Array([10 * M, 10 * M, 40 * M, 40 * M])
	g.spawn_by_tier = PackedInt32Array([0, 0, 0, 0, 1])
	return g


func _action(kind: TriggerAction.Kind) -> TriggerAction:
	var a: TriggerAction = TriggerAction.new()
	a.kind = kind
	return a


func _trigger(trigger_name: StringName, condition: TriggerSpec.Condition) -> TriggerSpec:
	var t: TriggerSpec = TriggerSpec.new()
	t.name = trigger_name
	t.condition = condition
	return t


func _timer(trigger_name: StringName, ticks: PackedInt32Array, after: StringName = &"") -> TriggerSpec:
	var t: TriggerSpec = _trigger(trigger_name, TriggerSpec.Condition.TIMER)
	t.ticks = ticks
	t.after = after
	return t


## AREA_ENTERED around (x, z) metres, radius in metres.
func _area(
	trigger_name: StringName, x: int, z: int, radius: int,
	side: UnitType.Faction = LIGHT, min_count: int = 1
) -> TriggerSpec:
	var t: TriggerSpec = _trigger(trigger_name, TriggerSpec.Condition.AREA_ENTERED)
	t.area = PackedInt32Array([x * M, z * M, radius * M])
	t.faction = side
	t.min_count = min_count
	return t


func _dies(trigger_name: StringName, names: Array[StringName], count: int) -> TriggerSpec:
	var t: TriggerSpec = _trigger(trigger_name, TriggerSpec.Condition.UNIT_DIES)
	t.names = names
	t.count = count
	return t


func _cleared(trigger_name: StringName, names: Array[StringName]) -> TriggerSpec:
	var t: TriggerSpec = _trigger(trigger_name, TriggerSpec.Condition.GROUP_CLEARED)
	t.names = names
	return t


func _eliminated(trigger_name: StringName, side: UnitType.Faction) -> TriggerSpec:
	var t: TriggerSpec = _trigger(trigger_name, TriggerSpec.Condition.FACTION_ELIMINATED)
	t.faction = side
	return t


func _spawn_action(group_name: StringName) -> TriggerAction:
	var a: TriggerAction = _action(TriggerAction.Kind.SPAWN_GROUP)
	a.group = group_name
	return a


func _script(groups: Array[AiGroupSpec], triggers: Array[TriggerSpec]) -> MissionScript:
	var s: MissionScript = MissionScript.new()
	s.groups = groups
	s.triggers = triggers
	return s


func _world(script: MissionScript, tier: int = 0) -> World:
	var world: World = World.new(1, TestTerrains.flat(60, 60), _catalog)
	assert_true(world.start_mission(script, tier), "the script should be accepted")
	return world


func _run(world: World, ticks: int) -> void:
	for _t: int in ticks:
		world.step()


func _light(world: World, x: int, z: int) -> Unit:
	return world.spawn_unit(WALKER, LIGHT, x * M, z * M, 1, 0)


func _fired(world: World, index: int) -> int:
	return world.mission.fired_tick[index]


func _inside(unit: Unit, x: int, z: int, radius: int) -> bool:
	var dx: int = unit.x - x * M
	var dz: int = unit.z - z * M
	return dx * dx + dz * dz <= radius * M * radius * M


func _event_kinds(world: World) -> Array[int]:
	var kinds: Array[int] = []
	for e: MissionEvent in world.mission_events:
		kinds.append(e.kind)
	return kinds


# --- groups spawning from the script ----------------------------------------


func test_start_group_spawns_on_the_first_step_at_the_tier_count_and_point() -> void:
	var world: World = _world(_script([_squad()], []), 0)
	assert_true(world.ai.groups.is_empty(), "nothing spawns until the first step")
	assert_eq(world.units.size(), 0)
	world.step()
	assert_eq(world.ai.groups.size(), 1)
	var group: AiGroup = world.ai.groups[0]
	assert_eq(group.id, 1)
	assert_eq(group.members.size(), 2, "tier 0 count")
	assert_eq(world.units.size(), 2)
	assert_eq(Vector2i(group.spawn_x, group.spawn_z), Vector2i(10 * M, 10 * M))
	assert_eq(Vector2i(group.anchor_x, group.anchor_z), Vector2i(10 * M, 10 * M))


func test_tier_changes_the_count_and_the_position() -> void:
	var easy: World = _world(_script([_squad()], []), 0)
	var hard: World = _world(_script([_squad()], []), 4)
	easy.step()
	hard.step()
	assert_eq(easy.ai.groups[0].members.size(), 2)
	assert_eq(hard.ai.groups[0].members.size(), 6)
	assert_eq(Vector2i(easy.ai.groups[0].spawn_x, easy.ai.groups[0].spawn_z), Vector2i(10 * M, 10 * M))
	assert_eq(Vector2i(hard.ai.groups[0].spawn_x, hard.ai.groups[0].spawn_z), Vector2i(40 * M, 40 * M))
	for id: int in hard.ai.groups[0].members:
		var unit: Unit = hard.get_unit(id)
		assert_lt(Vector2(unit.x, unit.z).distance_to(Vector2(40 * M, 40 * M)), 4.0 * M, "near the tier's point")


func test_members_take_distinct_formation_slots_on_the_groups_side() -> void:
	var world: World = _world(_script([_squad()], []), 4)
	world.step()
	var seen: Dictionary[Vector2i, bool] = {}
	for id: int in world.ai.groups[0].members:
		var unit: Unit = world.get_unit(id)
		assert_eq(unit.faction, DARK)
		seen[Vector2i(unit.x, unit.z)] = true
	assert_eq(seen.size(), 6, "no two units on one spot")


func test_a_group_keeps_its_specs_faction() -> void:
	var g: AiGroupSpec = _group(&"allies", PackedInt32Array([3]))
	g.faction = LIGHT
	var world: World = _world(_script([g], []))
	world.step()
	assert_eq(world.ai.groups[0].faction, LIGHT)
	for id: int in world.ai.groups[0].members:
		assert_eq(world.get_unit(id).faction, LIGHT)


func test_a_group_mixes_its_entries_in_order_and_sums_their_hp() -> void:
	var g: AiGroupSpec = _group(&"mixed", PackedInt32Array([1]))
	g.units.append(_entry(&"brute", PackedInt32Array([2])))
	var world: World = _world(_script([g], []))
	world.step()
	var group: AiGroup = world.ai.groups[0]
	assert_eq(group.members.size(), 3)
	assert_eq(world.get_unit(group.members[0]).type_index, HUSK)
	assert_eq(world.get_unit(group.members[1]).type_index, BRUTE)
	assert_eq(world.get_unit(group.members[2]).type_index, BRUTE)
	assert_eq(group.start_hp, 100_000 + 2 * 40_000)
	assert_eq(group.last_hp, group.start_hp)


func test_spawning_emits_one_spawned_event_at_the_point() -> void:
	var world: World = _world(_script([_squad()], []), 0)
	world.step()
	assert_eq(world.ai_events.size(), 1)
	var e: AiEvent = world.ai_events[0]
	assert_eq(e.kind, AiEvent.Kind.SPAWNED)
	assert_eq(e.group_id, 1)
	assert_eq(Vector2i(e.x, e.z), Vector2i(10 * M, 10 * M))
	assert_eq(e.value, 2)
	world.step()
	assert_true(world.ai_events.is_empty(), "events last one step")


func test_a_group_that_waits_for_its_trigger_does_not_spawn_at_start() -> void:
	var spec: AiGroupSpec = _group(&"wave", PackedInt32Array([2]), 10, 10, false)
	var timer: TriggerSpec = _timer(&"release", PackedInt32Array([20]))
	timer.actions.append(_spawn_action(&"wave"))
	var world: World = _world(_script([spec], [timer]))
	_run(world, 20)
	assert_true(world.ai.groups.is_empty(), "not before its trigger")
	assert_eq(world.units.size(), 0)
	world.step()
	assert_eq(world.ai.groups.size(), 1)
	assert_eq(world.ai.groups[0].members.size(), 2)
	assert_eq(world.ai_events[0].kind, AiEvent.Kind.SPAWNED)


# --- AREA_ENTERED -----------------------------------------------------------


func test_area_entered_fires_the_tick_after_a_light_unit_walks_in() -> void:
	var world: World = _world(_script([], [_area(&"ford", 30, 30, 3)]))
	var walker: Unit = _light(world, 20, 30)
	world.enqueue(MoveUnitsCommand.new(0, PackedInt32Array([walker.id]), 30 * M, 30 * M, 0))
	var first_inside: int = -1
	for _t: int in 200:
		world.step()
		if first_inside < 0 and _inside(walker, 30, 30, 3):
			first_inside = world.tick
			assert_eq(_fired(world, 0), -1, "not yet: the unit arrived during this tick")
	assert_gt(first_inside, 0, "the walker should reach the area")
	assert_eq(_fired(world, 0), first_inside, "fires on the next tick's pass")


func test_area_entered_counts_a_unit_on_the_edge() -> void:
	var world: World = _world(_script([], [_area(&"ford", 30, 30, 3)]))
	_light(world, 33, 30)
	world.step()
	assert_eq(_fired(world, 0), 0, "exactly the radius away is inside")
	var just_out: World = _world(_script([], [_area(&"ford", 30, 30, 3)]))
	just_out.spawn_unit(WALKER, LIGHT, 33 * M + 1, 30 * M, 1, 0)
	just_out.step()
	assert_eq(_fired(just_out, 0), -1, "a milli-unit further is out")


func test_area_entered_waits_for_min_count() -> void:
	var world: World = _world(_script([], [_area(&"pair", 30, 30, 3, LIGHT, 2)]))
	_light(world, 30, 30)
	_light(world, 50, 50)
	_run(world, 60)
	assert_eq(_fired(world, 0), -1, "one inside is not two")
	_light(world, 31, 30)
	world.step()
	assert_eq(_fired(world, 0), 60)


func test_area_entered_ignores_the_other_faction() -> void:
	var for_light: World = _world(_script([], [_area(&"ford", 30, 30, 3, LIGHT)]))
	var for_dark: World = _world(_script([], [_area(&"ford", 30, 30, 3, DARK)]))
	for world: World in [for_light, for_dark]:
		world.spawn_unit(HUSK, DARK, 30 * M, 30 * M, 1, 0)
		_run(world, 30)
	assert_eq(_fired(for_light, 0), -1, "a DARK unit is not a LIGHT one")
	assert_eq(_fired(for_dark, 0), 0, "but it is for a DARK trigger")


func test_area_entered_does_not_count_the_dead() -> void:
	var world: World = _world(_script([], [_area(&"ford", 30, 30, 3)]))
	_light(world, 30, 30).kill()
	_run(world, 30)
	assert_eq(_fired(world, 0), -1)


# --- UNIT_DIES --------------------------------------------------------------


func test_unit_dies_counts_one_then_two_deaths() -> void:
	var pack: AiGroupSpec = _group(&"pack", PackedInt32Array([3]))
	var one: TriggerSpec = _dies(&"one", [&"pack"], 1)
	var two: TriggerSpec = _dies(&"two", [&"pack"], 2)
	var world: World = _world(_script([pack], [one, two]))
	world.step()
	assert_eq(_fired(world, 0), -1, "nobody has died")
	var members: PackedInt32Array = world.ai.groups[0].members.duplicate()
	world.get_unit(members[0]).kill()
	world.step()
	assert_eq(_fired(world, 0), 1, "one death")
	assert_eq(_fired(world, 1), -1, "not two yet")
	world.get_unit(members[1]).kill()
	world.step()
	assert_eq(_fired(world, 1), 2, "two deaths, though the first was pruned from members")


func test_unit_dies_sums_deaths_across_the_named_groups_only() -> void:
	var a: AiGroupSpec = _group(&"a", PackedInt32Array([2]), 10, 10)
	var b: AiGroupSpec = _group(&"b", PackedInt32Array([2]), 30, 10)
	var c: AiGroupSpec = _group(&"c", PackedInt32Array([2]), 50, 10)
	var world: World = _world(_script([a, b, c], [_dies(&"ab", [&"a", &"b"], 2)]))
	world.step()
	world.get_unit(world.ai.groups[0].members[0]).kill()
	world.get_unit(world.ai.groups[2].members[0]).kill()
	world.step()
	assert_eq(_fired(world, 0), -1, "a death in an unnamed group doesn't count")
	world.get_unit(world.ai.groups[1].members[0]).kill()
	world.step()
	assert_eq(_fired(world, 0), 2)


func test_unit_dies_counts_a_unit_that_is_gone() -> void:
	var world: World = _world(_script([_group(&"pack", PackedInt32Array([2]))], [_dies(&"gone", [&"pack"], 1)]))
	world.step()
	world.despawn_entity(world.ai.groups[0].members[0])
	world.step()
	assert_eq(_fired(world, 0), 1)


func test_unit_dies_counts_a_group_named_twice_once() -> void:
	var world: World = _world(_script(
		[_group(&"pack", PackedInt32Array([2]))], [_dies(&"twice", [&"pack", &"pack"], 2)]
	))
	world.step()
	world.get_unit(world.ai.groups[0].members[0]).kill()
	_run(world, 5)
	assert_eq(_fired(world, 0), -1, "one death is one death")


# --- TIMER ------------------------------------------------------------------


func test_timer_without_after_fires_at_exactly_its_tick() -> void:
	var world: World = _world(_script([], [_timer(&"t", PackedInt32Array([30]))]))
	_run(world, 30)
	assert_eq(_fired(world, 0), -1, "ticks 0..29 have run")
	world.step()
	assert_eq(_fired(world, 0), 30)


func test_a_timer_with_default_ticks_fires_on_the_first_tick() -> void:
	var world: World = _world(_script([], [_trigger(&"now", TriggerSpec.Condition.TIMER)]))
	world.step()
	assert_eq(_fired(world, 0), 0)


func test_timer_with_after_counts_from_the_tick_after_its_prerequisite() -> void:
	var first: TriggerSpec = _timer(&"first", PackedInt32Array([10]))
	var second: TriggerSpec = _timer(&"second", PackedInt32Array([20]), &"first")
	var world: World = _world(_script([], [first, second]))
	_run(world, 31)
	assert_eq(_fired(world, 0), 10)
	assert_eq(_fired(world, 1), -1, "10 + 1 + 20 is 31, which hasn't run yet")
	world.step()
	assert_eq(_fired(world, 1), 31)


func test_timer_of_zero_after_a_prerequisite_fires_on_the_next_tick() -> void:
	var first: TriggerSpec = _timer(&"first", PackedInt32Array([5]))
	var second: TriggerSpec = _timer(&"second", PackedInt32Array([0]), &"first")
	var world: World = _world(_script([], [first, second]))
	_run(world, 7)
	assert_eq(_fired(world, 0), 5)
	assert_eq(_fired(world, 1), 6)


func test_timer_ticks_follow_the_tier() -> void:
	var ticks: PackedInt32Array = PackedInt32Array([60, 50, 40, 30, 20])
	for tier: int in [0, 2, 4]:
		var world: World = _world(_script([], [_timer(&"t", ticks)]), tier)
		_run(world, 61)
		assert_eq(_fired(world, 0), ticks[tier], "tier %d" % tier)


func test_a_single_timer_value_serves_every_tier() -> void:
	var world: World = _world(_script([], [_timer(&"t", PackedInt32Array([15]))]), 3)
	_run(world, 16)
	assert_eq(_fired(world, 0), 15)


# --- the after gate ---------------------------------------------------------


func test_a_trigger_waits_for_its_prerequisite_even_if_its_condition_holds() -> void:
	var gate: TriggerSpec = _timer(&"gate", PackedInt32Array([10]))
	var entered: TriggerSpec = _area(&"entered", 30, 30, 3)
	entered.after = &"gate"
	var world: World = _world(_script([], [gate, entered]))
	_light(world, 30, 30)
	_run(world, 11)
	assert_eq(_fired(world, 0), 10)
	assert_eq(_fired(world, 1), -1, "the gate fired this tick, so it isn't open yet")
	world.step()
	assert_eq(_fired(world, 1), 11, "open on the next tick")


func test_triggers_do_not_see_each_others_effects_on_the_tick_they_fire() -> void:
	var allies: AiGroupSpec = _group(&"allies", PackedInt32Array([2]), 40, 40, false)
	allies.faction = LIGHT
	var spawn: TriggerSpec = _timer(&"spawn", PackedInt32Array([5]))
	spawn.actions.append(_spawn_action(&"allies"))
	var arrived: TriggerSpec = _area(&"arrived", 40, 40, 4)
	var world: World = _world(_script([allies], [spawn, arrived]))
	_run(world, 6)
	assert_eq(_fired(world, 0), 5)
	assert_eq(world.ai.groups.size(), 1)
	assert_eq(_fired(world, 1), -1, "the units spawned after this tick's conditions were read")
	world.step()
	assert_eq(_fired(world, 1), 6)


func test_a_fired_trigger_never_fires_again() -> void:
	var t: TriggerSpec = _timer(&"once", PackedInt32Array([3]))
	t.actions.append(_action(TriggerAction.Kind.SET_OBJECTIVE))
	var world: World = _world(_script([], [t]))
	_run(world, 50)
	assert_eq(_fired(world, 0), 3)
	assert_eq(world.mission.objective_revision, 1)


# --- GROUP_CLEARED ----------------------------------------------------------


func test_group_cleared_is_false_until_the_group_spawns_and_then_dies() -> void:
	var wave: AiGroupSpec = _group(&"wave", PackedInt32Array([2]), 10, 10, false)
	var release: TriggerSpec = _timer(&"release", PackedInt32Array([20]))
	release.actions.append(_spawn_action(&"wave"))
	var world: World = _world(_script([wave], [release, _cleared(&"cleared", [&"wave"])]))
	_run(world, 40)
	assert_eq(world.ai.groups.size(), 1)
	assert_eq(_fired(world, 1), -1, "the group is alive")
	var members: PackedInt32Array = world.ai.groups[0].members.duplicate()
	world.get_unit(members[0]).kill()
	world.step()
	assert_eq(_fired(world, 1), -1, "one still stands")
	world.get_unit(members[1]).kill()
	world.step()
	assert_eq(_fired(world, 1), world.tick - 1)


func test_group_cleared_does_not_fire_for_a_group_that_never_spawned() -> void:
	var wave: AiGroupSpec = _group(&"wave", PackedInt32Array([2]), 10, 10, false)
	var world: World = _world(_script([wave], [_cleared(&"cleared", [&"wave"])]))
	_run(world, 60)
	assert_true(world.ai.groups.is_empty())
	assert_eq(_fired(world, 0), -1, "zero living units is not a cleared group")


func test_group_cleared_waits_for_every_named_group() -> void:
	var a: AiGroupSpec = _group(&"a", PackedInt32Array([1]), 10, 10)
	var b: AiGroupSpec = _group(&"b", PackedInt32Array([1]), 30, 10)
	var world: World = _world(_script([a, b], [_cleared(&"both", [&"a", &"b"])]))
	world.step()
	world.get_unit(world.ai.groups[0].members[0]).kill()
	_run(world, 3)
	assert_eq(_fired(world, 0), -1)
	world.get_unit(world.ai.groups[1].members[0]).kill()
	world.step()
	assert_eq(_fired(world, 0), 4)


func test_a_group_with_no_units_at_this_tier_counts_as_cleared_once_spawned() -> void:
	var spec: AiGroupSpec = _group(&"late", PackedInt32Array([0, 0, 0, 0, 2]))
	var script: MissionScript = _script([spec], [_cleared(&"cleared", [&"late"])])
	var easy: World = _world(script, 0)
	var hard: World = _world(script, 4)
	_run(easy, 3)
	_run(hard, 3)
	assert_eq(easy.ai.groups.size(), 1, "the empty group still exists")
	assert_eq(easy.ai.groups[0].members.size(), 0)
	assert_eq(_fired(easy, 0), 0, "spawned and empty on the first tick")
	assert_eq(_fired(hard, 0), -1, "the hard tier's units are alive")


# --- FACTION_ELIMINATED -----------------------------------------------------


func test_faction_eliminated_fires_when_the_last_light_unit_dies() -> void:
	var world: World = _world(_script([], [_eliminated(&"wiped", LIGHT)]))
	var a: Unit = _light(world, 10, 10)
	var b: Unit = _light(world, 12, 10)
	_run(world, 3)
	a.kill()
	_run(world, 3)
	assert_eq(_fired(world, 0), -1, "one is left")
	b.kill()
	world.step()
	assert_eq(_fired(world, 0), 6)


func test_faction_eliminated_never_fires_for_a_side_that_never_existed() -> void:
	var world: World = _world(_script([_group(&"pack", PackedInt32Array([2]))], [_eliminated(&"wiped", LIGHT)]))
	_run(world, 100)
	assert_eq(_fired(world, 0), -1, "no LIGHT unit was ever alive")


func test_faction_eliminated_sees_units_the_mission_spawned() -> void:
	var world: World = _world(_script([_group(&"pack", PackedInt32Array([2]))], [_eliminated(&"wiped", DARK)]))
	world.step()
	assert_eq(_fired(world, 0), -1)
	for id: int in world.ai.groups[0].members:
		world.get_unit(id).kill()
	world.step()
	assert_eq(_fired(world, 0), 1)


# --- the other actions ------------------------------------------------------


func test_set_objective_updates_text_and_revision_and_emits_an_event() -> void:
	var first: TriggerSpec = _timer(&"first", PackedInt32Array([5]))
	var a: TriggerAction = _action(TriggerAction.Kind.SET_OBJECTIVE)
	a.text = "Reach the ford"
	first.actions.append(a)
	var second: TriggerSpec = _timer(&"second", PackedInt32Array([10]))
	var b: TriggerAction = _action(TriggerAction.Kind.SET_OBJECTIVE)
	b.text = "Hold the mill"
	second.actions.append(b)
	var world: World = _world(_script([], [first, second]))
	_run(world, 5)
	assert_eq(world.mission.objective, "")
	assert_eq(world.mission.objective_revision, 0)
	world.step()
	assert_eq(world.mission.objective, "Reach the ford")
	assert_eq(world.mission.objective_trigger, 0)
	assert_eq(world.mission.objective_revision, 1)
	assert_eq(_event_kinds(world), [MissionEvent.Kind.TRIGGER_FIRED, MissionEvent.Kind.OBJECTIVE])
	assert_eq(world.mission_events[1].trigger_index, 0)
	assert_eq(world.mission_events[1].text, "Reach the ford")
	world.step()
	assert_true(world.mission_events.is_empty(), "events last one step")
	_run(world, 4)
	assert_eq(world.mission.objective, "Hold the mill")
	assert_eq(world.mission.objective_trigger, 1)
	assert_eq(world.mission.objective_revision, 2)


func test_set_behavior_changes_every_group_of_the_spec_and_emits_events() -> void:
	var pack: AiGroupSpec = _group(&"pack", PackedInt32Array([2]))
	var again: TriggerSpec = _timer(&"again", PackedInt32Array([2]))
	again.actions.append(_spawn_action(&"pack"))
	var turn: TriggerSpec = _timer(&"turn", PackedInt32Array([5]))
	var a: TriggerAction = _action(TriggerAction.Kind.SET_BEHAVIOR)
	a.group = &"pack"
	a.behavior = AiGroupSpec.Behavior.HUNT
	turn.actions.append(a)
	var world: World = _world(_script([pack], [again, turn]))
	_run(world, 5)
	assert_eq(world.ai.groups.size(), 2, "two instances of the spec")
	for g: AiGroup in world.ai.groups:
		assert_eq(g.behavior, AiGroupSpec.Behavior.IDLE)
	world.step()
	var ids: Array[int] = []
	for g: AiGroup in world.ai.groups:
		assert_eq(g.behavior, AiGroupSpec.Behavior.HUNT)
		assert_true(g.think_now, "so it plans at once")
		ids.append(g.id)
	var seen: Array[int] = []
	for e: AiEvent in world.ai_events:
		if e.kind == AiEvent.Kind.BEHAVIOR:
			assert_eq(e.value, AiGroupSpec.Behavior.HUNT)
			seen.append(e.group_id)
	assert_eq(seen, ids)


func test_set_behavior_on_a_group_that_never_spawned_does_nothing() -> void:
	var wave: AiGroupSpec = _group(&"wave", PackedInt32Array([2]), 10, 10, false)
	var turn: TriggerSpec = _timer(&"turn", PackedInt32Array([1]))
	var a: TriggerAction = _action(TriggerAction.Kind.SET_BEHAVIOR)
	a.group = &"wave"
	a.behavior = AiGroupSpec.Behavior.HUNT
	turn.actions.append(a)
	var world: World = _world(_script([wave], [turn]))
	_run(world, 5)
	assert_eq(_fired(world, 0), 1)
	assert_true(world.ai.groups.is_empty())


# --- how a mission ends -----------------------------------------------------


func test_win_ends_the_mission() -> void:
	var t: TriggerSpec = _timer(&"win", PackedInt32Array([5]))
	t.actions.append(_action(TriggerAction.Kind.WIN))
	var world: World = _world(_script([], [t]))
	assert_eq(world.mission.outcome, MissionRuntime.Outcome.NONE)
	_run(world, 6)
	assert_eq(world.mission.outcome, MissionRuntime.Outcome.WON)
	assert_eq(world.mission.outcome_tick, 5)
	assert_eq(_event_kinds(world), [MissionEvent.Kind.TRIGGER_FIRED, MissionEvent.Kind.WON])


func test_win_and_lose_on_the_same_tick_lose() -> void:
	var win: TriggerSpec = _timer(&"win", PackedInt32Array([5]))
	win.actions.append(_action(TriggerAction.Kind.WIN))
	var lose: TriggerSpec = _timer(&"lose", PackedInt32Array([5]))
	lose.actions.append(_action(TriggerAction.Kind.LOSE))
	var win_first: Array[TriggerSpec] = [win, lose]
	var lose_first: Array[TriggerSpec] = [lose, win]
	for order: Array[TriggerSpec] in [win_first, lose_first]:
		var world: World = _world(_script([], order))
		_run(world, 6)
		assert_eq(world.mission.outcome, MissionRuntime.Outcome.LOST)
		var kinds: Array[int] = _event_kinds(world)
		assert_true(kinds.has(MissionEvent.Kind.LOST))
		assert_false(kinds.has(MissionEvent.Kind.WON), "one verdict per mission")


func test_no_trigger_fires_after_the_outcome() -> void:
	var win: TriggerSpec = _timer(&"win", PackedInt32Array([5]))
	win.actions.append(_action(TriggerAction.Kind.WIN))
	var later: TriggerSpec = _timer(&"later", PackedInt32Array([20]))
	later.actions.append(_action(TriggerAction.Kind.SET_OBJECTIVE))
	var same_tick: TriggerSpec = _timer(&"same_tick", PackedInt32Array([5]))
	same_tick.actions.append(_action(TriggerAction.Kind.SET_OBJECTIVE))
	var world: World = _world(_script([], [win, later, same_tick]))
	_run(world, 40)
	assert_eq(_fired(world, 2), 5, "a trigger due on the winning tick still fires")
	assert_eq(_fired(world, 1), -1, "but nothing fires afterwards")
	assert_eq(world.mission.objective_revision, 1)


# --- SET_WEATHER ------------------------------------------------------------


func test_a_weather_trigger_does_what_the_command_does() -> void:
	var t: TriggerSpec = _timer(&"storm", PackedInt32Array([10]))
	var a: TriggerAction = _action(TriggerAction.Kind.SET_WEATHER)
	a.weather = WeatherChange.new()
	a.weather.rain = 700
	a.weather.snow = 150
	a.weather.wind_x = 3000
	a.weather.wind_z = -2000
	a.weather.ramp_ticks = 60
	a.weather.snow_cover = 300
	t.actions.append(a)
	var by_trigger: World = _world(_script([], [t]))
	var by_command: World = World.new(1, TestTerrains.flat(60, 60), _catalog)
	by_command.enqueue(SetWeatherCommand.new(10, 700, 150, 3000, -2000, 60, 300))
	for _t: int in 200:
		by_trigger.step()
		by_command.step()
		assert_eq(
			by_trigger.weather.hash_fields(), by_command.weather.hash_fields(), "tick %d" % by_trigger.tick
		)
	assert_eq(by_trigger.weather.rain, 700, "the change really happened")
	assert_gt(by_trigger.weather.snow_cover_ppm, 0)


# --- determinism and start_mission ------------------------------------------


## Every kind of trigger in one script: a start group, a timed wave, an area
## gate, an objective, weather, and a win.
func _busy_script() -> MissionScript:
	var squad: AiGroupSpec = _squad()
	var wave: AiGroupSpec = _group(&"wave", PackedInt32Array([1, 2, 3, 4, 5]), 30, 30, false)
	var release: TriggerSpec = _timer(&"release", PackedInt32Array([40]))
	release.actions.append(_spawn_action(&"wave"))
	var objective: TriggerAction = _action(TriggerAction.Kind.SET_OBJECTIVE)
	objective.text = "Cross the ford"
	release.actions.append(objective)
	var weather: TriggerAction = _action(TriggerAction.Kind.SET_WEATHER)
	weather.weather = WeatherChange.new()
	weather.weather.rain = 500
	weather.weather.ramp_ticks = 30
	release.actions.append(weather)
	var turn: TriggerSpec = _area(&"turn", 30, 30, 3)
	var behave: TriggerAction = _action(TriggerAction.Kind.SET_BEHAVIOR)
	behave.group = &"wave"
	behave.behavior = AiGroupSpec.Behavior.HUNT
	turn.actions.append(behave)
	return _script([squad, wave], [release, turn, _timer(&"end", PackedInt32Array([250]), &"release")])


func _busy_world(world_seed: int, tier: int) -> World:
	var world: World = World.new(world_seed, TestTerrains.flat(60, 60), _catalog)
	assert_true(world.start_mission(_busy_script(), tier))
	var walker: Unit = _light(world, 10, 30)
	world.enqueue(MoveUnitsCommand.new(0, PackedInt32Array([walker.id]), 30 * M, 30 * M, 0))
	return world


func test_two_worlds_with_the_same_seed_and_mission_stay_identical() -> void:
	var a: World = _busy_world(7, 3)
	var b: World = _busy_world(7, 3)
	for t: int in 300:
		a.step()
		b.step()
		if t % 50 == 49:
			assert_eq(a.state_hash(), b.state_hash(), "tick %d" % a.tick)
	assert_eq(a.state_hash(), b.state_hash())
	assert_gt(a.ai.groups.size(), 1, "the wave spawned")
	assert_eq(a.mission.objective, "Cross the ford")
	assert_eq(a.mission.outcome, MissionRuntime.Outcome.NONE)


func test_the_tier_changes_the_state_hash() -> void:
	var easy: World = _busy_world(7, 0)
	var hard: World = _busy_world(7, 4)
	_run(easy, 100)
	_run(hard, 100)
	assert_ne(easy.state_hash(), hard.state_hash())


func test_mission_and_ai_state_are_part_of_the_state_hash() -> void:
	var a: World = _busy_world(7, 2)
	var b: World = _busy_world(7, 2)
	_run(a, 10)
	_run(b, 10)
	assert_eq(a.state_hash(), b.state_hash())
	b.mission.objective_revision += 1
	assert_ne(a.state_hash(), b.state_hash(), "mission progress is hashed")
	b.mission.objective_revision -= 1
	assert_eq(a.state_hash(), b.state_hash())
	b.mission.fired_tick[1] = 5
	assert_ne(a.state_hash(), b.state_hash(), "so is which triggers have fired")
	b.mission.fired_tick[1] = a.mission.fired_tick[1]
	assert_eq(a.state_hash(), b.state_hash())
	b.ai.groups[0].phase = 3
	assert_ne(a.state_hash(), b.state_hash(), "AI progress is hashed")


func test_start_mission_sets_up_the_runtime_without_spawning() -> void:
	var timers: Array[TriggerSpec] = [
		_timer(&"a", PackedInt32Array([5])), _timer(&"b", PackedInt32Array([6]))
	]
	var world: World = _world(_script([_squad()], timers), 2)
	assert_not_null(world.mission)
	assert_eq(world.mission.tier, 2)
	assert_eq(world.mission.start_tick, 0)
	assert_false(world.mission.started)
	assert_eq(world.mission.fired_tick, PackedInt64Array([-1, -1]))
	assert_eq(world.mission.outcome, MissionRuntime.Outcome.NONE)
	assert_eq(world.units.size(), 0)


func test_start_mission_rejects_an_invalid_script() -> void:
	var bad: AiGroupSpec = _group(&"ghost", PackedInt32Array([2]))
	bad.units[0].type_id = &"no_such_type"
	var world: World = World.new(1, TestTerrains.flat(60, 60), _catalog)
	assert_false(world.start_mission(_script([bad], []), 0))
	assert_push_error("start_mission")
	assert_null(world.mission)


func test_start_mission_rejects_a_bad_tier() -> void:
	var script: MissionScript = _script([_squad()], [])
	var world: World = World.new(1, TestTerrains.flat(60, 60), _catalog)
	assert_false(world.start_mission(script, -1))
	assert_false(world.start_mission(script, Difficulty.TIERS))
	assert_push_error_count(2)
	assert_null(world.mission)
	assert_true(world.start_mission(script, Difficulty.TIERS - 1), "the hardest tier is fine")


func test_start_mission_rejects_a_second_mission() -> void:
	var script: MissionScript = _script([_squad()], [])
	var world: World = _world(script)
	assert_false(world.start_mission(script, 1))
	assert_push_error("start_mission")
	assert_eq(world.mission.tier, 0, "the first mission stands")


func test_start_mission_rejects_a_world_that_has_already_stepped() -> void:
	var world: World = World.new(1, TestTerrains.flat(60, 60), _catalog)
	world.step()
	assert_false(world.start_mission(_script([_squad()], []), 0))
	assert_push_error("start_mission")
	assert_null(world.mission)


func test_start_mission_rejects_a_world_without_terrain_or_units() -> void:
	var script: MissionScript = _script([_squad()], [])
	var no_terrain: World = World.new(1, null, _catalog)
	var no_catalog: World = World.new(1, TestTerrains.flat(60, 60))
	assert_false(no_terrain.start_mission(script, 0))
	assert_false(no_catalog.start_mission(script, 0))
	assert_push_error_count(2)


func test_a_world_without_a_mission_has_no_ai() -> void:
	var world: World = World.new(1, TestTerrains.flat(60, 60), _catalog)
	_light(world, 10, 10)
	_run(world, 30)
	assert_null(world.mission)
	assert_true(world.ai.groups.is_empty())
	assert_true(world.ai_events.is_empty())
	assert_true(world.mission_events.is_empty())
