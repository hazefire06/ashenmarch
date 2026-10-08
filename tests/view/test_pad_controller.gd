extends GutTest
## A mission played with a pad (PadController), from synthetic pad events sent
## as a real pad's are (PadEvents: Input.parse_input_event, then a flush), so
## they travel the viewport and the action state like the real thing. The
## window is made 1280 x 720 for these: the headless one is 64 pixels square,
## too small to point at anything. Frames are stepped by hand.
## - The left stick moves the cursor; let go near a unit, it sticks to it; the
##   cursor pushed into an edge pans the camera, as the right stick does; the
##   triggers orbit; R3 held zooms with the right stick and tapped centers.
## - A selects, twice selects the type, held and moved boxes, held still on a
##   unit toggles it; X orders, held and moved sets the facing; B backs out of
##   whatever is under way, else selects none.
## - LB's wheel picks a formation, RB's an order; the D-pad steps through the
##   groups and holds to save or empty one; View opens the map (held: health
##   bars); L3 hands the pad to the control bar; Menu pauses, and B never does.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const FRAME: float = 1.0 / 60.0

var _physics_rate: int = 0
var _window_size: Vector2i
var _main: MainView
var _pad: PadController
var _soldier: Unit
var _second: Unit


func before_all() -> void:
	_physics_rate = Engine.physics_ticks_per_second
	_window_size = get_window().size
	get_window().size = Vector2i(1280, 720)


func after_all() -> void:
	get_window().size = _window_size
	Engine.physics_ticks_per_second = _physics_rate
	ViewFixtures.cleanup()


func before_each() -> void:
	InputBindings.install()
	InputBindings.reset(InputBindings.Preset.MODERN)
	_main = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	_main.launch = ViewFixtures.launch()
	add_child_autofree(_main)
	_main.set_physics_process(false)
	_main._physics_process(1.0 / World.TICK_RATE)
	_pad = _main.pad()
	for unit: Unit in _main.world.units:
		if unit.faction == LIGHT:
			_soldier = unit
	_second = _main.world.spawn_unit(
		_main.world.catalog.index_of(&"shieldman"), LIGHT, 22 * M, 25 * M, 1, 0
	)
	_main._units_view.after_step()
	_frames(2)
	InputDeviceTracker.tracker().use(InputBindings.Device.PAD)


func after_each() -> void:
	PadEvents.release_all()


# --- the cursor and the camera --------------------------------------------------


func test_the_pad_shows_its_cursor_and_the_keyboard_hides_it() -> void:
	assert_true(InputDeviceTracker.tracker().is_pad())
	assert_true(_pad.cursor.visible)
	assert_true(Pointer.using_pad(), "the tooltip follows it")
	var key: InputEventKey = InputEventKey.new()
	key.physical_keycode = KEY_W
	key.pressed = true
	InputDeviceTracker.tracker().note(key)
	assert_false(_pad.cursor.visible)


func test_the_left_stick_moves_the_cursor() -> void:
	_pad.place_cursor(Vector2(640, 360))
	PadEvents.left_stick(Vector2(1.0, 0.0))
	_frames(10)
	PadEvents.left_stick(Vector2.ZERO)
	assert_gt(_pad.cursor.at.x, 700.0)
	assert_almost_eq(_pad.cursor.at.y, 360.0, 1.0)


func test_let_go_near_a_unit_the_cursor_sticks_to_it() -> void:
	var on_unit: Vector2 = _main._selection.screen_point_of(_soldier.id)
	_pad.place_cursor(on_unit + Vector2(-60, 0))
	PadEvents.left_stick(Vector2(1.0, 0.0))
	while _pad.cursor.at.distance_to(on_unit) > PadController.SNAP_RADIUS * 0.8:
		_frames(1)
	PadEvents.left_stick(Vector2.ZERO)
	_frames(1)
	assert_almost_eq(_pad.cursor.at.x, on_unit.x, 1.0)
	assert_almost_eq(_pad.cursor.at.y, on_unit.y, 1.0)
	assert_true(_pad.cursor.snapped)


