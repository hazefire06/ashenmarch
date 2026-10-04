extends GutTest
## The Phase 7 data layer: Difficulty, AiGroupSpec, TriggerSpec/TriggerAction
## and MissionScript validate what the runtime will rely on, and UnitType's
## AI fields reject the combinations the AI can't honor. Each rule gets one
## test that starts from a script that validates clean and breaks one thing.

var _catalog: UnitCatalog


func before_each() -> void:
	var types: Array[UnitType] = [TestUnits.melee(&"husk"), TestUnits.ranged(&"archer")]
	_catalog = TestUnits.catalog(types)


# --- fixtures ---------------------------------------------------------------


func _entry(type_id: StringName, counts: PackedInt32Array) -> AiUnitEntry:
	var e: AiUnitEntry = AiUnitEntry.new()
	e.type_id = type_id
	e.counts = counts
	return e


## A PATROL group: husks 3 at every tier plus archers 0,0,1,1,2 by tier.
func _patrol_group() -> AiGroupSpec:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = &"patrol"
	g.units.append(_entry(&"husk", PackedInt32Array([3])))
	g.units.append(_entry(&"archer", PackedInt32Array([0, 0, 1, 1, 2])))
	g.spawns = PackedInt32Array([2000, 2000])
	g.behavior = AiGroupSpec.Behavior.PATROL
	g.waypoints = PackedInt32Array([2000, 2000, 20_000, 2000])
	g.guard_radius = 5000
	g.alert_radius = 8000
	return g


## An AMBUSH group with two spawn points chosen per tier.
func _ambush_group() -> AiGroupSpec:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = &"ambush"
	g.units.append(_entry(&"husk", PackedInt32Array([1, 2, 3, 4, 5])))
	g.spawns = PackedInt32Array([30_000, 5000, 30_000, 25_000])
	g.spawn_by_tier = PackedInt32Array([0, 0, 1, 1, 1])
	g.behavior = AiGroupSpec.Behavior.AMBUSH
	g.alert_radius = 4000
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


## Two groups and five triggers, one per condition, using every action kind.
func _valid_script() -> MissionScript:
	var s: MissionScript = MissionScript.new()
	s.groups.append(_patrol_group())
	s.groups.append(_ambush_group())

	var entered: TriggerSpec = _trigger(&"entered", TriggerSpec.Condition.AREA_ENTERED)
	entered.area = PackedInt32Array([10_000, 10_000, 3000])
	entered.min_count = 2
	var spawn: TriggerAction = _action(TriggerAction.Kind.SPAWN_GROUP)
	spawn.group = &"ambush"
	entered.actions.append(spawn)
	s.triggers.append(entered)

	var dies: TriggerSpec = _trigger(&"dies", TriggerSpec.Condition.UNIT_DIES)
	dies.after = &"entered"
	dies.names.append(&"patrol")
	dies.names.append(&"ambush")
	dies.count = 2
	var behave: TriggerAction = _action(TriggerAction.Kind.SET_BEHAVIOR)
	behave.group = &"patrol"
	behave.behavior = AiGroupSpec.Behavior.GUARD
	dies.actions.append(behave)
	s.triggers.append(dies)

	var timer: TriggerSpec = _trigger(&"timer", TriggerSpec.Condition.TIMER)
	timer.ticks = PackedInt32Array([300, 270, 240, 210, 180])
	var weather: TriggerAction = _action(TriggerAction.Kind.SET_WEATHER)
	weather.weather = WeatherChange.new()
	weather.weather.rain = 600
	weather.weather.ramp_ticks = 90
	timer.actions.append(weather)
	var objective: TriggerAction = _action(TriggerAction.Kind.SET_OBJECTIVE)
	objective.text = "Hold the mill"
	timer.actions.append(objective)
	s.triggers.append(timer)

	var cleared: TriggerSpec = _trigger(&"cleared", TriggerSpec.Condition.GROUP_CLEARED)
	cleared.after = &"timer"
	cleared.names.append(&"ambush")
	cleared.actions.append(_action(TriggerAction.Kind.WIN))
	s.triggers.append(cleared)

	var wiped: TriggerSpec = _trigger(&"wiped", TriggerSpec.Condition.FACTION_ELIMINATED)
	wiped.faction = UnitType.Faction.LIGHT
	wiped.actions.append(_action(TriggerAction.Kind.LOSE))
	s.triggers.append(wiped)
	return s


