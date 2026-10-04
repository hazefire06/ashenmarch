extends GutTest
## The Phase 8 mission format at run time: the draw that binds aliases to pool
## groups (World.roll_bindings), aliases standing in for group names, the
## TRIGGERS_FIRED and PLAYER_ELIMINATED conditions, AREA_ENTERED's group
## filter, objective states, AiDirector.controls, and what the hash covers.
## Validation of the new fields is in test_mission_campaign_validation.gd.

const M: int = MissionFixtures.M
const LIGHT: UnitType.Faction = MissionFixtures.LIGHT
const DARK: UnitType.Faction = MissionFixtures.DARK
const OBJ_STATE: MissionEvent.Kind = MissionEvent.Kind.OBJECTIVE_STATE
const ACTIVE: MissionRuntime.ObjectiveState = MissionRuntime.ObjectiveState.ACTIVE
const HIDDEN: MissionRuntime.ObjectiveState = MissionRuntime.ObjectiveState.HIDDEN
const DONE: MissionRuntime.ObjectiveState = MissionRuntime.ObjectiveState.DONE
const FAILED: MissionRuntime.ObjectiveState = MissionRuntime.ObjectiveState.FAILED


# --- fixtures ---------------------------------------------------------------


## Five pool groups a..e (group indices 0..4, two husks each, 10 m apart along
## z = 10, none spawning at start) and one draw of two slots, wave1 and wave2.
func _pool_script(triggers: Array[TriggerSpec] = [], ordered: bool = false) -> MissionScript:
	var groups: Array[AiGroupSpec] = []
	var pool: Array[StringName] = []
	for i: int in 5:
		var group_name: StringName = StringName(char(97 + i))
		groups.append(MissionFixtures.group(group_name, 2, 10 + i * 10, 10, false))
		pool.append(group_name)
	var draws: Array[MissionDraw] = [MissionFixtures.draw([&"wave1", &"wave2"], pool, ordered)]
	return MissionFixtures.script(groups, triggers, [], draws)


## wave1 is group c (2), wave2 is group e (4).
func _pool_world(triggers: Array[TriggerSpec]) -> World:
	return MissionFixtures.world_bound(_pool_script(triggers), PackedInt32Array([2, 4]))


func _spawn_waves_at(tick: int) -> TriggerSpec:
	var t: TriggerSpec = MissionFixtures.timer(&"release", tick)
	t.actions.append(MissionFixtures.spawn_action(&"wave1"))
	t.actions.append(MissionFixtures.spawn_action(&"wave2"))
	return t


func _fired(w: World, index: int) -> int:
	return w.mission.fired_tick[index]


func _kill_all(w: World, spec_index: int) -> void:
	for group: AiGroup in w.ai.groups_of(spec_index):
		for id: int in group.spawned_ids:
			w.get_unit(id).kill()


func _event_arrays(w: World) -> Array[PackedInt64Array]:
	var out: Array[PackedInt64Array] = []
	for e: MissionEvent in w.mission_events:
		out.append(e.to_array())
	return out


# --- World.roll_bindings ----------------------------------------------------


func test_roll_bindings_is_stable_for_a_seed() -> void:
	var script: MissionScript = _pool_script()
	for roll_seed: int in [0, 1, 7, 12345, -9]:
		assert_eq(
			World.roll_bindings(script, roll_seed), World.roll_bindings(script, roll_seed),
			"seed %d" % roll_seed
		)


func test_roll_bindings_varies_with_the_seed() -> void:
	var script: MissionScript = _pool_script()
	var distinct: Dictionary[String, bool] = {}
	for roll_seed: int in 30:
		distinct[str(World.roll_bindings(script, roll_seed))] = true
	assert_gt(distinct.size(), 5, "30 seeds should not all roll the same waves")


func test_roll_bindings_picks_distinct_groups_from_the_pool() -> void:
	var groups: Array[AiGroupSpec] = []
	var pool: Array[StringName] = []
	for i: int in 5:
		var group_name: StringName = StringName(char(97 + i))
		groups.append(MissionFixtures.group(group_name, 1, 10, 10, false))
		pool.append(group_name)
	var slots: Array[StringName] = [&"w1", &"w2", &"w3", &"w4"]
	var script: MissionScript = MissionFixtures.script(groups, [], [], [MissionFixtures.draw(slots, pool)])
	for roll_seed: int in 50:
		var bound: PackedInt32Array = World.roll_bindings(script, roll_seed)
		assert_eq(bound.size(), 4, "one group per slot")
		var seen: Dictionary[int, bool] = {}
		for g: int in bound:
			assert_between(g, 0, 4, "a group of the pool")
			seen[g] = true
		assert_eq(seen.size(), 4, "seed %d binds four different groups: %s" % [roll_seed, bound])


