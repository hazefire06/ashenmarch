class_name SettingsMenu
extends MenuScreen
## The Settings overlay, in three tabs:
## - Display: fullscreen, window size, vsync, frame cap, 3D render scale and
##   interface scale.
## - Audio: a volume per bus.
## - Controls: edge scroll, every rebindable action, the group modifiers, and
##   Reset all.
##
## Each change is saved to the settings file the moment it is made
## (GameSettings), then `changed` tells the App to apply it (a write that
## fails is shown and undone, and nothing is applied); Back (or Esc) emits
## `closed`, and the App removes the overlay. It is an overlay, not a screen,
## because it opens over the main menu and over a paused mission alike.
##
## Rebinding: press an action's button, then the key or mouse button (with any
## modifiers) for it; Esc cancels. A key another action already uses moves to
## the action that gave it up (a swap, so nothing is left unbound). A key that
## saves or recalls a group is refused: the group modifier is the thing to
## change.

## A setting was changed (and saved).
signal changed
## Back or Esc: the App should remove this overlay.
signal closed

const EDGE_SCROLL_HINT: String = "Pan the camera by pushing the mouse against the edge of the window."
const PRESS_A_KEY: String = "Press a key... (Esc cancels)"
const MODIFIER_KEYS: Array[Key] = [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]

var _path: String = GameSettings.DEFAULT_PATH
var _tabs: TabContainer
var _fullscreen: CheckBox
var _edge_scroll: CheckBox
var _back: Button
var _error: Label
var _note: Label
## The binding buttons by action, and the action waiting for a key.
var _binding_buttons: Dictionary[StringName, Button] = {}
var _capturing: StringName = &""
var _save_modifier: OptionButton
var _recall_modifier: OptionButton


func _init() -> void:
	super(false)


## Builds the screen from the settings file at `settings_path`.
func setup(settings_path: String = GameSettings.DEFAULT_PATH) -> void:
	_path = settings_path
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel: PanelContainer = MenuKit.panel()
	center.add_child(panel)
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	panel.add_child(column)
	var heading: Label = MenuKit.title("Settings", 32)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(heading)
	_tabs = TabContainer.new()
	_tabs.name = "Tabs"
	_tabs.custom_minimum_size = Vector2(560, 420)
	column.add_child(_tabs)
	_tabs.add_child(_display_tab())
	_tabs.add_child(_audio_tab())
	_tabs.add_child(_controls_tab())
	_note = MenuKit.paragraph("", 14, MenuKit.WARN_COLOR)
	_note.name = "Note"
	_note.visible = false
	_note.custom_minimum_size.x = 540.0
	column.add_child(_note)
	_error = MenuKit.paragraph("", 14, MenuKit.BAD_COLOR)
	_error.name = "SaveError"
	_error.visible = false
	_error.custom_minimum_size.x = 540.0
	column.add_child(_error)
	_back = MenuKit.button("BackButton", "Back")
	_back.pressed.connect(func() -> void: closed.emit())
	column.add_child(_back)
	if is_inside_tree():
		_focus_default()


## True while waiting for the key to bind.
func is_capturing() -> bool:
	return _capturing != &""


## Starts waiting for the key or button to bind `action` to (what pressing
## its button does).
func capture(action: StringName) -> void:
	_cancel_capture()
	_capturing = action
	_binding_buttons[action].text = PRESS_A_KEY


## Binds the action being captured to `event`, as if it had been pressed. Does
## nothing when nothing is being captured.
func bind_captured(event: InputEvent) -> void:
	if not is_capturing():
		return
	var action: StringName = _capturing
	_capturing = &""
	_rebind(action, event)


func _focus_default() -> void:
	_focus(_fullscreen)


func _cancel() -> bool:
	if is_capturing():
		_cancel_capture()
		return true
	closed.emit()
	return true


