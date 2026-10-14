class_name InputDeviceTracker
extends Node
## The InputDevice autoload: which kind of device the player used last, the
## keyboard and mouse (KBM) or a pad (PAD), so the prompts name the right
## buttons (InputPrompts) and the right pointer is shown. Any key, mouse
## button or real mouse movement makes it KBM; any pad button or a stick or
## trigger pushed past STICK_SWITCH makes it PAD. It only watches: it never
## consumes an event.
##
## On PAD the system pointer is hidden and the pad's cursor (PadCursor) shown;
## back on KBM the system pointer comes back where the pad's cursor was.
##
## A browser shows a pad to the page only once a button has been pressed on it
## (the Gamepad API's rule), so on the web nothing is connected until then;
## pad_connected() says whether any is.
##
## Reached through tracker() (or the static helpers), never by the autoload's
## name: a script run with `-s` (the capture and benchmark scripts, the pad
## playthrough) is compiled before the autoloads are registered, so the name
## isn't known to it. tracker() finds the autoload, or makes one.

## The device changed (InputBindings.Device).
signal changed(device: int)
## A pad was connected or disconnected.
signal pads_changed

## A stick or trigger counts as used past this.
const STICK_SWITCH: float = 0.35
## Mouse movement smaller than this (pixels) doesn't count: a nudged desk.
const MOUSE_SWITCH: float = 3.0

var current: InputBindings.Device = InputBindings.Device.KBM

static var _instance: InputDeviceTracker


## The tracker: the InputDevice autoload, or one made and put under the root
## if there is none.
static func tracker() -> InputDeviceTracker:
	if _instance != null and is_instance_valid(_instance):
		return _instance
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	var found: Node = tree.root.get_node_or_null("InputDevice") if tree != null else null
	if found is InputDeviceTracker:
		_instance = found
		return _instance
	_instance = InputDeviceTracker.new()
	_instance.name = "InputDevice"
	if tree != null:
		tree.root.add_child.call_deferred(_instance)
	return _instance


## True while a pad is the device in use.
static func pad_in_use() -> bool:
	return tracker().is_pad()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Input.joy_connection_changed.connect(func(_device: int, _connected: bool) -> void: pads_changed.emit())


func _input(event: InputEvent) -> void:
	note(event)


## Takes note of an event's device (called for every input event; tests call
## it directly).
func note(event: InputEvent) -> void:
	if event is InputEventJoypadButton:
		if (event as InputEventJoypadButton).pressed:
			use(InputBindings.Device.PAD)
	elif event is InputEventJoypadMotion:
		if absf((event as InputEventJoypadMotion).axis_value) >= STICK_SWITCH:
			use(InputBindings.Device.PAD)
	elif event is InputEventKey or event is InputEventMouseButton:
		if event.is_pressed():
			use(InputBindings.Device.KBM)
	elif event is InputEventMouseMotion:
		if (event as InputEventMouseMotion).relative.length() >= MOUSE_SWITCH:
			use(InputBindings.Device.KBM)


## Makes `device` the current one, telling everyone if it changed.
func use(device: InputBindings.Device) -> void:
	if device == current:
		return
	current = device
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN if device == InputBindings.Device.PAD else Input.MOUSE_MODE_VISIBLE
	changed.emit(device)


func is_pad() -> bool:
	return current == InputBindings.Device.PAD


## True if any pad is connected (on the web: has had a button pressed).
func pad_connected() -> bool:
	return not Input.get_connected_joypads().is_empty()
