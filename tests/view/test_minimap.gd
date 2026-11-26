extends GutTest
## Minimap (Phase 12): the always-on corner map. Its north-up coordinates
## round-trip; a left click moves the camera; the order button sends the
## selection exactly as the Tab map would (the same commands queued); it hides
## while the Tab map is open and when Settings turns it off; and the objectives
## hang below it, right-aligned, at 1280x720 and 1920x1080.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const SETTINGS_DIR: String = "user://test_minimap"

var _physics_rate: int = 0
var _window_size: Vector2i


func before_all() -> void:
	_physics_rate = Engine.physics_ticks_per_second
	_window_size = get_window().size


func after_all() -> void:
	get_window().size = _window_size
	Engine.physics_ticks_per_second = _physics_rate
	ViewFixtures.cleanup()


func before_each() -> void:
	InputBindings.install()
	InputBindings.reset(InputBindings.Preset.MODERN)


func after_each() -> void:
	InputBindings.reset(InputBindings.Preset.MODERN)
	get_window().content_scale_factor = 1.0
	if DirAccess.dir_exists_absolute(SETTINGS_DIR):
		for file_name: String in DirAccess.get_files_at(SETTINGS_DIR):
			DirAccess.remove_absolute(SETTINGS_DIR + "/" + file_name)
		DirAccess.remove_absolute(SETTINGS_DIR)


# --- helpers ------------------------------------------------------------------


# A world with two Light Shieldmen, a selection controller over it, a camera
# rig, and both maps fed the same of each.
func _fixture() -> Dictionary:
	get_window().size = Vector2i(1280, 720)
	var catalog: UnitCatalog = TestTerrains.catalog()
	var world: World = World.new(1, TestTerrains.flat(40, 40), catalog)
	var a: Unit = world.spawn_unit(catalog.index_of(&"shieldman"), LIGHT, 10 * M, 20 * M, 1, 0)
	world.spawn_unit(catalog.index_of(&"shieldman"), LIGHT, 16 * M, 20 * M, 1, 0)
	var rig: RtsCamera = RtsCamera.new()
	add_child_autofree(rig)
	rig.setup(world.terrain)
	var units: UnitsView = UnitsView.new()
	add_child_autofree(units)
	var controller: SelectionController = SelectionController.new()
	add_child_autofree(controller)
	units.setup(world, controller.selection, null)
	controller.setup(world, units, rig.get_camera(), TerrainPicker.new(world.terrain))
	controller.selection.select(PackedInt32Array([a.id]))
	var minimap: Minimap = Minimap.new()
	add_child_autofree(minimap)
	minimap.setup(world.terrain, rig, world)
	minimap.set_orders(controller)
	var overhead: OverheadMap = OverheadMap.new()
	add_child_autofree(overhead)
	overhead.setup(world.terrain, rig, world)
	overhead.set_orders(controller)
	overhead.visible = true
	return {"world": world, "rig": rig, "minimap": minimap, "overhead": overhead, "controller": controller}


# The commands queued so far, encoded, and the queue emptied.
func _drain(world: World) -> Array:
	var out: Array = []
	for command: SimCommand in world._pending:
		out.append(CommandCodec.encode(command))
	world._pending = []
	return out


func _attack_mask() -> int:
	return KEY_MASK_META if OS.has_feature("macos") else KEY_MASK_CTRL


func _click(button: MouseButton, at: Vector2, mods: int) -> InputEventMouseButton:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button
	event.pressed = true
	event.position = at
	event.shift_pressed = mods & KEY_MASK_SHIFT != 0
	event.alt_pressed = mods & KEY_MASK_ALT != 0
	event.ctrl_pressed = mods & KEY_MASK_CTRL != 0
	event.meta_pressed = mods & KEY_MASK_META != 0
	return event


func _main(size: Vector2i = Vector2i(1280, 720)) -> MainView:
	get_window().size = size
	var main: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	main.launch = ViewFixtures.launch()
	add_child_autofree(main)
	main.set_physics_process(false)
	main._physics_process(1.0 / World.TICK_RATE)
	return main


# --- coordinates --------------------------------------------------------------