## The script's first trigger with this name, for tests to break.
func _find_trigger(s: MissionScript, trigger_name: StringName) -> TriggerSpec:
	return s.triggers[s.trigger_index(trigger_name)]


## The group must produce more errors than a clean one, one of which says
## `expected`.
func _assert_group_error(g: AiGroupSpec, expected: String) -> void:
	var baseline: int = _patrol_group().validate(_catalog).size()
	var errors: PackedStringArray = g.validate(_catalog)
	assert_gt(errors.size(), baseline, "error count grows")
	assert_string_contains("\n".join(errors), expected)


func _assert_script_error(s: MissionScript, expected: String) -> void:
	var baseline: int = _valid_script().validate(_catalog).size()
	var errors: PackedStringArray = s.validate(_catalog)
	assert_gt(errors.size(), baseline, "error count grows")
	assert_string_contains("\n".join(errors), expected)


# --- Difficulty -------------------------------------------------------------


func test_pick_with_one_entry_ignores_the_tier() -> void:
	var values: PackedInt32Array = PackedInt32Array([7])
	for tier: int in Difficulty.TIERS:
		assert_eq(Difficulty.pick(values, tier), 7, "tier %d" % tier)


func test_pick_with_five_entries_indexes_by_tier() -> void:
	var values: PackedInt32Array = PackedInt32Array([10, 20, 30, 40, 50])
	for tier: int in Difficulty.TIERS:
		assert_eq(Difficulty.pick(values, tier), values[tier], "tier %d" % tier)


func test_five_tiers() -> void:
	assert_eq(Difficulty.TIERS, 5)


func test_is_valid_accepts_one_or_five_entries() -> void:
	assert_true(Difficulty.is_valid(PackedInt32Array([1])))
	assert_true(Difficulty.is_valid(PackedInt32Array([1, 2, 3, 4, 5])))


func test_is_valid_rejects_other_sizes() -> void:
	assert_false(Difficulty.is_valid(PackedInt32Array()))
	assert_false(Difficulty.is_valid(PackedInt32Array([1, 2])))
	assert_false(Difficulty.is_valid(PackedInt32Array([1, 2, 3, 4])))
	assert_false(Difficulty.is_valid(PackedInt32Array([1, 2, 3, 4, 5, 6])))


# --- AiGroupSpec accessors --------------------------------------------------


func test_spawn_point_defaults_to_the_first_spawn() -> void:
	var g: AiGroupSpec = _ambush_group()
	g.spawn_by_tier = PackedInt32Array()
	for tier: int in Difficulty.TIERS:
		assert_eq(g.spawn_point(tier), Vector2i(30_000, 5000), "tier %d" % tier)


func test_spawn_point_with_one_entry_is_used_at_every_tier() -> void:
	var g: AiGroupSpec = _ambush_group()
	g.spawn_by_tier = PackedInt32Array([1])
	for tier: int in Difficulty.TIERS:
		assert_eq(g.spawn_point(tier), Vector2i(30_000, 25_000), "tier %d" % tier)


func test_spawn_point_with_five_entries_picks_by_tier() -> void:
	var g: AiGroupSpec = _ambush_group()
	g.spawn_by_tier = PackedInt32Array([0, 1, 0, 1, 1])
	assert_eq(g.spawn_point(0), Vector2i(30_000, 5000))
	assert_eq(g.spawn_point(1), Vector2i(30_000, 25_000))
	assert_eq(g.spawn_point(2), Vector2i(30_000, 5000))
	assert_eq(g.spawn_point(3), Vector2i(30_000, 25_000))
	assert_eq(g.spawn_point(4), Vector2i(30_000, 25_000))


