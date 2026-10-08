class_name UnitInfoPanel
extends PanelContainer
## The selection at a glance, docked above the left end of the control bar,
## hidden when nothing is selected.
## - One unit: its name and side, a health bar, and the rest of what
##   UnitInfo says about it (activity, kills, veterancy, status effects with
##   the time they have left, ammunition, special, what it carries).
## - Several: how many of each type, and a cell per unit (up to MAX_CELLS)
##   in its type's color, with a health bar and a frame tinted by any status
##   effect. Click a cell to select just that unit; shift-click to drop it
##   from the selection.
## Refreshed when the tick or the selection changes. Reads the World; only
## changes the (view-side) selection.

const MAX_CELLS: int = 24
const COLUMNS: int = 8
const CELL_SIZE: Vector2 = Vector2(46.0, 46.0)
const MARGIN: float = 8.0
const MIN_WIDTH: float = 300.0
const HP_BAR_HEIGHT: float = 6.0
const STATUS_FRAME_WIDTH: int = 3
const PARALYZED_FRAME: Color = Color(0.6, 0.8, 1.0)
const CONFUSED_FRAME: Color = Color(1.0, 0.35, 0.9)
const BURNING_FRAME: Color = Color(1.0, 0.5, 0.1)

var _controller: SelectionController
var _world: World
var _bar: Control
var _title: Label
var _hp_bar: ProgressBar
var _details: Label
var _grid: GridContainer
var _more: Label
var _shown_ids: PackedInt32Array = PackedInt32Array()
var _shown_tick: int = -1
var _cell_ids: PackedInt32Array = PackedInt32Array()
var _focusable: bool = false


## bar is the control bar the panel sits above; null docks it at the bottom.
func setup(controller: SelectionController, world: World, bar: Control = null) -> void:
	_controller = controller
	_world = world
	_bar = bar
	_build()
	_controller.selection.changed.connect(refresh)
	refresh()


func _process(_delta: float) -> void:
	if _controller == null:
		return
	if _world.tick != _shown_tick:
		refresh()
	_dock()


## Lets the cells take focus while the pad's control-bar mode is on
## (HudFocus); new cells follow.
func set_focus_enabled(on: bool) -> void:
	_focusable = on
	HudFocus.enable(self, on)


## Rebuilds the panel from the selection and the World as they are now.
func refresh() -> void:
	_shown_tick = _world.tick
	var units: Array[Unit] = _selected_units()
	visible = not units.is_empty()
	if units.is_empty():
		_shown_ids = PackedInt32Array()
		return
	if units.size() == 1:
		_show_one(units[0])
	else:
		_show_many(units)


## The title line: a unit's name and side, or how many are selected.
func title_text() -> String:
	return _title.text


## Everything below the title as text: one unit's details, or the counts.
func detail_text() -> String:
	return _details.text


## Cells shown for a multiple selection (0 for one unit).
func cell_count() -> int:
	return _cell_ids.size() if _grid.visible else 0


## The unit id behind cell index.
func cell_unit(index: int) -> int:
	return _cell_ids[index]


## What a click on cell index does: select just its unit, or with shift drop
## it from the selection.
func press_cell(index: int, shift: bool) -> void:
	var unit_id: int = _cell_ids[index]
	if shift:
		_controller.selection.toggle(unit_id)
	else:
		_controller.selection.select(PackedInt32Array([unit_id]))


## "8 Shieldman, 4 Longbow": the selected units by type, in order of first
## appearance.
static func type_counts(units: Array[Unit]) -> String:
	var counts: Dictionary[String, int] = {}
	for unit: Unit in units:
		counts[unit.type.display_name] = counts.get(unit.type.display_name, 0) + 1
	var parts: PackedStringArray = PackedStringArray()
	for type_name: String in counts:
		parts.append("%d %s" % [counts[type_name], type_name])
	return ", ".join(parts)


