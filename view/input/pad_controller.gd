class_name PadController
extends Node
## Plays a mission with a pad (Phase 11), through the same pointer intents and
## orders the mouse uses (SelectionController), with its own cursor
## (PadCursor) in place of the mouse's. Every binding is rebindable
## (InputBindings.PAD_*); the defaults, for an Xbox layout:
## - Left stick: the cursor. It slows over a unit and, let go near one, sticks
##   to it. Pushed against the edge of the screen it pans the camera.
## - Right stick: pans the camera. LT / RT: orbit it. R3: tap to center on the
##   selection; hold it and the right stick zooms instead of panning.
## - A: tap to select what is under the cursor (nothing: select none); hold
##   and move to draw a box; tap twice to take every unit of that type on
##   screen; hold still on a unit to add it to the selection or take it out.
## - X: the order at the cursor, as a right click gives it (a move, an errand,
##   or the order armed from the order wheel). Hold X and move the cursor to
##   set the formation's facing, as a right drag does.
## - B: drops what is under way (a wheel, an armed order, a facing drag), else
##   closes the overhead map or leaves the control bar, else selects none.
## - Y: the special (InputBindings.ABILITY, handled by SelectionController).
## - LB held: the formation wheel (the left stick picks one, the right stick
##   turns the formation); RB held: the order wheel (attack-move, ground
##   attack, waypoints, guard, scatter, retreat, stop, select all). Let go to
##   choose.
## - D-pad left / right: the previous or next group slot, recalled if saved;
##   up held: save the selection there; down held: empty it.
## - View: tap for the overhead map (A there moves the camera, X sends the
##   selection, attack-moving if that was armed from the order wheel; the
##   cursor doesn't stick to units there); hold to show every health bar.
## - L3: put focus on the control bar (the D-pad moves it, A presses; B or L3
##   leaves); Menu: the pause menu (PauseMenu).
## Buttons are read from their events, not by polling, so a frame stepped by
## hand (a test) sees every press once; the sticks and triggers are polled.
## Nothing here runs while the pause menu is open: it is driven by focus.

const CURSOR_SPEED: float = 1.1
## The cursor's speed over a unit, in parts of its speed.
const NEAR_UNIT_SPEED: float = 0.45
## Pixels from a unit's middle within which the cursor slows and sticks.
const SNAP_RADIUS: float = 28.0
## Pixels from the screen's edge at which pushing on pans the camera.
const EDGE_MARGIN: float = 4.0
## Pixels the cursor must move with A held to draw a box.
const DRAG_THRESHOLD: float = 8.0
## Seconds A must be held still on a unit to add or drop it.
const LONG_PRESS: float = 0.5
## Seconds between two taps of A that select by type.
const DOUBLE_TAP: float = 0.35
## Seconds the D-pad's up or down is held to save or empty a group.
const GROUP_HOLD: float = 0.8
## Seconds View or R3 may be held and still count as a tap.
const TAP: float = 0.3
## The right stick turns the formation a step when pushed past FLICK, and
## again only after coming back under REARM.
const FLICK: float = 0.7
const REARM: float = 0.3

const ORDER_WHEEL: PackedStringArray = [
	"Attack-move", "Ground attack", "Waypoints", "Guard", "Scatter", "Retreat", "Stop", "Select all",
]

enum Wheel { NONE, FORMATION, ORDER }

var cursor: PadCursor
var wheel: RadialMenu
## The strip naming the pad's buttons, shown while the pad is in use.
var hints: RichTextLabel
## The cursor's speed, in parts of CURSOR_SPEED (Settings > Controller).
var cursor_speed_scale: float = 1.0
## Whether the cursor slows over units and sticks to them.
var snap: bool = true

var _main: MainView
var _controller: SelectionController
var _camera: RtsCamera
var _map: OverheadMap
var _bar: ControlBar
var _clock: float = 0.0
var _placed: bool = false
var _was_moving: bool = false
var _a_down: bool = false
var _a_at: Vector2
var _a_held: float = 0.0
var _a_box: bool = false
var _a_done: bool = false
var _last_tap: float = -100.0
var _last_tap_at: Vector2
var _x_down: bool = false
var _wheel: Wheel = Wheel.NONE
var _rotate_armed: bool = true
var _slot: int = 0
var _up_held: float = -1.0
var _down_held: float = -1.0
var _view_held: float = -1.0
var _r3_held: float = -1.0
var _r3_zoomed: bool = false
var _bar_focus: bool = false