func test_the_right_stick_pans_the_triggers_orbit_and_r3_zooms() -> void:
	var rig: RtsCamera = _main._camera
	var focus: Vector3 = rig.focus
	PadEvents.right_stick(Vector2(0.0, -1.0))
	_frames(1)
	assert_eq(rig.pad_pan, Vector2(0.0, 1.0), "up is forward")
	PadEvents.right_stick(Vector2.ZERO)
	PadEvents.axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	_frames(1)
	assert_gt(rig.pad_orbit, 0.9, "RT orbits right")
	PadEvents.axis(JOY_AXIS_TRIGGER_RIGHT, 0.0)
	PadEvents.press(JOY_BUTTON_RIGHT_STICK)
	PadEvents.right_stick(Vector2(0.0, -1.0))
	_frames(1)
	assert_eq(rig.pad_pan, Vector2.ZERO, "R3 held: no pan")
	assert_gt(rig.pad_zoom, 0.9, "but a zoom in")
	PadEvents.right_stick(Vector2.ZERO)
	PadEvents.release(JOY_BUTTON_RIGHT_STICK)
	assert_ne(rig.focus, focus)


func test_the_cursor_pushed_into_an_edge_pans() -> void:
	_pad.place_cursor(Vector2(1279, 360))
	PadEvents.left_stick(Vector2(1.0, 0.0))
	_frames(1)
	assert_gt(_main._camera.pad_pan.x, 0.9)


func test_r3_tapped_centers_on_the_selection() -> void:
	_main._selection.selection.select(PackedInt32Array([_soldier.id]))
	PadEvents.tap(JOY_BUTTON_RIGHT_STICK)
	assert_true(_main._camera.is_gliding())


# --- A, X, B ------------------------------------------------------------------


func test_a_selects_what_is_under_the_cursor_and_nothing_clears() -> void:
	_pad.place_cursor(_main._selection.screen_point_of(_soldier.id))
	PadEvents.tap(JOY_BUTTON_A)
	assert_eq(_main._selection.selection.ids(), PackedInt32Array([_soldier.id]))
	_pad.place_cursor(Vector2(5, 5))
	_frames(30)  # not a double tap
	PadEvents.tap(JOY_BUTTON_A)
	assert_true(_main._selection.selection.is_empty())


func test_a_twice_selects_every_unit_of_the_type() -> void:
	_pad.place_cursor(_main._selection.screen_point_of(_soldier.id))
	PadEvents.tap(JOY_BUTTON_A)
	_frames(2)
	PadEvents.tap(JOY_BUTTON_A)
	assert_eq(_main._selection.selection.size(), 2, "both Shieldmen")


func test_a_held_and_moved_draws_a_box() -> void:
	var a: Vector2 = _main._selection.screen_point_of(_soldier.id)
	var b: Vector2 = _main._selection.screen_point_of(_second.id)
	var corner: Vector2 = Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2(40, 60)
	var far: Vector2 = Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2(40, 60)
	_pad.place_cursor(corner)
	PadEvents.press(JOY_BUTTON_A)
	_pad.place_cursor(far)
	_frames(1)
	PadEvents.release(JOY_BUTTON_A)
	assert_eq(_main._selection.selection.size(), 2)


func test_a_held_still_on_a_unit_adds_it() -> void:
	_main._selection.selection.select(PackedInt32Array([_second.id]))
	_pad.place_cursor(_main._selection.screen_point_of(_soldier.id))
	PadEvents.press(JOY_BUTTON_A)
	_frames(roundi(PadController.LONG_PRESS / FRAME) + 2)
	PadEvents.release(JOY_BUTTON_A)
	assert_eq(_main._selection.selection.size(), 2, "added, not replaced")


func test_x_orders_a_move_to_the_cursor() -> void:
	_main._selection.selection.select(PackedInt32Array([_soldier.id]))
	_pad.place_cursor(Vector2(900, 500))
	PadEvents.tap(JOY_BUTTON_X)
	_main._physics_process(1.0 / World.TICK_RATE)
	assert_eq(_soldier.order, Unit.Order.MOVE)


func test_x_held_and_moved_sets_the_facing() -> void:
	_main._selection.selection.select(PackedInt32Array([_soldier.id, _second.id]))
	_pad.place_cursor(Vector2(700, 420))
	PadEvents.press(JOY_BUTTON_X)
	_pad.place_cursor(Vector2(700, 340))
	_frames(1)
	PadEvents.release(JOY_BUTTON_X)
	_main._physics_process(1.0 / World.TICK_RATE)
	assert_eq(_soldier.order, Unit.Order.MOVE)
	var facing: Vector2 = Vector2(_soldier.order_facing_x, _soldier.order_facing_z).normalized()
	# Up the screen is away from the camera, along the ground.
	var ahead: Vector3 = -_main._camera.get_camera().global_transform.basis.z
	assert_gt(facing.dot(Vector2(ahead.x, ahead.z).normalized()), 0.8, "it faces up the screen")