# While capturing, the next key (not a lone modifier) or mouse press is the
# binding; Esc cancels. Read in _input, ahead of the GUI, so the press can't
# also click a button or move focus.
func _input(event: InputEvent) -> void:
	if not is_capturing():
		return
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		var key: InputEventKey = event
		get_viewport().set_input_as_handled()
		if key.physical_keycode == KEY_ESCAPE:
			_cancel_capture()
		elif not MODIFIER_KEYS.has(key.physical_keycode):
			bind_captured(_portable(key))
	elif event is InputEventMouseButton and event.is_pressed():
		get_viewport().set_input_as_handled()
		bind_captured(_portable(event as InputEventMouseButton))


# The pressed key or button as a binding: physical keycode or button index,
# with Cmd on macOS or Ctrl elsewhere written as the portable "Cmd/Ctrl".
static func _portable(pressed: InputEventWithModifiers) -> InputEvent:
	var bound: InputEventWithModifiers
	if pressed is InputEventKey:
		var key: InputEventKey = InputEventKey.new()
		key.physical_keycode = (pressed as InputEventKey).physical_keycode
		bound = key
	else:
		var button: InputEventMouseButton = InputEventMouseButton.new()
		button.button_index = (pressed as InputEventMouseButton).button_index
		bound = button
	var mac: bool = OS.has_feature("macos") or OS.has_feature("web_macos")
	var command: bool = pressed.meta_pressed if mac else pressed.ctrl_pressed
	bound.command_or_control_autoremap = command
	if mac and pressed.ctrl_pressed:
		bound.ctrl_pressed = true
	bound.alt_pressed = pressed.alt_pressed
	bound.shift_pressed = pressed.shift_pressed
	return bound


func _cancel_capture() -> void:
	if not is_capturing():
		return
	var action: StringName = _capturing
	_capturing = &""
	_binding_buttons[action].text = InputBindings.label_for(action)


func _rebind(action: StringName, event: InputEvent) -> void:
	var previous: InputEvent = InputBindings.event_of(action)
	var clashes: Array[StringName] = InputBindings.conflicts(action, event)
	for other: StringName in clashes:
		if not InputBindings.is_rebindable(other):
			_say("%s saves or recalls a group; change the group modifier instead." % InputBindings.event_label(event))
			_refresh_bindings()
			return
	var changes: Dictionary[StringName, InputEvent] = {action: event}
	var swapped: PackedStringArray = PackedStringArray()
	for other: StringName in clashes:
		changes[other] = previous
		swapped.append(InputBindings.ACTION_NAMES[other])
	if not _saved(GameSettings.set_keybinds(changes, _path)):
		_refresh_bindings()
		return
	InputBindings.apply(changes)
	if swapped.is_empty():
		_say("")
	else:
		_say("%s was on %s; it now uses %s." % [
			InputBindings.event_label(event), ", ".join(swapped), InputBindings.event_label(previous),
		])
	_refresh_bindings()


func _reset_controls() -> void:
	_cancel_capture()
	if not _saved(GameSettings.clear_controls(_path)):
		return
	GameSettings.apply_bindings(_path)
	_save_modifier.select(InputBindings.DEFAULT_SAVE_MODIFIER)
	_recall_modifier.select(InputBindings.DEFAULT_RECALL_MODIFIER)
	_say("Controls are back to their defaults.")
	_refresh_bindings()


func _on_modifier_selected(_index: int) -> void:
	var save: int = _save_modifier.selected
	var recall: int = _recall_modifier.selected
	if save == recall:
		_say("Saving and recalling a group need different modifiers.")
		var saved: Array[int] = GameSettings.group_modifiers(_path)
		_save_modifier.select(saved[0])
		_recall_modifier.select(saved[1])
		return
	if _saved(GameSettings.set_group_modifiers(save, recall, _path)):
		InputBindings.set_group_modifiers(save as InputBindings.GroupModifier, recall as InputBindings.GroupModifier)
		_say("")


func _refresh_bindings() -> void:
	for action: StringName in _binding_buttons:
		_binding_buttons[action].text = InputBindings.label_for(action)


func _say(text: String) -> void:
	_note.text = text
	_note.visible = text != ""


# ---- tabs ------------------------------------------------------------------