## Builds the cursor and the wheel under `hud` and starts listening.
func setup(
	main: MainView, controller: SelectionController, camera: RtsCamera, map: OverheadMap,
	bar: ControlBar, hud: Node
) -> void:
	_main = main
	_controller = controller
	_camera = camera
	_map = map
	_bar = bar
	wheel = RadialMenu.new()
	wheel.name = "PadWheel"
	hud.add_child(wheel)
	hints = RichTextLabel.new()
	hints.name = "PadHints"
	hints.bbcode_enabled = true
	hints.fit_content = true
	hints.autowrap_mode = TextServer.AUTOWRAP_OFF
	hints.scroll_active = false
	hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hints.focus_mode = Control.FOCUS_NONE
	hints.add_theme_constant_override("outline_size", 4)
	hints.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.05))
	hud.add_child(hints)
	cursor = PadCursor.new()
	cursor.name = "PadCursor"
	hud.add_child(cursor)
	Pointer.pad_cursor = cursor
	InputDeviceTracker.tracker().changed.connect(_on_device_changed)
	_on_device_changed(InputDeviceTracker.tracker().current)


func _exit_tree() -> void:
	if Pointer.pad_cursor == cursor:
		Pointer.pad_cursor = null


## True while the control bar has the pad's focus.
func has_bar_focus() -> bool:
	return _bar_focus


## The group slot the D-pad is on.
func group_slot() -> int:
	return _slot


## Moves the cursor (viewport pixels), as the stick would.
func place_cursor(at: Vector2) -> void:
	cursor.at = _clamped(at)
	_placed = true


func _process(delta: float) -> void:
	_clock += delta
	if _controller == null:
		return
	_place_hints()
	_camera.pad_pan = Vector2.ZERO
	_camera.pad_orbit = 0.0
	_camera.pad_zoom = 0.0
	if not _in_play() or _bar_focus:
		return
	var stick: Vector2 = Input.get_vector(
		InputBindings.PAD_CURSOR_LEFT, InputBindings.PAD_CURSOR_RIGHT,
		InputBindings.PAD_CURSOR_UP, InputBindings.PAD_CURSOR_DOWN
	)
	if _wheel != Wheel.NONE:
		wheel.point(stick)
		if _wheel == Wheel.FORMATION:
			_turn_with_right_stick()
		return
	_move_cursor(stick, delta)
	_drive_camera(stick)
	_hold_buttons(delta)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventJoypadButton or event is InputEventJoypadMotion):
		return
	if _controller == null or not _in_play():
		return
	if _bar_focus:
		if event.is_action_pressed(InputBindings.CANCEL) or event.is_action_pressed(InputBindings.PAD_BAR_FOCUS):
			set_bar_focus(false)
			get_viewport().set_input_as_handled()
		return
	if _handle(event):
		get_viewport().set_input_as_handled()


