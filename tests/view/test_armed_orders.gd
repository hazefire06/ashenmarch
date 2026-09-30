extends GutTest
## Orders armed from the control bar: with Move, Attack-move or Ground attack
## armed, the next left click on the ground gives that order instead of
## selecting, then the arm clears. Right click and Esc cancel without ordering,
## and nothing can be armed with nothing selected. Also the direct inputs:
## Cmd/Ctrl + left click orders a ground attack without selecting anything, and
## T uses the selection's special. Clicks go through the real input handler
## with a camera looking straight down at a flat map, so the screen center is
## the ground point (20 m, 20 m).

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT

var _world: World
var _controller: SelectionController
var _unit: Unit
var _archer: Unit
var _sapper: Unit
var _camera: Camera3D
var _armed: Array[SelectionController.ArmedOrder] = []


func before_each() -> void:
	InputBindings.install()
	var catalog: UnitCatalog = TestTerrains.catalog()
	_world = World.new(1, TestTerrains.flat(40, 40), catalog)
	_unit = _world.spawn_unit(catalog.index_of(&"shieldman"), LIGHT, 10 * M, 20 * M, 1, 0)
	# Off the Shieldman's way, so nothing in these tests blocks its path.
	_archer = _world.spawn_unit(catalog.index_of(&"longbow"), LIGHT, 12 * M, 30 * M, 1, 0)
	_sapper = _world.spawn_unit(catalog.index_of(&"sapper"), LIGHT, 14 * M, 30 * M, 1, 0)
	_camera = Camera3D.new()
	add_child_autofree(_camera)
	_camera.position = Vector3(20.0, 30.0, 20.0)
	_camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_camera.make_current()
	var units: UnitsView = UnitsView.new()
	add_child_autofree(units)
	_controller = SelectionController.new()
	add_child_autofree(_controller)
	units.setup(_world, _controller.selection, null)
	_controller.setup(_world, units, _camera, TerrainPicker.new(_world.terrain))
	_armed.clear()
	_controller.armed_order_changed.connect(func(order: SelectionController.ArmedOrder) -> void:
		_armed.append(order))


func after_each() -> void:
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)


func test_armed_move_is_placed_by_a_left_click() -> void:
	_controller.selection.select(PackedInt32Array([_unit.id]))
	_controller.arm(SelectionController.ArmedOrder.MOVE)
	_click(MOUSE_BUTTON_LEFT)
	_world.step()
	assert_eq(_unit.order, Unit.Order.MOVE)
	assert_almost_eq(_unit.order_x, 20 * M, 300)
	assert_almost_eq(_unit.order_z, 20 * M, 300)
	assert_eq(_controller.armed_order, SelectionController.ArmedOrder.NONE, "one shot")
	assert_true(_controller.selection.is_selected(_unit.id), "the click didn't deselect")
	assert_eq(_armed, [SelectionController.ArmedOrder.MOVE, SelectionController.ArmedOrder.NONE])


func test_armed_attack_move_is_placed_by_a_left_click() -> void:
	_controller.selection.select(PackedInt32Array([_unit.id]))
	_controller.arm(SelectionController.ArmedOrder.ATTACK_MOVE)
	_click(MOUSE_BUTTON_LEFT)
	_world.step()
	assert_eq(_unit.order, Unit.Order.ATTACK_MOVE)
	assert_eq(_controller.armed_order, SelectionController.ArmedOrder.NONE)


func test_right_click_cancels_without_ordering() -> void:
	_controller.selection.select(PackedInt32Array([_unit.id]))
	_controller.arm(SelectionController.ArmedOrder.ATTACK_MOVE)
	_click(MOUSE_BUTTON_RIGHT)
	_world.step()
	assert_eq(_unit.order, Unit.Order.NONE, "no order given")
	assert_eq(_controller.armed_order, SelectionController.ArmedOrder.NONE)


func test_esc_cancels() -> void:
	_controller.selection.select(PackedInt32Array([_unit.id]))
	_controller.arm(SelectionController.ArmedOrder.MOVE)
	var esc: InputEventKey = InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	_controller._unhandled_input(esc)
	assert_eq(_controller.armed_order, SelectionController.ArmedOrder.NONE)


func test_nothing_arms_without_a_selection() -> void:
	_controller.arm(SelectionController.ArmedOrder.MOVE)
	assert_eq(_controller.armed_order, SelectionController.ArmedOrder.NONE)
	assert_eq(_armed, [SelectionController.ArmedOrder.NONE], "still signals, so the bar button pops up")


func test_losing_the_selection_disarms() -> void:
	_controller.selection.select(PackedInt32Array([_unit.id]))
	_controller.arm(SelectionController.ArmedOrder.MOVE)
	_controller.selection.clear()
	assert_eq(_controller.armed_order, SelectionController.ArmedOrder.NONE)


