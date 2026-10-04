extends GutTest
## MissionHud: hidden in a world with no mission; otherwise the mission's
## objective, and once the mission is decided a Victory or Defeat banner. It
## follows the World as it steps.

const NONE: MissionRuntime.Outcome = MissionRuntime.Outcome.NONE
const WON: MissionRuntime.Outcome = MissionRuntime.Outcome.WON
const LOST: MissionRuntime.Outcome = MissionRuntime.Outcome.LOST

var _world: World
var _hud: MissionHud


func before_each() -> void:
	_world = World.new(1, TestTerrains.flat(40, 40), TestTerrains.catalog())
	_hud = MissionHud.new()
	add_child_autofree(_hud)


func test_banner_text_names_the_outcome() -> void:
	assert_eq(MissionHud.banner_text(NONE), "")
	assert_eq(MissionHud.banner_text(WON), "Victory")
	assert_eq(MissionHud.banner_text(LOST), "Defeat")


func test_hidden_without_a_mission() -> void:
	_hud.show_world(_world)
	assert_false(_hud.visible)
	assert_eq(_hud.shown_objective(), "")
	assert_eq(_hud.shown_banner(), "")


func test_a_mission_with_no_objective_yet_shows_nothing_to_read() -> void:
	assert_true(_world.start_mission(MissionScript.new(), 0))
	_hud.show_world(_world)
	assert_true(_hud.visible)
	assert_eq(_hud.shown_objective(), "")
	assert_eq(_hud.shown_banner(), "")


func test_shows_the_objective() -> void:
	_world.start_mission(MissionScript.new(), 0)
	_world.mission.objective = "Hold the ford"
	_hud.show_world(_world)
	assert_true(_hud.visible)
	assert_eq(_hud.shown_objective(), "Hold the ford")
	assert_eq(_hud.shown_banner(), "")


func test_the_banner_follows_the_outcome() -> void:
	_world.start_mission(MissionScript.new(), 0)
	_world.mission.objective = "Clear the south bank"
	_world.mission.outcome = WON
	_hud.show_world(_world)
	assert_eq(_hud.shown_banner(), "Victory")
	assert_eq(_hud.shown_objective(), "Clear the south bank", "the objective stays under the banner")
	_world.mission.outcome = LOST
	_hud.show_world(_world)
	assert_eq(_hud.shown_banner(), "Defeat")


func test_it_follows_the_world_as_the_triggers_fire() -> void:
	var script: MissionScript = MissionScript.new()
	var objective: TriggerAction = TriggerAction.new()
	objective.kind = TriggerAction.Kind.SET_OBJECTIVE
	objective.text = "Cross the creek"
	var win: TriggerAction = TriggerAction.new()
	win.kind = TriggerAction.Kind.WIN
	var first: TriggerSpec = TriggerSpec.new()
	first.name = &"first"
	first.condition = TriggerSpec.Condition.TIMER
	first.ticks = PackedInt32Array([0])
	first.actions = [objective]
	var last: TriggerSpec = TriggerSpec.new()
	last.name = &"last"
	last.condition = TriggerSpec.Condition.TIMER
	last.ticks = PackedInt32Array([5])
	last.actions = [win]
	script.triggers = [first, last]
	assert_true(_world.start_mission(script, 0))
	_world.step()
	_hud.show_world(_world)
	assert_eq(_hud.shown_objective(), "Cross the creek")
	assert_eq(_hud.shown_banner(), "")
	for _t: int in 6:
		_world.step()
	_hud.show_world(_world)
	assert_eq(_hud.shown_banner(), "Victory")


func test_it_never_takes_the_mouse() -> void:
	assert_eq(_hud.mouse_filter, Control.MOUSE_FILTER_IGNORE)
