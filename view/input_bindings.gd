class_name InputBindings
extends RefCounted
## View-side input actions, registered in code so the project file stays
## readable and the player can rebind them (Settings > Controls). Bindings use
## physical keycodes, so they follow key position rather than the keyboard
## layout.
##
## Rebinding (Phase 10): every action in REBINDABLE has one binding, which
## apply() replaces; the group keys stay on the number row and only their two
## modifiers change (set_group_modifiers). reset() puts everything back.
## Bindings are saved as text (event_to_text), a format that already covers
## gamepad buttons and axes, and labels for the HUD come from label_for(), so
## a rebound key is named correctly everywhere. Debug keys (F5, F6, F8, F9)
## aren't rebindable.
##
## Held keys are polled in _process. Mouse-wheel zoom has its own step actions
## because a wheel notch is an instant press and release: poll it and it is
## never seen, so handle it as a discrete event in _unhandled_input.
##
## Number keys carry three action sets that differ only by modifier: bare for
## formations, Cmd/Ctrl to save a group, Option/Alt to recall one. Godot
## matches a key action even when extra modifiers are held, so these must be
## checked with exact_match = true.
##
## Right click carries two actions the same way: bare COMMAND moves, and
## Cmd/Ctrl + right click (ATTACK_MOVE) attack-moves. A mouse action also
## matches with extra modifiers held, so check ATTACK_MOVE with exact_match =
## true before COMMAND. Left click is the same: bare SELECT selects, and
## Cmd/Ctrl + left click (GROUND_ATTACK) bombards the ground, so check
## GROUND_ATTACK with exact_match = true before SELECT.

const CAM_FORWARD: StringName = &"cam_forward"
const CAM_BACK: StringName = &"cam_back"
const CAM_LEFT: StringName = &"cam_left"
const CAM_RIGHT: StringName = &"cam_right"
const CAM_ORBIT_LEFT: StringName = &"cam_orbit_left"
const CAM_ORBIT_RIGHT: StringName = &"cam_orbit_right"
const CAM_SWIVEL_LEFT: StringName = &"cam_swivel_left"
const CAM_SWIVEL_RIGHT: StringName = &"cam_swivel_right"
## Held: zoom continuously.
const CAM_ZOOM_IN: StringName = &"cam_zoom_in"
const CAM_ZOOM_OUT: StringName = &"cam_zoom_out"
## Mouse wheel notches: zoom one discrete step per event.
const CAM_ZOOM_IN_STEP: StringName = &"cam_zoom_in_step"
const CAM_ZOOM_OUT_STEP: StringName = &"cam_zoom_out_step"
const TOGGLE_OVERHEAD_MAP: StringName = &"toggle_overhead_map"
## Left click / drag: select. Right click: move the selection. Cmd/Ctrl +
## right click: attack-move it. Cmd/Ctrl + left click: ground attack.
const SELECT: StringName = &"unit_select"
const COMMAND: StringName = &"unit_command"
const ATTACK_MOVE: StringName = &"unit_attack_move"
const GROUND_ATTACK: StringName = &"unit_ground_attack"
## T: the selection's special ability (a Sapper drops a charge, a Longbow
## nocks its fire arrow).
const ABILITY: StringName = &"unit_ability"
## Space (Myth-style): halt the selection.
const STOP: StringName = &"unit_stop"
## H: glide the camera to the middle of the selection.
const CAM_CENTER: StringName = &"cam_center_selection"
## Esc: cancel an order armed from the control bar; with none armed, open or
## close the pause menu (PauseMenu).
const CANCEL: StringName = &"cancel"
## P: pause or resume without the menu (MainView). The sim stops stepping; the
## camera, selection, and HUD keep working.
const PAUSE: StringName = &"pause_game"
## Debug: switch which side the mouse commands. The AI keeps driving its
## groups whichever side that is.
const SWITCH_SIDE: StringName = &"debug_switch_side"
## Debug: cycle clear, rain, heavy rain, snow (DebugWeather), until the
## mission's next weather change.
const CYCLE_WEATHER: StringName = &"debug_cycle_weather"
## Debug: paralyze, confuse, or set alight the selection, in turn.
const CYCLE_STATUS: StringName = &"debug_cycle_status"
## Debug: F5 shows or hides the enemy AI overlay (AiDebugView).
const TOGGLE_AI_DEBUG: StringName = &"debug_toggle_ai"
## F7: shows or hides a skirmish's scoreboard (SkirmishHud).
const TOGGLE_SCOREBOARD: StringName = &"toggle_scoreboard"
## Debug: F12 draws every unit as its placeholder, or with its art again.
const TOGGLE_ART: StringName = &"debug_toggle_art"
## Index i is formation Formations.Kind i and group slot i; keys 1..9, 0.
const FORMATIONS: Array[StringName] = [
	&"formation_1", &"formation_2", &"formation_3", &"formation_4", &"formation_5",
	&"formation_6", &"formation_7", &"formation_8", &"formation_9", &"formation_10",
]
const GROUP_SAVES: Array[StringName] = [
	&"group_save_1", &"group_save_2", &"group_save_3", &"group_save_4", &"group_save_5",
	&"group_save_6", &"group_save_7", &"group_save_8", &"group_save_9", &"group_save_10",
]
const GROUP_RECALLS: Array[StringName] = [
	&"group_recall_1", &"group_recall_2", &"group_recall_3", &"group_recall_4", &"group_recall_5",
	&"group_recall_6", &"group_recall_7", &"group_recall_8", &"group_recall_9", &"group_recall_10",
]
const NUMBER_KEYS: Array[Key] = [
	KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9, KEY_0,
]

