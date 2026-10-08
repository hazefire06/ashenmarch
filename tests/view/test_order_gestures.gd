extends GutTest
## Phase 11's mouse and keyboard orders, through the real input handler with
## a camera looking straight down at a flat map (screen right is +x, screen
## down is +z): a right drag sets the formation's facing, and one started on
## the only unit selected turns it in place; Option + left drag is the same
## for a one-button mouse; shift + right click lays a route and closes it
## into a patrol; G, B and R guard, scatter and retreat; the arrow keys turn
## the next move or the one under way; Enter, `, F, Delete and F10 work the
## selection, the groups and the health bars. The Classic preset gives orders
## with the left button and saves a group by holding its key.
## The headless viewport is 64 pixels square, about 1.4 pixels to the meter
## here, so units stand 6 m apart to be told apart by a click, and drags are
## given as ground points, far enough to pass the pixel thresholds.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

var _world: World
var _controller: SelectionController
var _units: UnitsView
var _camera: Camera3D
var _a: Unit
var _b: Unit
var _notices: Array[String] = []


func before_each() -> void:
	InputBindings.install()
	InputBindings.reset(InputBindings.Preset.MODERN)
	var catalog: UnitCatalog = TestTerrains.catalog()
	_world = World.new(1, TestTerrains.flat(40, 40), catalog)
	_a = _world.spawn_unit(catalog.index_of(&"shieldman"), LIGHT, 10 * M, 20 * M, 1, 0)
	_b = _world.spawn_unit(catalog.index_of(&"shieldman"), LIGHT, 16 * M, 20 * M, 1, 0)
	_camera = Camera3D.new()
	add_child_autofree(_camera)
	_camera.position = Vector3(20.0, 30.0, 20.0)
	_camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_camera.make_current()
	_units = UnitsView.new()
	add_child_autofree(_units)
	_controller = SelectionController.new()
	add_child_autofree(_controller)
	_units.setup(_world, _controller.selection, null)
	_controller.setup(_world, _units, _camera, TerrainPicker.new(_world.terrain))
	_notices.clear()
	_controller.notice.connect(func(text: String) -> void: _notices.append(text))


func after_each() -> void:
	InputBindings.reset(InputBindings.Preset.MODERN)
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)


# --- facing -------------------------------------------------------------------


func test_a_right_drag_sets_the_formations_facing() -> void:
	_select(_a, _b)
	_press(MOUSE_BUTTON_RIGHT, _at(25, 20))
	_move(_at(25, 30))
	_release(MOUSE_BUTTON_RIGHT, _at(25, 30))
	_world.step()
	for unit: Unit in [_a, _b]:
		assert_eq(unit.order, Unit.Order.MOVE)
		assert_eq([unit.order_facing_x, unit.order_facing_z], [0, 1000], "dragged south, so facing south")
	var mid: Vector2 = Vector2(_a.order_x + _b.order_x, _a.order_z + _b.order_z) / 2.0
	assert_almost_eq(mid.x, 25.0 * M, 400.0, "the order went where the drag started")
	assert_almost_eq(mid.y, 20.0 * M, 400.0)


func test_a_right_click_without_a_drag_faces_the_usual_way() -> void:
	_select(_a, _b)
	_press(MOUSE_BUTTON_RIGHT, _at(30, 20))
	_release(MOUSE_BUTTON_RIGHT, _at(30, 20))
	_world.step()
	assert_eq([_a.order_facing_x, _a.order_facing_z], [1000, 0], "east, from the group toward the click")


func test_dragging_from_the_one_unit_selected_turns_it_in_place() -> void:
	await wait_process_frames(2)  # the sprites move to their units in _process
	_select(_a)
	var on_unit: Vector2 = _camera.unproject_position(Vector3(10.0, 1.0, 20.0))
	_press(MOUSE_BUTTON_RIGHT, on_unit)
	_move(_at(10, 8))
	_release(MOUSE_BUTTON_RIGHT, _at(10, 8))
	_world.step()
	assert_eq([_a.order_x, _a.order_z], [10 * M, 20 * M], "it stays where it is")
	# The press was over the sprite, a little off its feet on the ground.
	assert_almost_eq(_a.order_facing_x, 0, 60, "and turns north")
	assert_almost_eq(_a.order_facing_z, -1000, 3)


func test_option_left_drag_is_the_one_button_facing_order() -> void:
	_select(_a, _b)
	_press(MOUSE_BUTTON_LEFT, _at(25, 20), "a")
	_move(_at(15, 20))
	_release(MOUSE_BUTTON_LEFT, _at(15, 20))
	_world.step()
	assert_eq(_a.order, Unit.Order.MOVE)
	assert_eq([_a.order_facing_x, _a.order_facing_z], [-1000, 0])
	assert_eq(_controller.selection.size(), 2, "it selected nothing")


