extends GutTest
## Orders armed from the control bar: with Move or Attack-move armed, the next
## left click on the ground gives that order instead of selecting, then the
## arm clears. Right click and Esc cancel without ordering, and nothing can
## be armed with nothing selected. Clicks go through the real input handler
## with a camera looking straight down at a flat map, so the screen center is
## the ground point (20 m, 20 m).

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT

var _world: World
var _controller: SelectionController
var _unit: Unit
var _armed: Array[SelectionController.ArmedOrder] = []


func before_each() -> void:
	InputBindings.install()
	var catalog: UnitCatalog = TestTerrains.catalog()
	_world = World.new(1, TestTerrains.flat(40, 40), catalog)
	_unit = _world.spawn_unit(catalog.index_of(&"shieldman"), LIGHT, 10 * M, 20 * M, 1, 0)
	var camera: Camera3D = Camera3D.new()
	add_child_autofree(camera)
	camera.position = Vector3(20.0, 30.0, 20.0)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.make_current()
	var units: UnitsView = UnitsView.new()
	add_child_autofree(units)
	_controller = SelectionController.new()
	add_child_autofree(_controller)
	units.setup(_world, _controller.selection, null)
	_controller.setup(_world, units, camera, TerrainPicker.new(_world.terrain))
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


# Presses a mouse button at the screen center, straight into the handler.
func _click(button_index: MouseButton) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button_index
	event.pressed = true
	event.position = _controller.get_viewport().get_visible_rect().size * 0.5
	_controller._unhandled_input(event)