func test_unit_count_sums_the_entries_per_tier() -> void:
	var g: AiGroupSpec = _patrol_group()
	# Three husks at every tier, plus archers 0, 0, 1, 1, 2.
	var expected: Array[int] = [3, 3, 4, 4, 5]
	for tier: int in Difficulty.TIERS:
		assert_eq(g.unit_count(tier), expected[tier], "tier %d" % tier)


# --- a valid script ---------------------------------------------------------


func test_valid_script_has_no_errors() -> void:
	assert_eq(_valid_script().validate(_catalog), PackedStringArray())


func test_group_and_trigger_lookup() -> void:
	var s: MissionScript = _valid_script()
	assert_eq(s.group_index(&"patrol"), 0)
	assert_eq(s.group_index(&"ambush"), 1)
	assert_eq(s.group_index(&"nobody"), -1)
	assert_eq(s.trigger_index(&"entered"), 0)
	assert_eq(s.trigger_index(&"wiped"), 4)
	assert_eq(s.trigger_index(&"nobody"), -1)


func test_lookup_returns_the_first_match() -> void:
	var s: MissionScript = _valid_script()
	s.groups.append(_patrol_group())
	s.triggers.append(_trigger(&"entered", TriggerSpec.Condition.TIMER))
	assert_eq(s.group_index(&"patrol"), 0)
	assert_eq(s.trigger_index(&"entered"), 0)


func test_idle_group_ignores_on_alert_parameters() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.behavior = AiGroupSpec.Behavior.IDLE
	g.on_alert = AiGroupSpec.Behavior.GUARD
	g.guard_radius = 0
	assert_eq(g.validate(_catalog), PackedStringArray())


# --- AiGroupSpec rules ------------------------------------------------------


func test_group_with_no_name() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.name = &""
	_assert_group_error(g, "<unnamed>: name is empty")


func test_group_messages_are_prefixed_with_the_name() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.units.clear()
	_assert_group_error(g, "group patrol: ")


func test_group_with_no_units() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.units.clear()
	_assert_group_error(g, "units is empty")


func test_group_with_a_null_unit_entry() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.units.append(null)
	_assert_group_error(g, "is null")


func test_group_with_an_unknown_unit_type() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.units.append(_entry(&"ghoul", PackedInt32Array([1])))
	_assert_group_error(g, "unknown unit type ghoul")


func test_group_entry_counts_must_have_one_or_five_values() -> void:
	for counts: PackedInt32Array in [
		PackedInt32Array(), PackedInt32Array([1, 2]), PackedInt32Array([1, 2, 3, 4, 5, 6]),
	]:
		var g: AiGroupSpec = _patrol_group()
		g.units[0].counts = counts
		_assert_group_error(g, "needs 1 or 5 counts")


func test_group_entry_counts_cannot_be_negative() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.units[1].counts = PackedInt32Array([0, 0, -1, 1, 2])
	_assert_group_error(g, "can't be negative")


func test_group_that_never_spawns_anything() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.units[0].counts = PackedInt32Array([0])
	g.units[1].counts = PackedInt32Array([0])
	_assert_group_error(g, "never spawns anything")


func test_group_that_is_empty_at_only_some_tiers_is_fine() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.units.remove_at(0)
	assert_eq(g.unit_count(0), 0)
	assert_eq(g.validate(_catalog), PackedStringArray())


func test_group_without_spawns() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.spawns = PackedInt32Array()
	_assert_group_error(g, "at least one x, z pair")


func test_group_spawns_must_be_pairs() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.spawns = PackedInt32Array([2000, 2000, 3000])
	_assert_group_error(g, "spawns must hold x, z pairs")


func test_group_spawn_by_tier_must_have_one_or_five_values() -> void:
	var g: AiGroupSpec = _ambush_group()
	g.spawn_by_tier = PackedInt32Array([0, 1])
	_assert_group_error(g, "spawn_by_tier needs 1 or 5")


func test_group_spawn_by_tier_index_out_of_range() -> void:
	var g: AiGroupSpec = _ambush_group()
	g.spawn_by_tier = PackedInt32Array([0, 0, 2, 1, 1])
	_assert_group_error(g, "spawn_by_tier index 2 is out of range")