func _display_tab() -> Control:
	var tab: VBoxContainer = _tab("Display")
	_fullscreen = _add_toggle(tab, "FullscreenCheck", "Fullscreen", GameSettings.fullscreen(_path))
	_fullscreen.toggled.connect(func(on: bool) -> void:
		_saved_or_undo(GameSettings.set_fullscreen(on, _path), _fullscreen, on)
	)
	var web: bool = OS.has_feature("web")
	if not web:
		var sizes: PackedStringArray = PackedStringArray()
		for size: Vector2i in GameSettings.WINDOW_SIZES:
			sizes.append("%d x %d" % [size.x, size.y])
		_add_choice(tab, "WindowSize", "Window size", sizes, GameSettings.window_size(_path), func(index: int) -> void:
			_saved(GameSettings.set_display(GameSettings.WINDOW_SIZE, index, _path))
		)
		var vsync: CheckBox = _add_toggle(tab, "VsyncCheck", "Vertical sync", GameSettings.vsync(_path))
		vsync.toggled.connect(func(on: bool) -> void:
			_saved_or_undo(GameSettings.set_display(GameSettings.VSYNC, on, _path), vsync, on)
		)
	var caps: PackedStringArray = PackedStringArray()
	for fps: int in GameSettings.MAX_FPS_CHOICES:
		caps.append("No cap" if fps == 0 else "%d" % fps)
	_add_choice(tab, "MaxFps", "Frame rate cap", caps,
		Array(GameSettings.MAX_FPS_CHOICES).find(GameSettings.max_fps(_path)), func(index: int) -> void:
			_saved(GameSettings.set_display(GameSettings.MAX_FPS, GameSettings.MAX_FPS_CHOICES[index], _path))
	)
	var scales: PackedStringArray = PackedStringArray()
	for percent: int in GameSettings.UI_SCALE_CHOICES:
		scales.append("Auto (%d%%)" % roundi(GameSettings.resolved_ui_scale(0) * 100) if percent == 0 else "%d%%" % percent)
	_add_choice(tab, "UiScale", "Interface size", scales,
		Array(GameSettings.UI_SCALE_CHOICES).find(GameSettings.ui_scale(_path)), func(index: int) -> void:
			_saved(GameSettings.set_display(GameSettings.UI_SCALE, GameSettings.UI_SCALE_CHOICES[index], _path))
	)
	_add_slider(tab, "RenderScale", "3D resolution", GameSettings.RENDER_SCALE_MIN, 100, 5,
		GameSettings.render_scale(_path), func(percent: int) -> void:
			_saved(GameSettings.set_display(GameSettings.RENDER_SCALE, percent, _path))
	)
	return tab


func _audio_tab() -> Control:
	var tab: VBoxContainer = _tab("Audio")
	for bus: String in GameSettings.VOLUMES_DEFAULT:
		_add_slider(tab, "%sVolume" % bus, bus if bus != "Master" else "Master volume", 0, 100, 5,
			GameSettings.volume(bus, _path), func(percent: int) -> void:
				_saved(GameSettings.set_volume(bus, percent, _path))
		)
	return tab


