extends GutTest
## MainView running a campaign mission (Phase 8): the world, camera, and stats
## come from a MissionLaunch; the view stops stepping the sim on the tick the
## mission is decided and sends mission_ended once, a while later; pausing
## (P, Esc's menu, losing the window's focus) stops the stepping and every
## command with it; and the campaign switches the debug keys off. A MainView
## with no launch is the sandbox the demos use and stays as it was: the test
## squad, the Riverside AI mission, and no freezing.
## The scene is stepped by hand, never by awaiting frames, so every test runs
## the same ticks. Keys go through the viewport, so Esc really travels the tree
## order that decides whether the selection or the pause menu sees it first.

const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const NEVER: int = ViewFixtures.NEVER

var _physics_rate: int = 0


func before_all() -> void:
	# MainView sets the global physics rate to the sim's; put it back after.
	_physics_rate = Engine.physics_ticks_per_second


func after_all() -> void:
	Engine.physics_ticks_per_second = _physics_rate
	ViewFixtures.cleanup()


# --- helpers ------------------------------------------------------------------


func _view(win_ticks: int = NEVER, campaign: bool = true) -> MainView:
	var main: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	main.launch = ViewFixtures.launch(win_ticks, null, campaign)
	main.end_delay = 0.0
	add_child_autofree(main)
	return main


func _sandbox() -> MainView:
	var main: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	add_child_autofree(main)
	return main


func _step(main: MainView, ticks: int = 1) -> void:
	for _i: int in ticks:
		main._physics_process(1.0 / World.TICK_RATE)


func _soldier(main: MainView) -> Unit:
	for unit: Unit in main.world.units:
		if unit.faction == LIGHT:
			return unit
	return null


func _controller(main: MainView) -> SelectionController:
	return main.get_node("Hud/Selection") as SelectionController


func _key(keycode: Key) -> InputEventKey:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = keycode
	event.pressed = true
	return event


func _push(event: InputEvent) -> void:
	get_viewport().push_input(event)


func _right_click(main: MainView) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_RIGHT
	event.pressed = true
	event.position = get_viewport().get_visible_rect().size * 0.5
	_controller(main)._unhandled_input(event)


# --- the launch ---------------------------------------------------------------


func test_a_launch_builds_the_missions_world_and_nothing_else() -> void:
	var main: MainView = _view()
	assert_not_null(main.world)
	assert_not_null(main.world.mission, "the mission is started")
	assert_eq(main.world.tick, 0)
	_step(main)
	var light: int = 0
	for unit: Unit in main.world.units:
		if unit.faction == LIGHT:
			light += 1
	assert_eq(light, 1, "the roster and no test squad")
	assert_eq(main.world.units.size(), 2, "one soldier and the mission's one Husk")
	assert_eq(_soldier(main).type.id, &"shieldman")
	assert_eq(_soldier(main).soldier_id, 1, "a campaign soldier, from the deploy command")
	assert_eq(main.world.herb_plants.size(), 0, "the tiny map has no herbs, and the sandbox's aren't planted")
	assert_not_null(main.stats)


func test_the_camera_starts_where_the_mission_says() -> void:
	var main: MainView = _view()
	var camera: RtsCamera = main.get_node("CameraRig") as RtsCamera
	assert_almost_eq(camera.focus.x, 20.0, 0.01)
	assert_almost_eq(camera.focus.z, 25.0, 0.01)
	assert_almost_eq(camera.distance, 40.0, 0.01)