func test_group_spawn_by_tier_index_cannot_be_negative() -> void:
	var g: AiGroupSpec = _ambush_group()
	g.spawn_by_tier = PackedInt32Array([-1])
	_assert_group_error(g, "spawn_by_tier index -1 is out of range")


func test_group_formation_must_be_a_known_kind() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.set(&"formation", 99)
	_assert_group_error(g, "not a Formations.Kind")


func test_group_behavior_must_be_a_known_behavior() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.set(&"behavior", 99)
	_assert_group_error(g, "behavior is not an AiGroupSpec.Behavior")


func test_group_faction_must_be_a_known_faction() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.set(&"faction", 99)
	_assert_group_error(g, "faction is not a UnitType.Faction")


func test_group_patrol_mode_must_be_a_known_mode() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.set(&"patrol_mode", 99)
	_assert_group_error(g, "patrol_mode is not an AiGroupSpec.PatrolMode")


func test_group_on_alert_out_of_range_is_rejected() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.set(&"on_alert", 99)
	_assert_group_error(g, "on_alert must be GUARD, HUNT or FLANK")


func test_group_cannot_start_in_retreat() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.behavior = AiGroupSpec.Behavior.RETREAT
	_assert_group_error(g, "RETREAT can't be a starting behavior")


func test_group_patrol_needs_waypoints() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.waypoints = PackedInt32Array()
	_assert_group_error(g, "PATROL needs at least 2 waypoints")


func test_group_guard_needs_a_radius() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.behavior = AiGroupSpec.Behavior.GUARD
	g.guard_radius = 0
	_assert_group_error(g, "GUARD needs guard_radius > 0")


func test_group_ambush_needs_a_spring_radius() -> void:
	var g: AiGroupSpec = _ambush_group()
	g.alert_radius = 0
	_assert_group_error(g, "AMBUSH needs alert_radius > 0")


func test_group_flank_needs_roles() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.behavior = AiGroupSpec.Behavior.FLANK
	g.flank_roles = 0
	_assert_group_error(g, "FLANK needs flank_roles")


func test_group_on_alert_must_be_guard_hunt_or_flank() -> void:
	for b: AiGroupSpec.Behavior in [
		AiGroupSpec.Behavior.IDLE, AiGroupSpec.Behavior.PATROL,
		AiGroupSpec.Behavior.AMBUSH, AiGroupSpec.Behavior.RETREAT,
	]:
		var g: AiGroupSpec = _patrol_group()
		g.on_alert = b
		_assert_group_error(g, "on_alert must be GUARD, HUNT or FLANK")


func test_patrol_on_alert_parameters_are_checked() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.on_alert = AiGroupSpec.Behavior.GUARD
	g.guard_radius = 0
	_assert_group_error(g, "on_alert: GUARD needs guard_radius > 0")


func test_guard_on_alert_parameters_are_checked() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.behavior = AiGroupSpec.Behavior.GUARD
	g.on_alert = AiGroupSpec.Behavior.FLANK
	g.flank_roles = 0
	_assert_group_error(g, "on_alert: FLANK needs flank_roles")


func test_ambush_on_alert_parameters_are_checked() -> void:
	var g: AiGroupSpec = _ambush_group()
	g.on_alert = AiGroupSpec.Behavior.FLANK
	g.flank_roles = 0
	_assert_group_error(g, "on_alert: FLANK needs flank_roles")


func test_group_alert_radius_cannot_be_negative() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.alert_radius = -1
	_assert_group_error(g, "alert_radius can't be negative")


func test_group_guard_radius_cannot_be_negative() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.guard_radius = -1
	_assert_group_error(g, "guard_radius can't be negative")


func test_group_retreat_threshold_is_a_permille() -> void:
	for permille: int in [-1, 1001]:
		var g: AiGroupSpec = _patrol_group()
		g.retreat_below_permille = permille
		_assert_group_error(g, "retreat_below_permille must be 0..1000")
	var ok: AiGroupSpec = _patrol_group()
	ok.retreat_below_permille = 1000
	assert_eq(ok.validate(_catalog), PackedStringArray())


