class_name InputBindings
extends RefCounted
## View-side input actions, registered in code so the project file stays
## readable and Phase 10 can rebind at runtime. Bindings use physical keycodes,
## so they follow key position rather than the keyboard layout.
##
## Held keys are polled in _process. Mouse-wheel zoom has its own step actions
## because a wheel notch is an instant press and release: poll it and it is
## never seen, so handle it as a discrete event in _unhandled_input.

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
	return events


static func _key(keycode: Key) -> InputEventKey:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = keycode
	return event


static func _wheel(button: MouseButton) -> InputEventMouseButton:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button
	return event
