extends GutTest
## AiDebugView, the F5 overlay: hidden until toggled, then one label per
## group with living members at its centroid and a line set drawn from the
## world's AI state (patrol routes, guard and ambush circles, flank routes,
## area triggers). It redraws after a step only while shown, and never
## changes the World.

const M: int = 1000
const DARK: UnitType.Faction = UnitType.Faction.DARK
const GRAY_BEFORE: Color = AiDebugView.TRIGGER_IDLE_COLOR
const GREEN_AFTER: Color = AiDebugView.TRIGGER_FIRED_COLOR

var _catalog: UnitCatalog
var _world: World
var _view: AiDebugView


func before_each() -> void:
	_catalog = TestTerrains.catalog()
	_world = World.new(1, TestTerrains.flat(80, 80), _catalog)
	_view = AiDebugView.new()
	add_child_autofree(_view)
	_view.setup(_world)


# --- pure helpers -------------------------------------------------------------


func test_a_group_is_labelled_with_its_name_and_behavior() -> void:
	var spec: AiGroupSpec = _spec(&"south_patrol", AiGroupSpec.Behavior.PATROL)
	var group: AiGroup = AiGroup.new(1, 0, spec, DARK, 0, 0)
	assert_eq(AiDebugView.group_label(group), "south_patrol: PATROL")
	group.behavior = AiGroupSpec.Behavior.HUNT
	assert_eq(AiDebugView.group_label(group), "south_patrol: HUNT")


func test_a_circle_is_evenly_spaced_points_on_the_radius() -> void:
	var center: Vector2 = Vector2(10.0, 20.0)
	var ring: PackedVector2Array = AiDebugView.circle(center, 5.0)
	assert_eq(ring.size(), AiDebugView.CIRCLE_SEGMENTS)
	assert_eq(AiDebugView.CIRCLE_SEGMENTS, 32)
	for point: Vector2 in ring:
		assert_almost_eq(point.distance_to(center), 5.0, 0.001)
	assert_almost_eq(ring[0].distance_to(ring[1]), ring[7].distance_to(ring[8]), 0.001, "even steps")


func test_a_fired_trigger_is_green_and_an_unfired_one_gray() -> void:
	var idle: Color = AiDebugView.trigger_color(false)
	var fired: Color = AiDebugView.trigger_color(true)
	assert_eq(idle, GRAY_BEFORE)
	assert_eq(fired, GREEN_AFTER)
	assert_almost_eq(idle.r, idle.g, 0.05, "gray has no hue")
	assert_gt(fired.g, fired.r + 0.3, "green is green")


# --- the overlay --------------------------------------------------------------


func test_it_starts_hidden_and_draws_nothing_while_hidden() -> void:
	_spawn(_spec(&"lurkers", AiGroupSpec.Behavior.AMBUSH, {"alert_radius": 8 * M}), 20, 20)
	assert_false(_view.visible)
	_world.step()
	_view.after_step()
	assert_eq(_view.label_texts(), PackedStringArray())
	assert_eq(_view.line_count(), 0)


func test_toggling_shows_a_label_per_group_with_members_at_its_centroid() -> void:
	_spawn(_spec(&"lurkers", AiGroupSpec.Behavior.AMBUSH, {"alert_radius": 8 * M}), 20, 20)
	_spawn(_spec(&"post", AiGroupSpec.Behavior.GUARD, {"guard_radius": 6 * M}), 50, 50)
	_view.toggle()
	assert_true(_view.visible)
	assert_eq(_view.label_texts(), PackedStringArray(["lurkers: AMBUSH", "post: GUARD"]))
	var at: Vector3 = _view.label_position(0)
	assert_almost_eq(at.x, 20.0, 0.01)
	assert_almost_eq(at.z, 20.0, 0.01)
	assert_gt(at.y, 0.0, "above the ground")
	_view.toggle()
	assert_false(_view.visible)


func test_a_group_with_no_living_members_has_no_label() -> void:
	var group: AiGroup = _spawn(_spec(&"lurkers", AiGroupSpec.Behavior.AMBUSH, {"alert_radius": 8 * M}), 20, 20)
	_view.toggle()
	assert_eq(_view.label_texts().size(), 1)
	for unit: Unit in group.living(_world):
		unit.state = Unit.State.DEAD
	_view.after_step()
	assert_eq(_view.label_texts(), PackedStringArray())