func test_group_retreat_point_is_empty_or_one_pair() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.retreat_point = PackedInt32Array([1000])
	_assert_group_error(g, "retreat_point must be empty or one x, z pair")
	var ok: AiGroupSpec = _patrol_group()
	ok.retreat_point = PackedInt32Array([1000, 2000])
	assert_eq(ok.validate(_catalog), PackedStringArray())


func test_group_flank_roles_cannot_have_unknown_bits() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.flank_roles = 8
	_assert_group_error(g, "flank_roles has unknown role bits")


func test_params_errors_for_each_behavior() -> void:
	var g: AiGroupSpec = _patrol_group()
	assert_eq(g.params_errors(AiGroupSpec.Behavior.IDLE), PackedStringArray())
	assert_eq(g.params_errors(AiGroupSpec.Behavior.HUNT), PackedStringArray())
	assert_eq(g.params_errors(AiGroupSpec.Behavior.PATROL), PackedStringArray())
	assert_eq(g.params_errors(AiGroupSpec.Behavior.GUARD), PackedStringArray())
	assert_eq(g.params_errors(AiGroupSpec.Behavior.AMBUSH), PackedStringArray())
	assert_eq(g.params_errors(AiGroupSpec.Behavior.FLANK), PackedStringArray())
	assert_eq(g.params_errors(AiGroupSpec.Behavior.RETREAT).size(), 1)
	assert_string_contains(
		g.params_errors(AiGroupSpec.Behavior.RETREAT)[0], "RETREAT is entered by the AI, not set"
	)


func test_params_errors_patrol_needs_two_pairs() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.waypoints = PackedInt32Array([1000, 1000])
	assert_string_contains(
		"\n".join(g.params_errors(AiGroupSpec.Behavior.PATROL)), "at least 2 waypoints"
	)
	g.waypoints = PackedInt32Array([1000, 1000, 2000])
	assert_string_contains(
		"\n".join(g.params_errors(AiGroupSpec.Behavior.PATROL)), "x, z pairs"
	)


func test_params_errors_name_the_group() -> void:
	var g: AiGroupSpec = _patrol_group()
	g.guard_radius = 0
	var errors: PackedStringArray = g.params_errors(AiGroupSpec.Behavior.GUARD)
	assert_eq(errors.size(), 1)
	assert_string_contains(errors[0], "group patrol: ")


# --- MissionScript rules ----------------------------------------------------


func test_script_reports_group_errors() -> void:
	var s: MissionScript = _valid_script()
	s.groups[1].alert_radius = 0
	_assert_script_error(s, "group ambush: AMBUSH needs alert_radius > 0")


func test_script_with_a_null_group() -> void:
	var s: MissionScript = _valid_script()
	s.groups.append(null)
	_assert_script_error(s, "group 2 is null")


func test_script_duplicate_group_names() -> void:
	var s: MissionScript = _valid_script()
	s.groups[1].name = &"patrol"
	_assert_script_error(s, "duplicate group name patrol")


func test_script_duplicate_trigger_names() -> void:
	var s: MissionScript = _valid_script()
	s.triggers[1].name = &"entered"
	_assert_script_error(s, "duplicate trigger name entered")


func test_script_with_a_null_trigger() -> void:
	var s: MissionScript = _valid_script()
	s.triggers.append(null)
	_assert_script_error(s, "trigger 5 is null")


func test_trigger_with_no_name() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"wiped").name = &""
	_assert_script_error(s, "trigger <unnamed>: name is empty")


func test_trigger_condition_must_be_a_known_condition() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"timer").set(&"condition", 99)
	_assert_script_error(s, "trigger timer: condition is not a TriggerSpec.Condition")


func test_trigger_faction_must_be_a_known_faction() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"wiped").set(&"faction", 99)
	_assert_script_error(s, "trigger wiped: faction is not a UnitType.Faction")


