extends GutTest
## UnitInfoPanel: hidden with nothing selected; one unit gets its name, a
## health bar, and its details; several get the counts by type and a cell
## each (clicking one selects just it, shift-clicking drops it); it follows
## the World tick by tick.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT

var _catalog: UnitCatalog
var _world: World
var _controller: SelectionController
var _panel: UnitInfoPanel
var _units: Array[Unit] = []


func before_each() -> void:
	_catalog = TestTerrains.catalog()
	_world = World.new(1, TestTerrains.flat(40, 40), _catalog)
	_units.clear()
	for i: int in 3:
		_units.append(_world.spawn_unit(_catalog.index_of(&"shieldman"), LIGHT, (10 + i * 2) * M, 10 * M, 1, 0))
	_units.append(_world.spawn_unit(_catalog.index_of(&"warden"), LIGHT, 20 * M, 10 * M, 1, 0))
	_controller = SelectionController.new()
	add_child_autofree(_controller)
	_panel = UnitInfoPanel.new()
	add_child_autofree(_panel)
	_panel.setup(_controller, _world)


func test_hidden_with_nothing_selected() -> void:
	assert_false(_panel.visible)


func test_one_unit_shows_its_details() -> void:
	_units[3].hp = 40
	_controller.selection.select(PackedInt32Array([_units[3].id]))
	assert_true(_panel.visible)
	assert_eq(_panel.title_text(), "Warden (Light)")
	assert_true(_panel.detail_text().begins_with("HP 40/85 · Idle"), _panel.detail_text())
	assert_true(_panel.detail_text().ends_with("Herbs: 6/6"))
	assert_eq(_panel.cell_count(), 0)


func test_several_show_counts_and_cells() -> void:
	var ids: PackedInt32Array = PackedInt32Array()
	for unit: Unit in _units:
		ids.append(unit.id)
	_controller.selection.select(ids)
	assert_eq(_panel.title_text(), "4 selected")
	assert_eq(_panel.detail_text(), "3 Shieldman, 1 Warden")
	assert_eq(_panel.cell_count(), 4)
	assert_eq(_panel.cell_unit(3), _units[3].id)


func test_a_cell_selects_just_its_unit_and_shift_drops_it() -> void:
	var ids: PackedInt32Array = PackedInt32Array()
	for unit: Unit in _units:
		ids.append(unit.id)
	_controller.selection.select(ids)
	_panel.press_cell(1, true)
	assert_eq(_controller.selection.size(), 3)
	assert_false(_controller.selection.is_selected(_units[1].id))
	_panel.press_cell(0, false)
	assert_eq(_controller.selection.ids(), PackedInt32Array([_units[0].id]))
	assert_eq(_panel.title_text(), "Shieldman (Light)")


func test_it_follows_the_world() -> void:
	_controller.selection.select(PackedInt32Array([_units[0].id]))
	_world.enqueue(ApplyStatusCommand.new(0, PackedInt32Array([_units[0].id]), StatusEffects.Kind.CONFUSION, 60))
	_world.step()
	_panel.refresh()
	# 60 ticks from tick 0; one has gone: 59 left.
	assert_true(_panel.detail_text().contains("Confused 2.0 s"), _panel.detail_text())


func test_type_counts_keep_first_appearance_order() -> void:
	var warden: Unit = _units[3]
	assert_eq(UnitInfoPanel.type_counts([warden, _units[0], _units[1]]), "1 Warden, 2 Shieldman")