func test_an_ambush_and_a_guard_post_get_a_circle_each() -> void:
	_spawn(_spec(&"lurkers", AiGroupSpec.Behavior.AMBUSH, {"alert_radius": 8 * M}), 20, 20)
	_view.toggle()
	assert_eq(_view.line_count(), AiDebugView.CIRCLE_SEGMENTS)
	_spawn(_spec(&"post", AiGroupSpec.Behavior.GUARD, {"guard_radius": 6 * M}), 50, 50)
	_view.after_step()
	assert_eq(_view.line_count(), 2 * AiDebugView.CIRCLE_SEGMENTS)


func test_a_guard_without_a_radius_draws_the_default_one() -> void:
	_spawn(_spec(&"post", AiGroupSpec.Behavior.GUARD), 40, 40)
	_view.toggle()
	assert_eq(_view.line_count(), AiDebugView.CIRCLE_SEGMENTS)


func test_a_loop_patrol_closes_its_route_and_a_ping_pong_does_not() -> void:
	var waypoints: PackedInt32Array = PackedInt32Array([4 * M, 4 * M, 24 * M, 4 * M, 24 * M, 24 * M])
	_spawn(_spec(&"loop", AiGroupSpec.Behavior.PATROL, {"waypoints": waypoints}), 4, 4)
	_view.toggle()
	# Two 20 m legs, and the 28.3 m leg back, in pieces of at most STEP_LENGTH.
	assert_eq(_view.line_count(), 5 + 5 + 8)
	var other: World = World.new(1, TestTerrains.flat(80, 80), _catalog)
	var ping_pong: AiDebugView = AiDebugView.new()
	add_child_autofree(ping_pong)
	ping_pong.setup(other)
	var spec: AiGroupSpec = _spec(
		&"pong", AiGroupSpec.Behavior.PATROL, {"waypoints": waypoints, "patrol_mode": AiGroupSpec.PatrolMode.PING_PONG}
	)
	spec.spawns = PackedInt32Array([4 * M, 4 * M])
	other.ai.spawn_group(other, spec, 0, 0)
	ping_pong.toggle()
	assert_eq(ping_pong.line_count(), 5 + 5)


func test_a_patrol_that_turned_to_hunting_no_longer_shows_its_route() -> void:
	var waypoints: PackedInt32Array = PackedInt32Array([4 * M, 4 * M, 24 * M, 4 * M])
	var group: AiGroup = _spawn(_spec(&"loop", AiGroupSpec.Behavior.PATROL, {"waypoints": waypoints}), 4, 4)
	group.behavior = AiGroupSpec.Behavior.HUNT
	_view.toggle()
	assert_eq(_view.line_count(), 0)
	assert_eq(_view.label_texts(), PackedStringArray(["loop: HUNT"]))


func test_a_flank_group_shows_the_part_of_its_route_still_to_walk() -> void:
	var group: AiGroup = _spawn(_spec(&"raiders", AiGroupSpec.Behavior.FLANK), 10, 10)
	group.route = PackedInt64Array([10 * M, 30 * M, 30 * M, 30 * M])
	_view.toggle()
	# From the group's centroid (10, 10) to (10, 30) to (30, 30): 20 m twice.
	assert_eq(_view.line_count(), 5 + 5)
	group.route_index = 1
	_view.after_step()
	# From (10, 10) straight to (30, 30): 28.3 m.
	assert_eq(_view.line_count(), 8)
	group.route = PackedInt64Array()
	_view.after_step()
	assert_eq(_view.line_count(), 0, "no route planned, nothing to draw")


func test_area_triggers_are_gray_until_they_fire_then_green() -> void:
	var script: MissionScript = MissionScript.new()
	var ford: TriggerSpec = TriggerSpec.new()
	ford.name = &"ford"
	ford.condition = TriggerSpec.Condition.AREA_ENTERED
	ford.area = PackedInt32Array([40 * M, 40 * M, 15 * M])
	var timer: TriggerSpec = TriggerSpec.new()
	timer.name = &"timer"
	timer.condition = TriggerSpec.Condition.TIMER
	timer.ticks = PackedInt32Array([100000])
	script.triggers = [ford, timer]
	assert_true(_world.start_mission(script, 0))
	_view.toggle()
	assert_eq(_view.line_count(), AiDebugView.CIRCLE_SEGMENTS, "only the area trigger is drawn")
	for color: Color in _view.line_colors():
		assert_eq(color, GRAY_BEFORE)
	_world.mission.fired_tick[0] = 10
	_view.after_step()
	for color: Color in _view.line_colors():
		assert_eq(color, GREEN_AFTER)