## The modifier that turns a number key into a group save or recall.
enum GroupModifier {
	## Cmd on macOS, Ctrl elsewhere.
	COMMAND_OR_CONTROL,
	## Option on macOS, Alt elsewhere.
	ALT,
	SHIFT,
}
const DEFAULT_SAVE_MODIFIER: GroupModifier = GroupModifier.COMMAND_OR_CONTROL
const DEFAULT_RECALL_MODIFIER: GroupModifier = GroupModifier.ALT

## The actions the player may rebind, in the order Settings lists them, by
## section. The group keys are the number row plus a modifier, changed with
## set_group_modifiers.
const REBINDABLE: Dictionary[String, Array] = {
	"Camera": [
		CAM_FORWARD, CAM_BACK, CAM_LEFT, CAM_RIGHT, CAM_ORBIT_LEFT, CAM_ORBIT_RIGHT,
		CAM_SWIVEL_LEFT, CAM_SWIVEL_RIGHT, CAM_ZOOM_IN, CAM_ZOOM_OUT, CAM_CENTER, TOGGLE_OVERHEAD_MAP,
	],
	"Orders": [
		SELECT, COMMAND, ATTACK_MOVE, GROUND_ATTACK, ABILITY, STOP, PAUSE, TOGGLE_SCOREBOARD,
	],
	"Formations": [
		&"formation_1", &"formation_2", &"formation_3", &"formation_4", &"formation_5",
		&"formation_6", &"formation_7", &"formation_8", &"formation_9", &"formation_10",
	],
}
## Mouse buttons as the player reads them.
const MOUSE_NAMES: Dictionary[int, String] = {
	MOUSE_BUTTON_LEFT: "Left click", MOUSE_BUTTON_RIGHT: "Right click",
	MOUSE_BUTTON_MIDDLE: "Middle click", MOUSE_BUTTON_WHEEL_UP: "Wheel up",
	MOUSE_BUTTON_WHEEL_DOWN: "Wheel down", MOUSE_BUTTON_XBUTTON1: "Mouse 4",
	MOUSE_BUTTON_XBUTTON2: "Mouse 5",
}
## What Settings calls each rebindable action.
const ACTION_NAMES: Dictionary[StringName, String] = {
	CAM_FORWARD: "Camera forward", CAM_BACK: "Camera back",
	CAM_LEFT: "Camera left", CAM_RIGHT: "Camera right",
	CAM_ORBIT_LEFT: "Orbit left", CAM_ORBIT_RIGHT: "Orbit right",
	CAM_SWIVEL_LEFT: "Turn left", CAM_SWIVEL_RIGHT: "Turn right",
	CAM_ZOOM_IN: "Zoom in", CAM_ZOOM_OUT: "Zoom out",
	CAM_CENTER: "Center on selection", TOGGLE_OVERHEAD_MAP: "Overhead map",
	SELECT: "Select", COMMAND: "Move", ATTACK_MOVE: "Attack-move", GROUND_ATTACK: "Ground attack",
	ABILITY: "Special ability", STOP: "Stop", PAUSE: "Pause", TOGGLE_SCOREBOARD: "Scoreboard",
	&"formation_1": "Short line", &"formation_2": "Long line", &"formation_3": "Loose line",
	&"formation_4": "Staggered line", &"formation_5": "Box", &"formation_6": "Rabble",
	&"formation_7": "Shallow encirclement", &"formation_8": "Deep encirclement",
	&"formation_9": "Wedge", &"formation_10": "Circle",
}