func test_plain_right_click_still_moves_when_nothing_is_armed() -> void:
	_controller.selection.select(PackedInt32Array([_unit.id]))
	_click(MOUSE_BUTTON_RIGHT)
	_world.step()
	assert_eq(_unit.order, Unit.Order.MOVE)


func test_armed_ground_attack_is_placed_by_a_left_click() -> void:
	_controller.selection.select(PackedInt32Array([_archer.id]))
	_controller.arm(SelectionController.ArmedOrder.GROUND_ATTACK)
	_click(MOUSE_BUTTON_LEFT)
	_world.step()
	assert_eq(_archer.order, Unit.Order.GROUND_ATTACK)
	assert_almost_eq(_archer.ground_x, 20 * M, 300)
	assert_almost_eq(_archer.ground_z, 20 * M, 300)
	assert_eq(_controller.armed_order, SelectionController.ArmedOrder.NONE, "one shot")
	assert_true(_controller.selection.is_selected(_archer.id), "the click didn't deselect")
	assert_eq(_armed, [SelectionController.ArmedOrder.GROUND_ATTACK, SelectionController.ArmedOrder.NONE])


func test_right_click_cancels_an_armed_ground_attack() -> void:
	_controller.selection.select(PackedInt32Array([_archer.id]))
	_controller.arm(SelectionController.ArmedOrder.GROUND_ATTACK)
	_click(MOUSE_BUTTON_RIGHT)
	_world.step()
	assert_eq(_archer.order, Unit.Order.NONE, "no order given")
	assert_eq(_controller.armed_order, SelectionController.ArmedOrder.NONE)


func test_esc_cancels_an_armed_ground_attack() -> void:
	_controller.selection.select(PackedInt32Array([_archer.id]))
	_controller.arm(SelectionController.ArmedOrder.GROUND_ATTACK)
	var esc: InputEventKey = InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	_controller._unhandled_input(esc)
	assert_eq(_controller.armed_order, SelectionController.ArmedOrder.NONE)


func test_losing_the_selection_disarms_a_ground_attack() -> void:
	_controller.selection.select(PackedInt32Array([_archer.id]))
	_controller.arm(SelectionController.ArmedOrder.GROUND_ATTACK)
	_controller.selection.clear()
	assert_eq(_controller.armed_order, SelectionController.ArmedOrder.NONE)


func test_ground_attack_does_not_arm_without_a_selection() -> void:
	_controller.arm(SelectionController.ArmedOrder.GROUND_ATTACK)
	assert_eq(_controller.armed_order, SelectionController.ArmedOrder.NONE)
	assert_eq(_armed, [SelectionController.ArmedOrder.NONE], "still signals, so the bar button pops up")


func test_arming_another_order_replaces_the_armed_one() -> void:
	_controller.selection.select(PackedInt32Array([_archer.id]))
	_controller.arm(SelectionController.ArmedOrder.ATTACK_MOVE)
	_controller.arm(SelectionController.ArmedOrder.GROUND_ATTACK)
	_click(MOUSE_BUTTON_LEFT)
	_world.step()
	assert_eq(_archer.order, Unit.Order.GROUND_ATTACK, "the later arm won")


func test_modified_left_click_orders_a_ground_attack_and_does_not_select() -> void:
	_controller.selection.select(PackedInt32Array([_archer.id]))
	# Over the Shieldman, which a plain click would select in place of the archer.
	var over_shieldman: Vector2 = _camera.unproject_position(Vector3(10.0, 0.0, 20.0))
	_click(MOUSE_BUTTON_LEFT, over_shieldman, true)
	_release(over_shieldman)
	_world.step()
	assert_eq(_archer.order, Unit.Order.GROUND_ATTACK)
	assert_almost_eq(_archer.ground_x, 10 * M, 300, "the ground under the cursor")
	assert_almost_eq(_archer.ground_z, 20 * M, 300)
	assert_true(_controller.selection.is_selected(_archer.id), "the selection is untouched")
	assert_false(_controller.selection.is_selected(_unit.id), "the Shieldman wasn't picked")
	assert_eq(_unit.order, Unit.Order.NONE)


func test_modified_left_click_enqueues_a_ground_attack_command() -> void:
	# The command reaches the World: a ground attack only affects units with a
	# ranged attack, so the Shieldman in the selection holds still.
	_controller.selection.select(PackedInt32Array([_unit.id, _archer.id, _sapper.id]))
	_click(MOUSE_BUTTON_LEFT, Vector2.INF, true)
	_world.step()
	assert_eq(_archer.order, Unit.Order.GROUND_ATTACK)
	assert_eq(_sapper.order, Unit.Order.GROUND_ATTACK)
	assert_eq(_unit.order, Unit.Order.NONE, "a melee unit ignores it")
	assert_eq(_controller.selection.size(), 3)