func test_map_and_local_points_round_trip_north_up() -> void:
	var f: Dictionary = _fixture()
	var minimap: Minimap = f["minimap"]
	for p: Vector2 in [Vector2(0.0, 0.0), Vector2(12.5, 30.0), Vector2(39.0, 39.0), Vector2(20.0, 3.0)]:
		var back: Vector2 = minimap.local_to_map(minimap.map_to_local(p))
		assert_almost_eq(back.x, p.x, 0.001, str(p))
		assert_almost_eq(back.y, p.y, 0.001, str(p))
	var origin: Vector2 = minimap.map_to_local(Vector2.ZERO)
	var far: Vector2 = minimap.map_to_local(Vector2(39.0, 39.0))
	assert_lt(origin.x, far.x, "+x is right")
	assert_lt(origin.y, far.y, "+z is down: z = 0 is the top edge")
	assert_true(Rect2(Vector2.ZERO, minimap.size).has_point(origin))
	assert_true(Rect2(Vector2.ZERO, minimap.size).has_point(far))


func test_the_map_is_the_set_size() -> void:
	var f: Dictionary = _fixture()
	assert_eq((f["minimap"] as Minimap).size, Vector2(Minimap.SIZE_PX, Minimap.SIZE_PX))


# --- clicks -------------------------------------------------------------------


func test_a_left_click_moves_the_camera_focus() -> void:
	var f: Dictionary = _fixture()
	var minimap: Minimap = f["minimap"]
	var rig: RtsCamera = f["rig"]
	minimap.click_at(minimap.map_to_local(Vector2(30.0, 8.0)), MOUSE_BUTTON_LEFT, 0)
	assert_almost_eq(rig.focus.x, 30.0, 0.2)
	assert_almost_eq(rig.focus.z, 8.0, 0.2)
	assert_eq(_drain(f["world"]), [], "and orders nobody")


func test_the_order_button_queues_what_the_tab_map_would() -> void:
	var cases: Array[Array] = [
		[MOUSE_BUTTON_RIGHT, 0],
		[MOUSE_BUTTON_RIGHT, _attack_mask()],
		[MOUSE_BUTTON_RIGHT, KEY_MASK_SHIFT],
		[MOUSE_BUTTON_LEFT, KEY_MASK_ALT],
	]
	var point: Vector2 = Vector2(30.0, 8.0)
	var mini: Dictionary = _fixture()
	var tab: Dictionary = _fixture()
	var minimap: Minimap = mini["minimap"]
	var overhead: OverheadMap = tab["overhead"]
	for c: Array in cases:
		var focus_before: Vector3 = (mini["rig"] as RtsCamera).focus
		minimap.click_at(minimap.map_to_local(point), c[0], c[1])
		overhead._gui_input(_click(c[0], overhead._world_to_screen(point), c[1]))
		var from_mini: Array = _drain(mini["world"])
		var from_tab: Array = _drain(tab["world"])
		assert_eq(from_mini.size(), 1, "one command for %s" % [c])
		assert_eq(from_mini, from_tab, "the same command for %s" % [c])
		assert_eq((mini["rig"] as RtsCamera).focus, focus_before, "the camera stayed for %s" % [c])


func test_a_real_right_click_on_the_map_sends_the_selection() -> void:
	var f: Dictionary = _fixture()
	var minimap: Minimap = f["minimap"]
	minimap._gui_input(_click(MOUSE_BUTTON_RIGHT, minimap.map_to_local(Vector2(30.0, 8.0)), 0))
	var queued: Array = _drain(f["world"])
	assert_eq(queued.size(), 1)
	assert_true(CommandCodec.decode(queued[0]) is MoveUnitsCommand)


