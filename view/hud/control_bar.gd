class_name ControlBar
extends PanelContainer
## Bottom bar mirroring the keyboard controls so the game is playable with the
## mouse alone. Four rows:
## - formation buttons (1..0), and turning the formation a step either way
##   (the pending turn is shown);
## - control groups (click to recall; toggle Set or Clear, then click a slot
##   to save or empty it; Next recalls the next saved group), the group the
##   selection came from, beside a status line (the selection, how many units
##   are alive on each side, the side being controlled) and the last notice;
## - the orders: Stop, Move, Attack-move, Ground attack (each arms that order
##   for the next left click on the ground, once), Waypoints (every click a
##   route point until the route closes), Guard, Scatter, Retreat, and Ability
##   (the selection's special);
## - the view: Select all and None, Center (the camera on the selection),
##   Health (every health bar, while on), the game speed (single player),
##   Switch side (debug; the campaign hides it), and Menu (the pause menu,
##   which Esc opens too; it is how a mouse alone reaches it).
## The keys named on the buttons and in their tooltips are the current
## bindings (refresh_key_labels).
## All actions go through the SelectionController, so keys and buttons can't
## drift apart. While the game is paused the order buttons are disabled:
## nothing would be enqueued, and a greyed button says so.

## The Menu button was pressed: open the pause menu (MainView connects it).
signal menu_requested
## The Center button was pressed: the camera to the selection (MainView).
signal center_requested
## A game speed button was pressed: +1 faster, -1 slower (MainView).
signal speed_step_requested(step: int)

## Space kept below the last row of buttons: as deep as the camera's edge-scroll
## zone, so the bottom strip of the window is bar background and not a button,
## and edge scroll still works along the bottom edge (it only holds off over a
## button).
const BOTTOM_PADDING: float = RtsCamera.EDGE_SCROLL_MARGIN