func test_modified_left_click_with_nothing_selected_does_nothing() -> void:
	var over_shieldman: Vector2 = _camera.unproject_position(Vector3(10.0, 0.0, 20.0))
	_click(MOUSE_BUTTON_LEFT, over_shieldman, true)
	_release(over_shieldman)
	assert_true(_controller.selection.is_empty(), "no selecting either")


func test_modified_left_click_disarms_an_armed_order() -> void:
	_controller.selection.select(PackedInt32Array([_archer.id]))
	_controller.arm(SelectionController.ArmedOrder.MOVE)
	_click(MOUSE_BUTTON_LEFT, Vector2.INF, true)
	_world.step()
	assert_eq(_archer.order, Unit.Order.GROUND_ATTACK)
	assert_eq(_controller.armed_order, SelectionController.ArmedOrder.NONE)


func test_plain_left_click_still_selects() -> void:
	await wait_process_frames(2)  # the sprites move to their units in _process
	var over_shieldman: Vector2 = _camera.unproject_position(Vector3(10.0, 0.0, 20.0))
	_click(MOUSE_BUTTON_LEFT, over_shieldman)
	_release(over_shieldman)
	assert_true(_controller.selection.is_selected(_unit.id))
	assert_eq(_controller.selection.size(), 1)


func test_shift_left_click_still_adds_to_the_selection() -> void:
	await wait_process_frames(2)
	_controller.selection.select(PackedInt32Array([_archer.id]))
	var over_shieldman: Vector2 = _camera.unproject_position(Vector3(10.0, 0.0, 20.0))
	_click(MOUSE_BUTTON_LEFT, over_shieldman, false, true)
	_release(over_shieldman, true)
	assert_eq(_controller.selection.size(), 2)
	assert_true(_controller.selection.is_selected(_unit.id))


func test_t_uses_the_special_of_the_selection() -> void:
	_controller.selection.select(PackedInt32Array([_sapper.id, _archer.id]))
	_press_key(KEY_T)
	_world.step()
	assert_eq(_sapper.special_left, _sapper.type.special_charges - 1, "the Sapper spent a charge")
	assert_eq(_world.projectiles.size(), 1, "and dropped it")
	assert_true(_archer.fire_nocked, "the Longbow nocked its fire arrow")


func test_t_does_nothing_with_nothing_selected() -> void:
	_press_key(KEY_T)
	_world.step()
	assert_eq(_world.projectiles.size(), 0)
	assert_false(_archer.fire_nocked)


func test_held_t_uses_the_special_once() -> void:
	_controller.selection.select(PackedInt32Array([_sapper.id]))
	_press_key(KEY_T)
	_press_key(KEY_T, true)
	_press_key(KEY_T, true)
	_world.step()
	assert_eq(_world.projectiles.size(), 1, "key repeat isn't another press")


func test_modified_t_is_not_t() -> void:
	_controller.selection.select(PackedInt32Array([_sapper.id]))
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = KEY_T
	event.pressed = true
	_add_command_modifier(event)
	_controller._unhandled_input(event)
	_world.step()
	assert_eq(_world.projectiles.size(), 0)


func test_ability_button_path_uses_the_special() -> void:
	_controller.selection.select(PackedInt32Array([_sapper.id]))
	_controller.use_special_selected()
	_world.step()
	assert_eq(_world.projectiles.size(), 1)


# Presses a mouse button, straight into the handler: at the screen center
# unless `at` says otherwise (Vector2.INF also means the center), with
# Cmd/Ctrl or Shift held if asked.
func _click(
	button_index: MouseButton, at: Vector2 = Vector2.INF, command: bool = false, shift: bool = false
) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button_index
	event.pressed = true
	event.position = _controller.get_viewport().get_visible_rect().size * 0.5 if at == Vector2.INF else at
	event.shift_pressed = shift
	if command:
		_add_command_modifier(event)
	_controller._unhandled_input(event)


# Releases the left button where it was pressed. The controller reads
# releases in _input, before the GUI.
func _release(at: Vector2, shift: bool = false) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = at
	event.shift_pressed = shift
	_controller._input(event)


func _press_key(keycode: Key, echo: bool = false) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = keycode
	event.pressed = true
	event.echo = echo
	_controller._unhandled_input(event)


# Cmd on macOS, Ctrl elsewhere: what the bindings' command_or_control_autoremap
# means.
func _add_command_modifier(event: InputEventWithModifiers) -> void:
	if OS.get_name() == "macOS":
		event.meta_pressed = true
	else:
		event.ctrl_pressed = true
