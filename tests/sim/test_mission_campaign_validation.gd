extends GutTest
## MissionScript.validate() for the Phase 8 mission format: objectives, draws
## and aliases, TRIGGERS_FIRED, PLAYER_ELIMINATED, AREA_ENTERED's group names,
## and the objective actions. Each rule gets one test that starts from a script
## that validates clean and breaks one thing, like test_mission_script.gd.

const LIGHT: UnitType.Faction = MissionFixtures.LIGHT
const DARK: UnitType.Faction = MissionFixtures.DARK

var _catalog: UnitCatalog


func before_each() -> void:
	_catalog = MissionFixtures.catalog()


# --- fixtures ---------------------------------------------------------------


## A script that uses every new rule and breaks none: two objectives, a guard
## group that spawns at start, a pool of three groups (a, b, c) drawn into the
## slots wave1 and wave2, and triggers that name the waves by alias, link
## triggers, watch the player, and drive the objectives.
func _valid_script() -> MissionScript:
	var groups: Array[AiGroupSpec] = [
		MissionFixtures.group(&"guards", 2, 40, 40),
		MissionFixtures.group(&"a", 2, 10, 10, false),
		MissionFixtures.group(&"b", 2, 20, 10, false),
		MissionFixtures.group(&"c", 2, 30, 10, false),
	]
	var objectives: Array[ObjectiveSpec] = [
		MissionFixtures.objective(&"cross", "Cross the ford"),
		MissionFixtures.objective(&"loot", "Take the chest", true, false),
	]
	var draws: Array[MissionDraw] = [
		MissionFixtures.draw([&"wave1", &"wave2"], [&"a", &"b", &"c"])
	]
	var release: TriggerSpec = MissionFixtures.timer(&"release", 30)
	release.actions.append(MissionFixtures.spawn_action(&"wave1"))
	release.actions.append(MissionFixtures.behavior_action(&"wave1", AiGroupSpec.Behavior.HUNT))
	release.actions.append(MissionFixtures.objective_action(TriggerAction.Kind.SHOW_OBJECTIVE, &"loot"))
	var second: TriggerSpec = MissionFixtures.fired(&"second", [&"release", &"wiped"], 1)
	second.actions.append(MissionFixtures.spawn_action(&"wave2"))
	var swept: TriggerSpec = MissionFixtures.cleared(&"swept", [&"wave1", &"wave2", &"guards"])
	swept.actions.append(MissionFixtures.objective_action(TriggerAction.Kind.COMPLETE_OBJECTIVE, &"cross"))
	var wiped: TriggerSpec = MissionFixtures.player_eliminated(&"wiped")
	wiped.actions.append(MissionFixtures.objective_action(TriggerAction.Kind.FAIL_OBJECTIVE, &"cross"))
	wiped.actions.append(MissionFixtures.action(TriggerAction.Kind.LOSE))
	var arrived: TriggerSpec = MissionFixtures.area(&"arrived", 30, 30, 3, DARK, [&"wave2", &"guards"])
	var triggers: Array[TriggerSpec] = [release, second, swept, wiped, arrived]
	return MissionFixtures.script(groups, triggers, objectives, draws)


func _trigger(s: MissionScript, trigger_name: StringName) -> TriggerSpec:
	return s.triggers[s.trigger_index(trigger_name)]


func _joined(errors: PackedStringArray) -> String:
	return "\n".join(errors)


## The script is rejected, and one of its errors says `expected`.
func _assert_error(s: MissionScript, expected: String) -> void:
	var errors: PackedStringArray = s.validate(_catalog)
	assert_gt(errors.size(), 0, "something should be wrong")
	assert_string_contains(_joined(errors), expected)


# --- the baseline and the lookups ------------------------------------------


func test_the_baseline_script_is_clean() -> void:
	assert_eq(_valid_script().validate(_catalog), PackedStringArray())


func test_a_script_without_objectives_or_draws_is_unaffected() -> void:
	var s: MissionScript = MissionFixtures.script([MissionFixtures.group(&"pack")], [MissionFixtures.timer(&"t", 5)])
	assert_eq(s.validate(_catalog), PackedStringArray())
	assert_eq(s.objectives.size(), 0)
	assert_eq(s.draws.size(), 0)


func test_objective_index() -> void:
	var s: MissionScript = _valid_script()
	assert_eq(s.objective_index(&"cross"), 0)
	assert_eq(s.objective_index(&"loot"), 1)
	assert_eq(s.objective_index(&"nobody"), -1)


