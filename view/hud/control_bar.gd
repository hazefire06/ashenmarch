class_name ControlBar
extends PanelContainer
## Bottom bar mirroring the keyboard controls so the game is playable with the
## mouse alone. Three rows: formation buttons (1..0); control groups (click to
## recall; toggle Set, then click a slot to save) beside a status line (the
## selection, how many units are alive on each side, the side being
## controlled); and the orders: Stop, Move, Attack-move and Ground attack (each
## arms that order for the next left click on the ground, once), Ability (the
## selection's special), and Switch side. All actions go through the
## SelectionController, so keys and buttons can't drift apart.

const GROUP_LABELS: Array[String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

var _controller: SelectionController
var _world: World
var _formation_buttons: Array[Button] = []
var _group_buttons: Array[Button] = []
var _set_toggle: Button
var _move_toggle: Button
var _attack_move_toggle: Button
var _ground_attack_toggle: Button
var _status: Label
## Living units per side, recounted when the tick changes.
var _light_alive: int = 0
var _dark_alive: int = 0
var _counted_tick: int = -1


func setup(controller: SelectionController, world: World) -> void:
	_controller = controller
	_world = world
	_build()
	_controller.formation_changed.connect(_on_formation_changed)
	_on_formation_changed(_controller.formation)
	_controller.armed_order_changed.connect(_on_armed_order_changed)
	_on_armed_order_changed(_controller.armed_order)


func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var rows: VBoxContainer = VBoxContainer.new()
	add_child(rows)

	var formations: HBoxContainer = HBoxContainer.new()
	formations.add_child(_caption("Formation"))
	var group: ButtonGroup = ButtonGroup.new()
	for kind: int in Formations.Kind.size():
		var b: Button = _button("%s %s" % [GROUP_LABELS[kind], Formations.DISPLAY_NAMES[kind]])
		b.toggle_mode = true
		b.button_group = group
		b.tooltip_text = "Formation for the next move order (key %s)" % GROUP_LABELS[kind]
		b.pressed.connect(_controller.set_formation.bind(kind))
		formations.add_child(b)
		_formation_buttons.append(b)
	rows.add_child(formations)

	var groups: HBoxContainer = HBoxContainer.new()
	groups.add_child(_caption("Groups"))
	for slot: int in UnitSelection.GROUP_COUNT:
		var b: Button = _button(GROUP_LABELS[slot])
		b.custom_minimum_size.x = 34.0
		b.tooltip_text = "Recall group %s (Opt/Alt+%s); save with Set or Cmd/Ctrl+%s" % [
			GROUP_LABELS[slot], GROUP_LABELS[slot], GROUP_LABELS[slot]
		]
		b.pressed.connect(_on_group_pressed.bind(slot))
		groups.add_child(b)
		_group_buttons.append(b)
	_set_toggle = _button("Set")
	_set_toggle.toggle_mode = true
	_set_toggle.tooltip_text = "Then click a group slot to save the selection there"
	groups.add_child(_set_toggle)
	groups.add_child(VSeparator.new())
	_status = Label.new()
	groups.add_child(_status)
	rows.add_child(groups)

	var orders: HBoxContainer = HBoxContainer.new()
	orders.add_child(_caption("Orders"))
	var stop: Button = _button("Stop")
	stop.tooltip_text = "Halt the selection (H)"
	stop.pressed.connect(_controller.stop_selected)
	orders.add_child(stop)
	_move_toggle = _arm_button(
		"Move", SelectionController.ArmedOrder.MOVE,
		"Then left-click the ground to move there (or just right-click)"
	)
	orders.add_child(_move_toggle)
	_attack_move_toggle = _arm_button(
		"Attack-move", SelectionController.ArmedOrder.ATTACK_MOVE,
		"Then left-click the ground to attack-move there (or Cmd/Ctrl + right-click)"
	)
	orders.add_child(_attack_move_toggle)
	_ground_attack_toggle = _arm_button(
		"Ground attack", SelectionController.ArmedOrder.GROUND_ATTACK,
		"Then left-click the ground to bombard it with the selected archers and grenadiers (or Cmd/Ctrl + left-click)"
	)
	orders.add_child(_ground_attack_toggle)
	var ability: Button = _button("Ability (T)")
	ability.tooltip_text = "Use the selection's special: a Sapper drops a satchel charge, a Longbow nocks its fire arrow (T)"
	ability.pressed.connect(_controller.use_special_selected)
	orders.add_child(ability)
	var side: Button = _button("Switch side")
	side.tooltip_text = "Debug: command the other side (F9)"
	side.pressed.connect(_controller.switch_side)
	orders.add_child(side)
	rows.add_child(orders)

	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE, Control.PRESET_MODE_MINSIZE)
	grow_vertical = Control.GROW_DIRECTION_BEGIN