const GROUP_LABELS: Array[String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
## Seconds a notice from the controller stays up.
const NOTICE_SECONDS: float = 3.0

var _controller: SelectionController
var _world: World
var _formation_buttons: Array[Button] = []
var _group_buttons: Array[Button] = []
var _set_toggle: Button
var _clear_toggle: Button
var _next_group_button: Button
var _move_toggle: Button
var _attack_move_toggle: Button
var _ground_attack_toggle: Button
var _waypoint_toggle: Button
## Every button that gives an order, disabled while paused.
var _order_buttons: Array[Button] = []
var _side_button: Button
var _menu_button: Button
var _stop_button: Button
var _guard_button: Button
var _scatter_button: Button
var _retreat_button: Button
var _ability_button: Button
var _center_button: Button
var _rotate_left_button: Button
var _rotate_right_button: Button
var _rotation: Label
var _select_all_button: Button
var _deselect_button: Button
var _health_toggle: Button
var _slower_button: Button
var _faster_button: Button
var _speed: Label
var _status: Label
var _notice: Label
var _notice_left: float = 0.0
## Living units per side, recounted when the tick changes.
var _light_alive: int = 0
var _dark_alive: int = 0
var _counted_tick: int = -1
## True in a skirmish, where the status line names the player's side and the
## enemy's instead of Light and Dark, and every living unit counts.
var _skirmish: bool = false
var _player_faction: UnitType.Faction = UnitType.Faction.LIGHT


func setup(controller: SelectionController, world: World) -> void:
	_controller = controller
	_world = world
	_build()
	_controller.formation_changed.connect(_on_formation_changed)
	_on_formation_changed(_controller.formation)
	_controller.armed_order_changed.connect(_on_armed_order_changed)
	_on_armed_order_changed(_controller.armed_order)
	_controller.rotation_changed.connect(_on_rotation_changed)
	_controller.group_changed.connect(_on_group_changed)
	_controller.notice.connect(show_notice)


func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var panel: StyleBox = get_theme_stylebox("panel").duplicate() as StyleBox
	panel.content_margin_bottom = BOTTOM_PADDING
	add_theme_stylebox_override("panel", panel)
	var rows: VBoxContainer = VBoxContainer.new()
	add_child(rows)

	var formations: HBoxContainer = HBoxContainer.new()
	formations.add_child(_caption("Formation"))
	var group: ButtonGroup = ButtonGroup.new()
	for kind: int in Formations.Kind.size():
		var b: Button = _button(Formations.DISPLAY_NAMES[kind])
		b.toggle_mode = true
		b.button_group = group
		b.pressed.connect(_controller.set_formation.bind(kind))
		formations.add_child(b)
		_formation_buttons.append(b)
	formations.add_child(VSeparator.new())
	_rotate_left_button = _button("⟲")
	_rotate_left_button.pressed.connect(_controller.rotate_formation.bind(-1))
	formations.add_child(_rotate_left_button)
	_rotate_right_button = _button("⟳")
	_rotate_right_button.pressed.connect(_controller.rotate_formation.bind(1))
	formations.add_child(_rotate_right_button)
	_rotation = Label.new()
	_rotation.custom_minimum_size.x = 48.0
	formations.add_child(_rotation)
	rows.add_child(formations)

	var groups: HBoxContainer = HBoxContainer.new()
	groups.add_child(_caption("Groups"))
	for slot: int in UnitSelection.GROUP_COUNT:
		var b: Button = _button(GROUP_LABELS[slot])
		b.custom_minimum_size.x = 34.0
		b.pressed.connect(_on_group_pressed.bind(slot))
		groups.add_child(b)
		_group_buttons.append(b)
	_set_toggle = _button("Set")
	_set_toggle.toggle_mode = true
	_set_toggle.tooltip_text = "Then click a group slot to save the selection there"
	_set_toggle.toggled.connect(func(on: bool) -> void:
		if on:
			_clear_toggle.set_pressed_no_signal(false))
	groups.add_child(_set_toggle)
	_clear_toggle = _button("Clear")
	_clear_toggle.toggle_mode = true
	_clear_toggle.toggled.connect(func(on: bool) -> void:
		if on:
			_set_toggle.set_pressed_no_signal(false))
	groups.add_child(_clear_toggle)
	_next_group_button = _button("Next")
	_next_group_button.pressed.connect(_controller.cycle_group.bind(1))
	groups.add_child(_next_group_button)
	groups.add_child(VSeparator.new())
	_status = Label.new()
	groups.add_child(_status)
	_notice = Label.new()
	_notice.name = "Notice"
	_notice.modulate = Color(1.0, 0.92, 0.55)
	groups.add_child(_notice)
	rows.add_child(groups)

	var orders: HBoxContainer = HBoxContainer.new()
	orders.add_child(_caption("Orders"))
	_stop_button = _button("Stop")
	_stop_button.pressed.connect(_controller.stop_selected)
	orders.add_child(_stop_button)
	_order_buttons.append(_stop_button)
	_move_toggle = _arm_button("Move", SelectionController.ArmedOrder.MOVE)
	orders.add_child(_move_toggle)
	_order_buttons.append(_move_toggle)
	_attack_move_toggle = _arm_button("Attack-move", SelectionController.ArmedOrder.ATTACK_MOVE)
	orders.add_child(_attack_move_toggle)
	_order_buttons.append(_attack_move_toggle)
	_ground_attack_toggle = _arm_button("Ground attack", SelectionController.ArmedOrder.GROUND_ATTACK)
	orders.add_child(_ground_attack_toggle)
	_order_buttons.append(_ground_attack_toggle)
	_waypoint_toggle = _arm_button("Waypoints", SelectionController.ArmedOrder.WAYPOINT)
	orders.add_child(_waypoint_toggle)
	_order_buttons.append(_waypoint_toggle)
	_guard_button = _order_button(orders, "Guard", _controller.guard_selected)
	_scatter_button = _order_button(orders, "Scatter", _controller.scatter_selected)
	_retreat_button = _order_button(orders, "Retreat", _controller.retreat_selected)
	_ability_button = _order_button(orders, "Ability", _controller.use_special_selected)
	rows.add_child(orders)

	var view: HBoxContainer = HBoxContainer.new()
	view.add_child(_caption("View"))
	_select_all_button = _button("All")
	_select_all_button.pressed.connect(_controller.select_all_visible)
	view.add_child(_select_all_button)
	_deselect_button = _button("None")
	_deselect_button.pressed.connect(_controller.deselect)
	view.add_child(_deselect_button)
	_center_button = _button("Center")
	_center_button.pressed.connect(center_requested.emit)
	view.add_child(_center_button)
	_health_toggle = _button("Health")
	_health_toggle.toggle_mode = true
	_health_toggle.toggled.connect(_controller.set_health_bars)
	view.add_child(_health_toggle)
	view.add_child(VSeparator.new())
	_slower_button = _button("Slower")
	_slower_button.pressed.connect(speed_step_requested.emit.bind(-1))
	view.add_child(_slower_button)
	_speed = Label.new()
	_speed.name = "Speed"
	_speed.custom_minimum_size.x = 40.0
	_speed.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	view.add_child(_speed)
	_faster_button = _button("Faster")
	_faster_button.pressed.connect(speed_step_requested.emit.bind(1))
	view.add_child(_faster_button)
	set_game_speed(1.0)
	view.add_child(VSeparator.new())
	_side_button = _button("Switch side")
	_side_button.tooltip_text = "Debug: command the other side (F9)"
	_side_button.pressed.connect(_controller.switch_side)
	view.add_child(_side_button)
	_menu_button = _button("Menu")
	_menu_button.tooltip_text = "Pause and open the menu (Esc)"
	_menu_button.pressed.connect(menu_requested.emit)
	view.add_child(_menu_button)
	rows.add_child(view)
	refresh_key_labels()

	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE, Control.PRESET_MODE_MINSIZE)
	grow_vertical = Control.GROW_DIRECTION_BEGIN