func test_every_pool_group_comes_up_across_seeds() -> void:
	var script: MissionScript = _pool_script()
	var seen: Dictionary[int, bool] = {}
	for roll_seed: int in 20:
		for g: int in World.roll_bindings(script, roll_seed):
			seen[g] = true
	assert_eq(seen.size(), 5, "no pool group is unreachable")


func test_ordered_binds_the_picks_in_ascending_pool_order() -> void:
	# The pool lists the groups in reverse of their script order, so pool order
	# and group index run opposite ways and the test can tell which one sorts.
	var groups: Array[AiGroupSpec] = []
	var pool: Array[StringName] = []
	for i: int in 5:
		groups.append(MissionFixtures.group(StringName(char(97 + i)), 1, 10, 10, false))
	for i: int in range(4, -1, -1):
		pool.append(StringName(char(97 + i)))
	var slots: Array[StringName] = [&"w1", &"w2", &"w3"]
	var ordered: MissionScript = MissionFixtures.script(groups, [], [], [MissionFixtures.draw(slots, pool, true)])
	var free: MissionScript = MissionFixtures.script(groups, [], [], [MissionFixtures.draw(slots, pool, false)])
	var free_was_unsorted: bool = false
	for roll_seed: int in 30:
		var bound: PackedInt32Array = World.roll_bindings(ordered, roll_seed)
		for k: int in 2:
			assert_gt(bound[k], bound[k + 1], "pool position rises, so the group index falls: %s" % bound)
		var loose: PackedInt32Array = World.roll_bindings(free, roll_seed)
		if not (loose[0] > loose[1] and loose[1] > loose[2]):
			free_was_unsorted = true
		var sorted_loose: Array[int] = [loose[0], loose[1], loose[2]]
		sorted_loose.sort()
		sorted_loose.reverse()
		var sorted_bound: Array[int] = [bound[0], bound[1], bound[2]]
		assert_eq(sorted_bound, sorted_loose, "ordering reorders the same picks, it doesn't change them")
	assert_true(free_was_unsorted, "without `ordered` the picks come in draw order")


func test_roll_bindings_covers_every_draw_in_order() -> void:
	var groups: Array[AiGroupSpec] = []
	for i: int in 6:
		groups.append(MissionFixtures.group(StringName(char(97 + i)), 1, 10, 10, false))
	var first: MissionDraw = MissionFixtures.draw([&"x1", &"x2"], [&"a", &"b", &"c"])
	var second: MissionDraw = MissionFixtures.draw([&"y1"], [&"d", &"e", &"f"])
	var script: MissionScript = MissionFixtures.script(groups, [], [], [first, second])
	for roll_seed: int in 20:
		var bound: PackedInt32Array = World.roll_bindings(script, roll_seed)
		assert_eq(bound.size(), 3)
		assert_between(bound[0], 0, 2, "draw 0 draws from its pool")
		assert_between(bound[1], 0, 2)
		assert_between(bound[2], 3, 5, "draw 1 draws from its own")


func test_a_script_without_draws_binds_nothing() -> void:
	assert_eq(World.roll_bindings(MissionFixtures.script([], []), 5), PackedInt32Array())


func test_roll_bindings_leaves_the_world_rng_alone() -> void:
	var w: World = World.new(42, TestTerrains.flat(60, 60), MissionFixtures.catalog())
	var before: int = w.rng.state
	assert_true(w.start_mission(_pool_script(), 0))
	assert_eq(w.rng.state, before, "start_mission draws nothing from the world's generator")
	var plain: World = World.new(42, TestTerrains.flat(60, 60), MissionFixtures.catalog())
	assert_eq(w.rng.state, plain.rng.state)


func test_start_mission_binds_with_the_roll_of_the_world_seed() -> void:
	var script: MissionScript = _pool_script()
	for world_seed: int in [1, 2, 99]:
		var w: World = MissionFixtures.world(script, 0, world_seed)
		assert_eq(w.mission.bindings, World.roll_bindings(script, world_seed), "seed %d" % world_seed)


func test_two_worlds_with_one_seed_roll_the_same_waves() -> void:
	var script: MissionScript = _pool_script([_spawn_waves_at(3)])
	var a: World = MissionFixtures.world(script, 0, 11)
	var b: World = MissionFixtures.world(script, 0, 11)
	MissionFixtures.run(a, 20)
	MissionFixtures.run(b, 20)
	assert_eq(a.state_hash(), b.state_hash())


# --- AiDirector.controls ----------------------------------------------------


func test_the_director_controls_the_units_it_spawned_and_no_others() -> void:
	var w: World = MissionFixtures.world(MissionFixtures.script([MissionFixtures.group(&"pack", 2)], []))
	var commanded: Unit = MissionFixtures.commanded(w, LIGHT, 30, 30)
	assert_false(w.ai.controls(commanded.id), "nothing has spawned yet")
	w.step()
	for id: int in w.ai.groups[0].spawned_ids:
		assert_true(w.ai.controls(id))
	assert_false(w.ai.controls(commanded.id), "a unit the player commands is not the AI's")
	assert_false(w.ai.controls(99_999), "an id nobody has")