func _controls_tab() -> Control:
	var scroller: ScrollContainer = MenuKit.scroller()
	scroller.name = "Controls"
	var tab: VBoxContainer = VBoxContainer.new()
	tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab.add_theme_constant_override("separation", 6)
	scroller.add_child(tab)
	_edge_scroll = _add_toggle(tab, "EdgeScrollCheck", "Edge scroll", GameSettings.edge_scroll(_path))
	_edge_scroll.toggled.connect(func(on: bool) -> void:
		_saved_or_undo(GameSettings.set_edge_scroll(on, _path), _edge_scroll, on)
	)
	var hint: Label = MenuKit.paragraph(EDGE_SCROLL_HINT, 14, MenuKit.MUTED_COLOR)
	hint.custom_minimum_size.x = 340.0
	tab.add_child(hint)
	for section: String in InputBindings.REBINDABLE:
		tab.add_child(MenuKit.label(section, MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR))
		for action: StringName in InputBindings.REBINDABLE[section]:
			var row: HBoxContainer = HBoxContainer.new()
			var name_label: Label = MenuKit.label(InputBindings.ACTION_NAMES[action])
			name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(name_label)
			var button: Button = MenuKit.button("Bind_%s" % action, InputBindings.label_for(action), 220.0)
			button.pressed.connect(capture.bind(action))
			row.add_child(button)
			_binding_buttons[action] = button
			tab.add_child(row)
	tab.add_child(MenuKit.label("Groups", MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR))
	var modifiers: PackedStringArray = PackedStringArray()
	for modifier: int in InputBindings.GroupModifier.size():
		modifiers.append("%s + number" % InputBindings.modifier_label(modifier as InputBindings.GroupModifier))
	var saved: Array[int] = GameSettings.group_modifiers(_path)
	_save_modifier = _add_choice(tab, "SaveModifier", "Save a group", modifiers, saved[0], _on_modifier_selected)
	_recall_modifier = _add_choice(tab, "RecallModifier", "Recall a group", modifiers, saved[1], _on_modifier_selected)
	var reset: Button = MenuKit.button("ResetControls", "Reset all controls")
	reset.pressed.connect(_reset_controls)
	tab.add_child(reset)
	return scroller


func _tab(tab_name: String) -> VBoxContainer:
	var tab: VBoxContainer = VBoxContainer.new()
	tab.name = tab_name
	tab.add_theme_constant_override("separation", 10)
	return tab


# ---- saving ------------------------------------------------------------------


# The settings file is the one source of truth (the App re-reads it to apply
# anything), so a write that failed changed nothing: the player is told and
# `changed` isn't sent. True if it saved.
func _saved(result: Error) -> bool:
	_error.visible = result != OK
	if result == OK:
		changed.emit()
		return true
	_error.text = "Could not save the setting (%s); the change was not applied." % error_string(result)
	return false


# _saved for a checkbox, which also goes back to what it was if the write failed.
func _saved_or_undo(result: Error, box: CheckBox, flipped_to: bool) -> void:
	if not _saved(result):
		box.set_pressed_no_signal(not flipped_to)


static func _add_toggle(parent: Control, toggle_name: String, text: String, on: bool) -> CheckBox:
	var box: CheckBox = CheckBox.new()
	box.name = toggle_name
	box.text = text
	box.set_pressed_no_signal(on)
	MenuKit.style_check(box)
	parent.add_child(box)
	return box


static func _add_choice(
	parent: Control, choice_name: String, text: String, items: PackedStringArray, selected: int,
	on_selected: Callable
) -> OptionButton:
	var row: HBoxContainer = HBoxContainer.new()
	var label: Label = MenuKit.label(text)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var choice: OptionButton = OptionButton.new()
	choice.name = choice_name
	choice.custom_minimum_size.x = 220.0
	for item: String in items:
		choice.add_item(item)
	choice.select(maxi(selected, 0))
	choice.item_selected.connect(on_selected)
	row.add_child(choice)
	parent.add_child(row)
	return choice


static func _add_slider(
	parent: Control, slider_name: String, text: String, low: int, high: int, step: int, value: int,
	on_changed: Callable
) -> HSlider:
	var row: HBoxContainer = HBoxContainer.new()
	var label: Label = MenuKit.label(text)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var slider: HSlider = HSlider.new()
	slider.name = slider_name
	slider.min_value = low
	slider.max_value = high
	slider.step = step
	slider.value = value
	slider.custom_minimum_size.x = 220.0
	row.add_child(slider)
	var readout: Label = MenuKit.label("%d%%" % value)
	readout.custom_minimum_size.x = 52.0
	row.add_child(readout)
	# Saved and applied at every step, so a volume or the 3D resolution is
	# heard or seen while it is dragged. The writes are a few lines of text.
	slider.value_changed.connect(func(v: float) -> void:
		readout.text = "%d%%" % roundi(v)
		on_changed.call(roundi(v))
	)
	parent.add_child(row)
	return slider