func test_an_armed_order_is_placed_where_either_map_is_clicked() -> void:
	var armed: Array[SelectionController.ArmedOrder] = [
		SelectionController.ArmedOrder.ATTACK_MOVE, SelectionController.ArmedOrder.GROUND_ATTACK,
	]
	var point: Vector2 = Vector2(30.0, 8.0)
	for order: SelectionController.ArmedOrder in armed:
		for button: MouseButton in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			for on_tab: bool in [false, true]:
				var f: Dictionary = _fixture()
				var controller: SelectionController = f["controller"]
				var rig: RtsCamera = f["rig"]
				var focus_before: Vector3 = rig.focus
				controller.arm(order)
				var what: String = "%s, button %d, %s" % [
					SelectionController.ArmedOrder.keys()[order], button, "Tab map" if on_tab else "corner map"
				]
				if on_tab:
					var overhead: OverheadMap = f["overhead"]
					overhead._gui_input(_click(button, overhead._world_to_screen(point), 0))
				else:
					var minimap: Minimap = f["minimap"]
					minimap.click_at(minimap.map_to_local(point), button, 0)
				var queued: Array = _drain(f["world"])
				assert_eq(queued.size(), 1, what)
				if queued.size() != 1:
					continue
				var command: SimCommand = CommandCodec.decode(queued[0])
				if order == SelectionController.ArmedOrder.ATTACK_MOVE:
					assert_true(command is AttackMoveCommand, what)
				else:
					assert_true(command is GroundAttackCommand, what)
					assert_almost_eq((command as GroundAttackCommand).x, 30 * M, 1200, what)
					assert_almost_eq((command as GroundAttackCommand).z, 8 * M, 1200, what)
				assert_eq(controller.armed_order, SelectionController.ArmedOrder.NONE, "disarmed: " + what)
				assert_eq(rig.focus, focus_before, "the camera stayed: " + what)


func test_an_armed_move_is_placed_at_the_map_point() -> void:
	var f: Dictionary = _fixture()
	var controller: SelectionController = f["controller"]
	var minimap: Minimap = f["minimap"]
	controller.arm(SelectionController.ArmedOrder.MOVE)
	minimap.click_at(minimap.map_to_local(Vector2(30.0, 8.0)), MOUSE_BUTTON_LEFT, 0)
	var queued: Array = _drain(f["world"])
	assert_eq(queued.size(), 1)
	if queued.size() == 1:
		var command: SimCommand = CommandCodec.decode(queued[0])
		assert_true(command is MoveUnitsCommand)
		assert_almost_eq((command as MoveUnitsCommand).x, 30 * M, 1200)
		assert_almost_eq((command as MoveUnitsCommand).z, 8 * M, 1200)
	assert_eq(controller.armed_order, SelectionController.ArmedOrder.NONE, "disarmed")


func test_an_armed_route_point_stays_armed_as_on_the_ground() -> void:
	var f: Dictionary = _fixture()
	var controller: SelectionController = f["controller"]
	var minimap: Minimap = f["minimap"]
	controller.arm(SelectionController.ArmedOrder.WAYPOINT)
	minimap.click_at(minimap.map_to_local(Vector2(30.0, 8.0)), MOUSE_BUTTON_LEFT, 0)
	var queued: Array = _drain(f["world"])
	assert_eq(queued.size(), 1)
	if queued.size() == 1:
		assert_true(CommandCodec.decode(queued[0]) is RoutePointCommand)
	assert_eq(controller.armed_order, SelectionController.ArmedOrder.WAYPOINT, "still armed for the next point")


func test_an_armed_heal_falls_back_to_a_plain_click_and_stays_armed() -> void:
	var f: Dictionary = _fixture()
	var controller: SelectionController = f["controller"]
	var minimap: Minimap = f["minimap"]
	var rig: RtsCamera = f["rig"]
	controller.arm(SelectionController.ArmedOrder.HEAL)
	minimap.click_at(minimap.map_to_local(Vector2(30.0, 8.0)), MOUSE_BUTTON_LEFT, 0)
	assert_eq(_drain(f["world"]), [], "nobody ordered")
	assert_almost_eq(rig.focus.x, 30.0, 0.2, "the camera moved")
	assert_almost_eq(rig.focus.z, 8.0, 0.2)
	assert_eq(controller.armed_order, SelectionController.ArmedOrder.HEAL, "still armed")


func test_an_armed_order_that_cannot_be_given_leaves_the_click_to_the_camera() -> void:
	var f: Dictionary = _fixture()
	var controller: SelectionController = f["controller"]
	var minimap: Minimap = f["minimap"]
	var rig: RtsCamera = f["rig"]
	controller.paused = true
	# Pausing disarms; set the order behind its back, as a stale arm would be.
	controller.armed_order = SelectionController.ArmedOrder.ATTACK_MOVE
	minimap.click_at(minimap.map_to_local(Vector2(30.0, 8.0)), MOUSE_BUTTON_LEFT, 0)
	assert_eq(_drain(f["world"]), [], "nothing can be ordered while paused")
	assert_almost_eq(rig.focus.x, 30.0, 0.2, "but the click still moves the camera")
	controller.paused = false
	controller.armed_order = SelectionController.ArmedOrder.GROUND_ATTACK
	controller.selection.clear()
	controller.armed_order = SelectionController.ArmedOrder.GROUND_ATTACK
	minimap.click_at(minimap.map_to_local(Vector2(10.0, 30.0)), MOUSE_BUTTON_LEFT, 0)
	assert_eq(_drain(f["world"]), [], "nobody selected")
	assert_almost_eq(rig.focus.z, 30.0, 0.2, "the camera moved")