func test_trigger_after_must_name_a_trigger() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"dies").after = &"nowhere"
	_assert_script_error(s, "trigger dies: after names no trigger (nowhere)")


func test_trigger_after_loop() -> void:
	# cleared already waits for timer; timer waiting for cleared closes the loop.
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"timer").after = &"cleared"
	_assert_script_error(s, "after chain loops")


func test_trigger_after_itself() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"wiped").after = &"wiped"
	_assert_script_error(s, "trigger wiped: after chain loops")


func test_long_after_chain_without_a_loop_is_fine() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"entered").after = &""
	_find_trigger(s, &"wiped").after = &"cleared"
	assert_eq(s.validate(_catalog), PackedStringArray())


func test_area_needs_x_z_radius() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"entered").area = PackedInt32Array([10_000, 10_000])
	_assert_script_error(s, "AREA_ENTERED needs area as x, z, radius")


func test_area_needs_a_positive_radius() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"entered").area = PackedInt32Array([10_000, 10_000, 0])
	_assert_script_error(s, "AREA_ENTERED needs a radius above 0")


func test_area_needs_a_min_count() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"entered").min_count = 0
	_assert_script_error(s, "AREA_ENTERED needs min_count >= 1")


func test_unit_dies_needs_group_names() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"dies").names.clear()
	_assert_script_error(s, "UNIT_DIES needs at least one group name")


func test_unit_dies_names_must_be_known_groups() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"dies").names.append(&"phantoms")
	_assert_script_error(s, "unknown group phantoms")


func test_unit_dies_needs_a_count() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"dies").count = 0
	_assert_script_error(s, "UNIT_DIES needs count >= 1")


func test_group_cleared_needs_group_names() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"cleared").names.clear()
	_assert_script_error(s, "GROUP_CLEARED needs at least one group name")


func test_group_cleared_names_must_be_known_groups() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"cleared").names[0] = &"phantoms"
	_assert_script_error(s, "unknown group phantoms")


func test_timer_ticks_must_have_one_or_five_values() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"timer").ticks = PackedInt32Array([10, 20])
	_assert_script_error(s, "TIMER needs 1 or 5 ticks")


func test_timer_ticks_cannot_be_negative() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"timer").ticks = PackedInt32Array([300, 270, -1, 210, 180])
	_assert_script_error(s, "TIMER ticks can't be negative")


func test_trigger_without_actions_is_a_gate() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"timer").actions.clear()
	assert_eq(s.validate(_catalog), PackedStringArray())


func test_null_action() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"wiped").actions.append(null)
	_assert_script_error(s, "trigger wiped: action 1 is null")


func test_action_kind_must_be_a_known_kind() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"cleared").actions[0].set(&"kind", 99)
	_assert_script_error(s, "action 0: kind is not a TriggerAction.Kind")


func test_action_behavior_must_be_a_known_behavior() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"dies").actions[0].set(&"behavior", 99)
	_assert_script_error(s, "action 0: behavior is not an AiGroupSpec.Behavior")


func test_spawn_group_action_needs_a_known_group() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"entered").actions[0].group = &"phantoms"
	_assert_script_error(s, "action 0: unknown group phantoms")


func test_set_behavior_action_needs_a_known_group() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"dies").actions[0].group = &""
	_assert_script_error(s, "action 0: unknown group")


func test_set_behavior_action_checks_the_groups_parameters() -> void:
	var s: MissionScript = _valid_script()
	var action: TriggerAction = _find_trigger(s, &"dies").actions[0]
	action.group = &"ambush"
	action.behavior = AiGroupSpec.Behavior.GUARD
	_assert_script_error(s, "GUARD needs guard_radius > 0")


func test_set_behavior_action_cannot_set_retreat() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"dies").actions[0].behavior = AiGroupSpec.Behavior.RETREAT
	_assert_script_error(s, "RETREAT is entered by the AI, not set")


func test_set_weather_action_needs_a_weather() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"timer").actions[0].weather = null
	_assert_script_error(s, "SET_WEATHER needs a weather")


func test_set_weather_action_tick_must_be_zero() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"timer").actions[0].weather.tick = 30
	_assert_script_error(s, "weather tick must be 0")