func test_alias_draw_finds_the_draw_and_the_slot() -> void:
	var s: MissionScript = _valid_script()
	s.draws.append(MissionFixtures.draw([&"extra"], [&"a"]))
	assert_eq(s.alias_draw(&"wave1"), Vector2i(0, 0))
	assert_eq(s.alias_draw(&"wave2"), Vector2i(0, 1))
	assert_eq(s.alias_draw(&"extra"), Vector2i(1, 0))
	assert_eq(s.alias_draw(&"a"), Vector2i(-1, -1), "a group is not an alias")
	assert_eq(s.alias_draw(&"nobody"), Vector2i(-1, -1))
	assert_eq(s.alias_draw(&""), Vector2i(-1, -1))


func test_alias_draw_skips_a_null_draw() -> void:
	var s: MissionScript = _valid_script()
	s.draws.insert(0, null)
	assert_eq(s.alias_draw(&"wave2"), Vector2i(1, 1))


# --- objectives -------------------------------------------------------------


func test_a_null_objective() -> void:
	var s: MissionScript = _valid_script()
	s.objectives.append(null)
	_assert_error(s, "objective 2 is null")


func test_an_objective_with_no_name() -> void:
	var s: MissionScript = _valid_script()
	s.objectives[1].name = &""
	_assert_error(s, "objective 1: name is empty")


func test_duplicate_objective_names() -> void:
	var s: MissionScript = _valid_script()
	s.objectives[1].name = &"cross"
	_assert_error(s, "duplicate objective name cross")


func test_an_objective_action_must_name_an_objective() -> void:
	for kind: TriggerAction.Kind in [
		TriggerAction.Kind.SHOW_OBJECTIVE, TriggerAction.Kind.COMPLETE_OBJECTIVE,
		TriggerAction.Kind.FAIL_OBJECTIVE,
	]:
		var s: MissionScript = _valid_script()
		_trigger(s, &"release").actions.append(MissionFixtures.objective_action(kind, &"nowhere"))
		_assert_error(s, "unknown objective nowhere")


func test_an_objective_action_with_no_objective() -> void:
	var s: MissionScript = _valid_script()
	_trigger(s, &"release").actions.append(
		MissionFixtures.objective_action(TriggerAction.Kind.SHOW_OBJECTIVE, &"")
	)
	_assert_error(s, "unknown objective")


func test_a_script_with_objective_actions_but_no_objectives() -> void:
	var s: MissionScript = _valid_script()
	s.objectives.clear()
	_assert_error(s, "unknown objective cross")


func test_the_objective_field_is_ignored_by_other_kinds() -> void:
	var s: MissionScript = _valid_script()
	var spawn: TriggerAction = _trigger(s, &"release").actions[0]
	spawn.objective = &"nowhere"
	assert_eq(s.validate(_catalog), PackedStringArray())


# --- draws ------------------------------------------------------------------


func test_a_null_draw() -> void:
	var s: MissionScript = _valid_script()
	s.draws.append(null)
	_assert_error(s, "draw 1 is null")


func test_a_draw_with_no_slots() -> void:
	var s: MissionScript = _valid_script()
	s.draws[0].slots.clear()
	_assert_error(s, "draw 0 needs at least one slot")


func test_a_draw_with_more_slots_than_pool_groups() -> void:
	var s: MissionScript = _valid_script()
	s.draws[0].slots.append(&"wave3")
	s.draws[0].slots.append(&"wave4")
	_assert_error(s, "draw 0 has 4 slots but only 3 pool groups")


func test_a_draw_may_use_every_group_of_its_pool() -> void:
	var s: MissionScript = _valid_script()
	s.draws[0].slots.append(&"wave3")
	assert_eq(s.validate(_catalog), PackedStringArray())


func test_an_alias_with_no_name() -> void:
	var s: MissionScript = _valid_script()
	s.draws[0].slots[1] = &""
	_assert_error(s, "draw 0: alias name is empty")


func test_duplicate_aliases_within_a_draw() -> void:
	var s: MissionScript = _valid_script()
	s.draws[0].slots[1] = &"wave1"
	_assert_error(s, "draw 0: duplicate alias name wave1")


func test_duplicate_aliases_across_draws() -> void:
	var s: MissionScript = _valid_script()
	s.groups.append(MissionFixtures.group(&"d", 1, 10, 10, false))
	s.draws.append(MissionFixtures.draw([&"wave1"], [&"d"]))
	_assert_error(s, "draw 1: duplicate alias name wave1")