func test_once_ai_always_ai() -> void:
	var w: World = MissionFixtures.world(MissionFixtures.script([MissionFixtures.group(&"pack", 2)], []))
	w.step()
	var id: int = w.ai.groups[0].spawned_ids[0]
	w.get_unit(id).kill()
	assert_true(w.ai.controls(id), "a dead unit of a group is still the group's")
	w.despawn_entity(id)
	assert_true(w.ai.controls(id), "and so is a despawned one")


# --- aliases ----------------------------------------------------------------


func test_spawn_group_on_an_alias_spawns_the_bound_group() -> void:
	var w: World = _pool_world([_spawn_waves_at(3)])
	MissionFixtures.run(w, 4)
	assert_eq(w.ai.groups.size(), 2)
	assert_eq(w.ai.groups[0].spec_index, 2, "wave1 is group c")
	assert_eq(w.ai.groups[1].spec_index, 4, "wave2 is group e")
	assert_eq(Vector2i(w.ai.groups[0].spawn_x, w.ai.groups[0].spawn_z), Vector2i(30 * M, 10 * M))
	assert_eq(Vector2i(w.ai.groups[1].spawn_x, w.ai.groups[1].spawn_z), Vector2i(50 * M, 10 * M))


func test_the_binding_decides_which_group_an_alias_means() -> void:
	var script: MissionScript = _pool_script([_spawn_waves_at(3)])
	var w: World = MissionFixtures.world_bound(script, PackedInt32Array([3, 0]))
	MissionFixtures.run(w, 4)
	assert_eq(w.ai.groups[0].spec_index, 3, "wave1 is now d")
	assert_eq(w.ai.groups[1].spec_index, 0, "and wave2 is a")


func test_a_pool_group_that_was_not_drawn_never_spawns() -> void:
	var w: World = _pool_world([_spawn_waves_at(3)])
	MissionFixtures.run(w, 200)
	for undrawn: int in [0, 1, 3]:
		assert_true(w.ai.groups_of(undrawn).is_empty(), "group %d was not drawn" % undrawn)
	assert_eq(w.units.size(), 4, "two groups of two")


func test_set_behavior_on_an_alias_switches_the_bound_group() -> void:
	var turn: TriggerSpec = MissionFixtures.timer(&"turn", 10, &"release")
	turn.actions.append(MissionFixtures.behavior_action(&"wave2", AiGroupSpec.Behavior.HUNT))
	var w: World = MissionFixtures.world_bound(
		_pool_script([_spawn_waves_at(3), turn]), PackedInt32Array([2, 4])
	)
	MissionFixtures.run(w, 20)
	assert_eq(w.ai.groups_of(2)[0].behavior, AiGroupSpec.Behavior.IDLE, "wave1 is untouched")
	assert_eq(w.ai.groups_of(4)[0].behavior, AiGroupSpec.Behavior.HUNT, "wave2 switched")
	for undrawn: int in [0, 1, 3]:
		assert_true(w.ai.groups_of(undrawn).is_empty())


func test_group_cleared_on_an_alias_waits_for_the_bound_group() -> void:
	var done: TriggerSpec = MissionFixtures.cleared(&"done", [&"wave1"])
	var w: World = _pool_world([_spawn_waves_at(3), done])
	MissionFixtures.run(w, 3)
	assert_eq(_fired(w, 1), -1, "wave1 hasn't spawned: an empty group isn't a cleared one")
	MissionFixtures.run(w, 5)
	assert_eq(_fired(w, 1), -1, "it has, and it's alive")
	_kill_all(w, 4)
	MissionFixtures.run(w, 3)
	assert_eq(_fired(w, 1), -1, "killing wave2 doesn't clear wave1")
	_kill_all(w, 2)
	w.step()
	assert_eq(_fired(w, 1), w.tick - 1, "wave1 dead")


func test_group_cleared_can_mix_aliases_and_plain_groups() -> void:
	var done: TriggerSpec = MissionFixtures.cleared(&"done", [&"wave1", &"guards"])
	var guards: AiGroupSpec = MissionFixtures.group(&"guards", 1, 40, 40)
	var script: MissionScript = _pool_script([_spawn_waves_at(3), done])
	script.groups.append(guards)
	var w: World = MissionFixtures.world_bound(script, PackedInt32Array([2, 4]))
	MissionFixtures.run(w, 6)
	_kill_all(w, 2)
	MissionFixtures.run(w, 3)
	assert_eq(_fired(w, 1), -1, "the guards are alive")
	_kill_all(w, 5)
	w.step()
	assert_gt(_fired(w, 1), 0)


