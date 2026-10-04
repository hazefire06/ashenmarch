extends GutTest
## ObjectivePanel: the mission's objectives, one line each for those that
## aren't hidden: "○ text" while active, "✓ text" (green) once done, "✗ text"
## (red) once failed, "(optional)" after an optional one. It hides itself with
## no mission and rebuilds its lines only when an OBJECTIVE_STATE event came
## with the step, or for the first time.

const ACTIVE: MissionRuntime.ObjectiveState = MissionRuntime.ObjectiveState.ACTIVE
const DONE: MissionRuntime.ObjectiveState = MissionRuntime.ObjectiveState.DONE
const FAILED: MissionRuntime.ObjectiveState = MissionRuntime.ObjectiveState.FAILED
const HIDDEN: MissionRuntime.ObjectiveState = MissionRuntime.ObjectiveState.HIDDEN

var _panel: ObjectivePanel


func before_each() -> void:
	_panel = ObjectivePanel.new()
	add_child_autofree(_panel)


# A world whose mission has these objectives (name, text, optional, shown at
# start) and these triggers; the mission is started.
func _world(
	objectives: Array[ObjectiveSpec], triggers: Array[TriggerSpec] = []
) -> World:
	var no_groups: Array[AiGroupSpec] = []
	return MissionFixtures.world(MissionFixtures.script(no_groups, triggers, objectives))


func _three() -> Array[ObjectiveSpec]:
	return [
		MissionFixtures.objective(&"cross", "Cross the ford"),
		MissionFixtures.objective(&"raid", "Destroy the raiders", false, false),
		MissionFixtures.objective(&"hold", "Hold the north bank", true),
	]


func _at_tick(trigger_name: StringName, tick: int, actions: Array[TriggerAction]) -> TriggerSpec:
	var t: TriggerSpec = MissionFixtures.timer(trigger_name, tick)
	t.actions = actions
	return t


func test_the_line_text_marks_each_state() -> void:
	assert_eq(ObjectivePanel.line_text("Go", ACTIVE, false), "○ Go")
	assert_eq(ObjectivePanel.line_text("Go", DONE, false), "✓ Go")
	assert_eq(ObjectivePanel.line_text("Go", FAILED, false), "✗ Go")
	assert_eq(ObjectivePanel.line_text("Go", HIDDEN, false), "", "a hidden one has no line")


func test_an_optional_objective_says_so() -> void:
	assert_eq(ObjectivePanel.line_text("Go", ACTIVE, true), "○ Go (optional)")
	assert_eq(ObjectivePanel.line_text("Go", DONE, true), "✓ Go (optional)")
	assert_eq(ObjectivePanel.line_text("Go", FAILED, true), "✗ Go (optional)")


func test_done_is_green_failed_is_red() -> void:
	var done: Color = ObjectivePanel.state_color(DONE)
	var failed: Color = ObjectivePanel.state_color(FAILED)
	var active: Color = ObjectivePanel.state_color(ACTIVE)
	assert_gt(done.g, done.r + 0.2, "green")
	assert_gt(failed.r, failed.g + 0.3, "red")
	assert_ne(active, done)
	assert_ne(active, failed)


func test_hidden_with_no_mission() -> void:
	var world: World = World.new(1, TestTerrains.flat(40, 40), TestTerrains.catalog())
	_panel.show_world(world)
	assert_false(_panel.visible)
	assert_eq(_panel.line_texts(), PackedStringArray())


func test_hidden_when_the_mission_has_no_objectives() -> void:
	_panel.show_world(_world([]))
	assert_false(_panel.visible)


func test_lists_the_objectives_that_are_not_hidden() -> void:
	_panel.show_world(_world(_three()))
	assert_true(_panel.visible)
	assert_eq(
		_panel.line_texts(),
		PackedStringArray(["○ Cross the ford", "○ Hold the north bank (optional)"]),
		"the hidden one waits, and the optional one says so"
	)


func test_lines_take_the_colour_of_their_state() -> void:
	var world: World = _world(_three())
	world.mission.objective_states[0] = DONE
	world.mission.objective_states[2] = FAILED
	_panel.show_world(world)
	assert_eq(_panel.line_color(0), ObjectivePanel.state_color(DONE))
	assert_eq(_panel.line_color(1), ObjectivePanel.state_color(FAILED))