# A pad button's event. True if it was this controller's.
func _handle(event: InputEvent) -> bool:
	if _wheel != Wheel.NONE:
		return _handle_wheel(event)
	if event.is_action_pressed(InputBindings.PAD_SELECT):
		_a_press()
		return true
	if event.is_action_released(InputBindings.PAD_SELECT):
		_a_release()
		return true
	if event.is_action_pressed(InputBindings.PAD_ORDER):
		_x_press()
		return true
	if event.is_action_released(InputBindings.PAD_ORDER):
		_x_release()
		return true
	if event.is_action_pressed(InputBindings.CANCEL):
		_back()
		return true
	if event.is_action_pressed(InputBindings.PAD_FORMATION_WHEEL):
		_open_wheel(Wheel.FORMATION)
		return true
	if event.is_action_pressed(InputBindings.PAD_ORDER_WHEEL):
		_open_wheel(Wheel.ORDER)
		return true
	if event.is_action_pressed(InputBindings.PAD_GROUP_PREV):
		_step_group(-1)
		return true
	if event.is_action_pressed(InputBindings.PAD_GROUP_NEXT):
		_step_group(1)
		return true
	if event.is_action_pressed(InputBindings.PAD_GROUP_SAVE):
		_up_held = 0.0
		return true
	if event.is_action_released(InputBindings.PAD_GROUP_SAVE):
		_up_held = -1.0
		return true
	if event.is_action_pressed(InputBindings.PAD_GROUP_CLEAR):
		_down_held = 0.0
		return true
	if event.is_action_released(InputBindings.PAD_GROUP_CLEAR):
		_down_held = -1.0
		return true
	if event.is_action_pressed(InputBindings.PAD_VIEW):
		_view_held = 0.0
		return true
	if event.is_action_released(InputBindings.PAD_VIEW):
		_view_release()
		return true
	if event.is_action_pressed(InputBindings.PAD_BAR_FOCUS):
		set_bar_focus(true)
		return true
	if event.is_action_pressed(InputBindings.PAD_CENTER):
		_r3_held = 0.0
		_r3_zoomed = false
		return true
	if event.is_action_released(InputBindings.PAD_CENTER):
		if _r3_held >= 0.0 and _r3_held < TAP and not _r3_zoomed:
			_main.center_on_selection()
		_r3_held = -1.0
		return true
	return false


# ---- A: select ---------------------------------------------------------------


func _a_press() -> void:
	if _map.visible:
		_map.click_at(cursor.at, false)
		return
	_a_down = true
	_a_at = cursor.at
	_a_held = 0.0
	_a_box = false
	_a_done = false


func _a_release() -> void:
	if not _a_down:
		return
	_a_down = false
	if _a_box:
		_controller.end_box_preview()
		_controller.box_select(Rect2(_a_at, cursor.at - _a_at).abs(), false)
		return
	if _a_done:
		return
	if _clock - _last_tap <= DOUBLE_TAP and _last_tap_at.distance_to(cursor.at) <= SNAP_RADIUS:
		_controller.select_type_at(cursor.at, false)
		_last_tap = -100.0
		return
	_controller.select_at(cursor.at, false)
	_last_tap = _clock
	_last_tap_at = cursor.at


# ---- X: order ----------------------------------------------------------------


func _x_press() -> void:
	if _map.visible:
		var attack: bool = _controller.armed_order == SelectionController.ArmedOrder.ATTACK_MOVE
		if _map.click_at(cursor.at, true, attack) and attack:
			_controller.arm(SelectionController.ArmedOrder.NONE)
		return
	if _controller.armed_order != SelectionController.ArmedOrder.NONE:
		_controller.place_armed(cursor.at)
		return
	_x_down = true
	_controller.begin_facing(cursor.at, false, false)


func _x_release() -> void:
	if not _x_down:
		return
	_x_down = false
	_controller.end_facing(cursor.at)


# ---- B: back -----------------------------------------------------------------


func _back() -> void:
	if _x_down:
		_x_down = false
		_controller.cancel_facing()
	elif _a_box:
		_a_down = false
		_a_box = false
		_controller.end_box_preview()
	elif _controller.armed_order != SelectionController.ArmedOrder.NONE:
		_controller.arm(SelectionController.ArmedOrder.NONE)
	elif _map.visible:
		_map.toggle()
	else:
		_controller.deselect()


# ---- the wheels --------------------------------------------------------------


func _open_wheel(kind: Wheel) -> void:
	_wheel = kind
	_rotate_armed = true
	if kind == Wheel.FORMATION:
		var names: PackedStringArray = PackedStringArray(Formations.DISPLAY_NAMES)
		wheel.open(names, "Right stick: turn the formation")
	else:
		wheel.open(ORDER_WHEEL)