func test_esc_drops_a_drag_without_an_order() -> void:
	_select(_a)
	_press(MOUSE_BUTTON_RIGHT, _at(25, 20))
	_move(_at(25, 30))
	_key(KEY_ESCAPE)
	_release(MOUSE_BUTTON_RIGHT, _at(25, 30))
	_world.step()
	assert_eq(_a.order, Unit.Order.NONE)


# --- routes -------------------------------------------------------------------


func test_shift_right_clicks_lay_a_route_and_the_first_point_again_makes_a_loop() -> void:
	_select(_a, _b)
	for p: Vector2i in [Vector2i(25, 10), Vector2i(30, 25), Vector2i(20, 32)]:
		_click(MOUSE_BUTTON_RIGHT, _at(p.x, p.y), "s")
		_world.step()
	assert_eq(UnitRoute.point_count(_a), 3)
	assert_eq(_controller.route_points().size(), 3, "the view shows the three points")
	_click(MOUSE_BUTTON_RIGHT, _at(25.5, 10.5), "s")
	_world.step()
	assert_eq(_a.route_mode, UnitRoute.Mode.LOOP)
	assert_eq(_b.route_mode, UnitRoute.Mode.LOOP)
	assert_true(_a.route_attack, "patrols fight")


func test_the_last_point_again_makes_a_back_and_forth() -> void:
	_select(_a)
	_click(MOUSE_BUTTON_RIGHT, _at(25, 10), "s")
	_world.step()
	_click(MOUSE_BUTTON_RIGHT, _at(30, 25), "s")
	_world.step()
	_click(MOUSE_BUTTON_RIGHT, _at(30, 25), "s")
	_world.step()
	assert_eq(_a.route_mode, UnitRoute.Mode.BACK_AND_FORTH)


func test_a_fifth_point_is_refused_with_a_notice() -> void:
	_select(_a)
	for p: Vector2i in [Vector2i(5, 5), Vector2i(10, 5), Vector2i(15, 5), Vector2i(20, 5), Vector2i(25, 5)]:
		_click(MOUSE_BUTTON_RIGHT, _at(p.x, p.y), "s")
		_world.step()
	assert_eq(UnitRoute.point_count(_a), 4)
	assert_has(_notices, "Route full (4 points)")


func test_cmd_shift_right_click_gives_an_attack_route() -> void:
	_select(_a)
	_click(MOUSE_BUTTON_RIGHT, _at(25, 10), "cs")
	_world.step()
	assert_true(_a.route_attack)
	assert_eq(_a.order, Unit.Order.ATTACK_MOVE)


func test_the_bars_waypoints_take_every_left_click_until_the_loop_closes() -> void:
	_select(_a)
	_controller.arm(SelectionController.ArmedOrder.WAYPOINT)
	for p: Vector2i in [Vector2i(25, 10), Vector2i(30, 25), Vector2i(20, 32)]:
		_click(MOUSE_BUTTON_LEFT, _at(p.x, p.y))
		_world.step()
	assert_eq(_controller.armed_order, SelectionController.ArmedOrder.WAYPOINT, "still armed")
	_click(MOUSE_BUTTON_LEFT, _at(25, 10))
	_world.step()
	assert_eq(_a.route_mode, UnitRoute.Mode.LOOP)
	assert_eq(_controller.armed_order, SelectionController.ArmedOrder.NONE, "the loop ends it")


# --- keys ---------------------------------------------------------------------


func test_g_b_and_r_guard_scatter_and_retreat() -> void:
	_select(_a, _b)
	_key(KEY_G)
	_world.step()
	assert_eq(_a.order, Unit.Order.GUARD)
	_key(KEY_B)
	_world.step()
	assert_eq(_a.order, Unit.Order.MOVE, "scattering")
	_world.spawn_unit(_world.catalog.index_of(&"husk"), DARK, 30 * M, 20 * M, -1, 0)
	_key(KEY_R)
	_world.step()
	assert_lt(_a.order_x, _a.x, "retreating west, away from the husk")


func test_an_arrow_turns_the_next_move() -> void:
	_select(_a, _b)
	_key(KEY_RIGHT)
	_key(KEY_RIGHT)
	_key(KEY_RIGHT)
	_key(KEY_RIGHT)
	assert_eq(_controller.pending_rotation(), 4)
	_click(MOUSE_BUTTON_RIGHT, _at(30, 20))
	_world.step()
	# The automatic facing is east; four steps (90 degrees) clockwise is south.
	assert_almost_eq(_a.order_facing_x, 0, 2)
	assert_almost_eq(_a.order_facing_z, 1000, 2)
	assert_eq(_controller.pending_rotation(), 0, "used up")