func test_it_redraws_after_a_step_only_while_shown() -> void:
	var group: AiGroup = _spawn(_spec(&"lurkers", AiGroupSpec.Behavior.AMBUSH, {"alert_radius": 8 * M}), 20, 20)
	_view.toggle()
	assert_eq(_view.line_count(), AiDebugView.CIRCLE_SEGMENTS)
	_view.toggle()
	group.behavior = AiGroupSpec.Behavior.HUNT
	_view.after_step()
	assert_eq(_view.line_count(), AiDebugView.CIRCLE_SEGMENTS, "hidden: nothing was redrawn")
	_view.toggle()
	assert_eq(_view.line_count(), 0, "shown again: it draws what is there now")


func test_f5_toggles_it() -> void:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = KEY_F5
	event.pressed = true
	_view._unhandled_input(event)
	assert_true(_view.visible)
	_view._unhandled_input(event)
	assert_false(_view.visible)


func test_drawing_does_not_change_the_world() -> void:
	_spawn(_spec(&"lurkers", AiGroupSpec.Behavior.AMBUSH, {"alert_radius": 8 * M}), 20, 20)
	var before: String = _world.state_hash()
	_view.toggle()
	_view.after_step()
	assert_eq(_world.state_hash(), before)


# --- ADVANCE and the skirmish commanders --------------------------------------


func test_advance_has_a_color_of_its_own() -> void:
	var advance: Color = AiDebugView.behavior_color(AiGroupSpec.Behavior.ADVANCE)
	assert_eq(advance, AiDebugView.ADVANCE_COLOR)
	assert_ne(advance, AiDebugView.IDLE_COLOR, "not the fallback gray")
	for behavior: AiGroupSpec.Behavior in [
		AiGroupSpec.Behavior.PATROL, AiGroupSpec.Behavior.GUARD, AiGroupSpec.Behavior.AMBUSH,
		AiGroupSpec.Behavior.FLANK, AiGroupSpec.Behavior.HUNT, AiGroupSpec.Behavior.RETREAT,
		AiGroupSpec.Behavior.ESCORT,
	]:
		assert_ne(AiDebugView.behavior_color(behavior), advance)


func test_an_advance_group_shows_its_anchor_and_its_engage_and_hold_circles() -> void:
	var group: AiGroup = _spawn(_spec(&"army", AiGroupSpec.Behavior.ADVANCE, {"guard_radius": 25 * M}), 20, 20)
	group.anchor_x = 40 * M
	group.anchor_z = 20 * M
	_view.toggle()
	assert_eq(_view.label_texts(), PackedStringArray(["army: ADVANCE"]))
	# The line from the group to its anchor (20 m, five pieces), the anchor's
	# cross (two lines), the engage circle and the hold circle.
	assert_eq(_view.line_count(), 5 + 2 + 2 * AiDebugView.CIRCLE_SEGMENTS)


func test_an_advance_group_with_no_engage_radius_draws_no_engage_circle() -> void:
	var group: AiGroup = _spawn(_spec(&"army", AiGroupSpec.Behavior.ADVANCE), 20, 20)
	assert_eq(group.engage_radius, 0)
	group.anchor_x = 40 * M
	group.anchor_z = 20 * M
	_view.toggle()
	assert_eq(_view.line_count(), 5 + 2 + AiDebugView.CIRCLE_SEGMENTS, "the hold circle is the default one")


func test_the_engage_circle_dims_while_the_group_is_marching_without_fighting() -> void:
	var group: AiGroup = _spawn(_spec(&"army", AiGroupSpec.Behavior.ADVANCE, {"guard_radius": 25 * M}), 20, 20)
	group.anchor_x = 40 * M
	group.anchor_z = 20 * M
	_view.toggle()
	assert_eq(
		_ends_in(AiDebugView.ADVANCE_COLOR), 2 * (2 + 2 * AiDebugView.CIRCLE_SEGMENTS),
		"the cross and both circles, in full color"
	)
	group.march_attack = false
	_view.after_step()
	assert_eq(
		_ends_in(AiDebugView.ADVANCE_COLOR), 2 * (2 + AiDebugView.CIRCLE_SEGMENTS),
		"the engage circle went dim"
	)
	assert_eq(_view.line_count(), 5 + 2 + 2 * AiDebugView.CIRCLE_SEGMENTS, "but it is still there")