func _handle_wheel(event: InputEvent) -> bool:
	var formation: bool = _wheel == Wheel.FORMATION
	var shoulder: StringName = InputBindings.PAD_FORMATION_WHEEL if formation else InputBindings.PAD_ORDER_WHEEL
	if event.is_action_released(shoulder) or event.is_action_pressed(InputBindings.PAD_SELECT):
		_close_wheel(true)
		return true
	if event.is_action_pressed(InputBindings.CANCEL):
		_close_wheel(false)
		return true
	# Everything else waits until the wheel is closed.
	return event is InputEventJoypadButton


func _close_wheel(choose: bool) -> void:
	var kind: Wheel = _wheel
	_wheel = Wheel.NONE
	var choice: int = wheel.close()
	if not choose or choice < 0:
		return
	if kind == Wheel.FORMATION:
		_controller.set_formation(choice as Formations.Kind)
		return
	match choice:
		0:
			_controller.arm(SelectionController.ArmedOrder.ATTACK_MOVE)
		1:
			_controller.arm(SelectionController.ArmedOrder.GROUND_ATTACK)
		2:
			_controller.arm(SelectionController.ArmedOrder.WAYPOINT)
		3:
			_controller.guard_selected()
		4:
			_controller.scatter_selected()
		5:
			_controller.retreat_selected()
		6:
			_controller.stop_selected()
		7:
			_controller.select_all_visible()


# The right stick, flicked sideways, turns the formation a step.
func _turn_with_right_stick() -> void:
	var x: float = Input.get_axis(InputBindings.PAD_PAN_LEFT, InputBindings.PAD_PAN_RIGHT)
	if _rotate_armed and absf(x) >= FLICK:
		_controller.rotate_formation(1 if x > 0.0 else -1)
		_rotate_armed = false
	elif absf(x) < REARM:
		_rotate_armed = true


# ---- groups, views -----------------------------------------------------------


func _step_group(direction: int) -> void:
	_slot = posmod(_slot + direction, UnitSelection.GROUP_COUNT)
	var number: int = (_slot + 1) % UnitSelection.GROUP_COUNT
	if _controller.selection.group(_slot).is_empty():
		_controller.notice.emit("Group %d (empty)" % number)
	else:
		_controller.recall_group(_slot)
		_controller.notice.emit("Group %d" % number)


func _view_release() -> void:
	if _view_held < 0.0:
		return
	if _view_held < TAP:
		_map.toggle()
	else:
		_controller.show_health_held(false)
	_view_held = -1.0


## Puts the pad's focus on the control bar (on), or gives it back to the game.
func set_bar_focus(on: bool) -> void:
	if on == _bar_focus:
		return
	_bar_focus = on
	_main.set_hud_focus(on)
	cursor.visible = InputDeviceTracker.tracker().is_pad() and not on


func _hold_buttons(delta: float) -> void:
	if _a_down:
		_a_held += delta
		if not _a_box and _a_at.distance_to(cursor.at) > DRAG_THRESHOLD:
			_a_box = true
		if _a_box:
			_controller.preview_box(_a_at, cursor.at)
		elif not _a_done and _a_held >= LONG_PRESS:
			_a_done = true
			var unit_id: int = _controller.unit_at(cursor.at)
			if unit_id >= 0:
				_controller.selection.toggle(unit_id)
	if _x_down:
		_controller.update_facing(cursor.at)
	if _up_held >= 0.0:
		_up_held += delta
		if _up_held >= GROUP_HOLD:
			_up_held = -1.0
			_controller.save_group(_slot)
			_controller.notice.emit("Group %d saved" % ((_slot + 1) % UnitSelection.GROUP_COUNT))
	if _down_held >= 0.0:
		_down_held += delta
		if _down_held >= GROUP_HOLD:
			_down_held = -1.0
			_controller.selection.clear_group(_slot)
			_controller.notice.emit("Group %d cleared" % ((_slot + 1) % UnitSelection.GROUP_COUNT))
	if _view_held >= 0.0:
		_view_held += delta
		if _view_held >= TAP:
			_controller.show_health_held(true)
	if _r3_held >= 0.0:
		_r3_held += delta


# ---- the cursor and the camera -----------------------------------------------