## Names the current bindings on the buttons and in their tooltips. Called
## once built, and again by MainView after the controls are changed.
func refresh_key_labels() -> void:
	for kind: int in _formation_buttons.size():
		var key: String = InputBindings.label_for(InputBindings.FORMATIONS[kind])
		_formation_buttons[kind].text = "%s %s" % [key, Formations.DISPLAY_NAMES[kind]]
		_formation_buttons[kind].tooltip_text = "Formation for the next move order (%s)" % key
	for slot: int in _group_buttons.size():
		_group_buttons[slot].tooltip_text = "Recall group %s (%s); save with Set or %s" % [
			GROUP_LABELS[slot], InputBindings.label_for(InputBindings.GROUP_RECALLS[slot]),
			InputBindings.label_for(InputBindings.GROUP_SAVES[slot]),
		]
	var ability_key: String = InputBindings.label_for(InputBindings.ABILITY)
	_stop_button.tooltip_text = "Halt the selection (%s)" % InputBindings.label_for(InputBindings.STOP)
	_move_toggle.tooltip_text = "Then left-click the ground to move there (or %s)" % InputBindings.label_for(InputBindings.COMMAND)
	_attack_move_toggle.tooltip_text = "Then left-click the ground to attack-move there (or %s)" % InputBindings.label_for(InputBindings.ATTACK_MOVE)
	_ground_attack_toggle.tooltip_text = (
		"Then left-click the ground to bombard it with the selected archers and grenadiers (or %s)"
		% InputBindings.label_for(InputBindings.GROUND_ATTACK)
	)
	_ability_button.text = "Ability (%s)" % ability_key
	_ability_button.tooltip_text = (
		"Use the selection's special (%s): a Sapper drops a satchel charge, a Longbow nocks its fire arrow, " % ability_key
		+ "a Blightbag bursts. With a Warden, then click a unit to heal it (an undead one dies of it)"
	)
	_center_button.tooltip_text = "Center the camera on the selection (%s)" % InputBindings.label_for(InputBindings.CAM_CENTER)
	_waypoint_toggle.tooltip_text = (
		"Then left-click up to four points (or %s); click the first again for a loop, the last for back and forth"
		% ("Shift+" + InputBindings.label_for(InputBindings.COMMAND))
	)
	_guard_button.tooltip_text = "Hold this spot; archers step back from melee and keep shooting (%s)" % InputBindings.label_for(InputBindings.GUARD)
	_scatter_button.tooltip_text = "Run apart from each other (%s)" % InputBindings.label_for(InputBindings.SCATTER)
	_retreat_button.tooltip_text = "Fall back from the nearest enemy, facing it (%s)" % InputBindings.label_for(InputBindings.RETREAT)
	_rotate_left_button.tooltip_text = "Turn the formation left (%s)" % InputBindings.label_for(InputBindings.ROTATE_LEFT)
	_rotate_right_button.tooltip_text = "Turn the formation right (%s)" % InputBindings.label_for(InputBindings.ROTATE_RIGHT)
	_select_all_button.tooltip_text = "Select all of your units on screen (%s)" % InputBindings.label_for(InputBindings.SELECT_ALL)
	_deselect_button.tooltip_text = "Select nothing (%s)" % InputBindings.label_for(InputBindings.DESELECT)
	_next_group_button.tooltip_text = "Recall the next saved group (%s)" % InputBindings.label_for(InputBindings.CYCLE_GROUPS)
	_clear_toggle.tooltip_text = "Then click a group slot to empty it (%s clears the group just recalled)" % InputBindings.label_for(InputBindings.CLEAR_GROUP)
	_health_toggle.tooltip_text = "Show every unit's health (or hold %s)" % InputBindings.label_for(InputBindings.HEALTH_BARS)
	_slower_button.tooltip_text = "Slow the game down (%s)" % InputBindings.label_for(InputBindings.SPEED_DOWN)
	_faster_button.tooltip_text = "Speed the game up (%s)" % InputBindings.label_for(InputBindings.SPEED_UP)