func test_a_guard_still_draws_its_own_radius() -> void:
	_spawn(_spec(&"post", AiGroupSpec.Behavior.GUARD, {"guard_radius": 6 * M}), 50, 50)
	_view.toggle()
	assert_eq(_view.line_count(), AiDebugView.CIRCLE_SEGMENTS)
	assert_eq(_ends_in(AiDebugView.GUARD_COLOR), 2 * AiDebugView.CIRCLE_SEGMENTS)


func test_a_commander_is_not_drawn_before_it_has_thought() -> void:
	_spawn(_spec(&"hunters", AiGroupSpec.Behavior.HUNT), 20, 20)
	_commander()
	_view.toggle()
	assert_eq(_view.label_texts(), PackedStringArray(["hunters: HUNT"]))
	assert_eq(_view.line_count(), 0)


func test_a_commander_draws_its_objective_line_stage_circle_and_posture() -> void:
	_spawn(_spec(&"hunters", AiGroupSpec.Behavior.HUNT), 20, 20)
	var commander: SkirmishCommander = _commander(DARK)
	_decided(commander, Vector2i(60, 20), Vector2i(30, 20), SkirmishCommander.Posture.COMMIT)
	_view.toggle()
	assert_eq(
		_view.label_texts(), PackedStringArray(["hunters: HUNT", "dark commander: COMMIT"]),
		"the group's label, then the commander's"
	)
	var at: Vector3 = _view.label_position(1)
	assert_almost_eq(at.x, 30.0, 0.01, "the posture is named at the staging point")
	assert_almost_eq(at.z, 20.0, 0.01)
	# From the group to the objective: 40 m, ten pieces; and the staging circle.
	assert_eq(_view.line_count(), 10 + AiDebugView.STAGE_SEGMENTS)
	assert_eq(_ends_in(SideColors.DARK), 2 * (10 + AiDebugView.STAGE_SEGMENTS), "in its side's color")


func test_a_light_commander_is_drawn_in_lights_color() -> void:
	_spawn(_spec(&"hunters", AiGroupSpec.Behavior.HUNT), 20, 20)
	var commander: SkirmishCommander = _commander(UnitType.Faction.LIGHT)
	_decided(commander, Vector2i(60, 20), Vector2i(30, 20), SkirmishCommander.Posture.STAGE)
	_view.toggle()
	assert_eq(_ends_in(SideColors.LIGHT), 2 * (10 + AiDebugView.STAGE_SEGMENTS))
	assert_true(_view.label_texts().has("light commander: STAGE"), "%s" % [_view.label_texts()])


func test_a_commanders_label_names_each_posture() -> void:
	var commander: SkirmishCommander = _commander(DARK)
	for posture: SkirmishCommander.Posture in SkirmishCommander.Posture.values():
		commander.posture = posture
		assert_eq(
			AiDebugView.commander_label(commander),
			"dark commander: %s" % SkirmishCommander.Posture.find_key(posture)
		)
	commander.posture = SkirmishCommander.Posture.DEFEND
	assert_eq(AiDebugView.commander_label(commander), "dark commander: DEFEND")
	commander.posture = SkirmishCommander.Posture.STAGE
	assert_eq(AiDebugView.commander_label(commander), "dark commander: STAGE")


func test_a_commander_follows_its_main_group_and_falls_back_on_its_raiders() -> void:
	var main: AiGroup = _spawn(_spec(&"main", AiGroupSpec.Behavior.HUNT), 20, 20)
	_spawn(_spec(&"raiders", AiGroupSpec.Behavior.HUNT), 10, 50)
	var commander: SkirmishCommander = _commander(DARK, 0, 1)
	_decided(commander, Vector2i(60, 50), Vector2i(30, 50), SkirmishCommander.Posture.COMMIT)
	_view.toggle()
	# From the main group at (20, 20) to (60, 50): 50 m, thirteen pieces.
	assert_eq(_view.line_count(), 13 + AiDebugView.STAGE_SEGMENTS)
	_kill_all(main)
	_view.after_step()
	# From the raiders at (10, 50) to (60, 50): 50 m, thirteen pieces.
	assert_eq(_view.line_count(), 13 + AiDebugView.STAGE_SEGMENTS)
	assert_true(_view.label_texts().has("dark commander: COMMIT"))


