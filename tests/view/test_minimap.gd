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
	if DirAccess.dir_exists_absolute(SETTINGS_DIR):
		for file_name: String in DirAccess.get_files_at(SETTINGS_DIR):
			DirAccess.remove_absolute(SETTINGS_DIR + "/" + file_name)
		DirAccess.remove_absolute(SETTINGS_DIR)


# --- helpers ------------------------------------------------------------------


# A world with two Light Shieldmen, a selection controller over it, a camera
# rig, and both maps fed the same of each.
func _fixture() -> Dictionary:
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
	return {"world": world, "rig": rig, "minimap": minimap, "overhead": overhead}


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