func test_b_backs_out_one_step_at_a_time() -> void:
	_main._selection.selection.select(PackedInt32Array([_soldier.id]))
	_main._selection.arm(SelectionController.ArmedOrder.ATTACK_MOVE)
	PadEvents.tap(JOY_BUTTON_B)
	assert_eq(_main._selection.armed_order, SelectionController.ArmedOrder.NONE, "first the armed order")
	assert_false(_main._selection.selection.is_empty())
	assert_false(_main.pause_menu().is_open(), "B never pauses")
	PadEvents.tap(JOY_BUTTON_BACK)
	assert_true(_main._overhead_map.visible)
	PadEvents.tap(JOY_BUTTON_B)
	assert_false(_main._overhead_map.visible, "then the map")
	PadEvents.tap(JOY_BUTTON_B)
	assert_true(_main._selection.selection.is_empty(), "then the selection")


# --- wheels, groups, views ----------------------------------------------------


func test_lb_picks_a_formation_with_the_left_stick() -> void:
	PadEvents.press(JOY_BUTTON_LEFT_SHOULDER)
	assert_true(_pad.wheel.visible)
	PadEvents.left_stick(Vector2(1.0, 0.0))
	_frames(1)
	PadEvents.release(JOY_BUTTON_LEFT_SHOULDER)
	assert_false(_pad.wheel.visible)
	assert_eq(_main._selection.formation, RadialMenu.choice_for(Vector2(1, 0), Formations.Kind.size()) as Formations.Kind)


func test_lbs_right_stick_turns_the_formation() -> void:
	PadEvents.press(JOY_BUTTON_LEFT_SHOULDER)
	PadEvents.right_stick(Vector2(1.0, 0.0))
	_frames(1)
	PadEvents.right_stick(Vector2.ZERO)
	_frames(1)
	PadEvents.right_stick(Vector2(1.0, 0.0))
	_frames(1)
	PadEvents.right_stick(Vector2.ZERO)
	PadEvents.release(JOY_BUTTON_LEFT_SHOULDER)
	assert_eq(_main._selection.pending_rotation(), 2, "two flicks, two steps")


func test_rb_gives_an_order_from_the_wheel() -> void:
	_main._selection.selection.select(PackedInt32Array([_soldier.id]))
	PadEvents.press(JOY_BUTTON_RIGHT_SHOULDER)
	var guard: int = PadController.ORDER_WHEEL.find("Guard")
	var angle: float = guard * TAU / PadController.ORDER_WHEEL.size()
	PadEvents.left_stick(Vector2(sin(angle), -cos(angle)))
	_frames(1)
	PadEvents.release(JOY_BUTTON_RIGHT_SHOULDER)
	_main._physics_process(1.0 / World.TICK_RATE)
	assert_eq(_soldier.order, Unit.Order.GUARD)


func test_letting_go_of_the_wheel_pointing_nowhere_chooses_nothing() -> void:
	var before: Formations.Kind = _main._selection.formation
	PadEvents.tap(JOY_BUTTON_LEFT_SHOULDER)
	assert_eq(_main._selection.formation, before)


func test_the_d_pad_saves_recalls_and_clears_groups() -> void:
	_main._selection.selection.select(PackedInt32Array([_soldier.id]))
	PadEvents.tap(JOY_BUTTON_DPAD_RIGHT)
	assert_eq(_pad.group_slot(), 1)
	PadEvents.press(JOY_BUTTON_DPAD_UP)
	_frames(roundi(PadController.GROUP_HOLD / FRAME) + 2)
	PadEvents.release(JOY_BUTTON_DPAD_UP)
	assert_eq(_main._selection.selection.group(1), PackedInt32Array([_soldier.id]), "held up: saved")
	_main._selection.selection.clear()
	PadEvents.tap(JOY_BUTTON_DPAD_LEFT)
	PadEvents.tap(JOY_BUTTON_DPAD_RIGHT)
	assert_eq(_main._selection.selection.ids(), PackedInt32Array([_soldier.id]), "stepping onto it recalls it")
	PadEvents.press(JOY_BUTTON_DPAD_DOWN)
	_frames(roundi(PadController.GROUP_HOLD / FRAME) + 2)
	PadEvents.release(JOY_BUTTON_DPAD_DOWN)
	assert_true(_main._selection.selection.group(1).is_empty(), "held down: emptied")