func test_the_wheel_over_the_map_zooms_the_camera() -> void:
	get_window().size = Vector2i(1280, 720)
	var f: Dictionary = _fixture()
	var minimap: Minimap = f["minimap"]
	var rig: RtsCamera = f["rig"]
	(f["overhead"] as OverheadMap).visible = false
	await wait_process_frames(1)
	var press: InputEventMouseButton = _click(MOUSE_BUTTON_RIGHT, minimap.get_global_rect().get_center(), 0)
	get_viewport().push_input(press)
	assert_eq(_drain(f["world"]).size(), 1, "a pushed click does reach the map")
	var up: InputEventMouseButton = press.duplicate() as InputEventMouseButton
	up.pressed = false
	get_viewport().push_input(up)
	var before: float = rig._target_distance
	var wheel: InputEventMouseButton = _click(MOUSE_BUTTON_WHEEL_UP, minimap.get_global_rect().get_center(), 0)
	get_viewport().push_input(wheel)
	assert_lt(rig._target_distance, before, "the wheel reached the camera")
	var release: InputEventMouseButton = wheel.duplicate() as InputEventMouseButton
	release.pressed = false
	get_viewport().push_input(release)


# --- lifecycle ------------------------------------------------------------------


# The fixture with a Husk 10 m from the selected Shieldman, spotted.
func _spotting() -> Dictionary:
	var f: Dictionary = _fixture()
	var world: World = f["world"]
	f["husk"] = world.spawn_unit(world.catalog.index_of(&"husk"), DARK, 20 * M, 20 * M, 2, 0)
	var minimap: Minimap = f["minimap"]
	minimap.set_viewer(LIGHT)
	_updates(f, SpottingMemory.REFRESH_UPDATES)
	assert_eq(minimap.memory.spotted().size(), 1, "the Husk is spotted")
	return f


func _updates(f: Dictionary, count: int) -> void:
	var world: World = f["world"]
	for _i: int in count:
		world.tick += Minimap.REFRESH_TICKS
		(f["minimap"] as Minimap).after_step()


func test_a_new_map_forgets_what_was_spotted() -> void:
	var f: Dictionary = _spotting()
	var minimap: Minimap = f["minimap"]
	var world: World = f["world"]
	minimap.setup(world.terrain, f["rig"], world)
	assert_eq(minimap.memory.spotted().size(), 0)


func test_another_viewer_forgets_and_the_same_one_does_not() -> void:
	var f: Dictionary = _spotting()
	var minimap: Minimap = f["minimap"]
	minimap.set_viewer(LIGHT)
	assert_eq(minimap.memory.spotted().size(), 1, "the same side keeps it")
	minimap.set_viewer(DARK)
	assert_eq(minimap.memory.spotted().size(), 0, "the other side starts afresh")


func test_the_debug_side_switch_forgets() -> void:
	var main: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	get_window().size = Vector2i(1280, 720)
	add_child_autofree(main)
	main.set_physics_process(false)
	var minimap: Minimap = main.get_node("Hud/Minimap") as Minimap
	minimap.memory._spotted[12345] = Vector2.ONE
	main._selection.switch_side()
	assert_eq(minimap.viewer, DARK)
	assert_eq(minimap.memory.spotted().size(), 0)


func test_an_enemy_no_one_sees_any_more_fades_as_a_mark() -> void:
	var f: Dictionary = _spotting()
	var world: World = f["world"]
	var minimap: Minimap = f["minimap"]
	for unit: Unit in world.units:
		if unit.faction == LIGHT:
			unit.state = Unit.State.DEAD
	_updates(f, SpottingMemory.REFRESH_UPDATES)
	var colors: Array[Color] = []
	for dot: Dictionary in minimap.dots():
		colors.append(dot["color"])
	assert_eq(colors.size(), 1, "only the mark: %s" % [colors])
	if colors.size() == 1:
		assert_eq(Color(colors[0], 1.0), Color(Minimap.MARK_COLOR, 1.0), "dim red")
		assert_lt(colors[0].a, Minimap.MARK_COLOR.a, "and fading")