## Shows or hides the debug Switch side button. The campaign hides it.
func set_switch_side_visible(shown: bool) -> void:
	_side_button.visible = shown


## Whether Switch side is on show.
func is_switch_side_visible() -> bool:
	return _side_button.visible


## Puts the bar in skirmish mode for a player on `player_faction`: the status
## line reads "You (Light) 14 · Enemy (Dark) 11 alive", the player's side first,
## with no side being controlled to name (the player's is fixed). MainView calls
## it for a skirmish launch; a campaign mission and the sandbox keep the line
## they had.
func set_skirmish(player_faction: UnitType.Faction) -> void:
	_skirmish = true
	_player_faction = player_faction
	_counted_tick = -1


## The status line as drawn: the selection, how many are alive on each side, and
## which side is controlled.
func status_text() -> String:
	return _status.text


## Turns the Menu button on or off. MainView turns it off once the mission is
## decided, with the menu itself. Unlike the order buttons it stays on while
## paused: the menu is how a paused game is left.
func set_menu_enabled(enabled: bool) -> void:
	_menu_button.disabled = not enabled


## Shows the game speed ("2x").
func set_game_speed(speed: float) -> void:
	_speed.text = ("%dx" % roundi(speed)) if speed >= 1.0 else "1/%dx" % roundi(1.0 / speed)


## Shows or hides the game speed buttons: hidden while watching a replay
## (which has its own) and in a lockstep game.
func set_game_speed_visible(shown: bool) -> void:
	_slower_button.visible = shown
	_speed.visible = shown
	_faster_button.visible = shown


## Shows a short message (a group saved, a route full) for NOTICE_SECONDS.
func show_notice(text: String) -> void:
	_notice.text = text
	_notice_left = NOTICE_SECONDS