## Registers every action that is not already in the InputMap. Safe to call
## from several nodes: an existing action, including one rebound by the user,
## is left alone.
static func install() -> void:
	var events: Dictionary[StringName, InputEvent] = defaults()
	for action: StringName in events:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		InputMap.action_add_event(action, events[action])


## Every action back on its default binding, the group modifiers included.
static func reset() -> void:
	var events: Dictionary[StringName, InputEvent] = defaults()
	for action: StringName in events:
		_bind(action, events[action])


## Rebinds each action in `overrides` to its event. Actions that aren't
## rebindable are ignored, so a stale settings file can't rebind a debug key.
static func apply(overrides: Dictionary[StringName, InputEvent]) -> void:
	for action: StringName in overrides:
		if is_rebindable(action) and overrides[action] != null:
			_bind(action, overrides[action])


## Puts the group saves and recalls on these modifiers plus the number keys.
## The two must differ; equal ones are refused (false).
static func set_group_modifiers(save: GroupModifier, recall: GroupModifier) -> bool:
	if save == recall:
		return false
	for i: int in NUMBER_KEYS.size():
		_bind(GROUP_SAVES[i], _with_modifier(_key(NUMBER_KEYS[i]), save))
		_bind(GROUP_RECALLS[i], _with_modifier(_key(NUMBER_KEYS[i]), recall))
	return true


static func is_rebindable(action: StringName) -> bool:
	return ACTION_NAMES.has(action)


## The event an action is bound to now (its first), or null.
static func event_of(action: StringName) -> InputEvent:
	if not InputMap.has_action(action):
		return null
	var events: Array[InputEvent] = InputMap.action_get_events(action)
	return events[0] if not events.is_empty() else null


## The actions other than `action` already bound to `event`: the rebindable
## ones and the group keys, which a rebinding mustn't shadow.
static func conflicts(action: StringName, event: InputEvent) -> Array[StringName]:
	var text: String = event_to_text(event)
	var found: Array[StringName] = []
	var candidates: Array[StringName] = []
	candidates.assign(ACTION_NAMES.keys())
	candidates.append_array(GROUP_SAVES)
	candidates.append_array(GROUP_RECALLS)
	for other: StringName in candidates:
		var bound: InputEvent = event_of(other)
		if other != action and bound != null and event_to_text(bound) == text:
			found.append(other)
	return found


## An event as saved text: "key:<name>", "mouse:<button>", "joy_button:<n>" or
## "joy_axis:<axis>:plus|minus", then "+cmdorctrl", "+ctrl", "+meta", "+alt",
## "+shift" for each modifier it needs. "" for an event it can't describe.
static func event_to_text(event: InputEvent) -> String:
	var text: String = ""
	if event is InputEventKey:
		var key: InputEventKey = event
		text = "key:" + OS.get_keycode_string(key.physical_keycode)
	elif event is InputEventMouseButton:
		text = "mouse:%d" % (event as InputEventMouseButton).button_index
	elif event is InputEventJoypadButton:
		return "joy_button:%d" % (event as InputEventJoypadButton).button_index
	elif event is InputEventJoypadMotion:
		var motion: InputEventJoypadMotion = event
		return "joy_axis:%d:%s" % [motion.axis, "plus" if motion.axis_value >= 0.0 else "minus"]
	else:
		return ""
	var with: InputEventWithModifiers = event
	if with.command_or_control_autoremap:
		text += "+cmdorctrl"
	else:
		if with.ctrl_pressed:
			text += "+ctrl"
		if with.meta_pressed:
			text += "+meta"
	if with.alt_pressed:
		text += "+alt"
	if with.shift_pressed:
		text += "+shift"
	return text


