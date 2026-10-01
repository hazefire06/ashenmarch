class_name InputBindings
extends RefCounted
## View-side input actions, registered in code so the project file stays
## readable and Phase 10 can rebind at runtime. Bindings use physical keycodes,
## so they follow key position rather than the keyboard layout.
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
const STOP: StringName = &"unit_stop"
## Esc: cancel an order armed from the control bar.
const CANCEL: StringName = &"cancel"
## Debug until the AI exists: switch which side the mouse commands.
const SWITCH_SIDE: StringName = &"debug_switch_side"
## Debug until missions drive the weather: cycle clear, rain, heavy rain,
## snow (DebugWeather).
const CYCLE_WEATHER: StringName = &"debug_cycle_weather"
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


## Registers every action that is not already in the InputMap. Safe to call
## from several nodes: an existing action, including one rebound by the user,
## is left alone.
static func install() -> void:
	var defaults: Dictionary[StringName, InputEvent] = _default_events()
	for action: StringName in defaults:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		InputMap.action_add_event(action, defaults[action])


static func _default_events() -> Dictionary[StringName, InputEvent]:
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
	events[STOP] = _key(KEY_H)
	events[CANCEL] = _key(KEY_ESCAPE)
	events[SWITCH_SIDE] = _key(KEY_F9)
	events[CYCLE_WEATHER] = _key(KEY_F6)
	for i: int in NUMBER_KEYS.size():
		events[FORMATIONS[i]] = _key(NUMBER_KEYS[i])
		var save: InputEventKey = _key(NUMBER_KEYS[i])
		# Cmd on macOS, Ctrl elsewhere.
		save.command_or_control_autoremap = true
		events[GROUP_SAVES[i]] = save
		var recall: InputEventKey = _key(NUMBER_KEYS[i])
		recall.alt_pressed = true
		events[GROUP_RECALLS[i]] = recall
	return events


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