func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size.x = MIN_WIDTH
	var rows: VBoxContainer = VBoxContainer.new()
	add_child(rows)
	_title = Label.new()
	rows.add_child(_title)
	_hp_bar = ProgressBar.new()
	_hp_bar.show_percentage = false
	_hp_bar.custom_minimum_size.y = 10.0
	_hp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_child(_hp_bar)
	_details = Label.new()
	rows.add_child(_details)
	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	rows.add_child(_grid)
	_more = Label.new()
	rows.add_child(_more)


func _show_one(unit: Unit) -> void:
	var lines: PackedStringArray = UnitInfo.lines(unit, _world.catalog, _world)
	_title.text = lines[0]
	lines.remove_at(0)
	_details.text = "\n".join(lines)
	_hp_bar.visible = true
	_hp_bar.max_value = unit.type.max_hp
	_hp_bar.value = unit.hp
	_grid.visible = false
	_more.visible = false
	_cell_ids = PackedInt32Array()
	_shown_ids = PackedInt32Array([unit.id])
	reset_size()


func _show_many(units: Array[Unit]) -> void:
	_title.text = "%d selected" % units.size()
	_details.text = type_counts(units)
	_hp_bar.visible = false
	_grid.visible = true
	var ids: PackedInt32Array = PackedInt32Array()
	for unit: Unit in units:
		ids.append(unit.id)
	if ids != _shown_ids:
		_shown_ids = ids
		_rebuild_cells(units)
	for i: int in _cell_ids.size():
		_update_cell(_grid.get_child(i) as Button, _world.get_unit(_cell_ids[i]))
	var hidden: int = units.size() - _cell_ids.size()
	_more.visible = hidden > 0
	_more.text = "and %d more" % hidden
	reset_size()


func _rebuild_cells(units: Array[Unit]) -> void:
	for child: Node in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	_cell_ids = PackedInt32Array()
	for unit: Unit in units.slice(0, MAX_CELLS):
		var cell: Button = Button.new()
		cell.custom_minimum_size = CELL_SIZE
		cell.focus_mode = Control.FOCUS_ALL if _focusable else Control.FOCUS_NONE
		cell.text = unit.type.display_name.substr(0, 2)
		var index: int = _cell_ids.size()
		cell.pressed.connect(func() -> void: press_cell(index, Input.is_key_pressed(KEY_SHIFT)))
		var bar: ProgressBar = ProgressBar.new()
		bar.name = "Hp"
		bar.show_percentage = false
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		bar.offset_top = -HP_BAR_HEIGHT
		cell.add_child(bar)
		_grid.add_child(cell)
		_cell_ids.append(unit.id)


# The cell's color, frame, health, and tooltip follow its unit.
func _update_cell(cell: Button, unit: Unit) -> void:
	if unit == null:
		return
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = unit.type.placeholder_color.darkened(0.35)
	var frame: Color = _status_frame(unit)
	if frame.a > 0.0:
		style.border_color = frame
		style.set_border_width_all(STATUS_FRAME_WIDTH)
	cell.add_theme_stylebox_override("normal", style)
	var bar: ProgressBar = cell.get_node("Hp") as ProgressBar
	bar.max_value = unit.type.max_hp
	bar.value = unit.hp
	cell.tooltip_text = "%s\nHP %d/%d" % [UnitInfo.header_of(unit), unit.hp, unit.type.max_hp]
	var statuses: String = UnitInfo.status_line(unit, _world)
	if not statuses.is_empty():
		cell.tooltip_text += "\n" + statuses


func _status_frame(unit: Unit) -> Color:
	if StatusEffects.paralyzed(_world, unit):
		return PARALYZED_FRAME
	if StatusEffects.confused(_world, unit):
		return CONFUSED_FRAME
	if StatusEffects.has(_world, unit, StatusEffects.Kind.BURNING):
		return BURNING_FRAME
	return Color.TRANSPARENT


func _selected_units() -> Array[Unit]:
	var units: Array[Unit] = []
	for unit_id: int in _controller.selection.ids():
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and unit.is_alive():
			units.append(unit)
	return units


# Bottom left, just above the control bar.
func _dock() -> void:
	var bottom: float = get_viewport_rect().size.y
	if _bar != null and _bar.visible:
		bottom = _bar.global_position.y
	position = Vector2(MARGIN, bottom - size.y - MARGIN)