## The event event_to_text described, or null for text it doesn't recognize.
static func text_to_event(text: String) -> InputEvent:
	var parts: PackedStringArray = text.split("+")
	var head: PackedStringArray = parts[0].split(":")
	var event: InputEvent = null
	match head[0]:
		"key":
			if head.size() != 2:
				return null
			var keycode: Key = OS.find_keycode_from_string(head[1])
			if keycode == KEY_NONE:
				return null
			event = _key(keycode)
		"mouse":
			if head.size() != 2 or not head[1].is_valid_int() or head[1].to_int() <= 0:
				return null
			event = _mouse(head[1].to_int() as MouseButton)
		"joy_button":
			if head.size() != 2 or not head[1].is_valid_int() or parts.size() != 1:
				return null
			var button: InputEventJoypadButton = InputEventJoypadButton.new()
			button.button_index = head[1].to_int() as JoyButton
			return button
		"joy_axis":
			if head.size() != 3 or not head[1].is_valid_int() or not head[2] in ["plus", "minus"] or parts.size() != 1:
				return null
			var motion: InputEventJoypadMotion = InputEventJoypadMotion.new()
			motion.axis = head[1].to_int() as JoyAxis
			motion.axis_value = 1.0 if head[2] == "plus" else -1.0
			return motion
		_:
			return null
	var with: InputEventWithModifiers = event
	for modifier: String in parts.slice(1):
		match modifier:
			"cmdorctrl":
				with.command_or_control_autoremap = true
			"ctrl":
				with.ctrl_pressed = true
			"meta":
				with.meta_pressed = true
			"alt":
				with.alt_pressed = true
			"shift":
				with.shift_pressed = true
			_:
				return null
	return event


## The key or button an action is on, for the HUD: "T", "Space",
## "Cmd+Right click". "" for an action with no binding.
static func label_for(action: StringName) -> String:
	var event: InputEvent = event_of(action)
	return event_label(event) if event != null else ""


## An event as the player reads it.
static func event_label(event: InputEvent) -> String:
	var key_name: String = ""
	if event is InputEventKey:
		key_name = OS.get_keycode_string((event as InputEventKey).physical_keycode)
	elif event is InputEventMouseButton:
		var button: int = (event as InputEventMouseButton).button_index
		key_name = MOUSE_NAMES.get(button, "Mouse %d" % button)
	elif event is InputEventJoypadButton:
		return "Pad button %d" % (event as InputEventJoypadButton).button_index
	elif event is InputEventJoypadMotion:
		var motion: InputEventJoypadMotion = event
		return "Pad axis %d%s" % [motion.axis, "+" if motion.axis_value >= 0.0 else "-"]
	else:
		return ""
	var with: InputEventWithModifiers = event
	var prefix: String = ""
	if with.command_or_control_autoremap:
		prefix += "Cmd+" if _on_mac() else "Ctrl+"
	else:
		if with.ctrl_pressed:
			prefix += "Ctrl+"
		if with.meta_pressed:
			prefix += "Cmd+" if _on_mac() else "Meta+"
	if with.alt_pressed:
		prefix += "Option+" if _on_mac() else "Alt+"
	if with.shift_pressed:
		prefix += "Shift+"
	return prefix + key_name


# Cmd and Option, not Ctrl and Alt: on a Mac, and in a browser on one.
static func _on_mac() -> bool:
	return OS.has_feature("macos") or OS.has_feature("web_macos")