func test_unit_dies_on_an_alias_counts_the_bound_groups_deaths() -> void:
	var two: TriggerSpec = MissionFixtures.dies(&"two", [&"wave1", &"wave2"], 2)
	var w: World = _pool_world([_spawn_waves_at(3), two])
	MissionFixtures.run(w, 6)
	var first: AiGroup = w.ai.groups_of(2)[0]
	w.get_unit(first.spawned_ids[0]).kill()
	MissionFixtures.run(w, 3)
	assert_eq(_fired(w, 1), -1, "one death")
	var second: AiGroup = w.ai.groups_of(4)[0]
	w.get_unit(second.spawned_ids[1]).kill()
	w.step()
	assert_eq(_fired(w, 1), w.tick - 1, "two, one in each wave")


func test_unit_dies_ignores_the_deaths_of_a_group_that_was_not_named() -> void:
	var one: TriggerSpec = MissionFixtures.dies(&"one", [&"wave1"], 1)
	var w: World = _pool_world([_spawn_waves_at(3), one])
	MissionFixtures.run(w, 6)
	_kill_all(w, 4)
	MissionFixtures.run(w, 3)
	assert_eq(_fired(w, 1), -1, "wave2 died, wave1 didn't")


func test_area_entered_on_an_alias_counts_only_the_bound_groups_units() -> void:
	# Group c spawns at (30, 10), group a at (10, 10): the area is around c.
	var near_c: TriggerSpec = MissionFixtures.area(&"near_c", 30, 10, 4, DARK, [&"wave1"])
	var script: MissionScript = _pool_script([_spawn_waves_at(3), near_c])
	var wave1_is_c: World = MissionFixtures.world_bound(script, PackedInt32Array([2, 4]))
	var wave2_is_c: World = MissionFixtures.world_bound(script, PackedInt32Array([0, 2]))
	MissionFixtures.run(wave1_is_c, 6)
	MissionFixtures.run(wave2_is_c, 6)
	assert_gt(_fired(wave1_is_c, 1), 0, "wave1 stands in the area")
	assert_eq(_fired(wave2_is_c, 1), -1, "wave2 does, but the trigger names wave1")


# --- TRIGGERS_FIRED ---------------------------------------------------------


func test_triggers_fired_fires_one_tick_after_its_last_prerequisite() -> void:
	var both: TriggerSpec = MissionFixtures.fired(&"both", [&"a", &"b"], 2)
	var w: World = MissionFixtures.world(MissionFixtures.script(
		[], [MissionFixtures.timer(&"a", 5), MissionFixtures.timer(&"b", 10), both]
	))
	MissionFixtures.run(w, 11)
	assert_eq(_fired(w, 0), 5)
	assert_eq(_fired(w, 1), 10)
	assert_eq(_fired(w, 2), -1, "b fired this tick: a link takes a tick, like `after`")
	w.step()
	assert_eq(_fired(w, 2), 11)


func test_triggers_fired_never_fires_on_the_tick_its_prerequisite_does() -> void:
	var gate: TriggerSpec = MissionFixtures.timer(&"gate", 5)
	var link: TriggerSpec = MissionFixtures.fired(&"link", [&"gate"])
	var w: World = MissionFixtures.world(MissionFixtures.script([], [gate, link]))
	MissionFixtures.run(w, 5)
	assert_eq(_fired(w, 0), -1)
	w.step()
	assert_eq(_fired(w, 0), 5)
	assert_eq(_fired(w, 1), -1, "same tick: no")
	w.step()
	assert_eq(_fired(w, 1), 6, "next tick: yes")


func test_triggers_fired_may_name_a_trigger_listed_after_it() -> void:
	var link: TriggerSpec = MissionFixtures.fired(&"link", [&"late"])
	var w: World = MissionFixtures.world(MissionFixtures.script([], [link, MissionFixtures.timer(&"late", 4)]))
	MissionFixtures.run(w, 10)
	assert_eq(_fired(w, 1), 4)
	assert_eq(_fired(w, 0), 5)


func test_triggers_fired_waits_for_min_count_of_several() -> void:
	var two_of_three: TriggerSpec = MissionFixtures.fired(&"two", [&"a", &"b", &"c"], 2)
	var w: World = MissionFixtures.world(MissionFixtures.script(
		[], [MissionFixtures.timer(&"a", 5), MissionFixtures.timer(&"b", 20), MissionFixtures.timer(&"c", 12), two_of_three]
	))
	MissionFixtures.run(w, 13)
	assert_eq(_fired(w, 3), -1, "a is one; c fired on 12, so it is not yet seen")
	w.step()
	assert_eq(_fired(w, 3), 13, "a and c")


func test_any_of_fires_once_even_when_every_prerequisite_fires() -> void:
	var any: TriggerSpec = MissionFixtures.fired(&"any", [&"a", &"b"], 1)
	any.actions.append(MissionFixtures.action(TriggerAction.Kind.SET_OBJECTIVE))
	var w: World = MissionFixtures.world(MissionFixtures.script(
		[], [MissionFixtures.timer(&"a", 5), MissionFixtures.timer(&"b", 8), any]
	))
	MissionFixtures.run(w, 40)
	assert_eq(_fired(w, 2), 6, "one tick after the first of them")
	assert_eq(w.mission.objective_revision, 1, "its action ran once, not once per prerequisite")