func test_view_tapped_opens_the_map_and_held_shows_health() -> void:
	PadEvents.tap(JOY_BUTTON_BACK)
	assert_true(_main._overhead_map.visible)
	PadEvents.tap(JOY_BUTTON_BACK)
	assert_false(_main._overhead_map.visible)
	PadEvents.press(JOY_BUTTON_BACK)
	_frames(roundi(PadController.TAP / FRAME) + 2)
	assert_true(_main._units_view.show_all_health)
	PadEvents.release(JOY_BUTTON_BACK)
	assert_false(_main._units_view.show_all_health)
	assert_false(_main._overhead_map.visible, "a hold isn't a tap")


func test_on_the_map_x_sends_the_selection_and_a_moves_the_camera() -> void:
	_main._selection.selection.select(PackedInt32Array([_soldier.id]))
	PadEvents.tap(JOY_BUTTON_BACK)
	var target: Vector2 = _main._overhead_map._world_to_screen(Vector2(45.0, 10.0))
	_pad.place_cursor(target)
	PadEvents.tap(JOY_BUTTON_X)
	_main._physics_process(1.0 / World.TICK_RATE)
	assert_eq(_soldier.order, Unit.Order.MOVE)
	assert_almost_eq(_soldier.order_x, 45 * M, 1500)
	PadEvents.tap(JOY_BUTTON_A)
	assert_almost_eq(_main._camera.focus.x, 45.0, 1.5)


func test_l3_hands_the_pad_to_the_control_bar_and_b_takes_it_back() -> void:
	PadEvents.tap(JOY_BUTTON_LEFT_STICK)
	assert_true(_pad.has_bar_focus())
	var focused: Control = get_viewport().gui_get_focus_owner()
	assert_true(focused is Button and _main._control_bar.is_ancestor_of(focused), "a bar button has focus")
	PadEvents.tap(JOY_BUTTON_DPAD_RIGHT)
	assert_ne(get_viewport().gui_get_focus_owner(), focused, "the D-pad moves it")
	PadEvents.tap(JOY_BUTTON_B)
	assert_false(_pad.has_bar_focus())
	assert_null(get_viewport().gui_get_focus_owner(), "and no button keeps it")


func test_a_on_a_focused_bar_button_presses_it() -> void:
	PadEvents.tap(JOY_BUTTON_LEFT_STICK)
	var first: Button = get_viewport().gui_get_focus_owner() as Button
	assert_not_null(first)
	PadEvents.tap(JOY_BUTTON_A)
	assert_eq(_main._selection.formation, Formations.Kind.SHORT_LINE, "the first button is Short line")
	PadEvents.tap(JOY_BUTTON_DPAD_RIGHT)
	PadEvents.tap(JOY_BUTTON_A)
	assert_eq(_main._selection.formation, Formations.Kind.LONG_LINE, "the next one along")


func test_menu_pauses_and_b_resumes() -> void:
	PadEvents.tap(JOY_BUTTON_START)
	assert_true(_main.pause_menu().is_open())
	assert_true(_main.paused)
	PadEvents.tap(JOY_BUTTON_B)
	assert_false(_main.pause_menu().is_open())
	assert_false(_main.paused)


func test_y_uses_the_special() -> void:
	var sapper: Unit = _main.world.spawn_unit(_main.world.catalog.index_of(&"sapper"), LIGHT, 26 * M, 26 * M, 1, 0)
	_main._selection.selection.select(PackedInt32Array([sapper.id]))
	PadEvents.tap(JOY_BUTTON_Y)
	_main._physics_process(1.0 / World.TICK_RATE)
	assert_eq(sapper.special_left, sapper.type.special_charges - 1)


# Steps the pad's (and the camera's, the selection's, the sprites') frames.
func _frames(count: int) -> void:
	for i: int in count:
		_pad._process(FRAME)
		_main._camera._process(FRAME)
		_main._selection._process(FRAME)
		_main._units_view._process(FRAME)