func test_after_step_waits_for_every_eighth_tick_and_for_the_map_to_show() -> void:
	var f: Dictionary = _fixture()
	var world: World = f["world"]
	var minimap: Minimap = f["minimap"]
	world.spawn_unit(world.catalog.index_of(&"husk"), DARK, 20 * M, 20 * M, 2, 0)
	minimap.set_viewer(LIGHT)
	world.tick = Minimap.REFRESH_TICKS - 1
	minimap.after_step()
	assert_eq(minimap.memory.spotted().size(), 0, "not on tick 7")
	world.tick = Minimap.REFRESH_TICKS
	minimap.visible = false
	minimap.after_step()
	assert_eq(minimap.memory.spotted().size(), 0, "not while hidden")
	assert_false(minimap.is_processing(), "and a hidden map does no work each frame")
	minimap.visible = true
	assert_true(minimap.is_processing())
	minimap.after_step()
	assert_eq(minimap.memory.spotted().size(), 1, "on tick 8, shown")


func test_a_contested_hill_redraws_only_when_its_flash_turns() -> void:
	var f: Dictionary = _fixture()
	var world: World = f["world"]
	var rules: SkirmishRules = SkirmishRules.for_map(
		ViewFixtures.skirmish_map(), SkirmishRules.Mode.KING_OF_THE_HILL, 10, LIGHT
	)
	assert_true(world.start_mission(MissionScript.new(), 0))
	assert_true(world.start_skirmish(rules))
	world.skirmish.hill_holder = SkirmishRuntime.CONTESTED
	var minimap: Minimap = f["minimap"]
	(f["overhead"] as OverheadMap).visible = false
	var now: Array[float] = [0.0]
	minimap.clock = func() -> float: return now[0]
	minimap.setup(world.terrain, f["rig"], world)
	await wait_process_frames(3)
	var draws: Array[int] = [0]
	minimap.draw.connect(func() -> void: draws[0] += 1)
	await wait_process_frames(4)
	assert_eq(draws[0], 0, "the same flash side: nothing drawn")
	now[0] = FlagsView.CONTEST_FLASH_SECONDS * 1.5
	await wait_process_frames(4)
	assert_eq(draws[0], 1, "the flash turned: one redraw")
	now[0] = FlagsView.CONTEST_FLASH_SECONDS * 1.9
	await wait_process_frames(4)
	assert_eq(draws[0], 1, "still the same side: no more")


func test_a_quiet_skirmish_map_does_not_redraw_every_frame() -> void:
	var f: Dictionary = _fixture()
	var world: World = f["world"]
	var rules: SkirmishRules = SkirmishRules.for_map(
		ViewFixtures.skirmish_map(), SkirmishRules.Mode.KING_OF_THE_HILL, 10, LIGHT
	)
	assert_true(world.start_mission(MissionScript.new(), 0))
	assert_true(world.start_skirmish(rules))
	var minimap: Minimap = f["minimap"]
	(f["overhead"] as OverheadMap).visible = false
	minimap.setup(world.terrain, f["rig"], world)
	await wait_process_frames(3)
	var draws: Array[int] = [0]
	minimap.draw.connect(func() -> void: draws[0] += 1)
	await wait_process_frames(5)
	assert_eq(draws[0], 0, "nothing changed, nothing drawn")


# --- what it draws --------------------------------------------------------------


func test_the_camera_outline_surrounds_the_focus() -> void:
	var f: Dictionary = _fixture()
	var minimap: Minimap = f["minimap"]
	var rig: RtsCamera = f["rig"]
	rig.set_pose(Vector2(20.0, 20.0), 0.0, 30.0)
	var corners: PackedVector2Array = minimap.camera_footprint()
	assert_eq(corners.size(), 4)
	assert_true(Geometry2D.is_point_in_polygon(Vector2(20.0, 20.0), corners), str(corners))
	# Looking north (-z) from the south: the far (top-screen) edge is the wider.
	assert_lt(corners[0].y, 20.0, "the top-left screen corner is north of the focus")
	assert_gt(corners[2].y, 20.0, "the bottom-right is south")
	assert_gt(absf(corners[1].x - corners[0].x), absf(corners[2].x - corners[3].x), "a trapezoid, far edge wider")