func test_any_of_two_prerequisites_firing_on_the_same_tick_fires_once() -> void:
	var any: TriggerSpec = MissionFixtures.fired(&"any", [&"a", &"b"], 1)
	any.actions.append(MissionFixtures.action(TriggerAction.Kind.SET_OBJECTIVE))
	var w: World = MissionFixtures.world(MissionFixtures.script(
		[], [MissionFixtures.timer(&"a", 5), MissionFixtures.timer(&"b", 5), any]
	))
	MissionFixtures.run(w, 20)
	assert_eq(_fired(w, 2), 6)
	assert_eq(w.mission.objective_revision, 1)


func test_triggers_fired_chains_a_tick_per_link() -> void:
	var w: World = MissionFixtures.world(MissionFixtures.script([], [
		MissionFixtures.timer(&"a", 3),
		MissionFixtures.fired(&"b", [&"a"]),
		MissionFixtures.fired(&"c", [&"b"]),
	]))
	MissionFixtures.run(w, 10)
	assert_eq(_fired(w, 0), 3)
	assert_eq(_fired(w, 1), 4)
	assert_eq(_fired(w, 2), 5)


# --- PLAYER_ELIMINATED ------------------------------------------------------


func _light_allies() -> AiGroupSpec:
	var allies: AiGroupSpec = MissionFixtures.group(&"allies", 2, 40, 40)
	allies.faction = LIGHT
	return allies


func test_player_eliminated_fires_when_the_last_commanded_unit_dies() -> void:
	var w: World = MissionFixtures.world(MissionFixtures.script([], [MissionFixtures.player_eliminated(&"wiped")]))
	var a: Unit = MissionFixtures.commanded(w, LIGHT, 10, 10)
	var b: Unit = MissionFixtures.commanded(w, LIGHT, 12, 10)
	MissionFixtures.run(w, 3)
	a.kill()
	MissionFixtures.run(w, 3)
	assert_eq(_fired(w, 0), -1, "one is left")
	b.kill()
	w.step()
	assert_eq(_fired(w, 0), 6)


func test_player_eliminated_ignores_a_living_ai_controlled_unit_of_the_side() -> void:
	var wiped: TriggerSpec = MissionFixtures.player_eliminated(&"wiped")
	var plain: TriggerSpec = MissionFixtures.trigger(&"plain", TriggerSpec.Condition.FACTION_ELIMINATED)
	var w: World = MissionFixtures.world(MissionFixtures.script([_light_allies()], [wiped, plain]))
	var mine: Unit = MissionFixtures.commanded(w, LIGHT, 10, 10)
	MissionFixtures.run(w, 3)
	assert_eq(w.ai.groups[0].members.size(), 2, "the allies are alive, and the AI's")
	mine.kill()
	w.step()
	assert_eq(_fired(w, 0), 3, "the player has nobody left, whatever the AI's Light side has")
	assert_eq(_fired(w, 1), -1, "FACTION_ELIMINATED still sees the allies")


func test_player_eliminated_does_not_count_a_side_that_only_the_ai_ever_had() -> void:
	var w: World = MissionFixtures.world(MissionFixtures.script(
		[_light_allies()], [MissionFixtures.player_eliminated(&"wiped")]
	))
	MissionFixtures.run(w, 60)
	assert_eq(_fired(w, 0), -1, "the player never had a unit here")


func test_player_eliminated_does_not_fire_on_tick_zero_before_light_has_spawned() -> void:
	var w: World = MissionFixtures.world(MissionFixtures.script([], [MissionFixtures.player_eliminated(&"wiped")]))
	MissionFixtures.run(w, 50)
	assert_eq(_fired(w, 0), -1, "no commanded Light unit has existed yet")
	var late: Unit = MissionFixtures.commanded(w, LIGHT, 10, 10)
	MissionFixtures.run(w, 5)
	assert_eq(_fired(w, 0), -1, "one arrived")
	late.kill()
	w.step()
	assert_eq(_fired(w, 0), 55, "and then died")


func test_player_eliminated_is_per_faction() -> void:
	var for_dark: TriggerSpec = MissionFixtures.player_eliminated(&"dark_wiped", DARK)
	var w: World = MissionFixtures.world(MissionFixtures.script([], [for_dark]))
	MissionFixtures.commanded(w, LIGHT, 10, 10)
	var dark: Unit = MissionFixtures.commanded(w, DARK, 20, 20)
	MissionFixtures.run(w, 3)
	assert_eq(_fired(w, 0), -1)
	dark.kill()
	w.step()
	assert_eq(_fired(w, 0), 3)


# --- AREA_ENTERED with names ------------------------------------------------


func test_area_entered_with_no_names_counts_every_unit_of_the_faction() -> void:
	var w: World = MissionFixtures.world(MissionFixtures.script([], [MissionFixtures.area(&"zone", 30, 30, 3)]))
	MissionFixtures.commanded(w, LIGHT, 30, 30)
	w.step()
	assert_eq(_fired(w, 0), 0)