## The notice on show, or "".
func notice_text() -> String:
	return _notice.text


## Disables the order buttons while the game is paused and enables them again
## after. Formations and groups stay on: they are selection state.
func set_paused(paused: bool) -> void:
	for button: Button in _order_buttons:
		button.disabled = paused


func _process(delta: float) -> void:
	if _controller == null:
		return
	if _notice_left > 0.0:
		_notice_left -= delta
		if _notice_left <= 0.0:
			_notice.text = ""
	var selection: UnitSelection = _controller.selection
	for slot: int in _group_buttons.size():
		var count: int = selection.group(slot).size()
		_group_buttons[slot].text = GROUP_LABELS[slot] if count == 0 else "%s·%d" % [GROUP_LABELS[slot], count]
	_recount_alive()
	if _skirmish:
		_status.text = "%s   |   %s" % [_selection_summary(selection), _skirmish_counts()]
		return
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
	elif _clear_toggle.button_pressed:
		_controller.selection.clear_group(slot)
		_clear_toggle.button_pressed = false
	else:
		_controller.recall_group(slot)


func _on_group_changed(slot: int) -> void:
	for i: int in _group_buttons.size():
		_group_buttons[i].modulate = Color(1.0, 0.92, 0.55) if i == slot else Color.WHITE


func _on_rotation_changed(steps: int) -> void:
	var degrees: int = roundi(steps * 360.0 / SelectionController.ROTATE_STEPS)
	if degrees > 180:
		degrees -= 360
	_rotation.text = "" if steps == 0 else "%+d°" % degrees


func _on_formation_changed(kind: Formations.Kind) -> void:
	_formation_buttons[kind].set_pressed_no_signal(true)


func _on_armed_order_changed(order: SelectionController.ArmedOrder) -> void:
	_move_toggle.set_pressed_no_signal(order == SelectionController.ArmedOrder.MOVE)
	_attack_move_toggle.set_pressed_no_signal(order == SelectionController.ArmedOrder.ATTACK_MOVE)
	_ground_attack_toggle.set_pressed_no_signal(order == SelectionController.ArmedOrder.GROUND_ATTACK)
	_waypoint_toggle.set_pressed_no_signal(order == SelectionController.ArmedOrder.WAYPOINT)


# A toggle that arms order while pressed. Pressing it again disarms. The
# controller's signal keeps both toggles in step with each other and with Esc
# or right-click cancels.
func _arm_button(text: String, order: SelectionController.ArmedOrder) -> Button:
	var b: Button = _button(text)
	b.toggle_mode = true
	b.toggled.connect(func(pressed: bool) -> void:
		_controller.arm(order if pressed else SelectionController.ArmedOrder.NONE))
	return b


# A button that gives an order (disabled while paused), added to `row`.
func _order_button(row: HBoxContainer, text: String, action: Callable) -> Button:
	var b: Button = _button(text)
	b.pressed.connect(action)
	row.add_child(b)
	_order_buttons.append(b)
	return b


# Counts each side's living units, once per tick rather than every frame. The
# Light count is the player's: units the AI drives (an escort) aren't theirs.
# In a skirmish both armies are fully counted: either side may be the AI's.
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
			if _skirmish or not _world.ai.controls(unit.id):
				_light_alive += 1
		else:
			_dark_alive += 1


# "You (Light) 14 · Enemy (Dark) 11 alive": the player's side first.
func _skirmish_counts() -> String:
	var enemy: int = 1 - _player_faction
	var own_alive: int = _light_alive if _player_faction == UnitType.Faction.LIGHT else _dark_alive
	var enemy_alive: int = _dark_alive if _player_faction == UnitType.Faction.LIGHT else _light_alive
	return "You (%s) %d · Enemy (%s) %d alive" % [
		SideColors.side_name(_player_faction), own_alive, SideColors.side_name(enemy), enemy_alive,
	]


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