func test_a_commander_with_no_group_left_is_not_drawn() -> void:
	var group: AiGroup = _spawn(_spec(&"main", AiGroupSpec.Behavior.HUNT), 20, 20)
	var commander: SkirmishCommander = _commander(DARK)
	_decided(commander, Vector2i(60, 20), Vector2i(30, 20), SkirmishCommander.Posture.COMMIT)
	_view.toggle()
	assert_eq(_view.label_texts().size(), 2)
	_kill_all(group)
	_view.after_step()
	assert_eq(_view.label_texts(), PackedStringArray())
	assert_eq(_view.line_count(), 0)


func test_commanders_are_only_drawn_while_the_overlay_is_shown() -> void:
	_spawn(_spec(&"hunters", AiGroupSpec.Behavior.HUNT), 20, 20)
	var commander: SkirmishCommander = _commander(DARK)
	_decided(commander, Vector2i(60, 20), Vector2i(30, 20), SkirmishCommander.Posture.COMMIT)
	_view.after_step()
	assert_eq(_view.line_count(), 0, "hidden: nothing drawn")
	_view.toggle()
	assert_gt(_view.line_count(), 0)
	_view.toggle()
	commander.posture = SkirmishCommander.Posture.DEFEND
	_view.after_step()
	_view.toggle()
	assert_true(_view.label_texts().has("dark commander: DEFEND"), "shown again: what is there now")


func test_drawing_commanders_and_advance_groups_does_not_change_the_world() -> void:
	var group: AiGroup = _spawn(_spec(&"army", AiGroupSpec.Behavior.ADVANCE, {"guard_radius": 25 * M}), 20, 20)
	group.anchor_x = 40 * M
	var commander: SkirmishCommander = _commander(DARK)
	_decided(commander, Vector2i(60, 20), Vector2i(30, 20), SkirmishCommander.Posture.STAGE)
	var before: String = _world.state_hash()
	_view.toggle()
	_view.after_step()
	assert_eq(_world.state_hash(), before)


# --- helpers ------------------------------------------------------------------


# A Dark Husk group spec; fields sets the rest by name.
func _spec(group_name: StringName, behavior: AiGroupSpec.Behavior, fields: Dictionary = {}) -> AiGroupSpec:
	var spec: AiGroupSpec = AiGroupSpec.new()
	spec.name = group_name
	var entry: AiUnitEntry = AiUnitEntry.new()
	entry.type_id = &"husk"
	entry.counts = PackedInt32Array([1])
	spec.units = [entry]
	spec.behavior = behavior
	for field: String in fields:
		spec.set(field, fields[field])
	return spec


# A commander of `side` over the group spawned from the spec at `main_index`
# (the first group is spec index 0), added to the world's commanders.
func _commander(
	side: UnitType.Faction = DARK, main_index: int = 0, raider_index: int = -1
) -> SkirmishCommander:
	var commander: SkirmishCommander = SkirmishCommander.new(
		_world.ai.commanders.size() + 1, side, main_index, raider_index, Vector2i(40 * M, 40 * M)
	)
	_world.ai.commanders.append(commander)
	return commander


# What the commander has after a think, set by hand: an objective, a staging
# point (metres) and a posture.
func _decided(
	commander: SkirmishCommander, objective: Vector2i, stage: Vector2i, posture: SkirmishCommander.Posture
) -> void:
	commander.objective_x = objective.x * M
	commander.objective_z = objective.y * M
	commander.stage_x = stage.x * M
	commander.stage_z = stage.y * M
	commander.posture = posture


# How many line ends are this color.
func _ends_in(color: Color) -> int:
	var count: int = 0
	for end: Color in _view.line_colors():
		if end == color:
			count += 1
	return count


func _kill_all(group: AiGroup) -> void:
	for unit: Unit in group.living(_world):
		unit.state = Unit.State.DEAD


# Spawns the spec's group at (x, z) metres and returns it. The group's spec
# index is the number of groups so far, which the overlay doesn't read.
func _spawn(spec: AiGroupSpec, x: int, z: int) -> AiGroup:
	spec.spawns = PackedInt32Array([x * M, z * M])
	return _world.ai.spawn_group(_world, spec, _world.ai.groups.size(), 0)