func test_area_entered_with_names_ignores_units_outside_the_named_groups() -> void:
	var zone: TriggerSpec = MissionFixtures.area(&"zone", 30, 30, 3, LIGHT, [&"escort"])
	var escort: AiGroupSpec = MissionFixtures.group(&"escort", 1, 10, 10)
	escort.faction = LIGHT
	var w: World = MissionFixtures.world(MissionFixtures.script([escort], [zone]))
	MissionFixtures.commanded(w, LIGHT, 30, 30)
	MissionFixtures.run(w, 5)
	assert_eq(_fired(w, 0), -1, "a commanded unit stands inside, but it isn't in the escort")


func test_area_entered_with_names_fires_for_a_named_groups_unit() -> void:
	var zone: TriggerSpec = MissionFixtures.area(&"zone", 30, 30, 3, LIGHT, [&"escort"])
	var escort: AiGroupSpec = MissionFixtures.group(&"escort", 1, 30, 30)
	escort.faction = LIGHT
	var w: World = MissionFixtures.world(MissionFixtures.script([escort], [zone]))
	w.step()
	assert_eq(_fired(w, 0), 0, "the escort spawned inside, and conditions read it that tick")


func test_area_entered_with_names_does_not_count_the_dead() -> void:
	var zone: TriggerSpec = MissionFixtures.area(&"zone", 30, 30, 3, LIGHT, [&"escort"])
	var wait: TriggerSpec = MissionFixtures.timer(&"wait", 3)
	var escort: AiGroupSpec = MissionFixtures.group(&"escort", 1, 30, 30, false)
	escort.faction = LIGHT
	wait.actions.append(MissionFixtures.spawn_action(&"escort"))
	var w: World = MissionFixtures.world(MissionFixtures.script([escort], [wait, zone]))
	MissionFixtures.run(w, 4)
	_kill_all(w, 0)
	MissionFixtures.run(w, 3)
	assert_eq(_fired(w, 1), -1, "the escort stood inside, but it is dead")


func test_area_entered_with_names_still_needs_the_faction() -> void:
	var zone: TriggerSpec = MissionFixtures.area(&"zone", 30, 30, 3, DARK, [&"escort"])
	var escort: AiGroupSpec = MissionFixtures.group(&"escort", 1, 30, 30)
	escort.faction = LIGHT
	var w: World = MissionFixtures.world(MissionFixtures.script([escort], [zone]))
	MissionFixtures.run(w, 5)
	assert_eq(_fired(w, 0), -1, "a LIGHT escort is not a DARK unit")


func test_area_entered_with_names_waits_for_min_count_among_them() -> void:
	var named: TriggerSpec = MissionFixtures.area(&"named", 30, 30, 6, DARK, [&"pack"])
	named.min_count = 3
	var everyone: TriggerSpec = MissionFixtures.area(&"everyone", 30, 30, 6, DARK)
	everyone.min_count = 3
	var pack: AiGroupSpec = MissionFixtures.group(&"pack", 2, 30, 30)
	var other: AiGroupSpec = MissionFixtures.group(&"other", 4, 30, 30)
	var w: World = MissionFixtures.world(MissionFixtures.script([pack, other], [named, everyone]))
	MissionFixtures.run(w, 5)
	assert_eq(_fired(w, 1), 0, "six dark units stand inside")
	assert_eq(_fired(w, 0), -1, "but the named group has two")


# --- objectives -------------------------------------------------------------


func _objective_world(triggers: Array[TriggerSpec]) -> World:
	var objectives: Array[ObjectiveSpec] = [
		MissionFixtures.objective(&"cross", "Cross the ford"),
		MissionFixtures.objective(&"loot", "Take the chest", true, false),
	]
	return MissionFixtures.world(MissionFixtures.script([], triggers, objectives))


func _objective_trigger(
	trigger_name: StringName, tick: int, kind: TriggerAction.Kind, objective_name: StringName
) -> TriggerSpec:
	var t: TriggerSpec = MissionFixtures.timer(trigger_name, tick)
	t.actions.append(MissionFixtures.objective_action(kind, objective_name))
	return t


func test_objectives_start_active_or_hidden_by_shown_at_start() -> void:
	var w: World = _objective_world([])
	assert_eq(w.mission.objective_count(), 2)
	assert_eq(w.mission.objective_state(0), ACTIVE)
	assert_eq(w.mission.objective_state(1), HIDDEN)
	assert_eq(w.mission.objective_states, PackedInt32Array([ACTIVE, HIDDEN]))
	w.step()
	assert_true(w.mission_events.is_empty(), "the opening states are not changes")


func test_objective_getters() -> void:
	var w: World = _objective_world([])
	assert_eq(w.mission.objective_text(0), "Cross the ford")
	assert_eq(w.mission.objective_text(1), "Take the chest")
	assert_false(w.mission.objective_optional(0))
	assert_true(w.mission.objective_optional(1))