## A group modifier as the player reads it.
static func modifier_label(modifier: GroupModifier) -> String:
	match modifier:
		GroupModifier.COMMAND_OR_CONTROL:
			return "Cmd" if _on_mac() else "Ctrl"
		GroupModifier.ALT:
			return "Option" if _on_mac() else "Alt"
	return "Shift"


## Every action's default binding.
static func defaults() -> Dictionary[StringName, InputEvent]:
	var events: Dictionary[StringName, InputEvent] = {}
	events[CAM_FORWARD] = _key(KEY_W)
	events[CAM_BACK] = _key(KEY_S)
	events[CAM_LEFT] = _key(KEY_A)
	events[CAM_RIGHT] = _key(KEY_D)
	events[CAM_ORBIT_LEFT] = _key(KEY_Q)
	events[CAM_ORBIT_RIGHT] = _key(KEY_E)
	events[CAM_SWIVEL_LEFT] = _key(KEY_Z)
	events[CAM_SWIVEL_RIGHT] = _key(KEY_X)
	events[CAM_ZOOM_IN] = _key(KEY_V)
	events[CAM_ZOOM_OUT] = _key(KEY_C)
	events[CAM_ZOOM_IN_STEP] = _wheel(MOUSE_BUTTON_WHEEL_UP)
	events[CAM_ZOOM_OUT_STEP] = _wheel(MOUSE_BUTTON_WHEEL_DOWN)
	events[TOGGLE_OVERHEAD_MAP] = _key(KEY_TAB)
	events[SELECT] = _mouse(MOUSE_BUTTON_LEFT)
	events[COMMAND] = _mouse(MOUSE_BUTTON_RIGHT)
	var attack_move: InputEventMouseButton = _mouse(MOUSE_BUTTON_RIGHT)
	# Cmd on macOS, Ctrl elsewhere.
	attack_move.command_or_control_autoremap = true
	events[ATTACK_MOVE] = attack_move
	var ground_attack: InputEventMouseButton = _mouse(MOUSE_BUTTON_LEFT)
	# Cmd on macOS, Ctrl elsewhere. Cmd is the Mac binding because Godot's
	# macOS layer delivers Ctrl + left click as a right click
	# (platform/macos/godot_content_view.mm, mouseDown).
	ground_attack.command_or_control_autoremap = true
	events[GROUND_ATTACK] = ground_attack
	events[ABILITY] = _key(KEY_T)
	events[STOP] = _key(KEY_SPACE)
	events[CAM_CENTER] = _key(KEY_H)
	events[CANCEL] = _key(KEY_ESCAPE)
	events[PAUSE] = _key(KEY_P)
	events[SWITCH_SIDE] = _key(KEY_F9)
	events[CYCLE_WEATHER] = _key(KEY_F6)
	events[CYCLE_STATUS] = _key(KEY_F8)
	events[TOGGLE_AI_DEBUG] = _key(KEY_F5)
	events[TOGGLE_SCOREBOARD] = _key(KEY_F7)
	events[TOGGLE_ART] = _key(KEY_F12)
	for i: int in NUMBER_KEYS.size():
		events[FORMATIONS[i]] = _key(NUMBER_KEYS[i])
		events[GROUP_SAVES[i]] = _with_modifier(_key(NUMBER_KEYS[i]), DEFAULT_SAVE_MODIFIER)
		events[GROUP_RECALLS[i]] = _with_modifier(_key(NUMBER_KEYS[i]), DEFAULT_RECALL_MODIFIER)
	return events


static func _bind(action: StringName, event: InputEvent) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, event)


static func _with_modifier(event: InputEventKey, modifier: GroupModifier) -> InputEventKey:
	match modifier:
		GroupModifier.COMMAND_OR_CONTROL:
			event.command_or_control_autoremap = true
		GroupModifier.ALT:
			event.alt_pressed = true
		GroupModifier.SHIFT:
			event.shift_pressed = true
	return event


static func _key(keycode: Key) -> InputEventKey:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = keycode
	return event


static func _mouse(button: MouseButton) -> InputEventMouseButton:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button
	return event


static func _wheel(button: MouseButton) -> InputEventMouseButton:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button
	return event