func test_states_follow_the_triggers_as_the_world_steps() -> void:
	var show: TriggerAction = MissionFixtures.objective_action(TriggerAction.Kind.SHOW_OBJECTIVE, &"raid")
	var done: TriggerAction = MissionFixtures.objective_action(TriggerAction.Kind.COMPLETE_OBJECTIVE, &"cross")
	var fail: TriggerAction = MissionFixtures.objective_action(TriggerAction.Kind.FAIL_OBJECTIVE, &"hold")
	var world: World = _world(_three(), [
		_at_tick(&"reveal", 2, [show]),
		_at_tick(&"cross", 4, [done]),
		_at_tick(&"lose_hold", 6, [fail]),
	])
	var seen: Array[PackedStringArray] = []
	for _t: int in 8:
		world.step()
		_panel.show_world(world)
		seen.append(_panel.line_texts())
	assert_eq(seen[0], PackedStringArray(["○ Cross the ford", "○ Hold the north bank (optional)"]))
	assert_eq(seen[2], PackedStringArray([
		"○ Cross the ford", "○ Destroy the raiders", "○ Hold the north bank (optional)",
	]), "the raid objective appeared")
	assert_eq(seen[4], PackedStringArray([
		"✓ Cross the ford", "○ Destroy the raiders", "○ Hold the north bank (optional)",
	]))
	assert_eq(seen[7], PackedStringArray([
		"✓ Cross the ford", "○ Destroy the raiders", "✗ Hold the north bank (optional)",
	]))


func test_it_rebuilds_only_when_an_objective_changed() -> void:
	var world: World = _world(_three())
	_panel.show_world(world)
	var before: PackedStringArray = _panel.line_texts()
	# Change a state without the event a trigger would send: the panel isn't told.
	world.mission.objective_states[0] = DONE
	_panel.show_world(world)
	assert_eq(_panel.line_texts(), before, "no event, no rebuild")
	world.mission_events.append(
		MissionEvent.new(MissionEvent.Kind.OBJECTIVE_STATE, 0, "", 0, DONE)
	)
	_panel.show_world(world)
	assert_eq(_panel.line_texts()[0], "✓ Cross the ford")
	# Other kinds of event aren't a reason either.
	world.mission.objective_states[0] = FAILED
	world.mission_events.clear()
	world.mission_events.append(MissionEvent.new(MissionEvent.Kind.OBJECTIVE, 0, "Hello"))
	_panel.show_world(world)
	assert_eq(_panel.line_texts()[0], "✓ Cross the ford", "a message line isn't an objective's state")


func test_the_first_show_builds_whatever_the_events() -> void:
	var world: World = _world(_three())
	world.mission.objective_states[0] = DONE
	world.mission_events.clear()
	_panel.show_world(world)
	assert_eq(_panel.line_texts()[0], "✓ Cross the ford")


func test_a_different_mission_is_built_afresh() -> void:
	_panel.show_world(_world(_three()))
	var other: World = _world([MissionFixtures.objective(&"only", "The only one")])
	_panel.show_world(other)
	assert_eq(_panel.line_texts(), PackedStringArray(["○ The only one"]))


func test_it_hides_again_when_the_mission_goes() -> void:
	_panel.show_world(_world(_three()))
	assert_true(_panel.visible)
	_panel.show_world(World.new(1, TestTerrains.flat(40, 40), TestTerrains.catalog()))
	assert_false(_panel.visible)


func test_it_never_takes_the_mouse() -> void:
	_panel.show_world(_world(_three()))
	assert_eq(_panel.mouse_filter, Control.MOUSE_FILTER_IGNORE)
	for node: Node in _panel.find_children("*", "Control", true, false):
		assert_eq((node as Control).mouse_filter, Control.MOUSE_FILTER_IGNORE, "%s" % node.name)


func test_it_sits_at_the_top_right() -> void:
	assert_eq(_panel.anchor_left, 1.0)
	assert_eq(_panel.anchor_right, 1.0)
	assert_eq(_panel.anchor_top, 0.0)