func test_show_objective_reveals_a_hidden_one_and_reports_it() -> void:
	var w: World = _objective_world([_objective_trigger(&"reveal", 2, TriggerAction.Kind.SHOW_OBJECTIVE, &"loot")])
	MissionFixtures.run(w, 2)
	assert_eq(w.mission.objective_state(1), HIDDEN)
	w.step()
	assert_eq(w.mission.objective_state(1), ACTIVE)
	assert_eq(_event_arrays(w), [
		PackedInt64Array([MissionEvent.Kind.TRIGGER_FIRED, 0]),
		PackedInt64Array([OBJ_STATE, 0, 1, ACTIVE]),
	])


func test_show_objective_changes_nothing_that_is_already_shown() -> void:
	var w: World = _objective_world([_objective_trigger(&"again", 2, TriggerAction.Kind.SHOW_OBJECTIVE, &"cross")])
	MissionFixtures.run(w, 3)
	assert_eq(w.mission.objective_state(0), ACTIVE)
	assert_eq(_event_arrays(w), [PackedInt64Array([MissionEvent.Kind.TRIGGER_FIRED, 0])], "no state event")


func test_complete_objective_from_active_and_from_hidden() -> void:
	var triggers: Array[TriggerSpec] = [
		_objective_trigger(&"one", 2, TriggerAction.Kind.COMPLETE_OBJECTIVE, &"cross"),
		_objective_trigger(&"two", 4, TriggerAction.Kind.COMPLETE_OBJECTIVE, &"loot"),
	]
	var w: World = _objective_world(triggers)
	MissionFixtures.run(w, 3)
	assert_eq(w.mission.objective_state(0), DONE, "from ACTIVE")
	assert_eq(w.mission.objective_state(1), HIDDEN)
	MissionFixtures.run(w, 2)
	assert_eq(w.mission.objective_state(1), DONE, "from HIDDEN, without being shown first")
	assert_eq(_event_arrays(w)[1], PackedInt64Array([OBJ_STATE, 1, 1, DONE]))


func test_fail_objective_from_active_and_from_hidden() -> void:
	var triggers: Array[TriggerSpec] = [
		_objective_trigger(&"one", 2, TriggerAction.Kind.FAIL_OBJECTIVE, &"cross"),
		_objective_trigger(&"two", 4, TriggerAction.Kind.FAIL_OBJECTIVE, &"loot"),
	]
	var w: World = _objective_world(triggers)
	MissionFixtures.run(w, 5)
	assert_eq(w.mission.objective_states, PackedInt32Array([FAILED, FAILED]))


func test_done_and_failed_are_terminal() -> void:
	var triggers: Array[TriggerSpec] = [
		_objective_trigger(&"win", 2, TriggerAction.Kind.COMPLETE_OBJECTIVE, &"cross"),
		_objective_trigger(&"lose", 5, TriggerAction.Kind.FAIL_OBJECTIVE, &"loot"),
		_objective_trigger(&"flip_done", 8, TriggerAction.Kind.FAIL_OBJECTIVE, &"cross"),
		_objective_trigger(&"flip_failed", 8, TriggerAction.Kind.COMPLETE_OBJECTIVE, &"loot"),
		_objective_trigger(&"show_done", 9, TriggerAction.Kind.SHOW_OBJECTIVE, &"cross"),
		_objective_trigger(&"show_failed", 9, TriggerAction.Kind.SHOW_OBJECTIVE, &"loot"),
		_objective_trigger(&"redo", 10, TriggerAction.Kind.COMPLETE_OBJECTIVE, &"cross"),
	]
	var w: World = _objective_world(triggers)
	var state_events: int = 0
	for _t: int in 14:
		w.step()
		for e: MissionEvent in w.mission_events:
			if e.kind == OBJ_STATE:
				state_events += 1
	assert_eq(w.mission.objective_state(0), DONE, "never undone by a later FAIL, SHOW or COMPLETE")
	assert_eq(w.mission.objective_state(1), FAILED, "never undone by a later COMPLETE or SHOW")
	assert_eq(state_events, 2, "only the two real changes were reported")


func test_an_unchanged_objective_still_lets_the_trigger_fire() -> void:
	var redo: TriggerSpec = _objective_trigger(&"redo", 6, TriggerAction.Kind.COMPLETE_OBJECTIVE, &"cross")
	var w: World = _objective_world([
		_objective_trigger(&"win", 2, TriggerAction.Kind.COMPLETE_OBJECTIVE, &"cross"), redo,
	])
	MissionFixtures.run(w, 8)
	assert_eq(_fired(w, 1), 6)