func test_set_weather_action_is_validated_as_a_weather_change() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"timer").actions[0].weather.rain = 2000
	_assert_script_error(s, "rain must be 0..1000")


func test_set_objective_may_clear_the_text() -> void:
	var s: MissionScript = _valid_script()
	_find_trigger(s, &"timer").actions[1].text = ""
	assert_eq(s.validate(_catalog), PackedStringArray())


# --- UnitType AI fields -----------------------------------------------------


func test_unit_type_defaults_to_assault() -> void:
	var t: UnitType = TestUnits.melee(&"plain")
	assert_eq(t.ai_tactic, UnitType.AiTactic.ASSAULT)
	assert_eq(t.ai_standoff_permille, 0)


func test_standoff_unit_with_a_ranged_attack_is_valid() -> void:
	var t: UnitType = TestUnits.ranged(
		&"sniper", {"ai_tactic": UnitType.AiTactic.STANDOFF, "ai_standoff_permille": 900}
	)
	assert_eq(t.validate(), PackedStringArray())


func test_standoff_needs_a_ranged_attack() -> void:
	var t: UnitType = TestUnits.melee(&"brawler")
	t.ai_tactic = UnitType.AiTactic.STANDOFF
	t.ai_standoff_permille = 900
	assert_string_contains("\n".join(t.validate()), "STANDOFF needs a ranged attack")


func test_standoff_needs_a_permille() -> void:
	for permille: int in [0, -5, 951]:
		var t: UnitType = TestUnits.ranged(&"sniper")
		t.ai_tactic = UnitType.AiTactic.STANDOFF
		t.ai_standoff_permille = permille
		assert_string_contains(
			"\n".join(t.validate()), "ai_standoff_permille must be 1..950"
		)


func test_standoff_permille_accepts_1_through_950() -> void:
	for permille: int in [1, 950]:
		var t: UnitType = TestUnits.ranged(
			&"sniper", {"ai_tactic": UnitType.AiTactic.STANDOFF, "ai_standoff_permille": permille}
		)
		assert_eq(t.validate(), PackedStringArray(), "%d is valid" % permille)


func test_other_tactics_need_no_standoff_permille() -> void:
	for tactic: UnitType.AiTactic in [UnitType.AiTactic.ASSAULT, UnitType.AiTactic.CLUSTER]:
		var t: UnitType = TestUnits.ranged(&"archer2")
		t.ai_tactic = tactic
		t.ai_standoff_permille = 500
		assert_string_contains(
			"\n".join(t.validate()), "ai_standoff_permille only applies to STANDOFF"
		)


func test_cluster_unit_is_valid() -> void:
	var t: UnitType = TestUnits.melee(&"swarm", {"ai_tactic": UnitType.AiTactic.CLUSTER})
	assert_eq(t.validate(), PackedStringArray())


func test_shipped_catalog_is_still_valid() -> void:
	assert_eq(TestTerrains.catalog().validate(), PackedStringArray())


func test_shipped_tactics() -> void:
	var catalog: UnitCatalog = TestTerrains.catalog()
	var stormcaller: UnitType = catalog.find(&"stormcaller")
	assert_eq(stormcaller.ai_tactic, UnitType.AiTactic.STANDOFF)
	assert_eq(stormcaller.ai_standoff_permille, 900)
	var drifter: UnitType = catalog.find(&"drifter")
	assert_eq(drifter.ai_tactic, UnitType.AiTactic.STANDOFF)
	assert_eq(drifter.ai_standoff_permille, 850)
	var blightbag: UnitType = catalog.find(&"blightbag")
	assert_eq(blightbag.ai_tactic, UnitType.AiTactic.CLUSTER)
	assert_eq(blightbag.ai_standoff_permille, 0)
	for type_id: StringName in [&"shieldman", &"reaver", &"longbow", &"sapper", &"warden", &"husk", &"ripper"]:
		assert_eq(catalog.find(type_id).ai_tactic, UnitType.AiTactic.ASSAULT, String(type_id))