func _process(_delta: float) -> void:
	if _controller == null:
		return
	var selection: UnitSelection = _controller.selection
	for slot: int in _group_buttons.size():
		var count: int = selection.group(slot).size()
		_group_buttons[slot].text = GROUP_LABELS[slot] if count == 0 else "%s·%d" % [GROUP_LABELS[slot], count]
	_recount_alive()
	_status.text = "%s   |   Light %d · Dark %d alive   |   Controlling: %s" % [
		_selection_summary(selection),
		_light_alive,
		_dark_alive,
		"Light" if _controller.side == UnitType.Faction.LIGHT else "Dark (debug)",
	]


func _on_group_pressed(slot: int) -> void:
	if _set_toggle.button_pressed:
		_controller.save_group(slot)
		_set_toggle.button_pressed = false
	else:
		_controller.recall_group(slot)


func _on_formation_changed(kind: Formations.Kind) -> void:
	_formation_buttons[kind].set_pressed_no_signal(true)


func _on_armed_order_changed(order: SelectionController.ArmedOrder) -> void:
	_move_toggle.set_pressed_no_signal(order == SelectionController.ArmedOrder.MOVE)
	_attack_move_toggle.set_pressed_no_signal(order == SelectionController.ArmedOrder.ATTACK_MOVE)
	_ground_attack_toggle.set_pressed_no_signal(order == SelectionController.ArmedOrder.GROUND_ATTACK)


# A toggle that arms order while pressed. Pressing it again disarms. The
# controller's signal keeps both toggles in step with each other and with Esc
# or right-click cancels.
func _arm_button(text: String, order: SelectionController.ArmedOrder, tip: String) -> Button:
	var b: Button = _button(text)
	b.toggle_mode = true
	b.tooltip_text = tip
	b.toggled.connect(func(pressed: bool) -> void:
		_controller.arm(order if pressed else SelectionController.ArmedOrder.NONE))
	return b


# Counts each side's living units, once per tick rather than every frame.
func _recount_alive() -> void:
	if _world.tick == _counted_tick:
		return
	_counted_tick = _world.tick
	_light_alive = 0
	_dark_alive = 0
	for unit: Unit in _world.units:
		if not unit.is_alive():
			continue
		if unit.faction == UnitType.Faction.LIGHT:
			_light_alive += 1
		else:
			_dark_alive += 1


# "12 selected: 12 Shieldman", or "Nothing selected".
func _selection_summary(selection: UnitSelection) -> String:
	if selection.is_empty():
		return "Nothing selected"
	var counts: Dictionary[String, int] = {}
	for unit_id: int in selection.ids():
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null:
			counts[unit.type.display_name] = counts.get(unit.type.display_name, 0) + 1
	var parts: PackedStringArray = PackedStringArray()
	for type_name: String in counts:
		parts.append("%d %s" % [counts[type_name], type_name])
	return "%d selected: %s" % [selection.size(), ", ".join(parts)]


# Buttons never take keyboard focus, so the number keys keep reaching the game.
static func _button(text: String) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	return b


static func _caption(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.custom_minimum_size.x = 76.0
	return label