func test_spotted_enemies_and_your_units_are_dotted() -> void:
	var f: Dictionary = _fixture()
	var world: World = f["world"]
	var minimap: Minimap = f["minimap"]
	var catalog: UnitCatalog = world.catalog
	var near: Unit = world.spawn_unit(catalog.index_of(&"husk"), DARK, 20 * M, 20 * M, 2, 0)
	minimap.set_viewer(LIGHT)
	for _i: int in SpottingMemory.REFRESH_UPDATES:
		world.tick += Minimap.REFRESH_TICKS
		minimap.after_step()
	var dots: Array[Dictionary] = minimap.dots()
	var reds: int = 0
	var greens: int = 0
	var whites: int = 0
	for dot: Dictionary in dots:
		var color: Color = dot["color"]
		if color == Minimap.ENEMY_COLOR:
			reds += 1
			assert_almost_eq((dot["at"] as Vector2).x, minimap.map_to_local(Vector2(20.0, 20.0)).x, 0.01)
		elif color == Minimap.SELECTED_COLOR:
			whites += 1
		elif color == Minimap.OWN_COLOR:
			greens += 1
	assert_eq([greens, whites, reds], [1, 1, 1], "one of yours, one selected, the Husk spotted")
	near.state = Unit.State.DEAD
	minimap.after_step()
	assert_eq(minimap.dots().size(), 2, "a dead enemy isn't drawn")


# --- in the scene ---------------------------------------------------------------


func test_it_hides_while_the_tab_map_is_open() -> void:
	var main: MainView = _main()
	var minimap: Minimap = main.get_node("Hud/Minimap") as Minimap
	var overhead: OverheadMap = main.get_node("Hud/OverheadMap") as OverheadMap
	assert_true(minimap.visible)
	overhead.toggle()
	assert_false(minimap.visible)
	overhead.toggle()
	assert_true(minimap.visible)


func test_the_objectives_hang_below_it_right_aligned() -> void:
	for size: Vector2i in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
		var main: MainView = _main(size)
		var minimap: Minimap = main.get_node("Hud/Minimap") as Minimap
		var panel: ObjectivePanel = main.get_node("Hud/ObjectivePanel") as ObjectivePanel
		var map_rect: Rect2 = minimap.get_global_rect()
		var panel_rect: Rect2 = panel.get_global_rect()
		var screen: Vector2 = minimap.get_viewport_rect().size
		assert_true(panel.visible, str(size))
		assert_almost_eq(map_rect.end.x, screen.x - Minimap.MARGIN, 0.5, "the map's right edge at %s" % size)
		assert_almost_eq(map_rect.position.y, Minimap.MARGIN, 0.5, "its top at %s" % size)
		assert_gte(panel_rect.position.y, map_rect.end.y, "the objectives start below it at %s" % size)
		assert_almost_eq(panel_rect.end.x, map_rect.end.x, 0.5, "right-aligned at %s" % size)
		main.free()


func test_the_message_line_wraps_clear_of_it() -> void:
	var main: MainView = _main(Vector2i(1152, 648))
	var minimap: Minimap = main.get_node("Hud/Minimap") as Minimap
	var line: Label = (main.get_node("Hud/MissionHud") as MissionHud)._objective
	assert_lte(line.get_global_rect().end.x, minimap.get_global_rect().position.x, "the line stops short of the map")
	assert_ne(line.autowrap_mode, TextServer.AUTOWRAP_OFF, "and a long one wraps")
	var screen: float = minimap.get_viewport_rect().size.x
	assert_almost_eq(line.get_global_rect().get_center().x, screen / 2.0, 0.5, "still top centre")
	main.corner_map = false
	assert_almost_eq(line.get_global_rect().end.x, screen, 0.5, "the whole width without the map")


func test_the_skirmish_line_keeps_clear_of_it() -> void:
	get_window().size = Vector2i(1280, 720)
	var main: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	main.launch = ViewFixtures.skirmish_launch()
	add_child_autofree(main)
	main.set_physics_process(false)
	var minimap: Minimap = main.get_node("Hud/Minimap") as Minimap
	var line: Label = (main.get_node("Hud/SkirmishHud") as SkirmishHud)._line
	assert_lte(line.get_global_rect().end.x, minimap.get_global_rect().position.x)
	assert_ne(line.autowrap_mode, TextServer.AUTOWRAP_OFF, "a long one wraps")
	assert_almost_eq(line.get_global_rect().get_center().x, 640.0, 0.5, "still centred")


