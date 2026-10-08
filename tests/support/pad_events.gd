class_name PadEvents
extends RefCounted
## Synthetic pad input for tests, sent the way a real pad's is: into Input
## (parse_input_event, then flush_buffered_events, so it is dispatched at
## once), which updates the action state the sticks are polled from and
## delivers the event through the viewport (_input, the GUI, _unhandled_input)
## like any other. Pad state is global: release_all() at the end of a test.

const DEVICE: int = 0
const AXES: Array[JoyAxis] = [
	JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y, JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y,
	JOY_AXIS_TRIGGER_LEFT, JOY_AXIS_TRIGGER_RIGHT,
]


static func press(button: JoyButton) -> void:
	_send_button(button, true)


static func release(button: JoyButton) -> void:
	_send_button(button, false)


## A press and a release.
static func tap(button: JoyButton) -> void:
	press(button)
	release(button)


## Holds an axis at a value (-1..1; 0 lets it go).
static func axis(which: JoyAxis, value: float) -> void:
	var event: InputEventJoypadMotion = InputEventJoypadMotion.new()
	event.device = DEVICE
	event.axis = which
	event.axis_value = value
	_send(event)


## Holds the left stick at (x, y): right and down positive, as a pad reports.
static func left_stick(direction: Vector2) -> void:
	axis(JOY_AXIS_LEFT_X, direction.x)
	axis(JOY_AXIS_LEFT_Y, direction.y)


static func right_stick(direction: Vector2) -> void:
	axis(JOY_AXIS_RIGHT_X, direction.x)
	axis(JOY_AXIS_RIGHT_Y, direction.y)


## Every axis back to rest and every button up, and the keyboard and mouse in
## use again.
static func release_all() -> void:
	for which: JoyAxis in AXES:
		axis(which, 0.0)
	for button: int in JOY_BUTTON_SDL_MAX:
		if Input.is_joy_button_pressed(DEVICE, button as JoyButton):
			release(button as JoyButton)
	InputDeviceTracker.tracker().use(InputBindings.Device.KBM)


static func _send_button(button: JoyButton, pressed: bool) -> void:
	var event: InputEventJoypadButton = InputEventJoypadButton.new()
	event.device = DEVICE
	event.button_index = button
	event.pressed = pressed
	event.pressure = 1.0 if pressed else 0.0
	_send(event)


static func _send(event: InputEvent) -> void:
	Input.parse_input_event(event)
	Input.flush_buffered_events()