func test_the_missions_atmosphere_is_applied() -> void:
	var atmosphere: Atmosphere = Atmosphere.new()
	atmosphere.background_color = Color(0.4, 0.2, 0.1)
	atmosphere.terrain_desaturation = 0.5
	atmosphere.ash_fall = 0.5
	var main: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	main.launch = ViewFixtures.launch(NEVER, atmosphere)
	add_child_autofree(main)
	var environment: Environment = (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	assert_eq(environment.background_color, Color(0.4, 0.2, 0.1))
	var terrain: TerrainView = main.get_node("TerrainView") as TerrainView
	assert_eq(terrain.shader_parameter(&"grade_desaturation"), 0.5)
	assert_gt((main.get_node("Precipitation") as PrecipitationView).ash_count(), 0)


func test_the_scenes_own_sun_and_sky_are_the_atmosphere_defaults() -> void:
	# What a mission with no atmosphere keeps is what Atmosphere's defaults say.
	# Built but not entered into the tree: _ready would load the whole map, and
	# the scene's own values are all this needs.
	var main: Node = autofree((load("res://view/main.tscn") as PackedScene).instantiate())
	var sun: DirectionalLight3D = main.get_node("Sun") as DirectionalLight3D
	var fresh: Atmosphere = Atmosphere.new()
	assert_almost_eq(sun.rotation_degrees.x, fresh.sun_pitch_degrees, 0.01)
	assert_almost_eq(sun.rotation_degrees.y, fresh.sun_yaw_degrees, 0.01)
	assert_eq(sun.light_energy, fresh.sun_energy)
	assert_eq(sun.light_color, fresh.sun_color)
	var environment: Environment = (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	assert_eq(environment.background_color, fresh.background_color)
	assert_eq(environment.ambient_light_color, fresh.ambient_color)
	assert_eq(environment.ambient_light_energy, fresh.ambient_energy)
	assert_false(environment.fog_enabled)


func test_an_atmosphere_does_not_leak_into_the_next_scene() -> void:
	# main.tscn's Environment is local to each instance of it.
	var atmosphere: Atmosphere = Atmosphere.new()
	atmosphere.background_color = Color(0.9, 0.1, 0.1)
	var first: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	first.launch = ViewFixtures.launch(NEVER, atmosphere)
	add_child_autofree(first)
	var second: MainView = _view()
	var environment: Environment = (second.get_node("WorldEnvironment") as WorldEnvironment).environment
	assert_eq(environment.background_color, Color(0.52, 0.6, 0.68, 1), "the scene's own sky")


func test_a_mission_with_no_atmosphere_keeps_the_scenes_own_look() -> void:
	var main: MainView = _view()
	var environment: Environment = (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	assert_eq(environment.background_color, Atmosphere.new().background_color)
	assert_eq((main.get_node("TerrainView") as TerrainView).shader_parameter(&"grade_desaturation"), 0.0)
	assert_eq((main.get_node("Precipitation") as PrecipitationView).ash_count(), 0)


func test_the_objectives_panel_follows_the_mission() -> void:
	var main: MainView = _view()
	var panel: ObjectivePanel = main.get_node("Hud/ObjectivePanel") as ObjectivePanel
	_step(main)
	assert_true(panel.visible)
	assert_eq(panel.line_texts(), PackedStringArray(["○ Hold the field"]), "the hidden objective isn't listed")


# --- the end ------------------------------------------------------------------


func test_the_sim_freezes_on_the_outcome_tick() -> void:
	var main: MainView = _view(0)
	assert_false(main.is_frozen())
	_step(main)
	assert_eq(main.world.mission.outcome, MissionRuntime.Outcome.WON)
	assert_true(main.is_frozen())
	var decided_on: int = main.world.tick
	var hash_then: String = main.world.state_hash()
	_step(main, 20)
	assert_eq(main.world.tick, decided_on, "no more ticks")
	assert_eq(main.world.state_hash(), hash_then, "and nothing else moved")
	assert_eq(main.stats.end_tick, decided_on, "the stats ended on the last tick")


func test_the_banner_shows_over_the_frozen_field() -> void:
	var main: MainView = _view(0)
	_step(main)
	var hud: MissionHud = main.get_node("Hud/MissionHud") as MissionHud
	assert_eq(hud.shown_banner(), "Victory")


func test_a_mission_that_has_not_ended_keeps_stepping() -> void:
	var main: MainView = _view()
	_step(main, 5)
	assert_eq(main.world.tick, 5)
	assert_false(main.is_frozen())


func test_mission_ended_is_sent_once_with_the_outcome_and_stats() -> void:
	var main: MainView = _view(0)
	watch_signals(main)
	_step(main)
	assert_signal_not_emitted(main, "mission_ended", "not before a frame has passed")
	main._process(0.016)
	main._process(0.016)
	main._process(0.016)
	assert_signal_emit_count(main, "mission_ended", 1)
	assert_signal_emitted_with_parameters(main, "mission_ended", [MissionRuntime.Outcome.WON, main.stats])


func test_mission_ended_waits_for_the_delay() -> void:
	var main: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	main.launch = ViewFixtures.launch(0)
	assert_eq(main.end_delay, MainView.MISSION_END_DELAY, "2.5 s of real time by default")
	assert_eq(MainView.MISSION_END_DELAY, 2.5)
	add_child_autofree(main)
	watch_signals(main)
	_step(main)
	main._process(1.0)
	main._process(1.0)
	assert_signal_not_emitted(main, "mission_ended", "2 s is not yet 2.5")
	main._process(0.6)
	assert_signal_emit_count(main, "mission_ended", 1)
	main._process(10.0)
	assert_signal_emit_count(main, "mission_ended", 1, "still once")


func test_a_lost_mission_reports_the_defeat() -> void:
	var main: MainView = _view()
	_step(main)
	# The Light side wiped out: the mission script has no lose trigger here, so
	# decide it as a trigger would.
	main.world.mission.outcome = MissionRuntime.Outcome.LOST
	watch_signals(main)
	_step(main)
	assert_true(main.is_frozen())
	main._process(0.1)
	assert_signal_emitted_with_parameters(main, "mission_ended", [MissionRuntime.Outcome.LOST, main.stats])


func test_orders_are_refused_once_the_mission_is_decided() -> void:
	var main: MainView = _view(0)
	_step(main)
	assert_true(_controller(main).paused, "nothing would step, so nothing is ordered")


func test_pausing_does_nothing_once_the_mission_is_decided() -> void:
	var main: MainView = _view(0)
	_step(main)
	main.paused = true
	assert_false(main.paused)
	_push(_key(KEY_P))
	assert_false(main.paused)
	assert_false(main.pause_menu().enabled)


func test_esc_does_not_open_the_menu_once_the_mission_is_decided() -> void:
	var main: MainView = _view(0)
	_step(main)
	_push(_key(KEY_ESCAPE))
	assert_false(main.pause_menu().is_open())


# --- pause --------------------------------------------------------------------


func test_pause_stops_the_ticks_and_resume_continues() -> void:
	var main: MainView = _view()
	_step(main, 3)
	assert_eq(main.world.tick, 3)
	main.paused = true
	_step(main, 10)
	assert_eq(main.world.tick, 3, "paused: not a tick")
	main.paused = false
	_step(main, 2)
	assert_eq(main.world.tick, 5, "resumed")


func test_pausing_leaves_the_sim_exactly_as_it_would_have_been() -> void:
	var paused: MainView = _view()
	var straight: MainView = _view()
	_step(paused, 4)
	paused.paused = true
	_step(paused, 25)
	paused.paused = false
	_step(paused, 6)
	_step(straight, 10)
	assert_eq(paused.world.state_hash(), straight.world.state_hash(), "a pause leaves no mark on the sim")


func test_p_pauses_without_the_menu_and_again_resumes() -> void:
	var main: MainView = _view()
	_step(main, 2)
	_push(_key(KEY_P))
	assert_true(main.paused)
	assert_false(main.pause_menu().is_open(), "no menu")
	assert_true(main.pause_menu().is_paused_label_visible(), "a Paused label instead")
	_step(main, 5)
	assert_eq(main.world.tick, 2)
	_push(_key(KEY_P))
	assert_false(main.paused)
	assert_false(main.pause_menu().is_paused_label_visible())
	_step(main)
	assert_eq(main.world.tick, 3)


func test_the_selection_controller_enqueues_nothing_while_paused() -> void:
	var main: MainView = _view()
	_step(main, 2)
	var unit: Unit = _soldier(main)
	var controller: SelectionController = _controller(main)
	controller.selection.select(PackedInt32Array([unit.id]))
	_push(_key(KEY_P))
	assert_true(controller.paused)
	_right_click(main)
	controller.stop_selected()
	controller.use_special_selected()
	controller.arm(SelectionController.ArmedOrder.MOVE)
	assert_eq(controller.armed_order, SelectionController.ArmedOrder.NONE, "nothing arms while paused")
	_push(_key(KEY_P))
	_step(main, 2)
	assert_eq(unit.order, Unit.Order.NONE, "no command was queued to wake up on the resume")


func test_the_same_right_click_moves_when_not_paused() -> void:
	# The control for the test above: the click does give an order.
	var main: MainView = _view()
	_step(main, 2)
	var unit: Unit = _soldier(main)
	_controller(main).selection.select(PackedInt32Array([unit.id]))
	_right_click(main)
	_step(main)
	assert_eq(unit.order, Unit.Order.MOVE)


func test_selection_still_works_while_paused() -> void:
	var main: MainView = _view()
	_step(main, 2)
	var controller: SelectionController = _controller(main)
	main.paused = true
	controller.selection.select(PackedInt32Array([_soldier(main).id]))
	controller.set_formation(Formations.Kind.WEDGE)
	controller.save_group(0)
	assert_eq(controller.selection.size(), 1)
	assert_eq(controller.formation, Formations.Kind.WEDGE)
	assert_eq(controller.selection.group(0).size(), 1)


func test_pausing_drops_an_armed_order() -> void:
	var main: MainView = _view()
	_step(main, 2)
	var controller: SelectionController = _controller(main)
	controller.selection.select(PackedInt32Array([_soldier(main).id]))
	controller.arm(SelectionController.ArmedOrder.ATTACK_MOVE)
	main.paused = true
	assert_eq(controller.armed_order, SelectionController.ArmedOrder.NONE)


func test_the_bars_order_buttons_are_off_while_paused() -> void:
	var main: MainView = _view()
	var bar: ControlBar = main.get_node("Hud/ControlBar") as ControlBar
	var stop: Button = _button(bar, "Stop")
	assert_false(stop.disabled)
	main.paused = true
	assert_true(stop.disabled)
	assert_true(_button(bar, "Move").disabled)
	assert_false(_button(bar, "Set").disabled, "groups are selection state: still usable")
	main.paused = false
	assert_false(stop.disabled)


func test_sprites_hold_still_while_paused() -> void:
	var main: MainView = _view()
	var units: UnitsView = main.get_node("Units") as UnitsView
	var projectiles: ProjectilesView = main.get_node("Projectiles") as ProjectilesView
	assert_false(units.frozen)
	main.paused = true
	assert_true(units.frozen, "no swinging between the last two ticks")
	assert_true(projectiles.frozen)
	main.paused = false
	assert_false(units.frozen)


func test_losing_focus_pauses_a_campaign_mission() -> void:
	var main: MainView = _view()
	_step(main, 2)
	main.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	assert_true(main.paused)
	assert_true(main.pause_menu().is_paused_label_visible())
	_step(main, 5)
	assert_eq(main.world.tick, 2)
	main.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	assert_true(main.paused, "coming back is P's to undo, not the focus's")


func test_losing_focus_does_not_pause_a_development_launch() -> void:
	var main: MainView = _view(NEVER, false)
	main.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	assert_false(main.paused)


# --- Esc and the pause menu ---------------------------------------------------


func test_esc_with_an_armed_order_cancels_it_and_does_not_open_the_menu() -> void:
	var main: MainView = _view()
	_step(main, 2)
	var controller: SelectionController = _controller(main)
	controller.selection.select(PackedInt32Array([_soldier(main).id]))
	controller.arm(SelectionController.ArmedOrder.MOVE)
	assert_eq(controller.armed_order, SelectionController.ArmedOrder.MOVE)
	_push(_key(KEY_ESCAPE))
	assert_eq(controller.armed_order, SelectionController.ArmedOrder.NONE, "the order was cancelled")
	assert_false(main.pause_menu().is_open(), "and the menu stayed shut")
	assert_false(main.paused)


func test_esc_otherwise_opens_the_menu_and_pauses() -> void:
	var main: MainView = _view()
	_step(main, 2)
	_push(_key(KEY_ESCAPE))
	assert_true(main.pause_menu().is_open())
	assert_true(main.paused)
	assert_false(main.pause_menu().is_paused_label_visible(), "the menu says it already")
	_step(main, 5)
	assert_eq(main.world.tick, 2)


func test_esc_again_closes_the_menu_and_resumes() -> void:
	var main: MainView = _view()
	_step(main, 2)
	_push(_key(KEY_ESCAPE))
	_push(_key(KEY_ESCAPE))
	assert_false(main.pause_menu().is_open())
	assert_false(main.paused)
	_step(main)
	assert_eq(main.world.tick, 3)


func test_resume_in_the_menu_resumes() -> void:
	var main: MainView = _view()
	_push(_key(KEY_ESCAPE))
	_button(main.pause_menu(), "ResumeButton").pressed.emit()
	assert_false(main.pause_menu().is_open())
	assert_false(main.paused)


func test_the_bars_menu_button_opens_the_menu_for_a_mouse() -> void:
	var main: MainView = _view()
	var bar: ControlBar = main.get_node("Hud/ControlBar") as ControlBar
	_step(main, 2)
	_button(bar, "Menu").pressed.emit()
	assert_true(main.pause_menu().is_open())
	assert_true(main.paused)
	_step(main, 3)
	assert_eq(main.world.tick, 2)
	assert_false(_button(bar, "Menu").disabled, "it is not an order, so it stays on while paused")


func test_p_is_ignored_while_the_menu_is_open() -> void:
	var main: MainView = _view()
	_push(_key(KEY_ESCAPE))
	_push(_key(KEY_P))
	assert_true(main.paused, "the menu owns the pause")
	assert_true(main.pause_menu().is_open())


func test_esc_while_paused_with_p_opens_the_menu_and_resume_ends_the_pause() -> void:
	var main: MainView = _view()
	_push(_key(KEY_P))
	_push(_key(KEY_ESCAPE))
	assert_true(main.pause_menu().is_open())
	assert_false(main.pause_menu().is_paused_label_visible())
	_push(_key(KEY_ESCAPE))
	assert_false(main.paused, "closing the menu is a resume")


func test_the_menus_buttons_are_passed_on_to_the_app() -> void:
	var main: MainView = _view()
	watch_signals(main)
	_push(_key(KEY_ESCAPE))
	_button(main.pause_menu(), "RestartButton").pressed.emit()
	_button(main.pause_menu(), "SettingsButton").pressed.emit()
	assert_signal_emit_count(main, "restart_requested", 1)
	assert_signal_emit_count(main, "settings_requested", 1)
	assert_true(main.paused, "the game stays paused behind them")
	_button(main.pause_menu(), "QuitButton").pressed.emit()
	assert_signal_not_emitted(main, "quit_requested", "it asks first")
	_button(main.pause_menu(), "ConfirmQuitButton").pressed.emit()
	assert_signal_emit_count(main, "quit_requested", 1)


# --- the debug keys -----------------------------------------------------------


func test_the_campaign_hides_switch_side_and_ignores_f9() -> void:
	var main: MainView = _view()
	var bar: ControlBar = main.get_node("Hud/ControlBar") as ControlBar
	assert_false(bar.is_switch_side_visible())
	var controller: SelectionController = _controller(main)
	_push(_key(KEY_F9))
	assert_eq(controller.side, LIGHT, "still the player's side")
	controller.switch_side()
	assert_eq(controller.side, LIGHT)


func test_the_campaign_ignores_f6() -> void:
	var main: MainView = _view()
	_push(_key(KEY_F6))
	_step(main, 40)
	assert_eq(main.world.weather.rain, 0, "no debug rain")


func test_a_development_launch_keeps_the_debug_keys() -> void:
	var main: MainView = _view(NEVER, false)
	var bar: ControlBar = main.get_node("Hud/ControlBar") as ControlBar
	assert_true(bar.is_switch_side_visible())
	_push(_key(KEY_F9))
	assert_eq(_controller(main).side, UnitType.Faction.DARK)
	_push(_key(KEY_F6))
	_step(main, 40)
	assert_gt(main.world.weather.rain, 0, "F6 brings the rain")


# --- the sandbox --------------------------------------------------------------


func test_the_sandbox_still_spawns_the_test_squad_and_starts_riverside_ai() -> void:
	var main: MainView = _sandbox()
	assert_null(main.stats, "no stats without a mission launch")
	_step(main)
	var light: int = 0
	for unit: Unit in main.world.units:
		if unit.faction == LIGHT:
			light += 1
	var expected: int = (
		MainView.TEST_SQUAD_SIZE + MainView.TEST_SHOCK_ROW_SIZE + MainView.TEST_LONGBOW_COUNT
		+ MainView.TEST_SAPPER_COUNT + MainView.TEST_WARDEN_COUNT
	)
	assert_eq(light, expected, "the test squad")
	assert_not_null(main.world.mission)
	assert_eq(main.world.mission.mission_script.resource_path, MainView.MISSION_PATH)
	assert_eq(main.world.mission.tier, MainView.MISSION_TIER)
	assert_eq(main.world.herb_plants.size(), 4, "Riverside's herb plants")
	var camera: RtsCamera = main.get_node("CameraRig") as RtsCamera
	assert_almost_eq(camera.focus.x, MainView.CAMERA_START.x, 0.01)
	assert_almost_eq(camera.focus.z, MainView.CAMERA_START.y, 0.01)


func test_the_sandbox_never_freezes() -> void:
	var main: MainView = _sandbox()
	_step(main)
	main.world.mission.outcome = MissionRuntime.Outcome.WON
	_step(main, 3)
	assert_false(main.is_frozen())
	assert_eq(main.world.tick, 4, "it plays on, as it always has")


func test_the_sandbox_keeps_its_debug_keys_and_pauses_too() -> void:
	var main: MainView = _sandbox()
	var bar: ControlBar = main.get_node("Hud/ControlBar") as ControlBar
	assert_true(bar.is_switch_side_visible())
	_push(_key(KEY_F9))
	assert_eq(_controller(main).side, UnitType.Faction.DARK)
	main.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	assert_false(main.paused, "losing focus pauses a campaign mission only")
	_push(_key(KEY_P))
	assert_true(main.paused)
	_step(main, 3)
	assert_eq(main.world.tick, 0)


func test_the_sandbox_menu_can_only_resume() -> void:
	var main: MainView = _sandbox()
	_push(_key(KEY_ESCAPE))
	assert_true(main.pause_menu().is_open())
	assert_false(_button(main.pause_menu(), "RestartButton").visible)
	assert_false(_button(main.pause_menu(), "SettingsButton").visible)
	assert_false(_button(main.pause_menu(), "QuitButton").visible)
	assert_true(_button(main.pause_menu(), "ResumeButton").visible)


# --- one more helper, below its users -----------------------------------------


# The button with this name or text under the node.
func _button(under: Node, label: String) -> Button:
	for node: Node in under.find_children("*", "Button", true, false):
		var button: Button = node as Button
		if button.name == label or button.text == label:
			return button
	fail_test("no button %s" % label)
	return Button.new()