func test_an_arrow_turns_the_move_under_way() -> void:
	_select(_a, _b)
	_click(MOUSE_BUTTON_RIGHT, _at(35, 20))
	_world.step()
	_key(KEY_LEFT)
	_world.step()
	assert_eq(_controller.pending_rotation(), 0, "given again, not kept")
	var facing: Vector2 = Vector2(_a.order_facing_x, _a.order_facing_z) / 1000.0
	assert_almost_eq(facing.angle_to(Vector2(1, 0)), TAU / 16, 0.01, "a step counter-clockwise from east")
	assert_almost_eq(_a.order_x + _b.order_x, 70 * M, 2500, "the same place")


func test_enter_selects_all_on_screen_and_backtick_none() -> void:
	await wait_process_frames(2)
	_key(KEY_ENTER)
	assert_eq(_controller.selection.size(), 2)
	_key(KEY_QUOTELEFT)
	assert_true(_controller.selection.is_empty())


func test_f_cycles_the_groups_and_delete_clears_the_one_recalled() -> void:
	var centered: Array[bool] = [false]
	_controller.center_requested.connect(func() -> void: centered[0] = true)
	_select(_a)
	_controller.save_group(2)
	_select(_b)
	_controller.save_group(5)
	_controller.selection.clear()
	_key(KEY_F)
	assert_eq(_controller.selection.ids(), PackedInt32Array([_a.id]), "group 3 first")
	assert_true(centered[0], "and the camera follows")
	_key(KEY_F)
	assert_eq(_controller.selection.ids(), PackedInt32Array([_b.id]))
	_key(KEY_F)
	assert_eq(_controller.selection.ids(), PackedInt32Array([_a.id]), "round again")
	_key(KEY_BACKSPACE if OS.has_feature("macos") else KEY_DELETE)
	assert_true(_controller.selection.group(2).is_empty(), "group 3 is gone")
	assert_false(_controller.selection.group(5).is_empty())


func test_f10_shows_every_health_bar_while_held() -> void:
	_key(KEY_F10)
	assert_true(_units.show_all_health)
	_key(KEY_F10, false)
	assert_false(_units.show_all_health)


# --- Classic ------------------------------------------------------------------


func test_classic_left_click_on_the_ground_moves_and_on_a_unit_selects() -> void:
	await wait_process_frames(2)
	InputBindings.reset(InputBindings.Preset.CLASSIC)
	_click(MOUSE_BUTTON_LEFT, _camera.unproject_position(Vector3(10.0, 1.0, 20.0)))
	assert_eq(_controller.selection.ids(), PackedInt32Array([_a.id]), "the unit was selected")
	_click(MOUSE_BUTTON_LEFT, _at(30, 30))
	_world.step()
	assert_eq(_a.order, Unit.Order.MOVE, "the ground click ordered")
	assert_eq(_controller.selection.size(), 1, "and didn't deselect")


func test_classic_left_drag_from_the_ground_boxes() -> void:
	await wait_process_frames(2)
	InputBindings.reset(InputBindings.Preset.CLASSIC)
	_select(_b)
	_press(MOUSE_BUTTON_LEFT, _at(5, 15))
	_move(_at(13, 25))
	_release(MOUSE_BUTTON_LEFT, _at(13, 25))
	_world.step()
	assert_eq(_controller.selection.ids(), PackedInt32Array([_a.id]), "a box, not an order")
	assert_eq(_b.order, Unit.Order.NONE)


func test_classic_press_on_a_unit_and_drag_turns_it() -> void:
	await wait_process_frames(2)
	InputBindings.reset(InputBindings.Preset.CLASSIC)
	var on_unit: Vector2 = _camera.unproject_position(Vector3(10.0, 1.0, 20.0))
	_press(MOUSE_BUTTON_LEFT, on_unit)
	_move(_at(1, 20))
	_release(MOUSE_BUTTON_LEFT, _at(1, 20))
	_world.step()
	assert_eq(_controller.selection.ids(), PackedInt32Array([_a.id]))
	assert_eq([_a.order_facing_x, _a.order_facing_z], [-1000, 0], "it faces west")


func test_classic_shift_left_on_the_ground_lays_a_route() -> void:
	InputBindings.reset(InputBindings.Preset.CLASSIC)
	_select(_a)
	_click(MOUSE_BUTTON_LEFT, _at(25, 10), "s")
	_world.step()
	assert_eq(UnitRoute.point_count(_a), 1)


func test_classic_ground_click_drops_an_armed_heal_and_orders() -> void:
	InputBindings.reset(InputBindings.Preset.CLASSIC)
	var warden: Unit = _world.spawn_unit(_world.catalog.index_of(&"warden"), LIGHT, 20 * M, 12 * M, 1, 0)
	_units.after_step()
	_select(warden)
	_controller.use_special_selected()
	assert_eq(_controller.armed_order, SelectionController.ArmedOrder.HEAL)
	_click(MOUSE_BUTTON_LEFT, _at(30, 30))
	_world.step()
	assert_eq(_controller.armed_order, SelectionController.ArmedOrder.NONE)
	assert_eq(warden.order, Unit.Order.MOVE)