func test_the_replay_bar_keeps_clear_of_it_with_a_long_note() -> void:
	get_window().size = Vector2i(1280, 720)
	var main: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	main.launch = MissionLaunch.for_replay(ReplayStore.load_file("res://data/replays/golden/skirmish_ctf.amr"))
	add_child_autofree(main)
	main.set_physics_process(false)
	main.set_process(false)
	var bar: ReplayBar = main.find_child("ReplayBar", true, false) as ReplayBar
	bar.show_state(0, 9000, false, 1, "Left the recording at 12:34: recorded with version 0.11.0-a-long-build-name")
	await wait_process_frames(2)
	var minimap: Minimap = main.get_node("Hud/Minimap") as Minimap
	assert_false(bar.get_global_rect().intersects(minimap.get_global_rect()), "%s vs %s" % [
		bar.get_global_rect(), minimap.get_global_rect()
	])


func test_at_either_interface_scale_the_map_objectives_and_bar_keep_apart() -> void:
	for scale: float in [0.75, 2.5]:
		get_window().content_scale_factor = scale
		var main: MainView = _main(Vector2i(1280, 720))
		await wait_process_frames(2)
		var screen: Vector2 = main.get_node("Hud/Minimap").get_viewport_rect().size
		var map: Rect2 = (main.get_node("Hud/Minimap") as Control).get_global_rect()
		var panel: Rect2 = (main.get_node("Hud/ObjectivePanel") as Control).get_global_rect()
		var bar: Rect2 = (main.get_node("Hud/ControlBar") as Control).get_global_rect()
		var what: String = "at %d%%: map %s, objectives %s, bar %s" % [roundi(scale * 100), map, panel, bar]
		assert_lte(map.size.y, screen.y * Minimap.MAX_HEIGHT_SHARE + 0.5, what)
		assert_lte(map.size.x, screen.x * Minimap.MAX_WIDTH_SHARE + 0.5, what)
		assert_true(map.position.y >= 0.0 and map.end.x <= screen.x, "on screen " + what)
		assert_false(map.intersects(panel), "map and objectives " + what)
		assert_false(map.intersects(bar), "map and bar " + what)
		assert_false(panel.intersects(bar), "objectives and bar " + what)
		main.free()
	get_window().content_scale_factor = 1.0


func test_the_setting_off_hides_it_and_lifts_the_objectives() -> void:
	var main: MainView = _main()
	var minimap: Minimap = main.get_node("Hud/Minimap") as Minimap
	var panel: ObjectivePanel = main.get_node("Hud/ObjectivePanel") as ObjectivePanel
	main.corner_map = false
	assert_false(minimap.visible)
	assert_eq(panel.offset_top, ObjectivePanel.MARGIN_TOP, "back where it was without the map")
	main.corner_map = true
	assert_true(minimap.visible)
	assert_gte(panel.offset_top, minimap.get_global_rect().end.y)


func test_the_corner_map_setting_is_on_by_default_and_saved() -> void:
	var path: String = SETTINGS_DIR + "/settings.cfg"
	assert_true(GameSettings.corner_map(path))
	assert_eq(GameSettings.set_corner_map(false, path), OK)
	assert_false(GameSettings.corner_map(path))
	var menu: SettingsMenu = SettingsMenu.new()
	menu.setup(path)
	add_child_autofree(menu)
	var check: CheckBox = MenuFixtures.named(menu, "CornerMapCheck") as CheckBox
	assert_not_null(check)
	assert_false(check.button_pressed)
	check.button_pressed = true
	assert_true(GameSettings.corner_map(path), "the toggle saves")


func test_the_views_leave_the_sim_alone() -> void:
	var watched: MainView = _main()
	var plain: MainView = _main()
	plain.corner_map = false
	for _i: int in 40:
		watched._physics_process(1.0 / World.TICK_RATE)
		plain._physics_process(1.0 / World.TICK_RATE)
	(watched.get_node("Hud/Minimap") as Minimap).queue_redraw()
	await wait_process_frames(2)
	assert_eq(watched.world.state_hash(), plain.world.state_hash())
