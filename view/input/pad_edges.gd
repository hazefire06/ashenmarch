class_name PadEdges
extends RefCounted
## Presses and releases of pad actions that may be bound to a stick or a
## trigger as well as to a button (Settings > Controller allows either). A
## button sends one event to press and one to let go; an axis sends a stream
## while it moves, and every event past the deadzone "is pressed". feed() each
## event first; pressed() and released() then say whether this event took the
## action across the line, once, whatever sent it.

var _actions: Array[StringName] = []
var _down: Dictionary[StringName, bool] = {}
var _went_down: Array[StringName] = []
var _went_up: Array[StringName] = []


func _init(actions: Array[StringName]) -> void:
	_actions = actions


## Takes note of an event: for an axis, which actions it took across.
func feed(event: InputEvent) -> void:
	_went_down.clear()
	_went_up.clear()
	if not event is InputEventJoypadMotion:
		return
	for action: StringName in _actions:
		if not event.is_action(action):
			continue
		var down: bool = event.is_action_pressed(action)
		var was: bool = _down.get(action, false)
		_down[action] = down
		if down and not was:
			_went_down.append(action)
		elif was and not down:
			_went_up.append(action)


## True if the event fed last pressed the action (a button's press, or an
## axis crossing into it).
func pressed(event: InputEvent, action: StringName) -> bool:
	if event is InputEventJoypadMotion:
		return _went_down.has(action)
	return event.is_action_pressed(action)


## True if the event fed last let the action go.
func released(event: InputEvent, action: StringName) -> bool:
	if event is InputEventJoypadMotion:
		return _went_up.has(action)
	return event.is_action_released(action)


## Forgets which axes are held (a menu took over).
func reset() -> void:
	_down.clear()
	_went_down.clear()
	_went_up.clear()