func test_an_alias_cannot_be_a_group_name() -> void:
	var s: MissionScript = _valid_script()
	s.draws[0].slots[0] = &"guards"
	_assert_error(s, "draw 0: alias guards is also a group name")


func test_an_alias_cannot_be_the_name_of_a_pool_group() -> void:
	var s: MissionScript = _valid_script()
	s.draws[0].slots[0] = &"a"
	_assert_error(s, "draw 0: alias a is also a group name")


func test_a_pool_entry_must_be_a_group() -> void:
	var s: MissionScript = _valid_script()
	s.draws[0].pool[2] = &"ghost"
	_assert_error(s, "draw 0: unknown pool group ghost")


func test_a_pool_group_cannot_be_in_two_draws() -> void:
	var s: MissionScript = _valid_script()
	s.draws.append(MissionFixtures.draw([&"other"], [&"b"]))
	_assert_error(s, "draw 1: pool group b is already in a pool")


func test_a_pool_group_cannot_be_listed_twice_in_one_pool() -> void:
	var s: MissionScript = _valid_script()
	s.draws[0].pool[2] = &"a"
	_assert_error(s, "draw 0: pool group a is already in a pool")


func test_a_pool_group_cannot_spawn_at_start() -> void:
	var s: MissionScript = _valid_script()
	s.groups[2].spawn_at_start = true
	_assert_error(s, "draw 0: pool group b spawns at start")


func test_a_trigger_cannot_name_a_pool_group_in_a_condition() -> void:
	for condition: TriggerSpec.Condition in [
		TriggerSpec.Condition.UNIT_DIES, TriggerSpec.Condition.GROUP_CLEARED,
		TriggerSpec.Condition.AREA_ENTERED,
	]:
		var s: MissionScript = _valid_script()
		var t: TriggerSpec = MissionFixtures.trigger(&"direct", condition)
		t.area = PackedInt32Array([10_000, 10_000, 3000])
		t.names.append(&"a")
		s.triggers.append(t)
		_assert_error(s, "trigger direct: pool group a can only be named through an alias")


func test_a_trigger_cannot_name_a_pool_group_in_an_action() -> void:
	for kind: TriggerAction.Kind in [TriggerAction.Kind.SPAWN_GROUP, TriggerAction.Kind.SET_BEHAVIOR]:
		var s: MissionScript = _valid_script()
		var a: TriggerAction = MissionFixtures.action(kind)
		a.group = &"c"
		a.behavior = AiGroupSpec.Behavior.HUNT
		_trigger(s, &"release").actions.append(a)
		_assert_error(s, "pool group c can only be named through an alias")


func test_a_group_outside_every_pool_can_still_be_named() -> void:
	var s: MissionScript = _valid_script()
	var a: TriggerAction = MissionFixtures.spawn_action(&"guards")
	_trigger(s, &"release").actions.append(a)
	assert_eq(s.validate(_catalog), PackedStringArray())


func test_aliases_work_in_every_group_reference() -> void:
	var s: MissionScript = _valid_script()
	var dies: TriggerSpec = MissionFixtures.dies(&"dies", [&"wave1", &"wave2"], 2)
	dies.actions.append(MissionFixtures.spawn_action(&"wave2"))
	dies.actions.append(MissionFixtures.behavior_action(&"wave2", AiGroupSpec.Behavior.HUNT))
	s.triggers.append(dies)
	assert_eq(s.validate(_catalog), PackedStringArray())


func test_set_behavior_on_an_alias_checks_every_pool_group() -> void:
	var s: MissionScript = _valid_script()
	# GUARD needs a guard_radius, and only two of the three pool groups have one.
	s.groups[1].guard_radius = 5000
	s.groups[3].guard_radius = 5000
	_trigger(s, &"release").actions.append(
		MissionFixtures.behavior_action(&"wave1", AiGroupSpec.Behavior.GUARD)
	)
	var errors: PackedStringArray = s.validate(_catalog)
	assert_eq(errors.size(), 1, "one pool group lacks the parameter: %s" % [errors])
	assert_string_contains(_joined(errors), "group b: GUARD needs guard_radius > 0")


func test_set_behavior_on_an_alias_is_clean_when_the_whole_pool_can_take_it() -> void:
	var s: MissionScript = _valid_script()
	for i: int in range(1, 4):
		s.groups[i].guard_radius = 5000
	_trigger(s, &"release").actions.append(
		MissionFixtures.behavior_action(&"wave2", AiGroupSpec.Behavior.GUARD)
	)
	assert_eq(s.validate(_catalog), PackedStringArray())