func test_classic_tap_recalls_and_hold_saves() -> void:
	InputBindings.reset(InputBindings.Preset.CLASSIC)
	var group_key: String = "c" if OS.has_feature("macos") else "a"
	_select(_a)
	_key(KEY_1, true, group_key)
	_controller._process(SelectionController.GROUP_HOLD_SECONDS + 0.1)
	_key(KEY_1, false, group_key)
	assert_eq(_controller.selection.group(0), PackedInt32Array([_a.id]), "held: saved")
	assert_has(_notices, "Group 1 saved")
	_select(_b)
	_key(KEY_1, true, group_key)
	_controller._process(0.2)
	_key(KEY_1, false, group_key)
	assert_eq(_controller.selection.ids(), PackedInt32Array([_a.id]), "tapped: recalled")


func test_classic_letting_go_of_the_modifier_ends_the_hold() -> void:
	InputBindings.reset(InputBindings.Preset.CLASSIC)
	var group_key: String = "c" if OS.has_feature("macos") else "a"
	_select(_a)
	_controller.save_group(3)
	_select(_b)
	_key(KEY_4, true, group_key)
	_controller._process(0.1)
	# A browser on a Mac may never send the digit's release: Cmd's comes.
	_key(KEY_META if OS.has_feature("macos") else KEY_ALT, false)
	assert_eq(_controller.selection.ids(), PackedInt32Array([_a.id]))
	_controller._process(1.0)
	assert_eq(_controller.selection.group(3), PackedInt32Array([_a.id]), "and nothing saves late")


# --- the overhead map ---------------------------------------------------------


func test_a_right_click_on_the_overhead_map_sends_the_selection() -> void:
	var rig: RtsCamera = RtsCamera.new()
	add_child_autofree(rig)
	rig.setup(_world.terrain)
	var map: OverheadMap = OverheadMap.new()
	add_child_autofree(map)
	map.setup(_world.terrain, rig, _world)
	map.set_orders(_controller)
	map.visible = true
	_select(_a)
	var target: Vector2 = map._world_to_screen(Vector2(30.0, 8.0))
	var focus_before: Vector3 = rig.focus
	var click: InputEventMouseButton = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_RIGHT
	click.pressed = true
	click.position = target
	map._gui_input(click)
	_world.step()
	assert_eq(_a.order, Unit.Order.MOVE)
	assert_almost_eq(_a.order_x, 30 * M, 1200)
	assert_almost_eq(_a.order_z, 8 * M, 1200)
	assert_eq(rig.focus, focus_before, "the camera stayed")
	assert_true(map.click_at(target, false), "a left click still moves the camera")
	assert_almost_eq(rig.focus.x, 30.0, 1.2)


# --- helpers ------------------------------------------------------------------


func _select(a: Unit, b: Unit = null) -> void:
	var ids: PackedInt32Array = PackedInt32Array([a.id])
	if b != null:
		ids.append(b.id)
	_controller.selection.select(ids)


# The screen point over the ground at (x, z) meters.
func _at(x: float, z: float) -> Vector2:
	return _camera.unproject_position(Vector3(x, 0.0, z))


# mods: "c" Cmd/Ctrl, "a" Option/Alt, "s" Shift.
func _with_mods(event: InputEventWithModifiers, mods: String) -> void:
	if mods.contains("c"):
		if OS.has_feature("macos"):
			event.meta_pressed = true
		else:
			event.ctrl_pressed = true
	event.alt_pressed = mods.contains("a")
	event.shift_pressed = mods.contains("s")


func _press(button: MouseButton, at: Vector2, mods: String = "") -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button
	event.pressed = true
	event.position = at
	_with_mods(event, mods)
	_controller._unhandled_input(event)


func _move(to: Vector2) -> void:
	var event: InputEventMouseMotion = InputEventMouseMotion.new()
	event.position = to
	_controller._input(event)


func _release(button: MouseButton, at: Vector2, mods: String = "") -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button
	event.pressed = false
	event.position = at
	_with_mods(event, mods)
	_controller._input(event)


func _click(button: MouseButton, at: Vector2, mods: String = "") -> void:
	_press(button, at, mods)
	_release(button, at, mods)


func _key(keycode: Key, pressed: bool = true, mods: String = "") -> void:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = keycode
	event.pressed = pressed
	_with_mods(event, mods)
	if pressed:
		_controller._unhandled_input(event)
	else:
		_controller._input(event)
