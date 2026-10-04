extends GutTest
## The player commands only the units the AI doesn't drive. A Light unit a
## mission spawned (the Ford's villager, led by an ESCORT group) is Light and
## alive but is never selectable by click, box, or double-click, and the
## control bar's Light count leaves it out, since it isn't the player's to lose.
## Clicks go through the real input handler with a camera looking straight down
## at a flat map, so screen positions follow world positions.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT

var _world: World
var _controller: SelectionController
var _camera: Camera3D
var _commanded: Unit
var _led: Unit


func before_each() -> void:
	InputBindings.install()
	var catalog: UnitCatalog = TestTerrains.catalog()
	_world = World.new(1, TestTerrains.flat(40, 40), catalog)
	_commanded = _world.spawn_unit(catalog.index_of(&"shieldman"), LIGHT, 10 * M, 20 * M, 1, 0)
	# A Light group the AI leads: a villager standing off to the side.
	var entry: AiUnitEntry = AiUnitEntry.new()
	entry.type_id = &"villager"
	entry.counts = PackedInt32Array([1])
	var spec: AiGroupSpec = AiGroupSpec.new()
	spec.name = &"villager"
	spec.faction = LIGHT
	spec.units = [entry]
	spec.spawns = PackedInt32Array([20 * M, 20 * M])
	var group: AiGroup = _world.ai.spawn_group(_world, spec, 0, 0)
	_led = group.living(_world)[0]
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


func _screen_of(unit: Unit) -> Vector2:
	return _camera.unproject_position(Vector3(unit.x, 0.0, unit.z) / float(M))


func _click(at: Vector2, is_double: bool = false) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = at
	event.double_click = is_double
	_controller._unhandled_input(event)
	var release: InputEventMouseButton = InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = at
	_controller._input(release)


func test_the_harness_sees_both_units() -> void:
	assert_true(_world.ai.controls(_led.id))
	assert_false(_world.ai.controls(_commanded.id))
	assert_eq(_led.faction, LIGHT)
	assert_true(_led.is_alive())


func test_a_click_picks_the_commanded_unit() -> void:
	await wait_process_frames(2)  # the sprites move to their units in _process
	_click(_screen_of(_commanded))
	assert_true(_controller.selection.is_selected(_commanded.id))


func test_a_click_on_an_ai_led_light_unit_selects_nothing() -> void:
	await wait_process_frames(2)
	_click(_screen_of(_led))
	assert_true(_controller.selection.is_empty(), "the villager is led, not commanded")


func test_a_box_around_both_takes_only_the_commanded_one() -> void:
	await wait_process_frames(2)
	var from: Vector2 = Vector2.ZERO
	var to: Vector2 = get_viewport().get_visible_rect().size
	var press: InputEventMouseButton = InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = from
	_controller._unhandled_input(press)
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = to
	_controller._input(motion)
	var release: InputEventMouseButton = InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = to
	_controller._input(release)
	assert_eq(_controller.selection.ids(), PackedInt32Array([_commanded.id]))


func test_double_clicking_a_type_skips_the_ai_led_ones() -> void:
	# Same type on both: a shieldman the AI leads, beside the commanded one.
	var catalog: UnitCatalog = _world.catalog
	var entry: AiUnitEntry = AiUnitEntry.new()
	entry.type_id = &"shieldman"
	entry.counts = PackedInt32Array([1])
	var spec: AiGroupSpec = AiGroupSpec.new()
	spec.name = &"shields"
	spec.faction = LIGHT
	spec.units = [entry]
	spec.spawns = PackedInt32Array([30 * M, 20 * M])
	var led_shieldman: Unit = _world.ai.spawn_group(_world, spec, 1, 0).living(_world)[0]
	assert_eq(led_shieldman.type_index, catalog.index_of(&"shieldman"))
	await wait_process_frames(2)
	_click(_screen_of(_commanded), true)
	assert_true(_controller.selection.is_selected(_commanded.id))
	assert_false(_controller.selection.is_selected(led_shieldman.id), "same type, but the AI's")


func test_the_bar_counts_only_the_commanded_light_units() -> void:
	var bar: ControlBar = ControlBar.new()
	add_child_autofree(bar)
	bar.setup(_controller, _world)
	bar._process(0.0)
	assert_string_contains(bar.status_text(), "Light 1 ")
	_world.spawn_unit(_world.catalog.index_of(&"shieldman"), LIGHT, 12 * M, 20 * M, 1, 0)
	bar._process(0.0)
	assert_string_contains(bar.status_text(), "Light 1 ", "same tick: not recounted yet")
	_world.step()
	bar._process(0.0)
	assert_string_contains(bar.status_text(), "Light 2 ", "the villager still isn't counted")