func test_objective_actions_leave_the_message_line_alone() -> void:
	var w: World = _objective_world([_objective_trigger(&"win", 2, TriggerAction.Kind.COMPLETE_OBJECTIVE, &"cross")])
	MissionFixtures.run(w, 5)
	assert_eq(w.mission.objective, "")
	assert_eq(w.mission.objective_revision, 0)
	assert_eq(w.mission.objective_trigger, -1)


func test_set_objective_is_unchanged_by_the_new_states() -> void:
	var set_text: TriggerSpec = MissionFixtures.timer(&"say", 2)
	var a: TriggerAction = MissionFixtures.action(TriggerAction.Kind.SET_OBJECTIVE)
	a.text = "Hold the mill"
	set_text.actions.append(a)
	var w: World = _objective_world([set_text])
	MissionFixtures.run(w, 3)
	assert_eq(w.mission.objective, "Hold the mill")
	assert_eq(w.mission.objective_revision, 1)
	assert_eq(w.mission.objective_states, PackedInt32Array([ACTIVE, HIDDEN]))


func test_one_trigger_can_change_several_objectives() -> void:
	var t: TriggerSpec = MissionFixtures.timer(&"both", 2)
	t.actions.append(MissionFixtures.objective_action(TriggerAction.Kind.COMPLETE_OBJECTIVE, &"cross"))
	t.actions.append(MissionFixtures.objective_action(TriggerAction.Kind.SHOW_OBJECTIVE, &"loot"))
	var w: World = _objective_world([t])
	MissionFixtures.run(w, 3)
	assert_eq(w.mission.objective_states, PackedInt32Array([DONE, ACTIVE]))
	assert_eq(_event_arrays(w), [
		PackedInt64Array([MissionEvent.Kind.TRIGGER_FIRED, 0]),
		PackedInt64Array([OBJ_STATE, 0, 0, DONE]),
		PackedInt64Array([OBJ_STATE, 0, 1, ACTIVE]),
	])


func test_an_objective_events_array_carries_the_objective_and_its_state() -> void:
	var e: MissionEvent = MissionEvent.new(OBJ_STATE, 3, "", 2, FAILED)
	assert_eq(e.to_array(), PackedInt64Array([OBJ_STATE, 3, 2, FAILED]))
	assert_eq(MissionEvent.new(MissionEvent.Kind.WON, 1).to_array(), PackedInt64Array([MissionEvent.Kind.WON, 1]))


# --- the hash ---------------------------------------------------------------


func test_the_hash_covers_the_bindings() -> void:
	var script: MissionScript = _pool_script()
	var a: World = MissionFixtures.world_bound(script, PackedInt32Array([2, 4]))
	var b: World = MissionFixtures.world_bound(script, PackedInt32Array([2, 4]))
	assert_eq(a.state_hash(), b.state_hash())
	var c: World = MissionFixtures.world_bound(script, PackedInt32Array([4, 2]))
	assert_ne(a.state_hash(), c.state_hash(), "the same waves in another order")
	var d: World = MissionFixtures.world_bound(script, PackedInt32Array([2, 3]))
	assert_ne(a.state_hash(), d.state_hash(), "a different wave")


func test_the_hash_covers_the_objective_states() -> void:
	var a: World = _objective_world([])
	var b: World = _objective_world([])
	assert_eq(a.state_hash(), b.state_hash())
	b.mission.objective_states[1] = ACTIVE
	assert_ne(a.state_hash(), b.state_hash())
	b.mission.objective_states[1] = HIDDEN
	assert_eq(a.state_hash(), b.state_hash())


func test_the_hash_covers_seen_commanded() -> void:
	var a: World = _objective_world([])
	var b: World = _objective_world([])
	b.mission.seen_commanded = 1 << LIGHT
	assert_ne(a.state_hash(), b.state_hash())


func test_the_hash_separates_the_bindings_from_the_objective_states() -> void:
	# Each array's size is hashed first, so the boundary can't slide: bindings
	# [x] with states [] is not bindings [] with states [x].
	var groups: Array[AiGroupSpec] = [MissionFixtures.group(&"a", 1, 10, 10, false)]
	var with_draw: MissionScript = MissionFixtures.script(
		groups, [], [], [MissionFixtures.draw([&"w1"], [&"a"])]
	)
	var with_objective: MissionScript = MissionFixtures.script(
		[], [], [MissionFixtures.objective(&"o")]
	)
	var a: World = MissionFixtures.world_bound(with_draw, PackedInt32Array([0]))
	var b: World = MissionFixtures.world_bound(with_objective, PackedInt32Array())
	b.mission.objective_states[0] = 0
	assert_ne(a.mission.hash_fields(), b.mission.hash_fields())


func test_objective_text_is_not_hashed() -> void:
	var one: MissionScript = MissionFixtures.script([], [], [MissionFixtures.objective(&"o", "Cross")])
	var other: MissionScript = MissionFixtures.script([], [], [MissionFixtures.objective(&"o", "Ford it")])
	assert_eq(
		MissionFixtures.world(one).state_hash(), MissionFixtures.world(other).state_hash(),
		"display text isn't state"
	)