func test_set_behavior_retreat_on_an_alias_is_rejected() -> void:
	var s: MissionScript = _valid_script()
	_trigger(s, &"release").actions.append(
		MissionFixtures.behavior_action(&"wave1", AiGroupSpec.Behavior.RETREAT)
	)
	_assert_error(s, "RETREAT is entered by the AI, not set")


# --- TRIGGERS_FIRED ---------------------------------------------------------


func test_triggers_fired_needs_names() -> void:
	var s: MissionScript = _valid_script()
	_trigger(s, &"second").names.clear()
	_assert_error(s, "trigger second: TRIGGERS_FIRED needs at least one trigger name")


func test_triggers_fired_names_must_be_triggers() -> void:
	var s: MissionScript = _valid_script()
	_trigger(s, &"second").names[0] = &"nowhere"
	_assert_error(s, "trigger second: TRIGGERS_FIRED names no trigger (nowhere)")


func test_triggers_fired_cannot_name_a_group() -> void:
	var s: MissionScript = _valid_script()
	_trigger(s, &"second").names[0] = &"guards"
	_assert_error(s, "trigger second: TRIGGERS_FIRED names no trigger (guards)")


func test_triggers_fired_cannot_name_an_alias() -> void:
	var s: MissionScript = _valid_script()
	_trigger(s, &"second").names[0] = &"wave1"
	_assert_error(s, "trigger second: TRIGGERS_FIRED names no trigger (wave1)")


func test_triggers_fired_cannot_name_itself() -> void:
	var s: MissionScript = _valid_script()
	_trigger(s, &"second").names[0] = &"second"
	_assert_error(s, "trigger second: TRIGGERS_FIRED can't name itself")


func test_triggers_fired_cannot_name_a_trigger_twice() -> void:
	var s: MissionScript = _valid_script()
	_trigger(s, &"second").names[1] = &"release"
	_assert_error(s, "trigger second: TRIGGERS_FIRED names release twice")


func test_triggers_fired_min_count_must_be_at_least_one() -> void:
	var s: MissionScript = _valid_script()
	_trigger(s, &"second").min_count = 0
	_assert_error(s, "trigger second: TRIGGERS_FIRED needs min_count from 1 to 2")


func test_triggers_fired_min_count_cannot_exceed_the_names() -> void:
	var s: MissionScript = _valid_script()
	_trigger(s, &"second").min_count = 3
	_assert_error(s, "trigger second: TRIGGERS_FIRED needs min_count from 1 to 2")


func test_triggers_fired_may_need_all_of_them() -> void:
	var s: MissionScript = _valid_script()
	_trigger(s, &"second").min_count = 2
	assert_eq(s.validate(_catalog), PackedStringArray())


func test_triggers_fired_may_name_a_trigger_listed_after_it() -> void:
	var s: MissionScript = _valid_script()
	assert_gt(s.trigger_index(&"wiped"), s.trigger_index(&"second"), "the baseline already does")
	assert_eq(s.validate(_catalog), PackedStringArray())


# --- PLAYER_ELIMINATED and AREA_ENTERED -------------------------------------


func test_player_eliminated_needs_nothing_beyond_its_faction() -> void:
	var s: MissionScript = _valid_script()
	var t: TriggerSpec = _trigger(s, &"wiped")
	assert_eq(t.names.size(), 0)
	assert_eq(s.validate(_catalog), PackedStringArray())
	t.set(&"faction", 99)
	_assert_error(s, "trigger wiped: faction is not a UnitType.Faction")


func test_area_entered_names_are_optional() -> void:
	var s: MissionScript = _valid_script()
	_trigger(s, &"arrived").names.clear()
	assert_eq(s.validate(_catalog), PackedStringArray())


func test_area_entered_names_must_be_groups_or_aliases() -> void:
	var s: MissionScript = _valid_script()
	_trigger(s, &"arrived").names.append(&"ghost")
	_assert_error(s, "trigger arrived: unknown group ghost")


func test_area_entered_still_needs_its_area_with_names() -> void:
	var s: MissionScript = _valid_script()
	_trigger(s, &"arrived").area = PackedInt32Array()
	_assert_error(s, "trigger arrived: AREA_ENTERED needs area as x, z, radius")


func test_group_cleared_still_needs_names() -> void:
	var s: MissionScript = _valid_script()
	_trigger(s, &"swept").names.clear()
	_assert_error(s, "GROUP_CLEARED needs at least one group name")