func _move_cursor(stick: Vector2, delta: float) -> void:
	var view: Vector2 = get_viewport().get_visible_rect().size
	if not _placed:
		place_cursor(view * 0.5)
	# Over the overhead map the units are dots: nothing to stick to.
	var sticky: bool = snap and not _map.visible
	if stick == Vector2.ZERO:
		if _was_moving and sticky:
			# Let go: stick to a unit close by.
			var unit_point: Vector2 = _controller.nearest_unit_point(cursor.at, SNAP_RADIUS)
			if unit_point != Vector2.INF:
				cursor.at = _clamped(unit_point)
		_was_moving = false
		cursor.snapped = sticky and _controller.nearest_unit_point(cursor.at, 2.0) != Vector2.INF
		return
	_was_moving = true
	cursor.snapped = false
	var speed: float = CURSOR_SPEED * cursor_speed_scale * view.y * stick.length_squared()
	if sticky and _controller.nearest_unit_point(cursor.at, SNAP_RADIUS) != Vector2.INF:
		speed *= NEAR_UNIT_SPEED
	cursor.at = _clamped(cursor.at + stick.normalized() * speed * delta)


func _drive_camera(cursor_stick: Vector2) -> void:
	var pan: Vector2 = Input.get_vector(
		InputBindings.PAD_PAN_LEFT, InputBindings.PAD_PAN_RIGHT,
		InputBindings.PAD_PAN_FORWARD, InputBindings.PAD_PAN_BACK
	)
	if _r3_held >= 0.0:
		# R3 held: the right stick zooms (up, in).
		if absf(pan.y) > 0.0:
			_r3_zoomed = true
		_camera.pad_zoom = -pan.y
		pan = Vector2.ZERO
	var camera_pan: Vector2 = Vector2(pan.x, -pan.y)
	# The cursor pushed against an edge pans that way.
	var view: Vector2 = get_viewport().get_visible_rect().size
	if cursor.at.x <= EDGE_MARGIN and cursor_stick.x < 0.0:
		camera_pan.x += cursor_stick.x
	elif cursor.at.x >= view.x - EDGE_MARGIN and cursor_stick.x > 0.0:
		camera_pan.x += cursor_stick.x
	if cursor.at.y <= EDGE_MARGIN and cursor_stick.y < 0.0:
		camera_pan.y -= cursor_stick.y
	elif cursor.at.y >= view.y - EDGE_MARGIN and cursor_stick.y > 0.0:
		camera_pan.y -= cursor_stick.y
	_camera.pad_pan = camera_pan.limit_length(1.0)
	_camera.pad_orbit = Input.get_axis(InputBindings.PAD_ORBIT_LEFT, InputBindings.PAD_ORBIT_RIGHT)


# The hint strip, above the control bar's right end, while the pad is in use.
func _place_hints() -> void:
	var shown: bool = InputDeviceTracker.tracker().is_pad() and _in_play()
	hints.visible = shown
	if not shown:
		return
	var text: String = InputPrompts.pad_hints()
	if hints.text != text:
		hints.text = text
		hints.reset_size()
	var view: Vector2 = get_viewport().get_visible_rect().size
	var bottom: float = _bar.position.y if _bar != null else view.y
	hints.position = Vector2(maxf(view.x - hints.size.x - 12.0, 0.0), bottom - hints.size.y - 6.0)


func _clamped(at: Vector2) -> Vector2:
	var view: Vector2 = get_viewport().get_visible_rect().size
	return at.clamp(Vector2.ZERO, view - Vector2.ONE)


# True while the game is the pad's to play: no pause menu open, and the scene
# still has its world.
func _in_play() -> bool:
	return _main != null and _main.world != null and not _main.pause_menu().is_open()


func _on_device_changed(device: int) -> void:
	var pad: bool = device == InputBindings.Device.PAD
	if pad and not _placed and is_inside_tree():
		place_cursor(get_viewport().get_mouse_position())
	elif not pad and _placed and is_inside_tree() and not OS.has_feature("web") and DisplayServer.get_name() != "headless":
		# Back to the mouse: where the pad's cursor was (a browser won't move it).
		Input.warp_mouse(cursor.at)
	cursor.visible = pad and not _bar_focus
